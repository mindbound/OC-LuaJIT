# 2026-10-05 -- the window

The evidence behind [../../results-wall-window-2026-10-05.md](../../results-wall-window-2026-10-05.md):
the last row of the collector at the wall ("A refusal at a credit tier's top can land outside
the program's handler"). All harness runs on ocelot-brain with JDK 8, launched pinned to the
performance cores (`affrun C03C03`; the java process inherits the mask), the watchdog kernel
on ours, OC's own on stock, at OC's `ramScaleFor64Bit` 1.8. Native test runs that ran beside a
chain were pinned to the efficiency cores (`affrun 3FC3FC`).

The builds:

- **C, stage C (the positive control):** additive `05d133cf`, dropin `4cb483a5`, shim object
  `0259f0d1`.
- **W, THE WINDOW as the design round left it:** additive `6b2ff4ae`, dropin `bc4c8250`, shim
  object `d1242186` (additive) / `61aeba10` (dropin).
- **V, after the code review's fixes:** additive `ae3e414b`, dropin `7fa4e8f9`, shim object
  `082ff068` (additive) / `332dc85c` (dropin).

| path | what |
|---|---|
| `design/` | the round: `REQUIREMENTS.md`; five surveys of HEAD d9080d4 (`u2-shim-now`, `u2-checkpoints`, `u2-stalls` -- the forensics of the five bad runs, `u2-priors` -- the previous round, `u2-repro` -- the hermetic reproduction and W16); three prototyped designs (`d2-lend`, `d2-verdict`, `d2-prevent`); the judges (`j2-safety`, `j2-practice`); the synthesis `d2-final` (the design built, its tests and gate). Their prototypes were in scratch and are not kept |
| `repro/` | the reproduction's sources: `lj_repro.c` (the driver, linked like mem_test), `probe2.lua` (the capacity probe's program), `w16probe.lua`, `puc_repro.c` (stock PUC 5.2.4 under jnlua's allocator rule), `traj.c`/`probe3.lua`/`model.py` (the PUC-like rule on LuaJIT's trajectory), `sitepass.py`, the instrumentation generators; see `design/u2-repro.md` |
| `review/findings.json` | the code review: four lenses, 18 findings, each with its verifier's verdict |
| `crash/` | the unwinder crash: `report.md` (root cause), `verdict.md` (the adversarial verification), `patch-fastfunc-errmem-top.sh` (the fix, not applied) |
| `logs/runsG/` | the first in-machine chain on W: `sanity`, `full` (the five suites), `gate` (the amplified probe, batch 10: S, C, W x O/D/L x string/record, 120 runs), `matrix` (batch 100, chain C's layout with W, 68 runs); one log per run |
| `logs/runsT/` | the cost near the wall: S, C and W interleaved in one chain, 192 KB x 4 shapes x JIT on/off x 5 reps and 1024 KB x 3 shapes x JIT on x 4 reps, 136 runs |
| `logs/runsV/` | the confirmation on V: the five suites, the gate's V cells (50), the matrix's V cells (48) |
| `logs/mem/` | mem_test: `W-mt1` (W 30 runs, W's dropin 10, stage C 10: the first fail-first), `W2-mt1` (V, V's dropin, W -- the fresh-record defect --, stage C), `W2-mt2` (V, 20 more) |
| `logs/gates/` | `gatesW` and `gatesW2`: mem, wd, shim, security, race, penalty, the negative control, on W and on V; `negctl-measure.log` is the run that measured the sabotages' new expected sets |
| `analysis/` | `analyze.py` and `held.py` (bench/runs/2026-10-04-wall/scripts) over the chains; NOTE `held.py` keys cells by arm only, so on `runsT` (two builds per arm) its table mixes C and W -- the per-build capacity is in the results note |
| `scripts/` | `cap2.sh` (one capacity run, with batch and churn), `chainlib2.sh` (`run2()`, the classes incl. PROC-DEATH), `chainG.sh`, `chainT.sh`, `chainV.sh`, `mt.sh` (mem_test per object, N runs), `negrun.sh`, `archive-window.sh`; they hard-code this session's scratchpad paths |

Notes on the runs.

- `runsG`'s and `runsT`'s harness is the one W was built with; `runsV`'s carries the review's
  harness fixes (the STOPPED class, the step-entry site label). The class logic agrees on
  every run that occurred: no STOPPED, OTHER, BOOT-FAIL or PROC-DEATH appeared anywhere.
- The capacity probe changed with this work (its counters, row 19's paint, the onError
  wrapper): batch-100 results compare only with same-probe baselines (`runsT`), not with
  2026-10-04's chain C.
