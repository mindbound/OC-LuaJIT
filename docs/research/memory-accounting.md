# Memory accounting: enforcing OC's RAM cap on the LuaJIT native

**Status:** landed. Measured on ocelot-brain 0.24.2 (OpenComputers 1.8.9a),
LuaJIT 2.1 @ `1ee778a4` + CHECKHOOK, OC-JNLua @ `da3d4d45`, Windows x64,
MinGW-w64 15.2.0, JDK 17.

Everything in this note was observed in this repo's own harness. Nothing has
run in Minecraft.

---

## 1. What was wrong

`native/lj52shim.h` carried a deliberate stopgap:

```c
#define lua_setallocf(L, f, ud) ((void)(L), (void)(f), (void)(ud))
```

Every allocator swap jnlua attempted was discarded, so OC's per-machine RAM cap
was **reported but never enforced**. The symptom is exact and repeatable:
`NativeLuaArchitecture` measures

```scala
lua.gc(LuaState.GcAction.COLLECT, 0)
kernelMemory = math.max(lua.getTotalMemory - lua.getFreeMemory, 1)
```

and with nothing ever charged, `getFreeMemory == getTotalMemory`, the
difference is 0, and `kernelMemory` lands on its literal floor:

```
MILESTONE b-machine.lua-sandbox: PASS -- kernelMemory=1
```

A program could not run out of RAM. A runaway allocation consumed the server's
heap instead of failing inside the sandbox.

## 2. The naive fix, and how it dies

Removing the stopgap so that jnlua's own `l_alloc_checked` becomes the state's
allocator kills the JVM outright. Measured, twice:

```
SMOKE| architecture pinned to NativeLua52Architecture
  java exit=127
```

No `hs_err` file, no Java exception, no further output. This is the failure the
stopgap existed to avoid.

## 3. Root cause, and a correction to our own earlier account

The shim's previous comment blamed the allocator **swapping**: jnlua's
`l_alloc_checked` calls `lua_setallocf` twice per allocation. That is not it.
On LuaJIT `lua_setallocf` is two stores into `global_State`
(`lj_api.c:1297`) — it cannot allocate, fail, or re-enter. The swap is free.

The killer is one line inside it:

```c
lua_setallocf(L, l_alloc_unchecked, NULL);
obj = getjavastate(L);          /* <-- lua_getfield on the registry */
lua_setallocf(L, l_alloc_checked, L);
```

`getjavastate` re-enters the VM **from inside a `lua_Alloc` callback**, where
`g->gc.total` has not yet been updated for the allocation in flight
(`lj_gc.c`, `lj_mem_realloc` updates it *after* `allocf` returns) and a `GCtab`
may be mid-resize. PUC Lua tolerates this; LuaJIT does not.

Everything else in `l_alloc_checked` is plain JNI — `GetIntField` /
`SetIntField` on the Java `LuaState` — and is perfectly safe from an allocator.

## 4. The design

One allocator, `lj52_alloc`, installed by `lj52_newstate` with a per-state
record as its `ud`, and **that pairing is never changed again**. Two
consequences carry the design:

* `lua_getallocf(L, &ud)` hands the record back from *any* thread of the state,
  because `allocf`/`allocd` live in the shared `global_State`. No lookup table
  keyed by `lua_State*`, and therefore no locking — which a server running many
  machines on many threads would otherwise need.
* jnlua's `lua_setallocf` calls no longer install anything. They are
  intercepted and only flip a flag.

`lj52_alloc` reproduces `l_alloc_checked`'s arithmetic exactly, using **jnlua's
own JNI accessors**, handed to it at the call site:

```c
#define lua_setallocf(L, f, ud)                                    \
  lj52_setallocf((L), (f), (ud), (lj52_envfn)getthreadenv,         \
                 getluamemory, setluamemory, JNLUA_JAVASTATE)
```

`getluamemory`, `setluamemory` and `getthreadenv` are file-static in `jnlua.c`,
so `lj52shim.c` cannot name them — but this macro **expands inside `jnlua.c`**,
where all three are in scope (forward-declared at `jnlua.c:84-88`, far above
every `lua_setallocf` call site). Borrowing them means reusing jnlua's cached
`jfieldID`s and its JNI-version handling; the shim never needs a `JavaVM`, a
`jclass`, or a `GetFieldID` of its own. `JNLUA_JAVASTATE` rides along the same
way, so the registry key matched on is jnlua's own spelling rather than a copy
that could drift. If OC-JNLua renames or retypes any of the four, the build
**fails to compile** — the failure mode we want.

The Java object itself is cached by watching the one write that binds it:

```c
#define lua_setfield(L, idx, k) lj52_setfield((L), (idx), (k))
```

`newstate_protected` stores the Java `LuaState` at
`registry[JNLUA_JAVASTATE]` as a full userdata holding a weak global ref;
`close_protected` sets that key to nil. Caching the userdata's address there is
what lets the allocator find the object **without `lua_getfield`** — i.e.
without the VM re-entry of §3.

jnlua encodes its own intent in `ud`: `l_alloc_checked` is always installed with
`ud == L`, `l_alloc_unchecked` always with `ud == NULL`. Accounting is armed iff
`ud != NULL`, so the close path correctly stops us writing through a weak ref
the JVM is about to drop.

## 5. Why this had to land with the `lua_pushcfunction` change

