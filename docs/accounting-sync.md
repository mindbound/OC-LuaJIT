# Memory accounting without a JNI crossing per allocation

Status: BUILT 2026-10-03, in the working tree; measured and gated in
[bench/results-accounting-2026-10-03.md](../bench/results-accounting-2026-10-03.md).
The design below was revised before it was built, after an adversarial review
(three lenses: Java/OC semantics including javap of the installed GTNH
OpenComputers jar; C, threads and lifetimes; tests), which found no reason the
approach cannot work and three gaps in the first draft, all closed below: the
dropin variant (section "Handover"), uncapped states (the used figure is
returned, never written), and a test plan whose fail-first step could not run
(cores and wrappers). A second review, of the code as built, found no defect
in the C or Java logic; what it did find is listed in the results document,
with what was done about each.

## Why

Every allocation a machine makes goes through the shim's accounting allocator,
`lj52_alloc`, and today it crosses into the JVM on every call: `getthreadenv`,
two `GetIntField` (`luaMemoryTotal`, `luaMemoryUsed`) and one `SetIntField`.
Measured ([bench/results-allocator-2026-10-02.md](../bench/results-allocator-2026-10-02.md),
"What the machine still pays per allocation"): our DLL in a plain JVM runs
binarytrees in 0.389-0.399 s with that accounting and 0.209-0.222 s without
it; three scratch prototypes priced the parts (reads ~0.03 s, write ~0.06 s,
`getthreadenv` ~0.05 s of ~0.18 s) and showed that caching the figures per
allocation is wrong: Java changes the cap (OC does so around every save), and
a cached cap misses it.

The fix: keep both figures in C, and synchronise only where Java can read or
write them.

## The boundary is closed

The figures are two `private int` fields of jnlua's `LuaState` (OC-JNLua
`LuaState.java:210`, `:216`). Verified against the source, against the
installed GTNH OpenComputers 1.12.64 jar's own `LuaState.class` (javap) and
against the harness's OC-JNLua jar:

| access | where |
|---|---|
| write `luaMemoryTotal` | the constructor (`:297`); `setTotalMemory(int)` (`:484-487`) |
| read `luaMemoryTotal` | `getTotalMemory()` (`:471`); `setTotalMemory` (`:484`); `getFreeMemory()` (`:508`) |
| read `luaMemoryUsed` | `getFreeMemory()` (`:508`) only |
| JNI read (jnlua.c) | `getluamemory` from `l_alloc_checked` (never installed: the shim intercepts `lua_setallocf`) and from `controlled_newstate` (`:293`, `total` only, to decide whether to cap) |
| JNI write (jnlua.c) | `setluamemory` from `l_alloc_*` (never installed) and to 0 at close / failed newstate (`:328`, `:363`) |
| JNI read/write | the shim's `lj52_alloc` -- what this change removes on the fast path |

