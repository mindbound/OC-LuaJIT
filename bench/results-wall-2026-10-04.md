# The collector at the wall (2026-10-04)

**Stage B, recovery at the wall: a program that catches "not enough memory" and drops
its data now carries on, and the last quarter of memory costs 0.7-2.7x what it costs on
stock, not 21-121x.**

- **The credit.** A growth that would pass the cap is lent from a bounded credit:
  - G = total/16, clamped to 32-512 KB;
  - G/2 normally, and G from a refusal until a proof finds the heap back under the cap;
  - 16 KB more for the kernel only.

  The loan is charged, and the collector is armed to repay it. The allocator still never
  collects.
- **The cadence.** The emergency cycle re-arms after half the post-cycle headroom is
  used, not at every checkpoint.
- **Our additive arms, 60 runs of the capacity matrix:** no "recovery refused", no
  machine down, against 19 of 60 on 2026-10-03.
- **Near the wall:** 0.7-2.7x stock's time in 39 of 41 cells.
- **Capacity:** 0.99-7.14x stock's objects held at the refusal; at least stock's in every
  cell but O closures at 1024 KB (8087 against 8192).
- **What remains:**
  - 3 stalls and 1 dropin machine down in 68 of our runs, where a refusal landed in code
    with no handler of the program's (stock: 0 of 20);
  - one boot failure, unexplained.

The design's back-off was built, found by the harness to suppress the trace flush, and
removed.

**Stage A, the parked collector: fixed.** An emergency arm that lands while LuaJIT's
collector is sweeping is now restarted when the old cycle ends without `atomic()`,
instead of staying armed at the pause with the threshold twice the heap (the *park*).
The safety valve now counts allocation attempts only, so one armed sweep of more than
65 536 dead blocks no longer reads as a bailout. Both were seen failing on the 2026-10-03
shim first, in hermetic tests. In the machine the park did not occur at all in the fills
measured: it is not what took 192 KB machines down. Stage C makes `kernelMemory`
trace-free; this document grows with it.

All harness runs: ocelot-brain, JDK 8, pinned to the performance cores (`affrun
C03C03`), the watchdog kernel on ours, OC's own on stock. Baseline: the shipping
additive DLL `cb29485d` (and the dropin `f556d839`), saved before any rebuild. Stage A:
additive `4c225c7d`, dropin `ed3b4fe9`, shim object `d156cb7a`. Stage B: additive
`2869c2ad`, dropin `b33a1dbe`, shim object `377bc4d6`. Archive:
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
choice was shim-only, with the judges' grafts:

- **From safe-point:** a slice of credit only the kernel can use, and a back-off for
  pre-emptive cycles that a fill makes useless.
- **A reserve tier that survives a reload.**

All three arrived with stage B; the back-off was then removed (below). The hook carrier
stays a conditional stage, used only if the credit falls short. The decisions taken:

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

## Stage B: the credit at the cap, and the cadence

**The change** (`native/lj52shim.c`, THE CREDIT, THE CADENCE and NO BACK-OFF;
`lj52_gc_credit`, `lj52_gc_refused`, the unarmed branch of `lj52_gc_pressure`).

**A growth that would pass the cap is lent** up to a bounded credit, charged like any
other allocation, and the collector is armed to repay it. The allocator still never
collects. G = clamp(total/16, 32 KB, 512 KB):

- **Burst tier:** G/2 past the cap.
- **Reserve tier:** G, from a refusal until a proof finds the heap back under the cap. A
  cycle that runs before the program drops its data therefore does not take the recovery
  away.
- **A fresh record** whose live data is already past total + G/2 starts in the reserve
  tier, so a machine eris has just loaded is not refused for history its record never
  saw.
- **The kernel's slice:** 16 KB more, for the kernel only. That means no resume armed,
  or the thread that made the outermost arm.
- **Never under a finalizer or a host GCSTOP.**
- **The bound is absolute, not incremental:** used <= total + G (+ the slice). Every
  refusal arms, from any headroom.

**The arm while unarmed:**

- **No cycle proven yet:** headroom < w, as before.
- **Below the cap** (the last proof left the heap under it):
  - when headroom < min(w, half the post-cycle headroom);
  - and whenever a growth crosses the cap.
- **Past the cap** (the last proof left the heap there): when the distance to the current
  tier's top has halved since that proof.
- **The flush:** a cycle the flush armed never raises the flush flag at its own proof.

`_OCLJ_WALLSTATS` grows to nine values: overdrafts, od_peak, od_state, park_resets,
od_limit, the kernel's slice, then THE CADENCE's own gc_low, armby and hyst.