jnlua pushes a static `*_protected` function at **38 sites**, each in a bare JNI
frame *before* the `lua_pcall` that protects the real work. On PUC 5.2 that is a
light C function: a tagged pointer, no allocation, cannot fail. On LuaJIT there
is no such type, so it builds a `GCfunc` — and the moment the cap is genuinely
enforced, that allocation can be refused, raising `LUA_ERRMEM` with no protected
frame below it.

What happens then is worth stating precisely, because the obvious guess is
wrong. On Win x64 (`LJ_UNWIND_EXT`) `lj_err_throw` issues a
`RaiseException(LJ_EXCODE, EH_NONCONTINUABLE)`. The handler that would catch it
is stamped into LuaJIT's own generated VM assembler, so it is only reachable if
a LuaJIT VM frame is on the machine stack — and in a bare JNI frame there is
none. The exception finds no handler and the OS terminates the process.
**`lua_atpanic` is never called.** Measured: the `norefuse` negative control
dies with exit `127`, mid-test, and the shim's panic handler — its "at least
name it on the way down" — prints nothing. That is exactly why the JVM death of
section 2 had no diagnostic of any kind.

**Enforcing the cap without fixing this is strictly worse than not enforcing
it.**

The roadmap's plan was an *eager* warm-up: push all 38 once at newstate while
memory is plentiful. It cannot be written — the 38 targets are file-static in
`jnlua.c`, so `lj52shim.c` cannot name them, and the macro that could name them
expands at the push sites rather than at newstate.

So the guarantee is bought differently: inside `lj52_pushcfunction` the
allocator **charges but never refuses**. Three properties make that a
guarantee rather than a hole:

* the overshoot is bounded by a compile-time constant. The 38 sites push 38
  *distinct* named statics, one apiece, so a state memoises at most 38
  `GCfunc`s. Measured cost of one: **48 bytes**. Sandbox Lua cannot reach
  `lua_pushcfunction` and cannot add a 39th;
* the bytes are still charged, so `freeMemory` stays honest and the machine
  simply runs over budget by that bounded amount — which the very next
  allocation refuses, cleanly, where a protected frame exists;
* the window covers the whole function body, not just the cold push. This is
  not belt-and-braces: on GC64 `lua_pushlightuserdata` **interns the pointer's
  segment**, and that path calls `lj_mem_reallocvec` (`lj_udata.c:38-58`,
  `lj_lightud_intern`) — so even the warm lookup, which pushes a light userdata
  key, can allocate. `lua_rawset` can grow the memo table, and every `lua_push*`
  ends in `incr_top`. Any of them would land the same fatal `LUA_ERRMEM` in the
  same bare frame.

### The hazard that turned out not to exist

`checkstack()` guards all 38 sites, and on PUC Lua `lua_checkstack` can throw.
On LuaJIT it **cannot**: it grows the stack through `lj_state_cpgrowstack`, a
*protected* call, and returns 0 on failure (`lj_api.c`). jnlua turns that into a
Java `IllegalStateException`.

A scan of every `JNIEXPORT` entry point for allocating Lua API calls before its
`pcall` finds exactly two others that touch the Lua API unprotected —
`lua_1load` and `lua_1setmetatable` — and both are safe: `lua_load` returns its
status rather than throwing, and `lua_setmetatable` does not allocate.

One further site does exist, and it is worth naming precisely rather than
rounding away. `throw()` (`jnlua.c:2356-2368`) calls `lua_tostring(L, -1)` in a
bare frame, on the path where `throw_protected` itself failed, and converting a
non-string error value to a string allocates. It does not bite on the path that
matters, because LuaJIT **pre-allocates and GC-fixes** the "not enough memory"
message at state creation (`lj_state.c:202`,
`fixstring(lj_err_str(L, LJ_ERR_ERRMEM))`), so `lua_tostring` on an
out-of-memory error object is a no-op. It could bite only on a non-string error
raised while memory is exhausted — sandbox code doing `error(42)` exactly at the
wall. Narrow, on an error-while-reporting-an-error path, and not covered by the
window: recorded rather than fixed.

So `lua_pushcfunction` is the only *unconditional* bare-frame `LUA_ERRMEM`
source in `jnlua.c`, which is what makes the window sufficient in practice.

## 6. The bug the hermetic test found: `used` going negative

`controlled_newstate` installs the cap **before** `newstate_protected` has bound
the Java `LuaState`, so the state's own creation is allocated before anyone can
be told about it. Dropping those bytes is not merely imprecise: when those
blocks are later freed *under a live binding* they are credited, and `used` goes
**negative**. Measured at `-387188` across one ordinary allocate-then-collect
cycle.

That is not cosmetic. OC derives the machine's whole budget from the figure it
measures this way:

```scala
kernelMemory = math.max(getTotalMemory - getFreeMemory, 1)
setTotalMemory(kernelMemory + ceil(memoryBytes * ramScale))
```

An under-measured kernel produces an under-sized `totalMemory`, and the machine
starves. The fix is a `pending` accumulator: bank the bytes while nobody can be
told, and settle up on the first chargeable call. The difference it makes, on
otherwise identical settings:

| | `kernelMemory` | `totalMemory` | OpenOS boot |
|---|---|---|---|
| bytes dropped | 298 053 | 2 185 490 | **fails — "not enough memory"** |
| bytes banked | 323 809 | 2 211 246 | completes |