All three accessors are `public synchronized` and not `final`, in the source
and in the GTNH jar. Every caller -- GTNH `NativeLuaArchitecture`
(`recomputeMemory`, `runThreaded`'s `kernelMemory` and kernel-error path,
`save`, `load`, `close`), GTNH `ComputerAPI` (`computer.freeMemory` /
`totalMemory`), GTNH `LuaStateFactory` (`createState`, the `init` probe),
ocelot-brain's equivalents, the mod (`LuaJITArchitecture.java:499,574`) and
the harness -- calls them by `invokevirtual`, so overrides in
`LuaStateLuaJIT` dispatch. No reflection touches the fields anywhere (the
only `setAccessible` calls in the GTNH jar are LuaJ's), and no other mod jar
in the instance references jnlua's `LuaState`.

## The design

### Handover: C owns the figures only after Java hands them over

The dropin variant (the harness's default arm, and the stock-kernel control
arm) runs on OpenComputers' own `LuaState`, which can never carry our
overrides; an old committed class paired with a new DLL is the same case. So
the fast path is opt-in per state:

- Every state starts in **legacy mode**: `lj52_alloc` runs today's code
  exactly (the `pending` bank, `javaref`, `getmem`/`setmem`/`envfn` per
  allocation).
- `M->used` is updated on every successful operation **in both modes** (the
  sum of successful deltas from birth -- exactly the figure Java holds today
  once the bank has settled, as the review verified line by line).
- The first `ocljSetTotalMemory` call sets `M->csync`: from then on the state
  is in **C mode** and `lj52_alloc` makes no JNI call. It refuses a growth
  that does not fit `M->total - M->used` (unless `norefuse`), and runs
  `lj52_gc_pressure`, under one predicate -- `M->accounting && M->total > 0`
  -- on the refusal, the pre-free and the post-allocation paths. The
  `accounting` flag, set only by the intercepted `lua_setallocf`, stays the
  switch jnlua flips off before close.
- The dropin never hands over and keeps today's behaviour and cost. A stale
  class with a new DLL is correct but slow, never uncapped.

### Cores and wrappers

Two plain C cores, keyed by `lua_State *`, declared in `lj52shim.h` so the
native tests can drive them directly:

- `long long lj52_mem_used(lua_State *L)`: the record's `used`, or `-1` when
  there is no record (`lj52_memof` is NULL: a state not created by the shim,
  or its `luaL_newstate` fallback), or the state has not handed over.
  Counts reads.
- `void lj52_mem_settotal(lua_State *L, long long total)`: records the cap and
  sets `csync`. No-op without a record.

Two JNI wrappers, compiled only into the **additive** build
(`-DLJ52_ADDITIVE` from `build-native.sh`), `JNIEXPORT`, named
`Java_li_cil_repack_com_naef_jnlua_LuaStateLuaJIT_ocljUsedMemory` (returns
`jlong`) and `..._ocljSetTotalMemory` (takes `jint`). They find the state
through jnlua's own `luaState` field (not `luaThread`, which jnlua swaps on
every Java-function call): `GetObjectClass` + `GetFieldID("luaState","J")`,
the ID cached with relaxed atomics; on a NULL ID they return at once with
the pending error. `luaState == 0` (a closed state: jnlua zeroes it before
`lua_close`) means -1 / no-op. They call nothing but the cores, which call
nothing but `lua_getallocf` -- no Lua API call that can raise or allocate,
and never the watchdog mutex.

The used figure is **returned**, never written into jnlua's field: nothing
depends on `M->setmem`, which is NULL on uncapped states (the review's
crash scenario), and the field `luaMemoryUsed` simply stops being read once
a state is in C mode.

### Java: `LuaStateLuaJIT`, through its generator

`native/jnlua/gen-luastate-subclass.py` emits, in the existing formatting
(spotless owns it; one annotation per line):

```java
public LuaStateLuaJIT(int memory) {
    super(memory);
    // Hand the cap to C. Outside the monitor, safely: `this` has not escaped.
    ocljSetTotalMemory(memory);
}

@Override
public synchronized int getFreeMemory() {
    if (super.getTotalMemory() < 1) {
        return super.getFreeMemory(); // uncapped: never hands over, asks no native
    }
    long used = ocljUsedMemory();
    if (used < 0) {
        return super.getFreeMemory(); // legacy mode or closed: jnlua's figure
    }
    return (int) Math.max(0L, (long) super.getTotalMemory() - used);
}

@Override
public synchronized void setTotalMemory(int value) {
    super.setTotalMemory(value); // throws first on an uncapped state, as before
    ocljSetTotalMemory(super.getTotalMemory());
}

private native long ocljUsedMemory();

private native void ocljSetTotalMemory(int total);
```

The class's header note "No behavioural overrides, deliberately" is replaced
by one naming these three and pointing here. `synchronized` is not inherited,
so the generator emits it, and a reflection check asserts it.

### Why the monitor makes it exact

