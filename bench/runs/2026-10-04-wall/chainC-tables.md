## Outcomes, by stick, arm and build

| stick | arm | build | clean | recovery refused | stalled | machine down | boot failed |
|---|---|---|---|---|---|---|---|
| 192 KB | S | stock | 12 | 0 | 0 | 0 | 0 |
| 192 KB | D | C | 12 | 0 | 0 | 0 | 0 |
| 192 KB | D | Cunpinned | 1 | 0 | 0 | 0 | 0 |
| 192 KB | O | C | 12 | 0 | 0 | 0 | 0 |
| 192 KB | L | C | 4 | 0 | 0 | 0 | 0 |
| 256 KB | S | stock | 4 | 0 | 0 | 0 | 0 |
| 256 KB | D | C | 4 | 0 | 0 | 0 | 0 |
| 256 KB | O | C | 3 | 0 | 1 | 0 | 0 |
| 1024 KB | S | stock | 4 | 0 | 0 | 0 | 0 |
| 1024 KB | D | C | 4 | 0 | 0 | 0 | 0 |
| 1024 KB | O | C | 4 | 0 | 0 | 0 | 0 |
| 1024 KB | L | C | 4 | 0 | 0 | 0 | 0 |

## The collector over the fill (ours): medians over clean runs, and the park fingerprint over ALL runs