`test/native/negative-control.sh` reintroduces the drop and requires
`mem_test` to fail on `M4b`, `M5` and `M6b`.

## 7. What is measured

`test/native/mem_test.c` — hermetic, no JVM, milliseconds. It plays the part of
jnlua, supplying the four names the `lua_setallocf` macro reaches for, which
also pins their signatures. **13 checks, 0 failures.**

The sharpest two check the arithmetic against LuaJIT's own byte counter.
`g->gc.total` is maintained in `lj_mem_realloc` as the running sum of exactly
the `(osize, nsize)` pairs it hands the callback, so over any window where our
accounting is armed the two deltas must agree *to the byte*:

```
PASS  M3b charged to the byte, vs lua_gc(GCCOUNT)   we charged +1828506, LuaJIT counted +1828506  (difference 0)
PASS  M4c credited to the byte, vs lua_gc(GCCOUNT)  we credited -2215734, LuaJIT counted -2215734 (difference 0)
```

That is a free, exact oracle for the whole computation — it would catch a lost
free, a double-counted grow or a truncated delta, none of which the
order-of-magnitude assertions would notice.

The next two are asserted at a single instant, with the cap exhausted:

```
PASS  M6a lua_pushcfunction survives an exhausted cap   used == total == 238936; pushed=yes
PASS  M6b a RAW push is refused at that same cap        lua_pushcclosure under pcall -> status 4 (LUA_ERRMEM=4)
PASS  M7  the unrefusable push is still charged         used 238936 -> 238984 (+48)
```

If both halves of M6 went the same way the test would be vacuous, which is why
both are asserted rather than one.

`test/native/OcljSmoke.scala` — real OpenOS on ocelot-brain. **19 checks, 0
failures**, up from 13 before this change:

```
b2-machine-memory-accounted  kernelMemory=322521  totalMemory=2209958  freeMemory=1856649
e1-accounting-live           fresh private state: used=42276
e2-freemem-falls             after 20000 tables: used 42276 -> 2063370 (+2021094)
e3-gc-credits-frees          used 2063370 -> 40094 (2023276 reclaimed)
e4-oom-at-the-cap            cap 302238; allocation ended at used=302238;
                             threw LuaMemoryAllocationException: not enough memory
f5-restore-memory-still-accounted   kernelMemory survives a persist/restore round trip
```

`e4` is the enforcement result: an unbounded allocation stops **at** the cap and
surfaces as OC's own exception, which `NativeLuaArchitecture.runThreaded` maps
to `ExecutionResult.Error("not enough memory")` — the same thing a player sees
on stock OpenComputers. The process stays alive, which is §5 working.

`test/native/negative-control.sh` — **11 controls, all required to fail in an
exact way**, four of them new here. One must **kill the test process**: with the
`norefuse` window removed, a bare-frame push panics after M5 and never reaches
the summary line. That is the JVM-killer demonstrated rather than described.

Two build-time gates also guard this. `build-native.sh` now counts jnlua's
`lua_setallocf` sites and refuses to build unless the convention is the one
`lj52_setallocf` keys on (2 with `ud == L`, 3 with `ud == NULL`, 5 total) — a
rename of the borrowed accessors is already a compile error, but a change to
that *convention* would compile silently and either disarm the cap or leave it
armed through `lua_close`.


## 8. LuaJIT has no emergency GC, and it shows

PUC Lua retries after collecting when an allocation is refused
(`lmem.c`, `luaM_realloc_`):

```c
newblock = (*g->frealloc)(g->ud, block, osize, nsize);
if (newblock == NULL && nsize > 0) {
  luaC_fullgc(L, 1);                                    /* emergency */
  newblock = (*g->frealloc)(g->ud, block, osize, nsize);   /* retry */
  if (newblock == NULL) luaD_throw(L, LUA_ERRMEM);
}
```

LuaJIT's `lj_mem_realloc` throws immediately. Under a hard cap this is a real
behavioural divergence: a machine can be refused while holding a heap-full of
garbage that a collection would have reclaimed.

**How much garbage was stated far too conservatively here, and it is worth
correcting because the understatement is what made this look academic.** This
paragraph used to say the heap grows "to ~2× the live set before finishing a
cycle (`LUAI_GCPAUSE 200`)". Measured in a machine on `sieve` (the trio of
2026-09-04, cell B, `jit.status()=false` after a `jit.flush()` so no traces are
involved):

| | |
|---|---:|
| program budget — `totalMemory 3467681` − `kernelMemory 321953` | 3072 real KB |
| free at boot | 3042 real KB |
| live set, collect-then-count, every REPS in every sampling mode | **52.4 KB** |

The machine died of memory, so the heap reached roughly **58× its live set**,
and the only thing that stopped it there was the cap.

**CORRECTED 2026-09-04.** An earlier version of this paragraph said
`LUAI_GCPAUSE` fails to bound the growth "because `lj_gc.c:752-753` pins
`threshold = gc.total` once the collector has fallen behind: behind is where it
stays." The conclusion is right and **the mechanism was backwards**, which
matters because it is the mechanism that decides whether tuning could ever be
the fix.

`gc.threshold` is the **trip-wire for running a step**, never an allowance to
grow. Every one of the ~49 `lj_gc_check` sites (`lj_gc.h`), `lj_meta.c:382` and
the JIT's `asm_gc_check` test `total >= threshold` and *call the collector*. A
**high** threshold is what suppresses collection, stated in the source itself:

```c
lj_gc.c:516     g->gc.threshold = LJ_MAX_MEM;  /* Prevent GC steps. */
lj_api.c:1249   case LUA_GCSTOP:      g->gc.threshold = LJ_MAX_MEM;
lj_api.c:1252   case LUA_GCRESTART:   g->gc.threshold = ... : g->gc.total;
lj_api.c:1282   case LUA_GCISRUNNING: res = (g->gc.threshold != LJ_MAX_MEM);
```

So `threshold = g->gc.total` at `:753` is the **maximum-pressure** setting —
collect at the very next checkpoint. It is LuaJIT's *response* to falling
behind, not the cause of it.

**The heap grows because the collector is rate-limited below the allocation
rate.** `lj_gc_step` takes a fixed budget per invocation,
`lim = (GCSTEPSIZE/100) * stepmul` (`lj_gc.c:734`) — exactly **2000** at the
defaults (`GCSTEPSIZE` 1024u at `lj_gc.c:32`, `LUAI_GCMUL` 200 at
`luaconf.h:94`, installed at `lj_state.c:309`). Against that, `:737-738` charges
it `total - threshold`, i.e. *everything allocated since the last step*, while
`:752` repays only `GCSTEPSIZE` = 1024 bytes of debt. Any program allocating
more than ~1 KB between checkpoints therefore grows `debt` monotonically and
never finishes a cycle before the cap arrives. `sieve` allocates ~64 KB per
repetition.

`LUAI_GCPAUSE` (`luaconf.h:93`) never entered into it: `gc.pause` is read at
exactly two sites, `lj_gc.c:742` and `:801`, and both set the **start**
threshold of the *next* cycle from the post-sweep estimate. It does not bound
anything within a cycle.

**Why this is the paragraph that settles the design question.** If the collector
were merely mis-tuned, tuning would fix it. It is not: this is a *rate contest*
between a collector with a fixed per-step budget and an allocator with none.
Raising `lim` raises the collector's throughput ceiling, and for any ceiling
there is an allocation rate above it — and in OpenComputers the player chooses
that rate, and chooses the wall too, since `ramScaleFor64Bit` and the memory
tiers are both mod settings. **Pacing changes the probability of reaching the
wall; only collect-and-retry changes what happens at it.** That is the
difference between a mitigation and a fix, and it is why §11's emergency-mode
item cannot be retired by a tuning experiment, however well the tuning does.

Two things were tried:

* **GC pacing.** Calling `lua_gc(L, LUA_GCSETPAUSE, …)` when a cap is armed is
  safe (`lj52_setallocf` only ever runs at safe points, never from inside the
  allocator) and does help. But it was measured *marginal* — `pause=110,
  stepmul=400` passed in one sweep and failed in another at the same settings —
  and it buys its margin with collector CPU, which is the opposite of this
  project's point. **Not shipped.**
* **The `pending` fix of §6**, which turned out to be what actually mattered:
  with the accounting correct, OC's stock `ramScaleFor64Bit = 1.8` boots
  OpenOS 3/3, where the same build with the bytes dropped fails.

