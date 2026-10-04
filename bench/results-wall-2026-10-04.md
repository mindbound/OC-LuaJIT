# The collector at the wall (2026-10-04)

**Stage A, the parked collector: fixed.** An emergency arm that lands while LuaJIT's
collector is sweeping is now restarted when the old cycle ends without `atomic()`,
instead of staying armed at the pause with the threshold twice the heap (the *park*).
The safety valve now counts allocation attempts only, so one armed sweep of more than
65 536 dead blocks no longer reads as a bailout. Both were seen failing on the
2026-10-03 shim first, in hermetic tests. In the machine the park did not occur at all in
the fills measured: it is not what took 192 KB machines down, and it is not what makes
programs fail at the wall. Those are P1 and P2, stage B (the credit at the cap and the
re-arm cadence); stage C makes `kernelMemory` trace-free. This document grows with them.

All harness runs: ocelot-brain, JDK 8, pinned to the performance cores (`affrun
C03C03`), the watchdog kernel on ours, OC's own on stock. Baseline: the shipping
additive DLL `cb29485d` (and the dropin `f556d839`), saved before any rebuild. Stage A:
additive `4c225c7d`, dropin `ed3b4fe9`, shim object `d156cb7a`. Archive:
[runs/2026-10-04-wall/](runs/2026-10-04-wall/).

## The four problems, and the design

The roadmap row ([../docs/roadmap.md](../docs/roadmap.md), "THE COLLECTOR AT THE WALL")
and [results-ramscale-2026-10-03.md](results-ramscale-2026-10-03.md) found them:

- **P1, recovery at the wall.** PUC's `luaM_realloc_` runs a full collection when it is
  refused and tries again. Our allocator cannot collect (constraints C1-C7, which the
  build gate enforces), so a program that catches "not enough memory" and drops its data
  has its own next allocation refused. 20 of 60 capacity runs failed this way or went
  down, against 0 of 20 on stock.
- **P2, the last quarter.** Once a proven cycle leaves the heap inside the watermark,
  every GC checkpoint re-arms a whole cycle: 20-120x stock's time over the last batches
  of a fill.
- **P3, the park** (a code reading on 2026-10-03, confirmed here).
- **P4, the `kernelMemory` windfall.** Kernel-init traces are counted in the figure OC
  grants on top of the RAM, then flushed: 335-413 KB against a trace-free 164 393 B.

Eleven requirements were written first (R1-R11: stock's observable contract, collection
work proportional to bytes allocated, no park, a deterministic trace-free
`kernelMemory`, a bounded and charged excursion past the cap, no collection inside the
allocator, minimal VM change, eris-safe state, unchanged throughput far from the wall,
fail-first tests, no new player knob). Three designs were judged against them:

- **shim-only:** a bounded credit at the cap, hysteresis, the park reset;
- **safe-point:** a full collection run from the watchdog's count hook at the next
  instruction boundary;
- **vm-faithful:** an emergency collection inside `lj_mem_realloc`, as PUC does.

vm-faithful was rejected: it breaks R6 and R7 and has an unaudited host-crash path. The
choice was shim-only, with the judges' grafts (from safe-point, a back-off for
pre-emptive cycles that a fill makes useless and a slice of credit only the kernel can
use; and a reserve tier that survives a reload), which arrive with stage B. The hook
carrier stays a conditional stage, used only if the credit falls short. The decisions
taken:

- **Bounded credit first.** The shim only; no build-gate change.
- **Credit G = clamp(total/16, 32 KB, 512 KB),** in two tiers: G/2 before any refusal,
  G after one.
- **`kernelMemory` trace-free and unpadded** (arm E's 164 393 B on the 2026-10-03 DLL,
  164 525 B since stage A's one new global; stock's is 174 605 B), landing last.

The designs, the requirements and the judges' scores are archived under
`runs/2026-10-04-wall/design/`.

## Stage A: the park reset and the attempt-only valve

**The change** (`native/lj52shim.c`, THE PARK RESET and THE VALVE COUNTS ATTEMPTS):

- **The park reset.** In the armed branch of `lj52_gc_pressure`, a record that finds the
  collector at `GCSpause` with the white unchanged and `threshold > gc.total` writes
  `threshold = gc.total` again. The next checkpoint then starts a fresh cycle at stepmul
  0, which passes through `atomic()` and is proven by the latch. The reset fires only
  once the collector has been seen outside the pause since the arm (`gc_moved`). An arm
  made at the pause and followed by a free (a table rehash frees its old hash part right
  after allocating the new one) also leaves `gc.total` under the threshold, and that is
  not a park.
- **The valve counts attempts.** The 65 536-call bailout now counts growths, granted or
  refused, and never frees or shrinks.
- **Stats.** `_OCLJ_WALLSTATS` is a new raw global; its 4th value is `park_resets`.
  `_OCLJ_GCSTATS` stays at 20 values.

**Hermetic, fail-first** (`test/native/mem_test.c` W5, against the saved baseline object
`7c97f68a` through `OCLJ_SHIMOBJ`):