`arms/batch` is the fill's arms over its batches; `parked runs` counts runs whose fill snapshots (CAP-MID, every tick) read the park: armed, at the pause, stepmul 0, threshold past gc.total.  Chain A's harness counted a snapshot taken after the machine went down too; later chains count running snapshots only. The end state after a machine went down is listed with the unclean runs, not counted here. `od_peak` must stay within `od_limit` (the sandbox's G) plus the kernel's 16 KB slice and the 1.5 KB norefuse window.

| stick | arm | build | n clean | arms/batch | collects | bailouts (all runs) | park resets | overdrafts | od_peak max / od_limit | parked runs |
|---|---|---|---|---|---|---|---|---|---|---|
| 192 KB | D | C | 12 | 5.8 | 51 | 0 | 0 | 590 | 32755 / 32768 | 0 of 12 |
| 192 KB | D | Cunpinned | 1 | 7.0 | 42 | 0 | 0 | 493 | 16343 / 32768 | 0 of 1 |
| 192 KB | O | C | 12 | 4.1 | 38 | 0 | 0 | 608 | 16374 / 32768 | 0 of 12 |
| 192 KB | L | C | 4 | 5.4 | 43 | 0 | 0 | 278 | 16367 / 32768 | 0 of 4 |
| 256 KB | D | C | 4 | 3.0 | 41 | 0 | 0 | 624 | 19890 / 39798 | 0 of 4 |
| 256 KB | O | C | 3 | 2.9 | 39 | 0 | 0 | 714 | 36880 / 39798 | 0 of 4 |
| 1024 KB | D | C | 4 | 0.7 | 54 | 0 | 0 | 3321 | 128399 / 128272 | 0 of 4 |
| 1024 KB | O | C | 4 | 0.6 | 51 | 0 | 0 | 2756 | 64135 / 128272 | 0 of 4 |
| 1024 KB | L | C | 4 | 0.8 | 54 | 0 | 0 | 2621 | 128179 / 128230 | 0 of 4 |

## Near the wall, clean runs only: the last five batches' time (s, median), and over stock's in the same chain

| stick | shape | S/stock | D/C | D/Cunpinned | O/C | L/C |
|---|---|---|---|---|---|---|
| 192 KB | record | 0.0012 | 0.0028 (2.3x) | 0.0049 (4.1x) | 0.0025 (2.1x) | 0.0028 (2.3x) |
| 192 KB | array | 0.0012 | 0.0022 (1.8x) | - | 0.0025 (2.1x) | 0.0020 (1.7x) |
| 192 KB | string | 0.0014 | 0.0020 (1.4x) | - | 0.0031 (2.2x) | 0.0032 (2.3x) |
| 192 KB | closure | 0.0017 | 0.0023 (1.4x) | - | 0.0027 (1.6x) | 0.0026 (1.5x) |
| 256 KB | record | 0.0024 | 0.0029 (1.2x) | - | 0.0029 (1.2x) | - |
| 256 KB | array | 0.0015 | 0.0026 (1.7x) | - | 0.0048 (3.2x) | - |
| 256 KB | string | 0.0018 | 0.0002 (0.1x) | - | - | - |
| 256 KB | closure | 0.0023 | 0.0028 (1.2x) | - | 0.0030 (1.3x) | - |
| 1024 KB | record | 0.0035 | 0.0097 (2.8x) | - | 0.0099 (2.8x) | 0.0087 (2.5x) |
| 1024 KB | array | 0.0029 | 0.0025 (0.9x) | - | 0.0057 (2.0x) | 0.0037 (1.3x) |
| 1024 KB | string | 0.0020 | 0.0109 (5.5x) | - | 0.0117 (5.8x) | 0.0114 (5.7x) |
| 1024 KB | closure | 0.0041 | 0.0056 (1.4x) | - | 0.0121 (3.0x) | 0.0075 (1.8x) |

## Idle window, 400 ticks after boot (ours): arms, collects, trace flushes, park resets (median, range)

- 192 KB D/C: arms 20 (20..29), collects 20 (20..29), trace flushes 0 (0..1), park resets 0 (0..0); kernelMemory 164923; n=12
- 192 KB D/Cunpinned: arms 20 (20..20), collects 20 (20..20), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 164923; n=1
- 192 KB O/C: arms 1 (0..1), collects 1 (0..1), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 164923; n=12
- 192 KB L/C: arms 20 (20..22), collects 20 (20..22), trace flushes 0 (0..1), park resets 0 (0..0); kernelMemory 164247; n=4
- 256 KB D/C: arms 0 (0..0), collects 0 (0..0), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 164923; n=4
- 256 KB O/C: arms 0 (0..0), collects 0 (0..0), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 164923; n=4
- 1024 KB D/C: arms 0 (0..0), collects 0 (0..0), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 164923; n=4
- 1024 KB O/C: arms 0 (0..0), collects 0 (0..0), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 164923; n=4
- 1024 KB L/C: arms 0 (0..0), collects 0 (0..0), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 164247; n=4

## Every run that did not end cleanly

- onehalf-string-r1-O-C: stalled  held=? why=? running=true lastError=<null>; parked(mid/end)=0/false; collects=+98 bailouts=+0

## Objects held at the refusal, clean runs, median per cell, and over stock's in the same chain

| stick | shape | S | D (x S) | E (x S) | O (x S) | L (x S) |
|---|---|---|---|---|---|---|
| 192 KB | record | 262 | 551 (2.10) | - | 605 (2.31) | 551 (2.10) |
| 192 KB | array | 287 | 799 (2.78) | - | 872 (3.04) | 792 (2.76) |
| 192 KB | string | 1024 | 2048 (2.00) | - | 2231 (2.18) | 2048 (2.00) |
| 192 KB | closure | 508 | 778 (1.53) | - | 838 (1.65) | 767 (1.51) |
| 256 KB | record | 536 | 921 (1.72) | - | 969 (1.81) | - |
| 256 KB | array | 586 | 1369 (2.34) | - | 1357 (2.32) | - |
| 256 KB | string | 2048 | 2645 (1.29) | - | - | - |
| 256 KB | closure | 945 | 1319 (1.40) | - | 1382 (1.46) | - |
| 1024 KB | record | 4096 | 5663 (1.38) | - | 5726 (1.40) | 5664 (1.38) |
| 1024 KB | array | 4756 | 8192 (1.72) | - | 8192 (1.72) | 8192 (1.72) |
| 1024 KB | string | 16384 | 21768 (1.33) | - | 20939 (1.28) | 21764 (1.33) |
| 1024 KB | closure | 7313 | 8192 (1.12) | - | 8088 (1.11) | 8028 (1.10) |
