# Persistence, from a clean slate

*2026-09-17. A requirements-first redesign of OC-LuaJIT's persistence, run after
the first in-game persistence failure and the design rounds that followed it.
Ten agents: one derived requirements from the code and OC's contract, three
surveyed prior art (Lua lineage, general serialisation, sibling architectures),
four designed from different premises, two judged against the requirements.
Every measurement below was re-run on distinct binaries with recorded md5s.*

## The question

Two design rounds had converged on **unconditional deferral + nil holes +
back-patching + a retry drain** for the defect where a `__persist` recipe runs
before the objects it needs exist. It worked — all four target cases flipped,
212 unit tests and 19 for-in cases green — but it carried costs that were
measured rather than hypothetical: a parked recipe re-runs `userdata.load` on
the Java side (2× loads, one orphaned host Value per proxy), retry is safe only
for recipes that read before they publish, retry catches only recipes that
*crash* on a nil hole, and a hand-edited blob is a quadratic lever.

The question for this pass: starting from *what persistence must do* rather
than from the converged design, is there something better?

**Answer: yes, and the original author of Eris proposed it in 2014.**

## What "full working persistence" means

Derived from `Machine.save`/`NativeLuaArchitecture.save`, the `Architecture.load`
contract, and what OC's own PUC path guarantees. Twelve must-haves; the ones that
shaped the decision:

- **M1.** A blob from *any* state stock OpenOS can be in — including one holding
  wrapped-userdata proxies such as an open file handle — unpersists into the
  same object graph. Every recipe runs only once everything it reads at load
  time exists.
- **M2.** Restored proxies are indistinguishable from PUC-restored ones:
  `getmetatable(proxy) == "userdata"`, methods reach a host Value rebuilt by
  `userdata.load`, exactly one host Value instantiated per proxy, registered in
  the one fresh registry.
- **M3.** Failure is loud and contained, never silent. A restore that completes
  with wrong contents is the one forbidden outcome.
- **M4.** No write-only blobs: a persist → unpersist → persist oracle over the OC
  shape corpus.
- **M5.** Both OC roots (`_kernel` at index 1, `_stack` at index 2) round-trip
  and leave the stack in the shape `runThreaded` asserts.
- **M7.** Observable in-game acceptance on our architecture with a userdata *in*
  the blob, with a sample sequence number so a dead machine's repainted screen
  cannot pass.

**What the bar for host handles is.** OC's own PUC path splits by Value class,
and that is the bar: an **open file handle is usable after restore** —
`HandleValue` restores `(owner, handle)` from NBT, the component restores the
owner set, the filesystem reopens at the saved position, and OpenOS keeps
reading (`boot/01_process.lua:81-88` pins every handle). A **TCP socket is
not**, by design — no `load` override, every call throws "connection lost",
which OpenOS surfaces as `nil, reason`. So "full" means parity with the 5.2/5.3
CPUs on every state OpenOS can produce, never worse in any silent way, and every
deviation from resume is a loud Stopped machine with a named cause.

**Explicit non-goals:** JIT traces (flushed on every save), PRNG state, live
sockets, raw userdata/cdata, bug-for-bug parity with stock's own holes.

**Two things the requirements list got wrong**, caught by the skeptic judge:

1. *M12's remedy is dangerous.* "Never call `userdata.load` more than once per
   proxy without disposing the extra" — but `HandleValue.dispose` is
   `fs.close(context, handle)`, which closes the file the *surviving* proxy
   still holds. A duplicate must be dropped, never disposed.
2. *The `_stack` blob is a second kernel universe on this codec.* The sync-call
   closure at `machine.lua:1116-1122` captures `args`/`target` as open upvalues
   of `invoke`'s frame, so `elj_find_owner_any` pulls the whole kernel thread
   into `persist(2)`. Measured: stack blob == kernel blob, and 2 extra
   `userdata.load` calls per restore. This violates M2 under *every* design
   whenever a save lands between a sync-call yield and its resume — routine
   under `cat`, because `FileSystem.read` is limit=15 per tick and the 16th
   read yields a SynchronizedCall. **This needs its own must-have and its own
   fix**, scheduled before any dispose mechanism.

## Prior art

### The Lua lineage — the recipe was never deferred, and the fix was proposed in 2014