| check | baseline object | stage A |
|---|---|---|
| W5a: an arm in the sweep, then two checkpoints | **parked**: armed, state 0, stepmul 0, threshold 2 112 000 against gc.total 1 056 241 | proven: armed 0, stepmul back to 200, one park reset |
| W5b: 20 000 x 64 B over 1 MB live, 200 KB headroom | **refused** after 3195 tables, 0 collections | no refusal; collects 1 -> 10 001 (stage B's cadence brings this down) |
| W5c: 100 000 dead tables swept by one armed cycle | **bailout** 0 -> 1, the cycle never credited | collects 0 -> 1, bailouts 0 |

The first draft of W5c passed on the baseline object. Its garbage loop ran with the JIT
on, and allocation sinking removed all 100 000 tables, so the sweep had nothing to free.
The final W5c runs that loop interpreted.

**Sabotages** (`test/native/negative-control.sh` 4.4-4.5): removing the park reset
fails exactly W5a and W5b; counting frees in the valve again fails exactly W5c.

**The negative control runs again.** It still named `$OCLJ_BUILD/luajit/src` and
`$OCLJ_BUILD/obj`, stale since the per-platform build move, and had not run since. With
the paths derived as `run-mem.sh` derives them, it passes in full. Two expectation lists
had drifted, and both were re-pinned with the reason recorded beside them:

- `stopgap` (accounting off) now also fails W5a/b/c: an uncharged state never arms.
- `standinghook` also fails `wd_test` W10g, and does so on 2026-10-04's HEAD shim too: a
  standing hook keeps calling the parent's deadline callback, 2684 calls where the
  normal path promises none.

`run.sh`, `run-race.sh` and `run-security.sh` still have the stale paths; they ran
through a mirror of the old layout.

**Gates, stage A build:** mem_test 52/0, wd_test 35/0, shim_test PASS, security PASS,
race 2/0, penalty 6/0, negative control PASS.

## The instrument (stage 0)

The capacity probe now reads the collector's own state as well as its counters:

- `CAP-IDLE` gains collects, bailouts and park resets, the end state (armed, state,
  stepmul, threshold, gc.total, the native cap and figure) and whether `_OCLJ_WALLSTATS`
  exists.
- `CAP-MID` (new) takes a snapshot at every tick of the fill and counts how many read
  stepmul 0 and how many read the park.
- `CAP-GC` (new) gives the fill's collects, bailouts and park resets, the credit's
  counters (stage B), and the end state.

`_OCLJ_WALLSTATS` is looked up once, at idle. On a DLL without it, every later read is
skipped: `getGlobal` would intern the missing name, and at the cap that allocation would
be a refusal that arms the very collector being measured.

The harness's `gcstats` reader now takes booleans as 1/0. Positions 5 (armed) and 11
(flush_wanted) are booleans, and until now they always read -1; nothing consulted them.

**Seen first on the baseline DLL** (`chain0`, arm E, 192 KB):

- `wallstats=absent`.
- A record fill went down at `filling/500` within 220 ms. Its end state, read after the
  machine had stopped, had the park's shape (armed, state 0, stepmul 0, threshold
  256 000 against gc.total 128 106). That is also what OC's own full collection of a
  stopped machine leaves behind an armed record; this instrument cannot tell the two
  apart (see stage A in the machine, below).
- An array fill ended "recovery refused" after 42 275 arms; stepmul read 0 in 1 of 1000
  snapshots, and the collector never parked.

The first instrument sampled every 8 ticks and missed the 220 ms fill entirely; it now
samples every tick.

## Stage A in the machine

**The full suite** on stage A's DLLs:

- The dropin: 62/0.
- The additive build: 64 of 65 at first. **acc-4 had passed only because the collector
  was parked.** It allocates without bound on a raw `LuaStateLuaJIT(4 MB)`, then reads
  the native figure and expects about 4 MB. Its fill was a chunk local, which is garbage
  the moment the refusal unwinds. On HEAD the collector was parked and never collected
  it, so the read gave 4 194 319 B. On stage A the cycle the refusal had armed runs at
  the next checkpoint and collects the fill first, so the read gave 23 858 B.
- With the fill kept reachable through a global (`OcljSmoke.scala`, acc-4), the
  additive suite is 65/0 again (`chainA2`), reading 4 194 281 B.

**The reduced matrix**, arm E (the JIT off through kernel init) at 192 KB, 4 shapes x 3
reps on stage A. The baseline DLL ran at rep 1 of each shape in the same chain, and
chain1 (2026-10-03) ran the same cell on the same baseline:

| build | clean | recovery refused | machine down | boot failed |
|---|---|---|---|---|
| stage A, 12 runs | 6 | 3 | 3 | 0 |
| baseline, same chain, 4 runs | 3 | 0 | 1 | 0 |
| baseline, chain1, 12 runs | 5 | 3 | 3 | 1 |

**The park did not occur in these fills.** `park_resets` stayed 0 in every stage-A fill
and in every idle window: each arm landed at the pause, straight after the proof before
it, which is P2's re-arm at every checkpoint, so no arm landed mid-sweep. Bailouts stayed
0 throughout.

So the downs are not the park. All three stage-A downs are P1: a refusal raised where no
handler of the program caught it. The "parked" readings `chainA` reports for its down
runs come from samples taken after the machine had stopped (cap Int.MaxValue). Those
samples show an armed record after the host's own full collection, which this
instrument cannot tell from a park, and the harness now counts the running machine only.
Timing is not read from this chain: it is the same build family before stage B, and
P2's re-arm still dominates the last batches.

`chainA2` ran the corrected sampler on four more record fills, two per build. Both
baseline fills went down and both stage-A fills ended clean. Next to `chainA`'s three
stage-A downs, at n = 2 that is noise, not an effect. What it does show is the sampler:
each baseline down took 6 samples, 1 of them after the stop, and none read the park while
the machine ran. Before this run, that one post-stop sample was what `chainA` counted as
"parked".

**What stage A buys,** then, is correctness at a state the 192 KB fills did not reach but
the hermetic W5 reaches deterministically: an arm landing in the sweep with more than
half the cap live. It also makes `bailouts == 0` mean what the acceptance test says it
means. P1 and P2 are stage B.
