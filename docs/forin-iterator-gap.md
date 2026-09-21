# Closing the for-in iterator gap

Status: **design; the kernel half is implemented.** Written 2026-09-01, after
the replay iterator (M3.1) landed and the bridge spike surfaced a conflict with
the `LUA52COMPAT` build flag. Updated 2026-09-19: the two platform instances
(`component.list`, census #1, and `componentProxy.__pairs`, census #3) are
closed by kernel sites 10–11 in `native/kernel/patch-machine-lua.lua` — T1 in
its snapshot form (walk an array by integer index; see "Recommended
sequencing"). T2 and T3 are not built. The residual is the OS-authored wrapper
(census #9; OpenOS's own `boot/04_component.lua` installs one on the `component`
library table), and the planned answer is the save-time diagnostic under "Open
questions", not another rewrite.

This note exists because the reasoning is easy to lose and expensive to redo.
The gap itself is documented in [../serializer/README.md](../serializer/README.md);
this is about how to close it.

## The gap

The replay iterator makes a coroutine suspended inside `for ... in pairs(t)`
restorable in another process, by snapshotting the keys the loop has not
reached and rewriting its hidden `(func, state, control)` triple. It finds
those loops by looking for the real `next` in the func slot
(`ffid == FF_next_N`) or an `LJ_KEYINDEX`-tagged control slot.

A loop whose iterator is a **Lua closure that wraps `next`** has neither
marker:

```lua
local function myiter(t, k) return next(t, k) end
for k, v in myiter, tbl do ... end          -- invisible to the scan
```

Its control slot is a plain key with exactly the same dependence on the
table's current hash layout, so it persists today and can resume against a
different node order in another process — silently visiting the wrong keys.

## Why inference cannot close it

The obvious fix — treat any Lua-closure iterator over a table state as
layout-dependent — is unsound, because that shape is **indistinguishable from
a legitimate custom iterator**:

```lua
local function sorted(t)                    -- deliberate, stable ordering
  local keys = {} ; for k in pairs(t) do keys[#keys+1] = k end
  table.sort(keys)
  local i = 0
  return function(tbl, _) i = i + 1 ; return keys[i], tbl[keys[i]] end
end
```

Rewriting *that* into a replay of `next`'s order would silently change the
program's semantics. The two cases are the same shape; only their intent
differs, and intent is not in the bytecode.

## Why "just don't enable LUA52COMPAT" is not the answer

The bridge spike recommended dropping `LUAJIT_ENABLE_LUA52COMPAT`, on the
grounds that honouring OpenComputers' `componentProxy.__pairs` would hand the
serializer exactly this shape.

That is almost certainly the wrong trade. **OpenComputers' own `machine.lua`
and OpenOS are Lua 5.2/5.3 code** — OC's native architecture runs JNLua with
`LUA_VERSION=52`, and [roadmap.md](roadmap.md)'s v1 already requires the
sandbox to report `_VERSION = "Lua 5.2"` and to shim `bit32`. Turning the
compat layer off to dodge a narrow serializer gap risks breaking the entire
ecosystem we exist to run.

**RESOLVED by the shape census** ([research/os-shape-census.md](research/os-shape-census.md)),
and the answer is better than feared. `componentProxy.__pairs`
(`machine.lua:1269-1282`) is a two-phase closure over `next` with three
mutable upvalues, so it cannot simply *return* the raw `next` -- but it can be
restructured (`return next, self, nil`, or pre-flatten the fields into the
proxy). Measured 6/6 exact after that change versus 4/6 wrong before. Tier 1
therefore covers it.

The census also found a **second platform instance, and a shape this note did
not anticipate**: `component.list()` (`machine.lua:1309-1319`) is a **table
with `__call`** wrapping a `next`-closure, not a plain closure. Same fix
(`return next, list, nil`), also one line. Measured 18/20 and 20/20 pads
wrong before it -- and one pad visited the right *count* while having dropped
three components and duplicated three, which is precisely the failure mode
nothing ever reports.

So the tier analysis below stands, but the split moved: **Tier 1 covers
everything the PLATFORM generates.** What is left for Tier 2/3 is an OS
author's own iterators -- e.g. QuickOS's `lua_shell.lua:17-30`, which
reassigns its own `t` upvalue across `env` -> `_ENV` -> `package.loaded`
mid-walk and was the one measured case with no passing pad (20/20 wrong).

## A third category the tiers do NOT cover

Measured while turning the census into regression tests, and worth stating
plainly because it changes what "fix" can even mean.

The tiers above all assume the loop's traversal position lives in the **control
slot**, where the replay iterator can rewrite it. The platform's two instances
do not work that way. `component.list()` keeps its position in a **closure
upvalue**:

```lua
local function mklist(tbl)
  local key = nil                       -- the cursor, in an upvalue
  return setmetatable({}, { __call = function()
    key = next(tbl, key)
    if key ~= nil then return key, tbl[key] end
  end })
end
```

That upvalue holds an ordinary string key. It **round-trips perfectly** -- the
serializer does its job exactly right -- and the meaning still changes, because
the key's *position* in the rebuilt table differs. Measured in our own
cross-process suite (case `oclist`): **11 of 12 pads diverge**, with the save
succeeding every time.

**No serializer change can reach this.** There is nothing to detect: it is a
variable holding a key. It is the same category as AxisOS's `tostring(f)`
fingerprints -- ordinary program state that happens to encode a process-local
fact.

So for these shapes the fix is not a tier at all; it is to stop writing the
shape. `mklist` returning `next, tbl, nil` puts the cursor back in the control
slot, where the replay iterator handles it: case `oclist_fixed`, **12/12 pads
exact**. That promotes T1 from *cheapest option* to *the only possible fix* for
the platform's own iterators.

The general lesson, and it is the same one as the `tostring` case: **a
persistable program must not keep a hash-order-dependent cursor in ordinary
state.** That belongs in the OS-author contract, not in the serializer.

### The purest instance: no cursor, and no suspension at all

MineOS supplied a case with neither a stored cursor nor a live loop
([research/mineos-census.md](research/mineos-census.md)):

```lua
for w in pairs(icon.windows) do topmostWindow = w end   -- System.lua:2735-2739
topmostWindow:focus()
```

"Topmost" means "whatever `pairs()` happens to yield last", over a set keyed by
the window *table*. The loop **completes**; nothing is suspended; the replay
iterator never sees it; the serializer round-trips every value perfectly. The
meaning is read out of hash order *after* the restore. Measured cross-process,
40 round trips at each of 2/3/4/8/16 windows: **the focused window changed
40/40 every time**, with membership always exact, and divergence already at
pad=0. Controls carried: in-process stability 200/200 plus 20 fresh rebuilds
agreeing (so the invariant MineOS relies on is genuinely real in one process),
and an array-keyed negative control unchanged 16/16 while the pairs-last case
changed 16/16.

Note the keys are tables, so this is pointer hashing rather than string `sid` --
even less recoverable. Our entire for-in fix is **structurally irrelevant** to
this class. It is a contract item, and it is the strongest argument that the
contract has to ship *with* the feature.

### The rule is narrower than stated above

The matched pair that settles it, both measured with the same harness and a
yielding body: MineOS's own closure-over-`next` iterator (`filesystem.mounts`,
two mutable upvalues) scored **20/20 exact and order-exact**; `machine.lua`'s
structurally identical `component.list` scored **0/20**. Holding the iterator
and the body fixed and varying *only* whether the walked table is array-backed
or hash-backed reproduces the split (20/20 versus 1/20).

So the silent-gap condition is not "an iterator wrapping `next`" -- it is

> **an iterator wrapping `next` over a HASH-KEYED table.**

That is narrower, **statically checkable**, and it means an iterator over a
densely array-backed table (kept dense by `table.insert`/`table.remove`, as
MineOS's is) is safe by construction. It also shrinks what any future save-time
diagnostic would have to warn about.

## The axis these options live on

Every choice here trades along one line:

    silent-wrong  <-- (bad) ------------------- (bad) -->  over-refusal

Left, the user's world is corrupted quietly. Right, their computer's RAM state
is lost and it comes back switched off, loudly. Neither end is acceptable, and
the tiers below are all ways to buy coverage without paying at either end.

There is also an **orthogonal option: refuse.** Conservatively reject any
for-in loop over a table whose iterator is a Lua closure. That over-refuses —
it kills the `sorted` example above too — but it is *sound*, and it converts a
silent corruption into a loud failure. It is the cheapest thing on this page
and the correct fallback if none of the tiers ship.

## The three tiers

They are **layered, not alternatives.** Coverage is nested (T1 ⊂ T2 ⊂ T3), but
each is a different kind of solution, which is why more than one is worth
having.

| | mechanism | covers | cost |
|---|---|---|---|
| **T1** | *Prevent* — our sandbox never installs a wrapper | closures **we** install | free |
| **T2** | *Identify* — host declares "this wraps `next`" | closures the **host** knows | ~50 lines |
| **T3** | *Sidestep* — ask the iterator what comes next | **anything**, incl. user code | runs user code mid-save |

### T1 — return the raw `next` from any `__pairs` we install

If the sandbox's `__pairs` exists only to expose iteration, return `next`
itself rather than a wrapper. The loop then compiles to `ITERC` + `FF_next_N`
and the **existing** replay arm handles it, at zero cost.

Gated on the `componentProxy.__pairs` question above. Does nothing for user
code that writes its own wrapper.

### T2 — a host-declared registry of `next`-wrappers

All the replay machinery already exists. The only missing input is
*identification* — and the host has that knowledge, because it installed the
closure. Something like an `eris.settings` registry, or a marker reachable
from the closure, that lets `elj_forin_scan` accept a declared wrapper exactly
as it accepts `FF_next_N` today.

Still fails on a user program that writes `myiter` above, because the host has
never heard of that closure.

### T3 — enumerate by calling the iterator

At persist time, call `f(s, ctl)` repeatedly to collect the sequence the loop
would still produce, and replay *that*.

The elegant part: **T3 does not classify at all.** It records what the
iterator would do and replays it. For a layout-dependent wrapper that fixes
the bug; for the `sorted` iterator above, replaying the recorded sequence is
*identical behaviour*. It dissolves the classification problem rather than
solving it.

The dangerous part: it runs arbitrary user code in the middle of a save. The
iterator can

- raise an error (mid-persist, with the write buffer live),
- allocate without bound (under OC's per-machine memory ceiling),
- be impure — count its calls, touch a filesystem component, mutate state,
- be infinite: `for x in function() return 1 end do` collects keys forever.

So T3 needs a hard bound on the collected length, a protected call, and
probably an explicit opt-in. It is a last resort, not a default.

## Recommended sequencing

1. ~~**Settle `componentProxy.__pairs`.**~~ **Settled 2026-09-19.** It exists
   to present the proxy's own keys and then its `fields` sub-table as one flat
   walk, and it returns a Lua closure over `next` with a phase flag. Returning
   the raw `next` cannot express the second phase, and `component.list` must
   stay a callable table (`component.list("gpu")()` is idiomatic), so T1 took
   its snapshot form rather than the `return next, t, nil` form.
2. ~~**T1** if it fits~~ **Done 2026-09-19 as kernel sites 10–11:** each walk
   is snapshotted into an array walked by integer index — the position is a
   plain integer the replay never needs to see, and the walker's upvalues are
   an integer plus arrays, no function. `component.list` re-reads `list[key]`
   per step so a key cleared mid-walk is skipped as `next` would;
   `componentProxy.__pairs` snapshots both phases into one `{k, v}` array
   through the raw `next, self` triple (`pairs(self)` would recurse into the
   metamethod). `build-kernel.sh` asserts `snapshot walks=2` and
   `next( calls=0`. Gated by `fi-1/2/3` in the harness, fail-first with the
   sites cut out (restored walks 6/7 with a duplicate and 24/33, versus 7/7
   and 33/33 element-wise equal with them in), and by `oclist_snap` /
   `ocpairs_snap` in `run-forin.sh` (20/20 pads exact).
3. **T2** as the general answer for host-installed iterators.
4. **T3** only if the OS shape census turns up real iterators that need it.
5. **Refuse** as the fallback for anything still unhandled, so the residual is
   loud rather than silent.

The pattern generalises, and it has held for every hard call in this project:
**information we already have at the Java layer is cheaper than cleverness in
C.** Constraining the sandbox beats teaching the serializer another shape.

## The #9 diagnostic — design, 2026-09-19 (to ship with the next serializer bump)

What is left after sites 10–11 is the OS author's own `next`-wrapper (census
#9). It cannot be rewritten: at save time it is not soundly distinguishable
from a legitimate custom iterator with its own ordering. It can be *named*.

**Detection (persist side, in `elj_forin_scan`).** The scan already classifies
every live for-in triple by its control slot and func slot; the branch that
today `continue`s past a Lua-closure iterator is where the diagnostic hooks.
Condition: the func slot holds a Lua closure, the frame's position is inside
or at the loop (`inbody != 0`), and the closure *reaches `next`*:

- its prototype has a `BC_GGET` whose constant is the string `"next"` (the
  global lookup — the shape of OC's old `component.list`, of
  `componentProxy.__pairs`, of OpenOS's `component` library `__pairs`, and of
  QuickOS's `lua_shell`), or
- one of its upvalues holds the `next` fast function (`FF_next_N`; the
  `local next = next` idiom), or
- one of its function-valued upvalues is a Lua closure satisfying the above
  (one level; bounded).

The test does not require the state slot to be a table: an iterator that
carries its table in an upvalue (`for k in myiter(t)`) is the same hazard.
"Reaches `next`" is a heuristic — an iterator that calls `next` on some
*other* table is a false positive — which is acceptable for an opt-in warning
and why it is not a rewrite.

**Message.** Both locations, because the author needs both: the loop
(`chunkname:line` of the enclosing frame, from the frame pc) and the iterator
(`chunkname:linedefined` of the closure). Text on the order of:
`for-in loop at boot/04_component.lua:87 iterates with a Lua closure
(boot/04_component.lua:79) that calls next; its position is not replayable and
resumes against a different hash layout after a reload — return next, t, nil
from the iterator, or walk a snapshot array by index`.

**Surface.** A new `eris.settings("forin", mode)` with `mode` one of
`"ignore"` (default; the wire format and the blob bytes are unchanged),
`"warn"` (append the message to a registry-held list, retrievable and cleared
by a new `eris.diagnostics()`), or `"refuse"` (persist raises the message as
its error — the OS-developer setting, never a player default). In the mod,
`LuaJITArchitecture` sets the mode from the JVM property
`ocluajit.forin` (`-Docluajit.forin=warn`) at the end of `initialize()`, and
after every successful save drains `eris.diagnostics()` to the server log,
once per distinct message per machine (OC saves every 45 s; the same loop
would otherwise log every time).

**Tests, failing first.** In `serializer/tests/forin.lua`: (1) an OS-style
wrapper (the `ocpairs` control shape) under `"warn"` yields exactly one
diagnostic naming both lines; (2) the snapshot-array iterator (`ocpairs_snap`
shape) under `"warn"` yields none; (3) `"refuse"` makes persist error with the
same text; (4) under the default the blob is byte-identical to the one written
before the change (a fixture blob from the shipping binary, compared after
stripping the fingerprint header). The current binary fails (1) and (3) — the
setting name is unknown to it.

**What ships alongside** (one serializer hash move, one additive native
rebuild on both platforms): the persist-side trace flush becomes a read
through `GCtrace.startins` (roadmap: "JIT x persist interaction"), and the
`eris_lj.c:1530` userdata refusal text loses its "(M3)" placeholder.

## Open questions

- ~~What does OC's `componentProxy.__pairs` return, and why does it exist?~~
  **Answered** — see sequencing step 1: a two-phase closure over `next`, own
  keys then `fields`, so the proxy's methods and its field descriptors read as
  one table.
- ~~Do real OSes actually write `next`-wrappers?~~ **Answered: yes.** Both the
  platform (twice) and an OS (QuickOS's `lua_shell`) do. See the census.
- Given Tier 1 handles the platform, is Tier 2 worth building at all, or is
  the right residual answer a save-time **diagnostic** -- warn when a for-in
  iterator is a Lua closure whose body reaches `next` on its own loop state --
  plus the written contract? A warning an OS author can act on may beat a
  mechanism they never invoke.
- The census found the `ipairs` aux refusal is **live against stock OC**:
  real `PersistenceAPI.scala` does the sorted DFS but no builtin-upvalue
  sweep, so `for _,v in ipairs(t)` with a yield in the body fails to save on
  QuickOS's boot path (`base.lua:440`). Our sweep already fixes this, which
  means it is a thing to KEEP, not merely a nicety.
- Does `__ipairs` (also honoured under `LUA52COMPAT`) create an equivalent
  gap? `ipairs` is currently solved host-side by sweeping builtin upvalues
  into perms, which may not survive a metamethod override.