**No back-off.** The judges' graft from the safe-point design suspended pre-emptive
cycles once one freed less than half of what had been allocated since the proof before
it, which is the signature of a fill. It was built, and in a fill it saved 9 of 21
cycles. It was removed after the harness's `mem-2-pressure-flushes-traces` failed on
both builds that had it.

**The first stage-B build.** The additive and the dropin both failed `mem-2`:

- **The additive:** a program held live data until 33 KB were free, the collector armed
  once in 7 s, and no trace was flushed. The stage-A build had armed 13 451 times there
  and flushed 118 times.
- **The dropin:** 43 KB free, one arm in 6 s, no flush.

I first took this for a back-off left over from an earlier phase, which only a cycle at
the wall would end, and which a program holding below the cap never reaches. W13 shows
that hazard is real hermetically: on that build a later hold gets no cycle at all. The
harness runs, though, show one arm during the program, not none. That is the pattern the
second build exposed.

**The second build** added a release: the heap falling below the level its engaging
cycle left ends the back-off. Then:

- **The chain:** the additive passed and the dropin failed again.
- **The trace:** a cadence trace added to mem-2 (on that build, `_OCLJ_WALLSTATS` 8-11:
  the back-off, gc_low, armby, hyst), on a rerun of both full suites, showed why.
  - The dropin program's first cycle left the heap at 1 539 959 B against a cap of
    2 285 966 B: 746 007 B of headroom, outside the 571 491 B watermark. So that proof
    rightly asked for no flush.
  - By the arm gate, that cycle had freed about 174 KB of the program's own garbage,
    under half of the 1.2 MB the heap had grown since a proof taken before the program
    began. So the back-off engaged, with its release level at 1 539 959 B.
  - The program then grew to 2 216 979 B without dipping below that level, and no
    further cycle ran.
  - In the traced additive rerun, the heap dipped 2 KB under its release level one
    sample after the back-off engaged, and that released it. The chain run that passed
    (3 arms, 1 flush) carries no trace.

W14 reproduces the dropin's pattern hermetically. The flush needs one proof inside the
watermark, and halving the gate gives it that at log2 cost.

**Hermetic, fail-first** (`test/native/mem_test.c` W1-W14; there is no W6, and W9 is
printed, not asserted). Each asserted check was seen failing before it passed:

- W1-W5, W7, W8 and W10-W12 on the baseline object, and W1-W4, W7, W8 and W10-W12 on
  stage A's.
- W13 on the first stage-B build (it passes on the second).
- W14 on the second (it was not run on the first).

| check | baseline object | stage B |
|---|---|---|
| W1 / W1L / W1j: fill 512 KB to the refusal, catch, drop, carry on (C mode, legacy, JIT on; 3 rounds each) | the program's next allocation **refused**; about 1550 cycles a round (1551-1554 across runs and modes) | recovers every round; 21 cycles a round; repaid within one credit of further allocation |
| W8: the same, with one allocation between the catch and the drop | **refused** | recovers; repaid within one credit |
| W2b: one request bigger than the headroom, headroom still over the watermark | refused **without arming** | refused, armed |
| W2c: the same request again | **refused** (the garbage was never collected) | succeeds |
| W2d: a request of headroom + G/4 | refused | lent, repaid at the next checkpoint |
| W3: a compiled loop's sunk table at cap == used | **ERRMEM** (status 4; from the trace exit's restore, or the TDUP if uncompiled) | lent |
| W4: 20 000 x 64 B over 256 KB live, 64 KB headroom | **10 000** cycles, 63-122x the far case's time across three runs | 39 cycles (bound 61 = 3x stock's ~19.5, plus 2), 1.0x |
| W7: 4000 caught attempts past the wall, as the sandbox | (no credit) | excursion 32 710 B against od_limit 32 768; collects about one per refusal |
| W10: the kernel's table.pack after the sandbox spent both tiers | **refused** | succeeds, armed and after the disarm |
| W11: a fresh record with its cap set 3/4 G under the live set | the sandbox's first allocation refused, uncaught: the resume returns ERRMEM | 64 B lent, 32 KB refused |
| W12: the worst W1 round's cycle count (bound 32) | 1553 | 21 |
| W13: a fill, its data dropped and collected, then a hold inside the watermark below the cap | (re-arms everywhere) | 2 proven cycles, the flush flag raised; **first stage-B build: no cycle at all** |
| W14: live to the watermark's edge, garbage into it, live to 100 KB short of the cap | (re-arms everywhere) | 3 proven cycles, flag raised; **second stage-B build: 1 cycle, its proof outside the watermark, no flag** |
| W9 (printed, not asserted): an allocate-first retry with no checkpoint, request = headroom + G + 64 KB, covered by garbage | 20 tries made, none of the first 19 succeeding | the same: the residual (the line cannot tell a 20th-try success from none) |