Implementing a real emergency mode in `lj_gc.c` (a full collection that skips
finalizers, as PUC's `isemergency` does) is the faithful fix and is left as a
roadmap item. It is VM surgery, not a six-line patch: running arbitrary `__gc`
Lua from inside an allocation is exactly what PUC's emergency flag exists to
prevent.

### 8a. Step 3 Phase 1 found a workload that produces exactly this

Until Phase 1 the paragraph above was a mechanism argument with no program
behind it. `bench/oc/strings.lua` is that program. It is the naive coding of
the strings pair — a table constructor fed by a multi-return `string.byte` and
a wide `unpack` back into `string.char` — and the recorder answers its shape by
producing **210 traces for one loop**. Measured standalone at the shipped
parameters (BASE 4096, PASSES 3072), both columns returning the same checksum:

| | JIT on | `-joff` |
|---|---:|---:|
| wall time | 2.739 s | 0.430 s |
| **allocated at return** | **3064.3 KB** | **90.2 KB** |
| live after a full collect | 70.7 KB | 48.1 KB |
| reclaimed by `jit.flush()` | 0.0 KB | — |
| traces recorded (`-jv`) | 210 | 0 |

**CORRECTED 2026-09-04, AND THIS SECTION HAD IT BACKWARDS TWICE.** The
"~70 KB live, flush reclaims nothing" reading above is what you get when the
loaded chunk is DROPPED before collecting. Hold it, and the same run at the
same parameters retains 1.4 MB across three full collects that only
`jit.flush()` releases:

| JIT ON, same file, same parameters | drop the chunk | hold the chunk |
|---|---:|---:|
| heap on return | 2627.0 KB | 1625.9 KB |
| after 3 collects | **78.4 KB** | **1467.2 KB** |
| after `jit.flush()` + collect | 78.0 KB | 79.8 KB |
| reclaimed by flush | 0.4 KB | **1387.4 KB** |

Under `-joff` the two columns agree to within 6 KB, so this is trace memory
specifically. The mechanism is `gc_traverse_proto` marking `pt->trace`
(`lj_gc.c:287`): a trace is reachable exactly as long as the prototype it hangs
off is reachable, and `lj_trace_free` therefore never runs on it. Traces are
released by `lj_trace_flushall`, not by the collector.

**Which case is a machine in? The holding one, necessarily.** While a benchmark
runs, its prototype is the function on the stack, so its traces are pinned for
the entire run — exactly when the memory is needed. So for a compiled workload
this is **not** churn a collector could reclaim, and the earlier draft this
section replaced (which said the same thing and was retracted here) was closer
to right than the retraction was.

**Consequence for the emergency-GC work: `strings` with the JIT on is out of
scope for it.** No collection, emergency or otherwise, can free memory the
running prototype pins. That needs a trace tier — separate work. `sieve` is a
different mechanism (tables, not traces) and remains the case an emergency GC
would address. But
the churn is charged — trace objects go through `lj_mem_*` → `g->allocf` →
`lj52_alloc`, unlike machine code, which is `VirtualAlloc`'d and invisible
(§11) — and `lj52_alloc` refuses rather than collecting. So the JIT-on column
asks a machine with 865–1024 KB free for about 3 MB of transient heap that a
collection would have reclaimed. That is §8's scenario, exactly, with numbers.

This is the strongest argument yet for the emergency mode: on PUC Lua — what
OC ships — this program gets a full collect and a retry and very likely
survives. On ours it throws. The divergence is invisible in every benchmark
that fits comfortably and decisive for one that churns.

### 8b. Confirmed in a machine, 2026-09-04

It is now measured. One benchmark per freshly booted 1 MB machine, our native
and the watchdog kernel in both cells, the compiler the only variable:

| | `strings` in a 1 MB machine |
|---|---|
| **JIT off** | `strings/ok/12582912-3852468224/0.5461/0.5461/990/1` — runs, correct checksum, **990 KB free after** |
| **JIT on** | `OCLJPNOW=strings#1`, `OCLJPCOMPAT=operators`, 909 KB free on entry → **machine stopped, `lastError = not enough memory`** |

The compiler's allocation churn is the difference between running and not
running. §8's mechanism argument now has the workload behind it, and the
divergence from PUC is not academic: this is a program a player could write.

Two cautions carried forward. The failure does **not** surface as an
`ERROR/not_enough_memory` row the way cell B's `sieve` does — the driver
`pcall`s every benchmark, but this allocation failure takes the machine down
rather than unwinding into the `pcall`, so the evidence is the frozen row plus
the harness's `lastError`. And establishing it needed three runs and a harness
fix: the first attempt wedged for 463 s with the machine still reporting
`isRunning` and was read, reasonably but wrongly, as "the benchmark never
started" — because the scoreboard was painted only by a timer that stops when
the machine does. Painting synchronously before each `pcall` is what separated
"died before the suite" from "died inside the benchmark".

**The sibling failure is still only partly attributed.** `strings` is planted but
*quarantined* (a leading `!` on its `references.txt` line), because the persist
and restore milestones run after the suite and a run that loses the machine
would lose them too; it runs on its own with `OCLJ_BENCH_ONLY=strings`. Note
also that the sandbox-visible figure depends on `ramScaleFor64Bit`, so ~3 MB of
real bytes is ~1021 KB as the sandbox counts it — over, but close enough that
the divisor decides it, which is a second reason to measure rather than assert.

One correction is recorded with this, because it was published before it was
checked: an earlier draft of `bench/oc/strings2.lua` reported the same workload
as holding ~1456 KB **live**, reclaimable only by `jit.flush()`, and attributed
it to GCtrace objects pinned on the heap. That does not reproduce. It came from
reading `collectgarbage("count")` after a single `collect` — LuaJIT's collector
is incremental, and one cycle is not a full sweep. The conclusion (the twin is
not runnable in a 1 MB machine) survives; the mechanism behind it does not, and
the difference matters, because churn is something an emergency GC fixes and
pinned live state is not.

### 8c. The sieve trio: PUC completes what we die on, 3 of 3 against 3 of 3

`sieve` at the shipped `N, REPS = 8192, 4500`, one benchmark per freshly booted
1 MB machine, three replicates per cell, run 2026-09-04 with the RAM guard's
units corrected so the workload was **admitted** rather than refused.

| cell | outcome | detail |
|---|---|---|
| A — PUC 5.2 | **completes, 3 of 3** | `4626000`, 2.65–2.84 s, 676–805 KB free |
| B — ours, JIT **off** | **not enough memory, 3 of 3** | one `ERROR/not_enough_memory` painted by the driver's own `pcall`, two machines lost |
| C — ours, JIT **on** | **not enough memory, 3 of 3** | machines lost |

All nine logs are committed at `bench/runs/2026-09-04-sieve-trio/`, because
these claims rest on the runs individually rather than on an aggregate.

Cell B is the load-bearing one: `JIT PROBE: jit.off() + jit.flush() ->
jit.status()=false`, so **no trace memory is involved** and this is plain table
churn against the cap. The kernel is a fresh 8192-entry `flags` table per
repetition — about 64 KB of garbage each, 4500 times, with exactly one of them
live at any instant.

**This is §8's divergence as a program rather than an argument.** PUC's
`luaM_realloc_` calls `luaC_fullgc(L, 1)` and retries; at the wall it finds a
heap that is over 98% dead and continues. `lj_mem_realloc` calls `lj_err_mem`
on the first refusal — "emergency" appears nowhere in the LuaJIT tree — and the
machine stops.

**A player has no way to work around it.** `machine.lua` builds the sandbox
global table at `:737` and **`collectgarbage` is not in it**. The only
`collectgarbage` in that file is the kernel's own at `:1526`, a full collect
every tenth resume, gated on `persistKey` and fired *between* resumes — and
`sieve` finishes inside a single resume (2.7 s against OC's 5 s deadline), so
none fires anywhere during it. Between sandbox code and the wall there is
nothing but `lj52shim.c:290` returning `NULL`.

That also means the obvious cheap experiment — emulate an emergency collector
in Lua and see whether the garbage is reclaimable — **cannot be run in a
machine**. It does not need to be: the `liveKB` column of the standalone sweep
is produced by collecting and then counting, which is precisely the outcome an
emergency collect would produce, and it reads 52.4–52.5 KB at REPS 5, 100, 500,
1500 and 4500 in all three sampling modes. Reclaimability is measured, not
conjectured.

#### What the guard was doing, and why `sieve` is now quarantined by hand

The six `sieve` cells of the re-run Phase 1 matrix came back `SKIP-LOWMEM`
rather than dead, and that was **a units bug in the harness, not the guard
working**. `references.txt`'s peak column is real KB; `computer.freeMemory()`
is real free divided by `ramScaleFor64Bit` (`NativeLuaArchitecture.scala:161`,
against the cap set at `:145`). A machine advertising 1024 KB holds 3072 real
KB, and the guard was testing 1155 real against ~977 scaled.

Fixing it does not rescue the guard, because **the peak it guards on does not
exist**. Every sampler is a GC safepoint, so the figure tracks the sample rate:

| sieve, same file | reported peak |
|---|---:|
| count hook, every 10000 instructions | 440.8 KB |
| in-band, once per repetition | 1143.6 KB |
| no sampling — heap *on return* at REPS=1500 | **1205.7 KB** |

The unsampled heap at return exceeds the sampled *peak*, which a peak cannot
do, so even the in-band figure is short; in a machine it goes past 3042 KB.
`sieve` is therefore quarantined in `references.txt` by hand, as `strings`
already was — quarantine records what has been **observed** to kill a machine,
where the guard was trying to predict it from a number that is an artifact of
its own instrument.

### 8d. A third memory failure, on the persistence path, previously unrecorded

Found while auditing the matrix logs for this section, and written down here
because nothing else in the repository mentions it.

`bench/runs/2026-09-04-matrix3-fresh-machine/B-strings.smoke.log` — cell B,
JIT **off**, so distinct from §8b's JIT-on death:

```
strings/ok/12582912-3852468224/1.1043/1.1043/936/1     <- the benchmark SUCCEEDED
JIT MEMORY: mcode=0 B, traces=0, jit=false
restored machine running=true lastError=null            936 -> 968 KB free
restored lastError = not enough memory                  <- then this
MILESTONE m3-post-save-workload-resumes: FAIL
MILESTONE f4-restore-no-error:            FAIL
```

The benchmark completed with a correct checksum and 936 KB free. The machine
was saved, restored clean, and then the **encore** — the repeating timer that
rides through `eris` holding a closure, which is how post-save recovery is
measured at all — re-ran the workload and exhausted memory.

Two things make this worth its own entry rather than a footnote to §8b. It is
**JIT off**, so it is not the pinned-trace mechanism. And it happens **after a
restore**, which is the one path where the heap's shape is not something the
program produced incrementally — it is whatever `eris` rebuilt. Whether the
restored heap starts denser than a booted one, and whether that is what pushed
this over, is not established here. It should be measured before the emergency
GC is designed, because a collector that fires at the wall behaves differently
depending on how much of the heap is genuinely live at that moment.

## 9. Calibration: OC's stock RAM scale is not enough

`ramScaleFor64Bit` is how many real bytes OC charges per apparent byte of
installed RAM. It exists because objects are bigger on a 64-bit VM than on the
32-bit one the module sizes were written for, and OC ships **1.8**, calibrated
for 64-bit PUC Lua. LuaJIT GC64 needs more — the OC kernel alone measures
~320 KB here.

Now that the cap is enforced, that stops being a detail. A 1024 KB machine
booting OpenOS 1.8.9, same build, same everything but the scale:

| `ramScaleFor64Bit` | boots |
|---|---|
| **1.8 — OC's default** | **1 / 6** |
| 2.5 | 6 / 6 |
| 3.0 | 5 / 5 |

At OC's own default the machine runs out of RAM during boot most of the time.
`test/native/smoke-test.sh` therefore pins the scale (`OCLJ_RAM_SCALE`,
default 3.0) rather than inheriting it, because a suite that fails at random
says nothing about the change under test; `OCLJ_RAM_SCALE=1.8` reproduces the
finding. Choosing what our own architecture should default to is a roadmap
item, not something to inherit by accident.

### A methodology note, because it nearly went the other way

An earlier pass of this measurement reported "3/3 at 1.8" and was wrong. The
scoring script used `grep -q 'VERDICT: PASS'`, and `smoke-test.sh`'s failure
banner read `no 'VERDICT: PASS' line` — so every failure was scored as a pass.
It surfaced only because a second measurement contradicted the first. The
banner has been reworded so the string cannot appear in a failing log, and
anything scanning these logs should match the harness's own line, anchored:
`grep -qx 'SMOKE| VERDICT: PASS'`.

### Why the numbers move at all

`kernelMemory` varies run to run — 317 325 to 332 621 across six identical
runs, and 296 493 to 395 089 over a wider set. Some of that is presumably the
JIT: trace IR, snapshots and the `jit` state go through `lj_mem_realloc`, so
whether a trace has been recorded by the moment OC takes its measurement
changes the answer. That is a hypothesis, not a measurement. What matters here
is the consequence: the baseline OC sizes every machine from is **not
deterministic**, which is an independent reason not to run at a 1% margin.


## 10. Known costs and hazards

* **A JNI field get and set on every allocation.** This is what stock
  OpenComputers pays on PUC Lua, so it is not a regression against OC — but it
  *is* a regression against our previous unlimited build, and this project sells
  speed. Unmeasured; batching the publish (keeping a local delta and flushing on
  a threshold) would trade `freeMemory` precision for throughput. Do not do that
  without a benchmark.
* **`kernelMemory` is persisted to NBT** (`NativeLuaArchitecture.save/load`). A
  world written by a build with accounting dead carries `kernelMemory == 1`;
  loading it under this build recomputes `totalMemory` as `1 + ram` and starves
  the machine. Nothing has run in Minecraft, so no such save exists — but this
  must not ship to an existing world without a migration that discards a
  `kernelMemory` of 1.
* **The `jobject` is a weak global ref** and is used without an
  `IsSameObject(env, obj, NULL)` liveness check. jnlua does the same; adding the
  check would cost a JNI call per allocation.
* **`jint` throughout**, as in jnlua: a machine over 2 GB would wrap. OC caps
  `maxTotalRam` far below that.

## 11. Remediation plan for the RAM scale

Two separate items, and only one of them is urgent.

### Calibration -- one day, not a blocker

`ramScaleFor64Bit` is *exactly* the knob for "objects are bigger on this VM":
OC's 1.8 was set for 64-bit PUC Lua, and our kernel measures ~1.85x PUC's. So a
value around 1.8 x 1.85 ~ 3.3 is the knob doing its job, not a fudge -- the
apparent RAM the player sees stays the same, the real bytes behind it scale.

Do it by measurement rather than arithmetic: peak `used` over a full boot of
OpenOS *and* the three census OSes (QuickOS, axis-os, MineOS), with margin for
the run-to-run variance in §9, and set our architecture's default from that.
Until then `smoke-test.sh` pins 3.0. This is a config value we own; nothing
else waits on it.

### The emergency GC -- real, bounded, a milestone of its own

PUC collects-and-retries at the wall (`lmem.c:85-94`); LuaJIT throws
(`lj_mem_realloc`). With calibration done, the whole remaining exposure is "a
program right at the edge OOMs slightly earlier than it would on stock OC."

#### The constraints, verified against this tree 2026-09-04

An earlier design pass produced these as a transcript that no longer exists.
Each was re-derived here by reading the source and then adversarially re-checked
by a second reader told to default to disagreement. **All nine came back
PARTIAL: every conclusion roughly survived and every stated mechanism was wrong
in some load-bearing way.** They are recorded with the corrections because the
wrong mechanisms are the plausible ones, and this section previously prescribed
a design built on two of them.

**C1 -- A full collect driven from the allocator hangs on-trace, and does so
unconditionally.** `lj_gc_fullgc`'s terminal loop is
`do { gc_onestep(L); } while (g->gc.state != GCSpause);` (`lj_gc.c:800`), driven
on *state*, not on the return value. `case GCSatomic` returns `LJ_MAX_MEM`
without assigning `g->gc.state` while `tvref(g->jit_base)` is set
(`lj_gc.c:673-677`), and `:799` forces `GCSpause` immediately before the loop,
so the first pass always reaches `GCSatomic`. There is a second non-advancing
return at `GCSfinalize` (`:706-710`).

> Corrections to the inherited claim, all three material. The guard is
> `jit_base` -- *executing mcode* -- not "recording or compiling"; recording is
> explicitly supported, with `gc_traverse_curtrace` marking the trace under
> construction (`lj_gc.c:636`) behind a `traceno == 0` early-out (`:259`). The
> loop is not driven on `gc_onestep`'s return value. And in `lj_gc_step`,
> `LJ_MAX_MEM` is the *opposite* of a spin -- it is a working "abandon this
> budget" sentinel: `lim -= LJ_MAX_MEM` makes the `:746` loop condition 0 in
> both the GC64 and 32-bit builds.

**C2 -- It also re-enters the allocator, in a narrower place than claimed.**
Only *positive-delta* re-entry matters, because `lj52shim.c:290` lets every
shrink through. The live site is the sweep phase itself: `lj_gc.c:696` calls
`lj_str_resize`, which reaches `lj_mem_realloc` -> `g->allocf` (`lj_str.c:139`).
A nested refusal there raises `lj_err_mem` and longjmps out of the middle of a
sweep, leaving `g->gc.state` mid-sweep with `mref(g->gc.sweep)` pointing into a
partially-swept list.

**C3 -- The finalizer objection is backwards, and following it would diverge
from PUC rather than match it.** LuaJIT has no finalizer-in-OOM hazard today,
because nothing drives a GC from the allocator at all: `lj_gc.c:874-875` and
`:888-889` go straight to `lj_err_mem`. Do **not** add an `isemergency`-style
guard to `lj_gc_fullgc` -- its only caller is `lua_gc(LUA_GCCOLLECT)`
(`lj_api.c:1255`), an ordinary Lua-visible collect where running finalizers is
correct and where PUC itself passes `isemergency = 0`. The open question is
whether to *add* an emergency variant, not to guard the existing one.

**C4 -- There is no re-entrancy guard, and the threshold sentinel is not one.**
Setting `threshold = LJ_MAX_MEM` mutes *implicit* triggers only. Calling
`collectgarbage("collect"/"step"/"restart")` from inside a `__gc` metamethod
re-enters or disarms the collector today, unguarded, in stock LuaJIT.
**Unreachable for us, and worth stating why:** OpenComputers does not put
`collectgarbage` in the sandbox global table (`machine.lua:737`, and see §8c),
so sandbox code cannot reach it. That is a mitigation by the host, not by the
VM -- if the sandbox ever gains `collectgarbage` alongside `__gc` userdata, this
becomes reachable state corruption.

**C5 -- PUC-faithful pinning fails, but not by reading uninitialised slots.**
A collection at `lj_tab.c:123-124` *frees the table under construction* -- it is
unreachable, current-white, and already on `g->gc.root` -- leaving `newtab`
writing through a dangling pointer at `:46-48`.

**C6 -- `L->top` is stale at arbitrary allocation points**, and from
`lj_mem_newgco` the object is worse than stale: it is partially initialised and
already rooted and whitened (`lj_gc.c:893-895`). So the allocator is the one
place in this tree that provably never collects, and it must stay that way.

#### What the fix therefore has to look like

**Not a collect at the point of refusal.** C1, C2 and C6 each independently
forbid it. The previous text here -- "a full collection that skips finalizers,
as PUC's `isemergency` does, and a retry in `lj_mem_realloc`" -- is a
transliteration of PUC that does not survive contact with this VM, and C3 says
the finalizer half of it was aimed at a hazard LuaJIT does not have.

**The shim can reach the VM, and that is where the design space is.** An
earlier draft asserted the allocator has no handle on the running state. It is
false: `lj52shim.c:472-474` already includes `lj_obj.h`, `lj_dispatch.h` and
`lj_jit.h`, and `:540` already does `G(M->L)`, so `gcref(g->cur_L)`,
`g->gc.total` and `g->gc.threshold` are all in reach *today*. That makes a
**deferred** design available -- the allocator refuses as it does now, but
records the pressure, and the next ordinary safepoint (where `L->top` is sound
and `jit_base` is clear) does the collect and the retry. Writing the false
version into this document would have cost us that option, which is the concrete
reason these constraints are being recorded rather than the conclusions alone.

Whatever the shape, it gets its own adversarial review, on the same footing as
the CHECKHOOK patch. Schedule it; nothing is gated on it.

#### Pacing is a mitigation, not a candidate

Recorded earlier as "tried and rejected": `lua_gc(LUA_GCSETPAUSE, ...)` when a
cap is armed. Safe, it helps, and it does not rescue the stock scale -- 0/3 at
`ramScale` 1.8 with pause 150 / stepmul 400 -- while spending collector CPU,
which is the opposite of this project's point.

That rejection was measured against **boot success**, which is a different
question from the one §8c now poses, so it is worth re-testing against `sieve`.
But §8's corrected mechanism already bounds what such a test can conclude: the
collector is rate-limited below the allocation rate, at a fixed `lim = 2000`
cost units per step against unbounded allocation. Raising `lim` raises a
ceiling; it does not remove one. **For any pacing setting there is an allocation
rate above it, and in OpenComputers the player picks that rate and picks the
wall as well, since `ramScaleFor64Bit` and the memory tiers are both mod
settings.**

So a pacing experiment must be designed to find **where pacing breaks**, sweeping
the workload and the cap independently, and its result is a margin figure. It
cannot retire this item, and a passing benchmark must not be allowed to become
the implicit ceiling on what gets built.

### The JIT fix landed, and the blind spot now has a number

`hook-vs-jit.md` §7 made traces actually run, so the cap's blindness to JIT
machine code stopped being theoretical. Measured (`hook-vs-jit.md` §8, via the
`_OCLJ_JITSTATS()` accessor added for it): a booted OpenOS holds **196 608 B**
of machine code, stable across six consecutive runs, against a `maxmcode`
ceiling of 2 097 152 B. The cap charges for **none** of it.

So "the RAM cap is enforced" means "enforced for `allocf` traffic". A machine
advertising 1024 KB actually costs a server roughly 20% more than it says, and
its worst case is 2 MB over -- twice the advertised size. Two things follow,
neither done:

* an operator sizing a server needs the real figure, so `maxmcode` should
  probably be scaled per machine (`jit.opt` takes it per state, and the
  roadmap already carries that item) rather than left at a 2 MB default that
  was chosen for desktop LuaJIT;
* allocation from *inside* a compiled trace is the other half of what was
  masked, and is still unmeasured.

## 12. Not fixed here

* the emergency-GC divergence of §8;
* the C-recursion ceiling (LuaJIT has no `nCcalls`), still open;
* a real JIT benchmark inside a machine — still the project's largest
  unmeasured claim, and now with a second reason to want it.
