## Outcomes at OC's 1.8, by arm and stick

| stick | arm | clean | recovery refused | machine down | boot failed |
|---|---|---|---|---|---|
| 192 KB | S | 12 | 0 | 0 | 0 |
| 192 KB | D | 9 | 3 | 0 | 0 |
| 192 KB | E | 5 | 3 | 3 | 1 |
| 192 KB | O | 10 | 2 | 0 | 0 |
| 256 KB | S | 4 | 0 | 0 | 0 |
| 256 KB | D | 2 | 2 | 0 | 0 |
| 256 KB | E | 2 | 1 | 1 | 0 |
| 256 KB | O | 3 | 0 | 1 | 0 |
| 1024 KB | S | 4 | 0 | 0 | 0 |
| 1024 KB | D | 4 | 0 | 0 | 0 |
| 1024 KB | E | 2 | 0 | 2 | 0 |
| 1024 KB | O | 3 | 1 | 0 | 0 |

## Objects held at the refusal (clean runs; min / median / max), our median over stock's

A cell marked `+k` had k more runs that did not end cleanly (see the outcomes table); `-` with `+k` means no run in that cell ended cleanly.

| stick | shape | stock S | ours D | ours E | ours O | D/S | E/S | O/S |
|---|---|---|---|---|---|---|---|---|
| 192 KB | record | 262 / 262 / 262 | 1031 / 1145 / 1259 +1 | 499 / 505 / 512 +1 | 546 / 547 / 547 | 4.37 | 1.93 | 2.09 |
| 192 KB | array | 286 / 287 / 287 | 1566 +2 | 732 +2 | 788 / 789 / 790 | 5.46 | 2.55 | 2.75 |
| 192 KB | string | 853 / 1024 / 1024 | 4096 / 4598 / 4776 | 1995 +2 | 2048 / 2048 / 2048 | 4.49 | 1.95 | 2.00 |
| 192 KB | closure | 508 / 508 / 508 | 1489 / 1573 / 1593 | 698 +2 | 757 +2 | 3.10 | 1.37 | 1.49 |
| 256 KB | record | 536 | - +1 | 863 | - +1 | - | 1.61 | - |
| 256 KB | array | 533 | - +1 | - +1 | 1339 | - | - | 2.51 |
| 256 KB | string | 2048 | 5665 | 2912 | 2914 | 2.77 | 1.42 | 1.42 |
| 256 KB | closure | 1039 | 2048 | - +1 | 1288 | 1.97 | - | 1.24 |
| 1024 KB | record | 4255 | 6058 | 5448 | - +1 | 1.42 | 1.28 | - |
| 1024 KB | array | 4440 | 9019 | 8095 | 8091 | 2.03 | 1.82 | 1.82 |
| 1024 KB | string | 14822 | 23792 | - +1 | 19870 | 1.61 | - | 1.34 |
| 1024 KB | closure | 8192 | 8263 | - +1 | 7779 | 1.01 | - | 0.95 |

## Post-boot live set after three full collects: user = used - kernelMemory (bytes)

D's `user` under-reads at 192 and 256 KB: its kernelMemory holds trace metadata that kernel init compiled, which the pressure flush later released while OC's grant stayed.

| stick | arm | user min / median / max | kernelMemory min / max | n |
|---|---|---|---|---|
| 192 KB | S | 255893 / 255997 / 256173 | 174605 / 174605 | 12 |
| 192 KB | D | 44202 / 100310 / 135560 | 335961 / 413193 | 12 |
| 192 KB | E | 201114 / 212806 / 218912 | 164393 / 164393 | 11 |
| 192 KB | O | 188232 / 188509 / 188886 | 164393 / 164393 | 12 |
| 256 KB | S | 255827 / 255997 / 256107 | 174605 / 174605 | 4 |
| 256 KB | D | 62626 / 77455 / 80537 | 336193 / 367853 | 4 |
| 256 KB | E | 293114 / 297386 / 302155 | 164393 / 164393 | 4 |
| 256 KB | O | 187864 / 188021 / 188262 | 164393 / 164393 | 4 |
| 1024 KB | S | 255892 / 255963 / 256106 | 174605 / 174605 | 4 |
| 1024 KB | D | 281773 / 296623 / 298478 | 335513 / 413193 | 4 |
| 1024 KB | E | 295144 / 299973 / 301470 | 164393 / 164393 | 4 |
| 1024 KB | O | 187752 / 187827 / 188082 | 164393 / 164393 | 4 |

