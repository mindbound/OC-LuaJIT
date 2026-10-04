# 2026-10-04 -- the collector at the wall

The evidence behind [../../results-wall-2026-10-04.md](../../results-wall-2026-10-04.md).
All harness runs on ocelot-brain with JDK 8, launched pinned to the performance cores
(`affrun C03C03`; the java process inherits the mask), the watchdog kernel on ours, OC's
own on stock, at OC's `ramScaleFor64Bit` 1.8. Run names are `<stick>-<shape>-r<rep>-<arm>-<build>`:
sticks `one` = 192 KB, `onehalf` = 256 KB, `threehalf` = 1024 KB; arms S = stock PUC
5.2, D = ours as shipped, E = ours with the JIT off through kernel init (on once
`kernelMemory` is taken), O = ours with the JIT off throughout, L = the dropin (OC's own
LuaState class, the shim's legacy path).

The builds:

- `base`: the 2026-10-03 additive DLL `cb29485d`, saved before any rebuild.
- `A`: stage A, additive `4c225c7d`.
- `B3`: stage B as committed, additive `2869c2ad`, dropin `b33a1dbe`, shim object
  `377bc4d6`.
- Two earlier stage-B builds are kept as evidence:
  - B, first: the back-off, shim `a5e7700a`;
  - B2, second: the back-off with its release, shim `032c1cc9`.
- `C`: stage C, additive `05d133cf`, dropin `4cb483a5`, shim object `0259f0d1`, with the
  site-13 kernel (the harness patches ocelot-brain's at every run; the mod's is `1d12c322`).
  `C0` is the site-13 kernel on stage B's DLLs.

| file | what |
|---|---|
| `design/` | the requirements (R1-R11), five read-only surveys of the code at `bd302f2` (their `file:line` citations are to that tree), three designs and the judges' scores and staged plan |
| `chain0.log` | stage 0: the new capacity-probe instrument (`CAP-MID`, `CAP-GC`) against the baseline DLL, two runs |
| `chainA.log`, `chainA-tables.md` | stage A: the full suite (additive, dropin) on A's DLLs, then the reduced capacity matrix, arm E at 192 KB, 12 runs on A with the baseline at rep 1 of each shape interleaved; `scripts/analyze.py chainA.log` |
| `chainA2.log` | after acc-4 kept its fill reachable and `CAP-MID` counted only the running machine: the additive full suite again, and four record runs (two per build) |
| `logs/mem/` | `mem_test` on the stage-A tree against A's shim object and against the baseline object (`OCLJ_SHIMOBJ`); the negative control's first run after its paths were fixed, with the two drifted lists it found |
| `logs/gatesA/` | `scripts/gates.sh` on the stage-A build: mem, wd, shim, security, race (the last three through a mirror of the pre-per-platform layout), penalty, the negative control; object checksums |
| `chainB.log`, `chainB-tables.md` | stage B: the full suite (the dropin, additive JIT on and off, sieve, stock), then the capacity matrix in the 2026-10-03 layout (S D E O on 192 KB x3 reps, 256 and 1024 KB x1, four shapes) plus the dropin L on 192 and 1024 KB at rep 1: 88 capacity runs, 93 logs with the full suites; the tables are `scripts/analyze.py` and `scripts/held.py` |
| `logs/mem/final/` | the final `mem_test.c` (W1-W14) against the stage-B object, the second stage-B build's (fails W14), stage A's and the baseline's |
| `logs/mem/stageB-*`, `logs/mem/draft-*` | the stage-B tests' fail-first runs as they were written: W1-W11 against the baseline and stage-A objects; W12 against a draft build with the back-off (12 cycles), its sabotages and the baseline; W13 on the first and second stage-B builds; `draft-stageB-heap-only-reserve.log`, the first draft, whose reserve rule read the heap alone (W1, W1L, W1j, W8 fail at cap + G + the slice; M6b and C6 fail before the ballast) |
| `logs/gatesB/` | `scripts/gates.sh` on the stage-B build; its own negative-control run, `negctl.log`, found stopgap's list one short (W14) and then stopped at the refusal sabotage's stale `sed` anchor (`summary.txt` reads exit 2); `negctl-2.log` is the passing re-run after both were fixed |
| `logs/gatesB-first-build/`, `logs/chainB-first-build/` | the first stage-B build (the back-off): gates, then the chain stopped after its full suites (`mem-2` failing on the additive and the dropin) and four capacity runs; `one-record-r1-L-B.log` is a run killed part-way |
| `logs/gatesB-second-build/`, `logs/chainB-second-build/` | the second (the back-off released when the heap falls below its level): gates, then the chain stopped after its full suites (`mem-2` failing on the dropin only) and two capacity runs; `one-record-r1-E-B2.log` is a run killed part-way |
| `logs/mem2-cadence-trace/` | the second build with `_OCLJ_WALLSTATS` 8-11 and the `MEM-2 cadence` trace added: the dropin's and the additive's full suites, showing the back-off engage at the program's first proof (dropin) and release by a 2 KB dip (additive) |
| `chainC.log`, `chainC-tables.md` | stage C: the full suite (additive JIT on, the dropin, JIT off, sieve, stock), then the capacity matrix in chain B's layout without arm E (S, D, O on 192 KB x3 reps, 256 and 1024 KB x1, four shapes; L on 192 and 1024 KB), 68 runs, and one D run at 192 KB not pinned |
| `logs/chainC0/` | the site-13 kernel on stage B's DLLs: the additive and dropin full suites, three D runs and one E at 192 KB (kernelMemory equal, the idle flushes still there: 8-20 a window, ~25 KB each); `km1-sabotage-*` is one D run with site 13's `jit.off()` neutralised in the patcher for that run only (`km-1` FAIL: 246 traces at the baseline, kernelMemory 339 943 B) |
| `logs/kernel/` | `build-kernel.sh` with its site-13 postflight against the 12-site patcher (fails, naming site 13) and against the 13-site one (passes) |
| `logs/mem/stageC/` | W15 against stage B's object (fails: the flush asked for with 100 KB free); the half-watermark rule before P2 and C5b were re-scoped (P2c-h, C5b fail); the final suite on the stage-C and stage-B objects |
| `logs/gatesC/` | `scripts/gates.sh` on the stage-C build; `negctl.log` found stopgap's list one short (W15), `negctl-2.log` is the passing re-run |
| `logs/race/runsR/`, `runsR2/`, `runsR3/` | the boot failure's repro, `OCLJ_PROBE=rawrace` `race-1` (after the boot) on stage C's additive DLL at 192 KB: the first unlocked run (stopped at tick 9 on `:195`); 3 locked and 2 unlocked before the heartbeat check; 4 of each with it, alternating (`chain.log` in each). `scripts/race.sh` is one run, `scripts/racechain.sh` a chain |
| `logs/race/runsRF/` | after the fix (guard, f6 and gc-pace under the machine's monitor): 3 unlocked and 3 locked `race-1` runs, then the full suite on the additive, the dropin, JIT off, stock and JIT off at stepmul 400 (`scripts/chainRF.sh`); the JIT-off one fails `j0`, the second race |
| `logs/race/runsJpre/`, `runsJdpre/`, `runsJpost/` | that second race: 4 JIT-off full suites on the additive and 4 on the dropin before any fix for it; 6 on the additive with the first fix (the JIT off in `OcljArch.initialize`, since dropped) (`scripts/chainJ.sh`) |
| `logs/race/runsF/` | the final fix (`jit.on` a no-op at the JIT-off read-out) and `race-2` (`OCLJ_RACE_PHASE=boot`, the reads through OpenOS's boot): 4 unlocked and 4 locked `race-2`, 1 of each `race-1`, 6 JIT-off full suites on each arm, the JIT-on suite on each (`scripts/chainF.sh`). `race-2`'s verdict was printed after (d) here, so the 3 unlocked boots that never ran the autorun have none; the stack traces are in their logs |
| `logs/race/runsH/` | `race-2` with its verdict moved before (c): 12 unlocked and 2 locked; `u05.log` is the reproduction of the original `:172` |
| `logs/race/runsRfinal/`, `runsZ/` | the tree at two points: one locked `race-1` after a comment-only change; then, on the final tree, one locked `race-1` and the additive's full suite. `scripts/archive-race.sh` and `archive-race2.sh` copied all of this here |
| `logs/chain0/`, `logs/chainA/`, `logs/chainA2/`, `logs/chainB/`, `logs/chainC/` | the full harness log of every run in those chains |
| `scripts/` | the launchers (`cap.sh`, `full.sh` take the library directory as an argument; `chainlib.sh` holds `run()`), the chains (`chainB.sh`, `chainB2.sh`, `chainB3.sh` for the three stage-B builds; `chainM2.sh` for the cadence trace; `chainC0.sh`, `chainC.sh`), `gates.sh`, `sabotageB.sh` (the stage-B sabotages as first measured, in scratch), `analyze.py` (its "stalled" class added for chain B), `held.py`; they hard-code this session's scratchpad paths for `affrun.exe`, `OCLJ_LIBS` and the saved DLLs |

Notes on the runs.

- `chain0` ran an earlier `CAP-MID` that sampled every 8 ticks; its first run's fill was
  over in 220 ms and took no sample. `chainA` samples every tick but still counted samples
  taken after a machine had gone down; its "parked" counts for the three down runs are
  those post-stop samples (cap read Int.MaxValue). `chainA2` and later count the running
  machine only.
- An end state read after a machine went down can look like the park (armed, at the
  pause, stepmul 0, threshold twice the heap): that is also what OC's own full collection
  of a stopped machine leaves behind an armed record, and the harness cannot see the latched
  white that tells the two apart. Not evidence of a park.
- For about 12 s (06:36:13-06:36:25Z) unpinned native test builds (the stage-B sabotage
  set) ran beside `chainA`'s string runs at rep 1. No timing from `chainA` is quoted as a
  finding; its matrix is read for outcome classes.
- `chain0`'s second run overlapped an 18 GB runaway `mem_test` (the stopgap sabotage on an
  unbounded fill, killed); it is read for the instrument, not for timing.
- `chainB`'s full suites ran first and the capacity matrix after, as one chain; nothing
  else ran on the host while it did. Its three stalls and one dropin down are discussed in
  the results; its one boot failure (`one-array-r2-D-B3`, an assertion in OC's
  synchronized-call path one tick after boot) is unexplained.
- `chainC` ran alone on the host, pinned, except its last run, which ran without `affrun`
  on purpose: kernelMemory read 164 923 B there too.