Every jnlua method that can run Lua code or allocate is `public synchronized`
on the `LuaState` (120 of them; the four non-synchronized getters are
constants, the finalize guardian and the proxy internals take the monitor
themselves). The allocator therefore runs only on a thread holding the
monitor -- or on the constructing thread before `this` escapes -- and the
wrappers run under it too (the constructor's call excepted, for the same
reason). The watchdog thread never allocates. A plain `long long` for `used`
and `total` is not raced.

## What changes, observably

- **Nothing a program or OC can see.** `getFreeMemory()` is exact at every
  call, including inside a Lua->Java callback mid-slice (`computer.freeMemory`);
  the cap applies to the very next allocation after `setTotalMemory`.
- **jnlua's private `luaMemoryUsed`** stops being written once a state hands
  over; only `getFreeMemory()` read it, and it no longer does in C mode.
- **The construction window**: before the constructor's handover the state
  is in legacy mode, as today; OC and ocelot-brain construct with
  `Integer.MAX_VALUE` anyway.
- **Mismatched pieces**: a new class with an old DLL throws
  `UnsatisfiedLinkError` from the capped constructor (OC catches it and the
  machine does not start); an old class with a new DLL stays in legacy mode.
  `verifyModAssets` refuses a jar whose native lacks the two export names. An
  uncapped state (`computer.lua.limitMemory=false`) calls neither native, so a
  new class on an old library serves it as before -- the review's case: the
  first build of the override asked the native on every `getFreeMemory()`,
  which on that pairing would have thrown mid-run instead of at start.

## Gates and tests

- **Build**: per-variant export gates (additive: 89 `Java_*` + 2 hooks = 91 PE
  names, the two new names asserted exactly; dropin unchanged at 87/89, no
  `LuaStateLuaJIT_*`); `nm` asserts the additive shim object defines both;
  a regenerate-and-diff gate for `LuaStateLuaJIT.java`; spotless.
- **`_OCLJ_GCSTATS`**, six values appended after the 14th (twenty in all,
  which is `LUA_MINSTACK`, so the function needs no stack check): 15 `total`
  (C), 16 `used` (C), 17 `csync`, 18 used-reads, 19 allocator calls, 20
  allocator calls that took the JNI path. In C mode 20 stops moving while 19
  climbs: the fingerprint that the fast path is live. (The plan had a
  seventh, a count of cap hand-overs; the cap mirror -- 15 against
  `getTotalMemory()` after a change -- tests the same thing more directly.)
- **`mem_test`**: the existing cases keep testing legacy mode unchanged; new
  C-mode cases drive the cores: no JNI per allocation (the fake accessors'
  counters and GCSTATS 20 frozen across a burst while 19 climbs), `used`
  exact against LuaJIT's own count, the cap lowered and raised and biting on
  the next allocation, the save pattern (`Integer.MAX_VALUE` and back), the
  emergency collector arming against a synced cap, `norefuse` still charging,
  -1 for uncapped / not handed over / no record. A compile switch
  (`-DMEMTEST_OLD`) maps the cores to plain field operations so the same
  suite links against the pre-change object and the new cases are seen
  failing there.
- **The harness**: the e-group memory probes run on the arm's own factory
  (in the additive arm they ran on OC's PUC 5.2); new milestones for
  `freeMemory` exact inside one slice (the game reads it mid-slice; ocelot-brain
  also reads it between slices, which would hide staleness), the C mirror
  (GCSTATS 15 == `getTotalMemory()`), the fast path live (GCSTATS 19 vs 20),
  the constructor's cap biting, uncapped `getFreeMemory() == 0`, closed state;
  each with a sabotage that fails it (a Java copy through `OCLJ_JAVA_SRC`, or
  a shim copy).
- **The JVM arm** (`JniArm`): speed and correctness, old pair against new,
  interleaved and pinned; a mismatched pair.
- Both platforms, pinned harness runs, an in-game run.