Four existing checks were re-scoped on purpose; each still passes on the previous
objects:

- **M5 and C3a** now accept a refusal anywhere up to cap + G + the kernel's slice.
- **M6 and C6** set a cap that both tiers and the slice exhaust. Both carry 64 KB of live
  ballast, so that cap can sit 48 KB under the live set.
- **M6 also collects first.** M5's refusal now arms, and the push's checkpoint would
  otherwise collect M5's garbage.

**Sabotages** (`negative-control.sh` 4.6-4.12). Each fails exactly the checks named:

| sabotage | fails |
|---|---|
| credit = 0 | W1, W1L, W1j, W2d, W3, W8, W10, W11 |
| a refusal does not arm | W2b, W2c |
| no hysteresis | W4, W12 |
| credit = the whole cap | M5, C3a, W1, W1L, W1j, W2b, W7, W11, W12 |
| no kernel slice | W10 |
| no fresh-record reserve | W11 |
| every proof closes the reserve (safe-point's rule) | W8, W11 |

Two existing controls changed lists, each for a measured reason:

- **`stopgap`** (accounting off) now fails every W check but W2c, whose retry succeeds
  anyway when nothing is ever refused.
- **`nopending`** no longer fails M7. M6 now collects M5's garbage before it exhausts the
  cap, which confirms what its comment had called "the likely reading, not verified": the
  collector freeing M5's runaway inside the push was what made M7 fail there.

W13 and W14 have no sabotage of their own. The mechanism they guard against is no longer
in the code; they stay as regression tests against its return.

Two of the design's tests were redrawn from what they found:

- **W8 and W1 assert repayment within one credit of further allocation, not by the end of
  the chunk.** In the reserve tier the arm halves its distance to the top rather than
  firing at every grant, which bounds a held-over-the-cap program to log2 cycles per tier.
  The dropped data is collected at the latest when that distance halves. Stock does not
  repay any sooner: its emergency collection runs at the next refusal.
- **The reload rule applies to a fresh record only.** The first draft derived the reserve
  tier from the heap alone. In kernel context the slice takes the heap past total + G/2
  legitimately, so a kernel fill spent the reserve tier before its first refusal and
  recovery had nothing left. W1, W1L, W1j and W8 failed at cap + G + the slice
  (`logs/mem/draft-stageB-heap-only-reserve.log`).

**Gates, stage B build** (shim object `377bc4d6`, additive `2869c2ad`, dropin
`b33a1dbe`): mem_test 67/0, wd_test 35/0, shim_test PASS, security PASS, race 2/0,
penalty 6/0.

The negative control passed on its re-run (`negctl-2.log`), with 23 controls:

- 16 sabotages, each failing exactly its named checks;
- one expected death and one expected alarm;
- two build refusals;
- three positive controls passing.

`gates.sh`'s own run of it (`negctl.log`) found stopgap's list one short (W14), then
stopped at the refusal sabotage's stale `sed` anchor.

The earlier builds' gates and chains are archived as evidence:

- the first build (shim `a5e7700a`): `logs/gatesB-first-build/` and
  `logs/chainB-first-build/`;
- the back-off with its release (shim `032c1cc9`): `logs/gatesB-second-build/` and
  `logs/chainB-second-build/`;
- the mem-2 cadence trace, taken on that build with the trace added:
  `logs/mem2-cadence-trace/`.

## Stage B in the machine

**The full suite** on the final build: additive JIT on 65/0, JIT off 63/0, sieve only
59/0, the dropin 62/0, stock 47/0. `mem-2` passes on both the additive and the dropin (23
flushes on the dropin, holding 1531 KB). `acc-4` reads its refusal past the cap, within
G and the kernel's slice.

**The capacity matrix** (`chainB`) uses the 2026-10-03 layout in one pinned chain, 88
capacity runs after the five full suites:

- **Arms:** stock S, then ours D (as shipped), E (JIT off through kernel init) and O (JIT
  off throughout), plus the dropin L, which takes the shim's legacy path.
- **Sticks:** 192 KB (3 reps), 256 KB and 1024 KB (1 rep each), four shapes each. L ran at
  rep 1 on 192 and 1024 KB only.

The first table compares against chain1, which ran the same layout on the 2026-10-03 DLL:

| | runs | clean | recovery refused | stalled | machine down | boot failed |
|---|---|---|---|---|---|---|
| stock S, both chains | 20 + 20 | 40 | 0 | 0 | 0 | 0 (chain1's one stock boot failure was at scale 1.0, outside this layout) |
| ours D/E/O, chain1 (2026-10-03) | 60 | 40 | 12 | 0 | 7 | 1 |
| ours D/E/O, stage B | 60 | 56 | **0** | 3 | **0** | 1 |
| the dropin L, stage B | 8 | 7 | 0 | 0 | 1 | 0 |

**What is gone:** P1's two modes on our architecture. No program that caught the refusal
and dropped its data had its own next allocation refused, and no additive machine went
down.

**What is left:** three stalls, one dropin machine down, one boot failure.

- **A stall (new class, `analyze.py`)** is a fill stuck at `filling/N` with the machine up
  and the probe's free-memory line never written. Each step of the probe allocates in
  three places outside its `pcall`: the closure it hands to `pcall`, the stage string,
  and `event.timer(0, step)`. When the heap meets a credit tier's top at one of those,
  the refusal lands there, the timer chain breaks, and the handler never runs.
- **The dropin's down** is a refusal landing where no handler caught it: four refusals,
  the reserve tier's top reached, the machine stopped. It landed in OpenOS's dispatcher
  or the kernel; the log does not say which.
- **Stock can in principle fail the same way.** If live data crosses the cap at a batch's
  last object, its next allocation is outside the handler too. But stock collects at the
  refusal, so it rescues every crossing that garbage covers. We refuse when live data
  plus the garbage since the last cycle crosses the top; halving keeps that garbage
  small, but not zero.
- **The measured rate** is 4 of 68 of our runs against 0 of 20 on stock. The hook
  carrier would not change it: the refused allocation still fails, however soon a
  collection follows. A possible follow-up is to lend the first crossing after each
  proof and let the cycle it arms decide, which moves the refusal to the next allocation
  after a collection. It is not built.
- **The boot failure** is `one-array-r2-D`, on the boot loop's first tick, before OpenOS
  reached its shell. Kernel init had left 322 843 B free, the usual 192 KB reading. OC's
  synchronized-call path failed its own stack assertion (`lua.getTop == 2`,
  `NativeLuaArchitecture.scala:172`), and the machine stopped with `Error.InternalError`.
  - No refusal is visible.
  - The harness's dirty-stack check was silent. That rules nothing out: it is silent in
    all 17 of the 93 runs whose quiesce took 0 spins, and the other 76 warn
    `getTop=2`.
  - It is the first such failure in about 140 harness runs this session. Unexplained,
    and recorded as such.

**Near the wall** (clean runs, median per cell):

- **The last five batches' time:** 0.7-2.7x stock's in 39 of the 41 cells with a clean
  run on both sides. The exceptions are 0.1x (a single E string run at 256 KB) and 3.3x
  (a single L string run at 192 KB). On 2026-10-03 it was 21-121x.
- **Arms per batch:** 0.5-5.5, against 100-341 per stick and arm on 2026-10-03 (78-401
  per run). Above the judges' 3 at 192 KB (E 5.5, O 4.0) and at 256 KB (E 3.7, O 3.6).
- **Bailouts and park resets:** 0 throughout.
- **The excursion past the cap:** four runs passed their run's G, each by 105-131 B: E at
  192 KB (32 883 against 32 768), D and L at 192 KB, and E at 1024 KB. None passed G plus
  the kernel's slice; the slice and the norefuse window allow it.

**Capacity, the objects held at the refusal** (clean runs, median):

- Ours holds at least what stock holds in every cell but one, 0.99x to 7.14x stock's. The
  exception is O closures at 1024 KB, 8087 against 8192.
- The tightest cell is still closures at 1024 KB: D 1.05x, E 1.00x, O 0.99x, L 1.05x.
- The credit lets each arm hold a little more than on 2026-10-03 in most cells, for
  example E record at 192 KB, 584 against 505. Not E string at 256 KB or D array at
  1024 KB, both single runs.

**Idle, 400 ticks after boot:**

- **192 KB, arm E** (trace-free `kernelMemory`): 38 arms (32-40) and 18 trace flushes
  (12-20). On 2026-10-03 it read 1390-2964 arms and 16-29 flushes.
- **Every other cell:** 0 or 1 arms.

The arms are P2's idle thrash, gone. The flushes are P4's: stage C's business, with the
flush predicate.

**`kernelMemory` is unchanged by stage B.** D reads 334 733-413 645 B, clustered around
335-350k, 367k and 411-414k as on 2026-10-03, and E reads 164 525 B.

**Full tables:** [runs/2026-10-04-wall/chainB-tables.md](runs/2026-10-04-wall/chainB-tables.md).
