# Closing the for-in iterator gap

Status: **design, not implemented.** Written 2026-09-01, after the replay
iterator (M3.1) landed and the bridge spike surfaced a conflict with the
`LUA52COMPAT` build flag.

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

1. **Settle `componentProxy.__pairs`.** Five-minute question; decides whether
   T1 alone covers the case we actually know about.
2. **T1** if it fits — free, and it shrinks the surface even if T2/T3 ship.
3. **T2** as the general answer for host-installed iterators.
4. **T3** only if the OS shape census turns up real iterators that need it.
5. **Refuse** as the fallback for anything still unhandled, so the residual is
   loud rather than silent.

The pattern generalises, and it has held for every hard call in this project:
**information we already have at the Java layer is cheaper than cleverness in
C.** Constraining the sandbox beats teaching the serializer another shape.

## Open questions

- What does OC's `componentProxy.__pairs` return, and why does it exist?
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
