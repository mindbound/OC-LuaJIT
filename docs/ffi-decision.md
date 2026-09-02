# Decision: do not expose LuaJIT's FFI

Status: **decided, 2026-09-01.** Revisit only with new evidence, not with a
new opinion — this note exists so the question is not re-litigated from
scratch in a year.

Evidence: [research/os-shape-census.md](research/os-shape-census.md) and its
follow-up measurements.

## The decision

The sandbox does not expose `ffi`, and the architecture does not `luaopen_ffi`.
This is a **product** decision made deliberately up front, because deferring it
*is* the decision: ship without FFI and adding it later breaks every existing
save; ship with it and `cdata` is unpersistable forever.

It costs us something real. FFI is one of the headline reasons to want LuaJIT
at all, and a from-scratch OS would use it the moment it were available. We
are giving that up on purpose.

## Three arguments. Two of them are sufficient on their own.

### 1. Persistence — decisive

`cdata` cannot be persisted, and **the exposure is a number literal**. `1LL`
and `2ULL` are `cdata`. So is anything `ffi.new` or `ffi.cast` returns, and so
is a `string.buffer` object.

The failure mode is the worst one this project has: the save raises, the save
fails, and in OpenComputers the computer comes back **switched off with its
RAM gone**. A user writes `local mask = 1LL << 40` because they wanted a
64-bit integer, the world saves while that value is in a slot, and they lose
the machine.

**Why `cdata` and not the other things we refuse.** Everything else on the
refusal list is *bounded*:

- **userdata** are host objects. The platform created them, so the platform
  can describe them — which is exactly what the perms table and the `spkey`
  protocol are for. Enumerable.
- **runtime-minted C closures** (native `gmatch` iterators, raw
  `coroutine.wrap` wrappers) are one library function each, replaceable with a
  Lua equivalent. Enumerable.

`cdata` is neither, because the types are **user-defined at runtime** via
`ffi.cdef` — there is no fixed set to enumerate; a cdata is **opaque bytes
whose interpretation lives in a ctype the user wrote**, and some of those
bytes may be pointers into this process's address space with no way to
identify which without parsing that ctype; the **ctype is itself per-VM
interned** with process-local ids; and a cdata may carry a `__gc` finalizer or
an FFI callback, which have no restorable identity at all.

**The honest refinement:** this is not a theoretical wall for *every* value.
A scalar cdata of a primitive type — `1LL` is `int64_t` 1 — could be persisted
as a type name plus eight bytes and rebuilt with `ffi.new`. The wall is the
general case.

Which is what actually settles it: **a partial solution is worse than none.**
We cannot ship *"64-bit integers survive a save; a struct containing a pointer
silently does not; and you cannot tell which you have by looking."* That is
precisely the conditional, footnote-shaped guarantee this project has spent
its entire life eliminating — from the `pairs` gap onward. A guarantee with a
user-reachable exception that costs the whole RAM state is not a guarantee.

### 2. The watchdog — independently decisive

FFI breaks the **timeout**, not just the save, and it does so in a way that
changes the problem's kind rather than its size.

Two situations that are easy to conflate:

- **Lua calls out to C** (`ffi.C.something()`). The machine is executing
  foreign C. No Lua bytecode is running, so no debug hook can fire, and
  `CHECKHOOK` makes *compiled traces* poll `hookmask` — we are not in a trace.
  **The watchdog cannot interrupt at all.** If that call blocks or spins,
  `resume` never returns, we cannot `lua_close`, and a runner thread leaks per
  wedged machine. **This is the hazard.**
- **C calls back into Lua** (an FFI callback). Lua *is* running and a hook can
  fire; the constraint is only that the callback cannot yield, so the abort's
  unwind path is limited. Lesser problem.

The first is why FFI is different in kind: today the set of uninterruptible
operations is an **enumerable list of native builtins we already know about**
— the native pattern matcher and friends, already recorded as the
highest-severity row in the watchdog threat model. With FFI it becomes
**"whatever C function the user chose to call"**, which is not a set we can
reason about, bound, or test.

### 3. Sandbox escape — real, but the weakest of the three

FFI is arbitrary memory read and write plus `ffi.C.system`: a total escape
from the Lua sandbox into the JVM's address space, from a script any player
can put on a floppy disk. OpenComputers' whole security posture — wrapped
userdata, metatable hiding, the bytecode setting — assumes the opposite.

Listed third and weighted least, deliberately. It is the argument most likely
to be met with "then gate it behind a server config", and that answer is
available for this argument while doing nothing about the first two. **The
persistence and watchdog arguments do not have that escape hatch**, and either
one alone is sufficient.

## A trap for anyone who reaches for FFI anyway

Measured during the `__gc` investigation, and worth recording because it would
mislead exactly the person most likely to try: **`ffi.gc` is not reliable on
this VM under the JIT.** 77 finalizer firings out of 1,000,000 with the heap
flat -- the cdata were freed and the finalizers silently dropped -- versus
1,000,000/1,000,000 with `jit.off()`. `ffi.metatype`'s `__gc` is reliable
(1,000,000/1,000,000). So `ffi.gc` works in testing and evaporates under load,
which is the worst possible failure profile for a finalizer.

## What we are NOT saying

- Not "LuaJIT's FFI is bad." It is excellent; it is incompatible with a
  transparent-persistence guarantee and an enforceable timeout.
- Not "cdata is impossible to serialize." The general case is; the scalar case
  is merely work. See the refinement above.
- Not "this is settled forever." It is settled *until the persistence
  guarantee changes*. If a future version drops transparent persistence for
  some class of machine, the first argument evaporates and only the watchdog
  one remains.

## Consequences to implement

- The architecture must not call `luaopen_ffi`, and `ffi` must not be reachable
  from the sandbox — including indirectly, via `require`, `package.loaded`, or
  a `debug` upvalue walk.
- `string.buffer` is also out: its objects are cdata.
- The sandbox constraint list belongs with the other ones in
  [research/os-shape-census.md](research/os-shape-census.md); this note is the
  reasoning, that list is the checklist.
- Document the absence in user-facing docs *with the reason*. An OS author who
  discovers it by having a machine come back switched off has already shipped.
