# 2026-10-05 -- the reserve's size

The evidence behind [../../results-reserve-2026-10-05.md](../../results-reserve-2026-10-05.md):
the second-chance row ("A refusal the program never saw opens the reserve tier for it"), bounded
by THE RESERVE'S SIZE. All harness runs on ocelot-brain with JDK 8, launched pinned to the
performance cores (`affrun C03C03`), the watchdog kernel on ours and OC's own on stock, at OC's
`ramScaleFor64Bit` 1.8; every hermetic driver and native test pinned to the efficiency cores
(`affrun 3FC3FC`).

The builds:

- **E, the control:** THE WINDOW plus the unwinder fix (3186e87 plus the errmem change):
  additive `d9a51b6b`, dropin `8635573e`, shim object `332dc85c`.
- **F, the final:** E plus THE RESERVE'S SIZE: additive `45eb443b`, dropin `8f9bc419`, Linux
  additive `45b25422` (`logs/wsl-native.log`, `logs/wslgates/`), shim objects `1241325b`
  (additive) / `79f19c63` (dropin).
- **E-i, F-i:** the same two as instrumented natives (one stderr line per refusal, proof and
  sizing; a diagnostic copy, never shipped): additive `b425a809` / `c3216c84`, dropin
  `d52b5aae` / `714a1778`; their shim objects are byte-identical to E's and F's when the
  instrument is compiled out (`logs/refnative/`, `logs/finst-native/`, `finst/logs/`).

| path | what |
|---|---|
| `map/REPORT.txt` | the absorber map: every place a refusal is caught by code that is not the program's, what each does with it, whether the allocator can tell, what the reserve must keep doing, the candidate levers |
| `forensics/` | the hermetic forensics: `REPORT.txt`; `src/` the instrumented copy of THE WINDOW's shim (logic unchanged, proven inert); `tools/` its generator; `drv/` the drivers and probes (`lj_ref.c`, `wrapcp.c`, `probe2oe.lua`, `probe2k_2048.lua`, `ctl_rec.lua`); `analysis/`; `census-out.tar.gz` every census's TSV and classification |
| `logs/runsR/` | the in-machine forensics: 25 runs with the instrumented natives (`an/NOTE.txt` the findings, `per-run.txt`, `refusals.tsv`, one log per run) |
| `design/` | the round: `lifetime.txt`, `verdict.txt`, `identify.txt`; the judges `j3-safety.txt`, `j3-practice.txt`, `j3-evidence.txt`; the synthesis `d3-final.txt`; per design its diff, extended mem_test, sabotages, analyses (lifetime's census TSVs kept, its rule being the one built) |
| `finst/` | the final source's instrumented copy (`src/`, `tools/`, `README.txt`), its inertness logs, the M1 census (`census-M1.sh`, `analysis/compare-F.txt`, `census-out.tar.gz`) |
| `logs/native/` | the builds (`build-*.log`, `new.md5`), mem_test (`failfirst-old.log` on THE WINDOW's object, `mem-new-*.log`, `mem-fast.log`, `mt/` the 30 + 10 + 3 runs with `summary.txt`), the negative control (`negctl-measure.log` the measurement, `negctl-confirm.log` the 41 of 41), `guards/` the two `#error` guards firing |
| `logs/smoke/` | the recovery smoke runs that voided gate (7): F and E plain, the instrumented E at levels 1-3 |
| `logs/runsF/` | the in-machine gate: `chain.log`, `gate.log` (the amplified cells, E/F interleaved, instrumented), `recover.log` (levels 3 and 1, with stock), `matrix.log` (batch 100), `full.log` (the suites); one log per run under `gate/`, `recover/`, `matrix/`, `full/`; `analyzeF.txt` the criteria as computed by `scripts/analyzeF.py` |
| `scripts/` | the chains and tools; they hard-code this session's scratchpad paths |

Notes.

- The forensics' and the designs' baselines were linked against the one-site `libluajit.a`
  (`a93f546e`); the final census against the two-site one. The forensics' driver relinked on
  the final archive matched its baseline on 1 024 of 1 024 caps, so the confound is zero on
  this probe.
- The census `.err` directories (one file per cap, tens of thousands) are not archived; the
  TSVs carry every per-run figure the analyses use.
- The instrumented natives read `OCLJ_REFLOG` the gate-safe way (not `getenv`, which
  `build-native.sh` refuses); they are built from a scratch copy of the repo and never enter
  `build/native`.
