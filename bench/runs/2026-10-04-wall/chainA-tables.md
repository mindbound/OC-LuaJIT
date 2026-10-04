## Outcomes, by stick, arm and build

| stick | arm | build | clean | recovery refused | stalled | machine down | boot failed |
|---|---|---|---|---|---|---|---|
| 192 KB | E | A | 6 | 3 | 0 | 3 | 0 |
| 192 KB | E | base | 3 | 0 | 0 | 1 | 0 |

## The collector over the fill (ours): medians over clean runs, and the park fingerprint over ALL runs

`arms/batch` is the fill's arms over its batches; `parked runs` counts runs whose fill snapshots (CAP-MID, every tick) read the park: armed, at the pause, stepmul 0, threshold past gc.total.  Chain A's harness counted a snapshot taken after the machine went down too; later chains count running snapshots only. The end state after a machine went down is listed with the unclean runs, not counted here. `od_peak` must stay within `od_limit` (the sandbox's G) plus the kernel's 16 KB slice and the 1.5 KB norefuse window.

| stick | arm | build | n clean | arms/batch | collects | bailouts (all runs) | park resets | overdrafts | od_peak max / od_limit | parked runs |
|---|---|---|---|---|---|---|---|---|---|---|
| 192 KB | E | A | 6 | 347.8 | 2391 | 0 | 0 | 0 | 0 / n/a | 3 of 12 |
| 192 KB | E | base | 3 | 273.4 | 2658 | 0 | n/a | n/a | n/a / n/a | 1 of 4 |

## Near the wall, clean runs only: the last five batches' time (s, median), and over stock's in the same chain

| stick | shape | E/A | E/base |
|---|---|---|---|
| 192 KB | record | 0.0604 | 0.0716 |
| 192 KB | array | 0.0418 | 0.0386 |
| 192 KB | string | 0.0564 | 0.0596 |
| 192 KB | closure | 0.0590 | - |

## Idle window, 400 ticks after boot (ours): arms, collects, trace flushes, park resets (median, range)

- 192 KB E/A: arms 2323 (2122..2581), collects 2323 (2122..2581), trace flushes 26 (21..33), park resets 0 (0..0); kernelMemory 164525; n=12
- 192 KB E/base: arms 1933 (1195..2649), collects 1933 (1195..2649), trace flushes 25 (18..30), park resets n/a; kernelMemory 164393; n=4

## Every run that did not end cleanly

- one-array-r2-E-A: down  held=? why=? running=false lastError=not; parked(mid/end)=1/true; collects=+1990 bailouts=+0
- one-array-r3-E-A: recovery  held=? why=? running=true lastError=<null>; parked(mid/end)=0/false; collects=+43332 bailouts=+0
- one-closure-r1-E-base: down  held=? why=? running=false lastError=not; parked(mid/end)=1/true; collects=+2277 bailouts=+0
- one-closure-r3-E-A: recovery  held=? why=? running=true lastError=<null>; parked(mid/end)=0/false; collects=+53692 bailouts=+0
- one-record-r2-E-A: down  held=? why=? running=false lastError=not; parked(mid/end)=1/true; collects=+1718 bailouts=+0
- one-string-r1-E-A: recovery  held=? why=? running=true lastError=<null>; parked(mid/end)=0/false; collects=+163156 bailouts=+0
- one-string-r3-E-A: down  held=? why=? running=false lastError=not; parked(mid/end)=1/true; collects=+5160 bailouts=+0