Neither Pluto (2004) nor Eris (2013) defers a `__persist` recipe: Pluto's
`unpersistspecialtable` is `unpersist(upi); lua_call(L,0,1)` and Eris's
`u_special` is the same call made the instant the record is read. Upstream
detects *self*-reference loudly ("invalid reference #%d. this usually means a
special persistence callback of a table referenced said table") and detects a
partially-built *dependency* not at all. fnuecke's in-code assumption is
explicit: *"We can set this to nil at first, because there's no way the special
function would access this."*

When a user hit it — **Eris issue #9, 2014-07-02** — fnuecke called it a
documented constraint, improved the message, and proposed but never built the
fix:

> *"'pre-generating' the table, and passing it to the closure that should
> restore the table, instead of having that return a new table ... For userdata
> that wouldn't work."*

It wouldn't work for him because he didn't control the userdata wrapper's
recipe. We do — `machine.lua` is patched at six sites already. The design
chosen below is that proposal, twelve years late, with the kernel side he
couldn't change.

### General serialisation — every mature system answers this the same way

Common Lisp's `make-load-form` states it as law: a *creation form* builds
identity from immediate data only ("there must not be any circular dependencies
in creation forms"), and an *initialization form* fills contents later
("Initialization forms are not subject to any restriction against circular
dependencies, which is the reason that initialization forms exist"). Ruby's
`marshal_load` (allocate, register, populate), Java's `Externalizable` (no-arg
constructor then `readExternal`), Kryo ("reference must first be called with the
parent object" before reading children), Boost's `load_construct_data`, Fuel and
Parcels are the same design. Post-graph callbacks exist everywhere (.NET
`IDeserializationCallback`, Java `readResolve`), and **no mature system
guarantees ordering among them** — .NET documents none, Java offers only an
author-supplied priority. That is consistent with L8: order is a hint, never the
correctness mechanism.

.NET's `ObjectManager` is the converged design shipped elsewhere: nil holes are
unresolved fixups, back-patch is `DoFixups`, the retry drain is the progress
loop, the pass cap is `MaxReferenceDepth`. Its `ResolveObjectReference` catching
`NullReferenceException` and "coming back and trying again later" is precisely
the crash-only retry, hazard included. So the converged design was not wrong; it
was the *second-best* known pattern.

### Sibling architectures — three tiers, and which tier predicts survival

**Tier A, transparent whole-state persistence:** OC's own native Lua (Eris), the
mod's flagship differentiator, plus every emulated-CPU architecture (OpenPython
dumps registers + memory + a host-side Value map; Thistle, OCMOS, OC2/sedna
"fully persistable"). **Tier B, memory image at quiescent points, cost pushed
onto programs:** OC-Wasm's snapshot is `{binary, globals, linear memory,
execute buffer}` and *no call stack*, because `run` must return within the
timeout — programs are written "as a large state machine". **Tier C, none:**
ComputerCraft, and CCLuaJIT changed nothing about it.

Two transferable ideas from OC-Wasm worth keeping in reserve: its
`DescriptorTable`/`ValuePool` keeps the **host-handle registry outside the
guest graph**, restored before the guest, keyed by small integers — which
removes the KIND-2 dependency at the source rather than ordering around it; and
a **pool restored exactly once by identity** makes host-object duplication
impossible regardless of recipe order. Neither is needed for the chosen design,
both are the right shape if the registry ever needs to leave the Lua graph.

## Four designs

| # | premise | verdict |
|---|---|---|
| **1. Shell-fill** | allocate-then-populate: the reader creates the *final* table at record time; the recipe fills it after the graph exists | **Chosen by both judges.** No holes, no back-patch, no retry, no destination recording. 94 diff lines. Prototype built, measured, discriminates. |
| 2. Hoisted wrapper prelude | fix it in the kernel: OC's wrapper code becomes host permanents, everything else refused at write | Same idea as 4 at a stricter enforcement level. Fixes the instance via three unexercised host mechanisms. Not taken. |
| 3. Reach-ordered single-pass drain | unconditional deferral + nil holes + back-patch, with a **reachability walker** replacing retry | Correct where retry is silent or double-runs; drops the pass loop and the double Java load. But its silent mode moves into the walker (delete one edge → silent wrong contents), and four destination kinds still unimplemented. **Its walker is grafted onto 1.** |
| 4. Registry rebuild | proxies as plain data, one KIND-1 recipe per blob, registry rebuilt from the wire's structural nesting | Cheapest. Relies on nesting unenforced; its snapshot recipe resurrects garbage. **Its test rig is grafted onto 1.** |

All four independently **dropped retry** and measured that nothing needs it:
D3 runs each recipe 1/1/1 where retry gave 2; D1's `udload` is called exactly
once; D4 loads twice for two proxies. The skeptic judge's summary: *"The clean
slate did NOT rediscover the converged design; it dismantled it."*

Scores (judge 1 / judge 2), higher is better, silence = safety from silent
wrongness:

| design | must-haves | silence | completeness | cost |
|---|---|---|---|---|
| 1 shell-fill | 10/12 · 9/12 | 8 · 7 | 9 · 8 | 7 · 8 |
| 2 hoisted | 8/12 · 8/12 | 6 · 5 | 8 · 7 | 4 · 4 |
| 3 reach-ordered | 8/12 · 10/12 | 6 · 8 | 7 · 9 | 3 · 5 |
| 4 registry rebuild | 9/12 · 8/12 | 6 · 5 | 8 · 7 | 10 · 9 |

## The chosen design: shell-fill

### Mechanism

Reconstruction of a `__persist` special splits into two phases that need
nothing from each other:

1. **CREATE** needs no code. When `u_table`'s TABLE_SPECIAL arm reads the
   record, it does `lua_newtable` and registers that empty table under the
   special's reference id **as the object's final identity**. Every consumer —
   thread slots, literal tables, upvalues, table keys, `TAG_REF` — stores it
   exactly as it would store a literal table. Nothing is ever swapped, so L4
   (placeholders are poison) does not apply: **the shell is not a stand-in for
   the object, it *is* the object.** Raw metatable probes, `__eq`, table-key
   use and `__gc` are all correct-by-address.
2. **FILL** is the persisted closure called as `recipe(shell)`, exactly once,
   after the entire graph exists — after `unpersist` returns and the
   trailing-bytes check passes, so a truncated or crafted blob is refused
   before any recipe runs. The recipe populates the shell in place and returns
   nil or the shell.

The wire is unchanged; the writer (`p_table`, `persist_keyed`) is untouched.
One new fixed stack slot (`FILLIDX`), the TABLE_SPECIAL arm rewritten, one fill
loop, two refusals. Format bumps to 3 so old blobs are refused by fingerprint
before their old-protocol recipes could be.

### Refusals, each proven to fire

- A recipe that returns a fresh table instead of filling its argument (the
  upstream shape) — *"instead of filling its argument"*, naming the recipe's
  ordinal and byte offset.
- A recipe that leaves the shell without a metatable (inert or semi-inert).
- A special table used as another object's **metatable** during restore —
  LuaJIT's negative metamethod cache (`GCtab.nomm`) would be consulted on the
  empty shell. Source says the cache *is* invalidated on fill
  (`lj_tab_newkey`: `t->nomm = 0`), so this can be relaxed after a
  measurement; OC has no such shape, so refusing costs nothing today.
- A recipe whose environment is an unfilled shell.

### The kernel side — four anchored patch sites

- `wrapUserdataInto(proxy, data)` declared in the `:1075` group: the existing
  `wrapSingleUserdata` body, writing fields **before** `setmetatable` because
  `userdataWrapper.__newindex` routes to `udinvoke`.
- Registry recipe (`:1083-1089`): `function(self) setmetatable(self,
  wrappedUserdataMeta) end`.
- Proxy recipe (`:1156-1163`): `function(proxy) wrapUserdataInto(proxy,
  userdata.load(className, nbt)) end`.
- A by-name assertion for `wrapUserdataInto` in `build-kernel.sh`.

`wrapSingleUserdata`'s reuse scan (`:1193-1199`) is not needed on the restore
path: persist-time dedup by the reftable already collapses every reference to
one record, and every restored Value is a fresh Java object so `v == data`
can never match.

### What it resolves and what it inherits

**Resolves** L1–L7 and L9 outright: the recipe is never called mid-graph; every
destination receives the final table at write time; no stand-in, no key ever
removed and reinserted (no L5 ghost), one Java load per proxy, no
publish-before-read hazard because there is no second run, no quadratic lever
because there is no pass loop, and a KIND-2 content cycle between specials
either raises or is mode 1 below — never a drain that "gives up" silently.

**Inherits:** M4.4 (`_G` in fenvs), M4.5 (closure-over-`next`), the trace flush,
`kernelMemory` in NBT, and the `_stack` universe split above.

### Silent failure modes, stated adversarially

1. **Content dependency between specials.** Recipe A reads shell B's *fields*
   and tolerates nil → A completes wrong, no error. Fill order is descending
   id — a hint, not a guarantee. OC: impossible (the registry is written into,
   never read; the proxy reads only `className`/`nbt`). Third parties: cannot
   author recipes. **Closed by grafting D3's reachability walker as the
   fill-order oracle** (below); if deferred, it ships documented as an
   OC-kernel invariant, which is honest but is exactly the green-for-structural-
   reasons the project has been burned by.
2. A recipe that sets a metatable but fills the wrong fields (e.g. a future
   kernel edit forgets `proxy.type = "userdata"`). Contract; mitigated by f7's
   live-proxy probe.
3. The `_stack` blob universe split — pre-existing, needs its own fix.
4. A recipe calling `eris.persist` during fill sees unfilled shells as empty
   literals. Forbidden by contract; only a recipe author could reach it.
5. `u_permanent`'s `lua_gettable` on uperms honours `__index`; OC's uperms is a
   plain table. Flagged, left as is.

### Riskiest assumption

That OC's proxy reconstruction needs only the registry's **identity** and never
its contents — i.e. dropping the reuse scan on the restore path loses nothing.
If a Value class's `load()` ever returned a cached instance, two proxies would
persist for one Value where stock would have merged them, and `h1 == h2` would
silently differ from stock. `unwrapUserdata` would still be correct for both.

## Grafts

1. **From D3:** its reachability walker (~150 lines) as the fill-order oracle —
   compute which unfilled shells each recipe can reach over built objects, fill
   in dependency order, refuse mutual reach with both ordinals named. Ship with
   D3's negative control: delete the open-upvalue edge and the discriminator
   must go silent again.
2. **From D4:** promote its `rig.lua` to `serializer/tests/userdata.lua`, ported
   to the fill protocol. `RIG_MODE=orig` stays as the **negative control** —
   the only serializer-level test that reproduces the in-game error text on the
   shipping binary — and `RIG_MODE=shell` mirrors the patched kernel at
   `machine.lua`'s slot order including the index-2 closure. Plus its `udinvoke`
   nil-guard naming a Value-less proxy.
3. **From D2:** nothing mechanical. Its measurement that closed captures make
   the chain KIND-1 on the shipping binary is the confirmed explanation of why
   stock never hit this; its fixed-name perms tripwire goes into the post-pass.

## Build order

**Step 0 — the test that must fail first.** `serializer/tests/shell.lua`
case 1 is `poc2.lua` ported to the shell protocol: the exact OC chain at
`machine.lua`'s slot order. On the shipping binary it must fail with
`attempt to call upvalue 'wrapSingle' (a nil value)`; after the change it must
pass with load-count exactly 1. Cases 2–4 must each show a refusal firing:
legacy recipe → "instead of filling its argument"; inert recipe → "without a
metatable"; shell as metatable → "is the metatable of another object". The
existing `m2.lua:189-228` spkey cases go red for the first reason *before* they
are rewritten — that is the proof the refusal is live.

**Step 1 — serializer.** Judge 1's prototype `eris_lj_SHELL.c` (94 diff lines,
`SHELL.exe` md5 `83763275`) as the starting point. Verified independently on
2026-09-17: `shell.lua` fails 6/6 on the repo binary (`16e4f73c`) and 0/6 on
`SHELL.exe`; M1 82/82, M3 75/75, for-in all exact; m2 and contract red exactly
and only at their legacy-shape recipes.

**Step 2 — kernel.** The four anchored sites in `patch-machine-lua.lua`, the
by-name assertion, rewrite the four m2 spkey cases and contract's one to the
shell form.

**Step 3 — the walker graft**, with its negative control.

**Step 4 — the in-game gate.** OcljSmoke `f7` green with `f1b` green, plus the
negative control: new native with the *unpatched-recipe* kernel must come back
Stopped with "instead of filling its argument" in the log — proving both that
the check fires in the real host and that the kernel patch is load-bearing.

**Scheduled separately, before any dispose mechanism:** the `_stack` universe
split (persist(2) must not pull the kernel thread — either `LuaJITArchitecture`
persists indices 1 and 2 in one ref space, or the sync closure's kernel-frame
upvalues are written by value as stock does).

## What the clean slate added

Against the converged design: shells as final identity (which is what makes
the placeholder poisons vanish rather than get worked around); one linear pass
instead of a retry loop; the return-value and metatable post-conditions; the
metatable-of and fenv refusals; a writer that does not change; and the
recognition that OC's two recipes need only the registry's *identity*. The
reader change is 94 lines against ~330.

Against the requirements list: the `_stack` universe split, which no design
fixes and which violates M2 under all of them; and the dispose hazard, which
would have turned a fix into a use-after-close.

## Method notes

- Both judges built or re-ran prototypes rather than scoring specs; the
  recommendation rests on `SHELL.exe`, `ONCE.exe` and the rig, not on argument.
- Three instrument artifacts were caught and recorded in the course of the
  preceding rounds (stale binary from same-second `make`, rebuilding under a
  running suite, a layout-dependent repro that does not discriminate in one
  run). Force builds, distinct filenames, md5s on every measurement.
- The strongest single input was a 2014 GitHub issue. Search the lineage.
