## Outcomes, by stick, arm and build

| stick | arm | build | clean | recovery refused | stalled | machine down | boot failed |
|---|---|---|---|---|---|---|---|
| 192 KB | S | stock | 12 | 0 | 0 | 0 | 0 |
| 192 KB | D | B3 | 11 | 0 | 0 | 0 | 1 |
| 192 KB | E | B3 | 11 | 0 | 1 | 0 | 0 |
| 192 KB | O | B3 | 12 | 0 | 0 | 0 | 0 |
| 192 KB | L | B3 | 3 | 0 | 0 | 1 | 0 |
| 256 KB | S | stock | 4 | 0 | 0 | 0 | 0 |
| 256 KB | D | B3 | 4 | 0 | 0 | 0 | 0 |
| 256 KB | E | B3 | 4 | 0 | 0 | 0 | 0 |
| 256 KB | O | B3 | 3 | 0 | 1 | 0 | 0 |
| 1024 KB | S | stock | 4 | 0 | 0 | 0 | 0 |
| 1024 KB | D | B3 | 4 | 0 | 0 | 0 | 0 |
| 1024 KB | E | B3 | 3 | 0 | 1 | 0 | 0 |
| 1024 KB | O | B3 | 4 | 0 | 0 | 0 | 0 |
| 1024 KB | L | B3 | 4 | 0 | 0 | 0 | 0 |

## The collector over the fill (ours): medians over clean runs, and the park fingerprint over ALL runs