## Near the wall, clean runs only: the last five batches' time (s, median), and over stock's

The first-to-last ratio is not comparable across arms (the first batches start at different distances from the collector's knee, and with five or fewer batches both windows are the same batches); the absolute last-five time against stock's is.

| stick | shape | S last5 | D last5 (x S) | E last5 (x S) | O last5 (x S) | D arms / flushes | O arms |
|---|---|---|---|---|---|---|---|
| 192 KB | record | 0.0014 | 0.1013 (72) | 0.0602 (43) | 0.0795 (57) | 2572 / 8 | 2336 |
| 192 KB | array | 0.0010 | 0.0547 (55) | 0.0396 (40) | 0.0527 (53) | 2718 / 12 | 2155 |
| 192 KB | string | 0.0012 | 0.1234 (103) | 0.0599 (50) | 0.0674 (56) | 6878 / 23 | 5403 |
| 192 KB | closure | 0.0021 | 0.0923 (44) | 0.0638 (30) | 0.0641 (31) | 3110 / 10 | 2084 |
| 256 KB | record | 0.0038 | - | 0.0797 (21) | - | - / - | - |
| 256 KB | array | 0.0017 | - | - | 0.0527 (31) | - / - | 2674 |
| 256 KB | string | 0.0020 | 0.1242 (62) | 0.0566 (28) | 0.0660 (33) | 9539 / 32 | 5084 |
| 256 KB | closure | 0.0036 | 0.1071 (30) | - | 0.0755 (21) | 3972 / 12 | 2538 |
| 1024 KB | record | 0.0067 | 0.4540 (68) | 0.3016 (45) | - | 9313 / 23 | - |
| 1024 KB | array | 0.0038 | 0.1122 (30) | 0.1278 (34) | 0.2353 (62) | 7344 / 29 | 9800 |
| 1024 KB | string | 0.0082 | 0.4374 (53) | - | 0.4625 (56) | 26414 / 79 | 25747 |
| 1024 KB | closure | 0.0029 | 0.3505 (121) | - | 0.3431 (118) | 9774 / 26 | 9442 |

## Idle window, 400 ticks after boot, 192 KB (ours): collector arms and trace flushes (median, range)

- D: arms 5 (0..20), trace flushes 0 (0..0), n=12
- E: arms 1959 (1390..2964), trace flushes 27 (16..29), n=11
- O: arms 61 (60..63), trace flushes 0 (0..0), n=12

## Every run that did not end cleanly

- one-array-r1-D: recovery  held=? why=? running=true lastError=<null>
- one-array-r1-E: down  held=? why=? running=false lastError=not
- one-array-r3-D: recovery  held=? why=? running=true lastError=<null>
- one-array-r3-E: recovery  held=? why=? running=true lastError=<null>
- one-closure-r1-E: recovery  held=? why=? running=true lastError=<null>
- one-closure-r2-E: recovery  held=? why=? running=true lastError=<null>
- one-closure-r2-O: recovery  held=? why=? running=true lastError=<null>
- one-closure-r3-O: recovery  held=? why=? running=true lastError=<null>
- one-record-r2-D: recovery  held=? why=? running=true lastError=<null>
- one-record-r2-E: down  held=? why=? running=false lastError=not
- one-record-scale1.0-D: other: clean  held=775 why=not_enough_memory running=true lastError=<null>
- one-record-scale1.0-S: other: bootfail  held=None why=None running=None lastError=None
- one-string-r1-E: down  held=? why=? running=false lastError=not
- one-string-r2-E: bootfail  held=None why=None running=None lastError=None
- onehalf-array-r1-D: recovery  held=? why=? running=true lastError=<null>
- onehalf-array-r1-E: recovery  held=? why=? running=true lastError=<null>
- onehalf-closure-r1-E: down  held=? why=? running=false lastError=not
- onehalf-record-r1-D: recovery  held=? why=? running=true lastError=<null>
- onehalf-record-r1-O: down  held=? why=? running=false lastError=not
- threehalf-closure-r1-E: down  held=? why=? running=false lastError=not
- threehalf-record-r1-O: recovery  held=? why=? running=true lastError=<null>
- threehalf-string-r1-E: down  held=? why=? running=false lastError=not
