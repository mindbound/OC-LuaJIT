# 2026-10-04 -- the collector at the wall

The evidence behind [../../results-wall-2026-10-04.md](../../results-wall-2026-10-04.md).
All harness runs on ocelot-brain with JDK 8, launched pinned to the performance cores
(`affrun C03C03`; the java process inherits the mask), the watchdog kernel on ours, OC's
own on stock, at OC's `ramScaleFor64Bit` 1.8. Run names are `<stick>-<shape>-r<rep>-<arm>-<build>`:
stick `one` = 192 KB; arm E = ours with the JIT off through kernel init, on once
`kernelMemory` is taken; build `base` = the 2026-10-03 additive DLL `cb29485d`, saved before
any rebuild, `A` = stage A's additive DLL `4c225c7d`.

| file | what |
|---|---|
| `design/` | the requirements (R1-R11), five read-only surveys of the code at `bd302f2` (their `file:line` citations are to that tree), three designs and the judges' scores and staged plan |
| `chain0.log` | stage 0: the new capacity-probe instrument (`CAP-MID`, `CAP-GC`) against the baseline DLL, two runs |
| `chainA.log`, `chainA-tables.md` | stage A: the full suite (additive, dropin) on A's DLLs, then the reduced capacity matrix, arm E at 192 KB, 12 runs on A with the baseline at rep 1 of each shape interleaved; `scripts/analyze.py chainA.log` |
| `chainA2.log` | after acc-4 kept its fill reachable and `CAP-MID` counted only the running machine: the additive full suite again, and four record runs (two per build) |
| `logs/mem/` | `mem_test` on the stage-A tree against A's shim object and against the baseline object (`OCLJ_SHIMOBJ`); the negative control's first run after its paths were fixed, with the two drifted lists it found |
| `logs/gatesA/` | `scripts/gates.sh` on the stage-A build: mem, wd, shim, security, race (the last three through a mirror of the pre-per-platform layout), penalty, the negative control; object checksums |
| `logs/chain0/`, `logs/chainA/`, `logs/chainA2/` | the full harness log of every run in those chains |
| `scripts/` | the launchers (`cap.sh`, `full.sh` take the library directory as an argument; `chainlib.sh` holds `run()`), the chains, `gates.sh`, `analyze.py`; they hard-code this session's scratchpad paths for `affrun.exe`, `OCLJ_LIBS` and the saved DLLs |

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