`arms/batch` is the fill's arms over its batches; `parked runs` counts runs whose fill snapshots (CAP-MID, every tick) read the park: armed, at the pause, stepmul 0, threshold past gc.total.  Chain A's harness counted a snapshot taken after the machine went down too; later chains count running snapshots only. The end state after a machine went down is listed with the unclean runs, not counted here. `od_peak` must stay within `od_limit` (the sandbox's G) plus the kernel's 16 KB slice and the 1.5 KB norefuse window.

| stick | arm | build | n clean | arms/batch | collects | bailouts (all runs) | park resets | overdrafts | od_peak max / od_limit | parked runs |
|---|---|---|---|---|---|---|---|---|---|---|
| 192 KB | D | B3 | 11 | 2.4 | 45 | 0 | 0 | 738 | 47901 / 47971 | 0 of 12 |
| 192 KB | E | B3 | 11 | 5.5 | 50 | 0 | 0 | 521 | 32883 / 32768 | 0 of 12 |
| 192 KB | O | B3 | 12 | 4.0 | 40 | 0 | 0 | 677 | 32751 / 32768 | 0 of 12 |
| 192 KB | L | B3 | 3 | 2.8 | 39 | 0 | 0 | 608 | 43471 / 47824 | 0 of 4 |
| 256 KB | D | B3 | 4 | 2.0 | 42 | 0 | 0 | 704 | 52484 / 52490 | 0 of 4 |
| 256 KB | E | B3 | 4 | 3.7 | 46 | 0 | 0 | 943 | 39773 / 39774 | 0 of 4 |
| 256 KB | O | B3 | 3 | 3.6 | 42 | 0 | 0 | 715 | 38876 / 39774 | 0 of 4 |
| 1024 KB | D | B3 | 4 | 0.6 | 50 | 0 | 0 | 2522 | 139239 / 139848 | 0 of 4 |
| 1024 KB | E | B3 | 3 | 0.8 | 44 | 0 | 0 | 1765 | 128367 / 128247 | 0 of 4 |
| 1024 KB | O | B3 | 4 | 0.6 | 55 | 0 | 0 | 2684 | 64109 / 128247 | 0 of 4 |
| 1024 KB | L | B3 | 4 | 0.5 | 48 | 0 | 0 | 2380 | 70391 / 140830 | 0 of 4 |

## Near the wall, clean runs only: the last five batches' time (s, median), and over stock's in the same chain

| stick | shape | S/stock | D/B3 | E/B3 | O/B3 | L/B3 |
|---|---|---|---|---|---|---|
| 192 KB | record | 0.0022 | 0.0037 (1.7x) | 0.0027 (1.2x) | 0.0027 (1.2x) | 0.0023 (1.0x) |
| 192 KB | array | 0.0021 | 0.0024 (1.2x) | 0.0020 (1.0x) | 0.0043 (2.0x) | 0.0027 (1.3x) |
| 192 KB | string | 0.0018 | 0.0047 (2.6x) | 0.0030 (1.7x) | 0.0041 (2.3x) | 0.0059 (3.3x) |
| 192 KB | closure | 0.0024 | 0.0040 (1.7x) | 0.0043 (1.8x) | 0.0052 (2.2x) | - |
| 256 KB | record | 0.0032 | 0.0049 (1.5x) | 0.0024 (0.7x) | 0.0053 (1.7x) | - |
| 256 KB | array | 0.0033 | 0.0034 (1.0x) | 0.0060 (1.8x) | 0.0047 (1.4x) | - |
| 256 KB | string | 0.0026 | 0.0070 (2.7x) | 0.0003 (0.1x) | - | - |
| 256 KB | closure | 0.0021 | 0.0045 (2.1x) | 0.0051 (2.4x) | 0.0049 (2.3x) | - |
| 1024 KB | record | 0.0074 | 0.0106 (1.4x) | 0.0098 (1.3x) | 0.0099 (1.3x) | 0.0065 (0.9x) |
| 1024 KB | array | 0.0030 | 0.0060 (2.0x) | 0.0027 (0.9x) | 0.0066 (2.2x) | 0.0062 (2.1x) |
| 1024 KB | string | 0.0050 | 0.0095 (1.9x) | - | 0.0129 (2.6x) | 0.0089 (1.8x) |
| 1024 KB | closure | 0.0064 | 0.0110 (1.7x) | 0.0049 (0.8x) | 0.0157 (2.5x) | 0.0096 (1.5x) |

## Idle window, 400 ticks after boot (ours): arms, collects, trace flushes, park resets (median, range)

- 192 KB D/B3: arms 0 (0..0), collects 0 (0..0), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 334733/339225/340685/347225/367305/368085/410841/412733/413325/413645; n=11
- 192 KB E/B3: arms 38 (32..40), collects 38 (32..40), trace flushes 18 (12..20), park resets 0 (0..0); kernelMemory 164525; n=12
- 192 KB O/B3: arms 1 (0..1), collects 1 (0..1), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 164525; n=12
- 192 KB L/B3: arms 0 (0..0), collects 0 (0..0), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 334737/339549/348229/411289; n=4
- 256 KB D/B3: arms 0 (0..0), collects 0 (0..0), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 334733/340093/366625/367985; n=4
- 256 KB E/B3: arms 0 (0..1), collects 0 (0..1), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 164525; n=4
- 256 KB O/B3: arms 0 (0..0), collects 0 (0..0), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 164525; n=4
- 1024 KB D/B3: arms 0 (0..0), collects 0 (0..0), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 335413/338869/340673/350133; n=4
- 1024 KB E/B3: arms 0 (0..0), collects 0 (0..0), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 164525; n=4
- 1024 KB O/B3: arms 0 (0..0), collects 0 (0..0), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 164525; n=4
- 1024 KB L/B3: arms 0 (0..0), collects 0 (0..0), trace flushes 0 (0..0), park resets 0 (0..0); kernelMemory 334057/334737/338549/365849; n=4

## Every run that did not end cleanly

- one-array-r2-D-B3: bootfail  held=None why=None running=None lastError=None; parked(mid/end)=?/?; collects=? bailouts=?
- one-closure-r1-L-B3: down  held=? why=? running=false lastError=not; parked(mid/end)=0/true; collects=+75 bailouts=+0
- one-record-r1-E-B3: stalled  held=? why=? running=true lastError=<null>; parked(mid/end)=0/false; collects=+683 bailouts=+0
- onehalf-string-r1-O-B3: stalled  held=? why=? running=true lastError=<null>; parked(mid/end)=0/false; collects=+100 bailouts=+0
- threehalf-string-r1-E-B3: stalled  held=? why=? running=true lastError=<null>; parked(mid/end)=0/false; collects=+188 bailouts=+0

## Objects held at the refusal, clean runs, median per cell, and over stock's in the same chain

| stick | shape | S | D (x S) | E (x S) | O (x S) | L (x S) |
|---|---|---|---|---|---|---|
| 192 KB | record | 262 | 1188 (4.53) | 584 (2.23) | 605 (2.31) | 1122 (4.28) |
| 192 KB | array | 287 | 1677 (5.84) | 791 (2.76) | 874 (3.05) | 2048 (7.14) |
| 192 KB | string | 1024 | 4667 (4.56) | 2048 (2.00) | 2231 (2.18) | 4096 (4.00) |
| 192 KB | closure | 508 | 1887 (3.71) | 773 (1.52) | 839 (1.65) | - |
| 256 KB | record | 536 | 1626 (3.03) | 918 (1.71) | 969 (1.81) | - |
| 256 KB | array | 586 | 2190 (3.74) | 1465 (2.50) | 1438 (2.45) | - |
| 256 KB | string | 2048 | 6864 (3.35) | 2804 (1.37) | - | - |
| 256 KB | closure | 945 | 2048 (2.17) | 1411 (1.49) | 1303 (1.38) | - |
| 1024 KB | record | 4255 | 6343 (1.49) | 5667 (1.33) | 5726 (1.35) | 6299 (1.48) |
| 1024 KB | array | 4708 | 8979 (1.91) | 8192 (1.74) | 8192 (1.74) | 8976 (1.91) |
| 1024 KB | string | 16384 | 24891 (1.52) | - | 20937 (1.28) | 24070 (1.47) |
| 1024 KB | closure | 8192 | 8566 (1.05) | 8192 (1.00) | 8087 (0.99) | 8561 (1.05) |
