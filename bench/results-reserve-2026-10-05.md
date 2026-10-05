# The reserve's size: a refusal opens two windows past the heap it found, not G/2 past the cap (2026-10-05)

**The second-chance row, bounded: a refusal the program never saw used to open G/2 more past the
cap for it (16 KB at the floor, 256 KB at 8 MB); it now opens 8 KiB past the heap it was refused
at, sized once, clamped to [G/2, G] where it is read.** What the second chance buys falls to a
fixed, small amount at every cap; the sandbox's bound after a refusal tightens from
cap + G + 4 KiB to max(u, cap + G/2) + 12 KiB; nothing before a reserve opens changes. What it
does **not** change is where the reserve top's refusal lands: the verdict's lottery stays, and
so does its rate.

- **What was wrong, placed at last.** In the machine, every refusal the program never saw was a
  56-64 B closure the kernel's `machine.lua` makes on the sandbox thread inside a component call
  (`wrapUserdata`, `unwrapUserdata`, `checkArg`), caught by whatever `pcall` wraps that call --
  the capacity probe's paint, OpenOS's dispatcher. The JIT recorder and the string table, the
  two suspects the code reading named, absorbed 0 of 50 in-machine refusals.
- **Three designs, three judges.** The reserve's size (built), the verdict's address (deferred:
  the best hermetic record of the round, a frame-walking vote inside the allocator the judges
  would not ship on probe-shaped evidence), identifying the absorbers the shim can see (its
  reserve rule is this one; its recorder rule is deferred until a machine shows the recorder
  absorbing anything).
- **Zero LuaJIT lines; about 30 shim lines.** One field, one 4-line read helper at four sites,
  a 5-line sizing block on the refusal path, three guard lines (a VM event handler gets no
  credit, as a finalizer), one `_OCLJ_WALLSTATS` value.
- **Hermetically** (the designers' prototypes of the same rule at 4 KiB): every cap whose
  program saw its own refusal byte-identical (9 399 of 9 399); capacity -0.06..-0.68 % per cell,
  all of it in second-chance runs; collections -1 %; the OpenOS-shaped stall count moved by the
  probe's phase (21 → 0, 0 → 6, 25 → 0 across three seeds), not by the size. The final object
  (8 KiB), 14 cell-and-seed rows: every non-second-chance cap byte-identical, 0 of 36 864 runs
  past either bound (the previous build passed the new one in 3 545), every reserve sized
  exactly 8 192 B past the refused heap, capacity 0.996-1.000, collections −0.5..−1.1 %.
- **mem_test 86 checks**: five new (W20, W20L, W21, W22, W7m), W7 tightened to the new bound;
  W7, W20, W20L and W22 fail on THE WINDOW's object in 3 of 3 runs and all 86 pass on the new
  one in 30 + 10 runs. The negative control: 41 sabotages, six new, twelve existing sets
  re-measured.
- **In the machine** (166 runs, the previous build against this one, interleaved,
  instrumented): the bound holds in 30 of 30 amplified runs (worst 27.5 KB past the cap; the
  previous build passes it in 21 of 30); the creep after an absorbed refusal 8.3 KB median
  against 16.2; bad outcomes 1 of 30 against 0 of 30, within the regression bar and the
  lottery's history (3 of 46); the batch-100 matrix 76 of 76 clean, capacity within 1 % of the
  previous build's like for like and at least 2.6x stock's; the five suites pass; the cost bar
  (1.10x) missed in one of three cells by 0.02.
- **Found on the way:** a recovery that formats while it still holds its data, after a second
  chance, is refused -- on this build, on the previous one, and on stock: the reserve was spent
  by the fill that never saw its refusal, and the program's own first refusal arrives at the
  reserve top with no room. Measured: a traceback, the tty and OpenOS's `event.onError` while
  holding -- stock 0 of 6 recoveries clean, the previous build 2 of 6, this one 3 of 10.

All harness runs: ocelot-brain, JDK 8, pinned to the performance cores (`affrun C03C03`),
OC's `ramScaleFor64Bit` 1.8, the watchdog kernel on ours and OC's own on stock; the native
tests on the efficiency cores. Archive: [runs/2026-10-05-reserve/](runs/2026-10-05-reserve/).
The previous rows: [results-wall-window-2026-10-05.md](results-wall-window-2026-10-05.md),
[results-wall-2026-10-04.md](results-wall-2026-10-04.md).

## What was wrong

THE CREDIT's reserve tier gives a program G/2 more past the cap after a refusal, so that
"catch, format the message, drop, carry on" works where PUC collects and retries. The window
round left one residual: when the refusal is caught by code that is not the program's, the
program never learns of it, keeps filling into the reserve, and the reserve top's refusal -- a
verdict, on data that survived two cycles -- can land outside any handler. Three machines went
down that way in 30 amplified JIT-on record runs; the shim logged 5, 4 and 3 refusals against
one paint failure each, unexplained.

**The forensics** (hermetic, with an inert instrumented copy of the shim: one stderr line per
refusal, with the tier, the window, the VM state, the innermost C frame and the nearest Lua
frame; proven inert on 4 096 caps and 81 of 81 mem_test checks; `sc/forensics/` in the archive):

- **Every absorbed refusal is a verdict refusal.** A proof decides that the data does not fit;
  the refusal is handed to the first crossing after it, whoever makes it: the batch (good), the
  paint, the trace assembler, `event.timer`'s record (outside). Over 28 672 runs, 2 192 had a
  second chance; the paint opened 2 169 of them, the JIT recorder 23.
- **The deterministic stall the census had found is not this row.** It has one refusal: THE
  WINDOW's verdict at the burst top, taken by `event.timer`'s 64 B record on data 72 B past the
  top. The documented residual, landing outside; the recorder was lent, not refused.
- **On the census probe the second chance never ends outside** (0 of 1 401). It does in the
  OpenOS-shaped timer probe (21 of 228: the reserve top's verdict at the timer's record or a
  `checkArg` closure, 224-500 B past the top). The kernel-garbage probe's downs are the window
  overrun residual, with or without a second chance.
- **The recorder does not account for the extra refusals**: 25 of 31 000, two of them after a
  run's first.

**The absorber map** (code reading; `sc/map/` in the archive) listed every place a refusal is
caught by code that is not the program's -- LuaJIT's recorder, finalizers and VM event
handlers, jnlua's protected entries and OC's `invoke`, the kernel's wrappers, OpenOS's
dispatcher and `onError`, the probe's paint -- and which of them the allocator can recognise
without allocating: the recorder (exactly, with a two-line LuaJIT patch; nearly, by the
innermost C frame), `HOOK_VMEVENT`, the kernel thread, a string-table doubling. Not the
sandbox-thread Lua code under someone else's `pcall`, which is where the machine's absorber
turned out to be.

**In the machine** (the instrumented shim built into both natives and run on the cells where
the machines went down, 25 runs, 50 refusals, all runs clean this time; `runsR/` in the
archive):

- The JIT-on record runs logged 1-5 refusals each; the JIT-off and string runs exactly 1. In
  every multi-refusal run the paint's failures equal the refusals minus one: the paint absorbed
  every refusal but the last, and the last was the fill's own, inside its handler.
- The absorbed ones all land in the kernel's `machine.lua` running on the sandbox thread inside
  a component call: `wrapUserdata`'s inner closure (17), `unwrapUserdata`'s (5), `checkArg`'s
  (3) -- 56-64 B each, the paint's `gpu.set` going through the invoke wrapper.
- All 50: interpreter, recorder idle, no hook. 46 are verdicts. At the reserve top the fill got
  a 2nd, 3rd and 4th chance for as long as the verdict kept landing on those closures.
- The earlier downs' "5/4/3 against one paint failure" were this sequence ending outside a
  handler instead; the painted figure was the last successful paint's.

## The design round

Three designers prototyped hermetically against the forensics' baseline; three judges (safety,
practice, evidence) scored them with the in-machine note in hand; a synthesis chose
(`sc/design/` in the archive: the three designs, `j3-*.txt`, `d3-final.txt`).

- **The reserve's size** (built): the reserve a refusal opens reaches a few KiB past the heap
  it was refused at, clamped to [G/2, G]. Unconditional -- it reaches the in-machine absorber
  whoever it is -- and 25 lines. Its own L4 variant, closing the reserve at the next resume,
  was rejected by its evidence: 39 stalls against the shipped 46, because closing puts the top
  under the live data and the verdict forms at the first proof after the resume.
- **The verdict's address** (deferred): a handler-of-record vote by walking frames inside the
  allocator; the verdict refuses only an addressed crossing and holds the others. Second
  chances 0 in all eight hermetic cells, the best record of the round. Not built: the vote
  has no decay; a trace-inlined `pcall` is invisible to the walk; a frame walk on every
  past-cap growth was tested on probe shapes only; when the vote is wrong it is today's defect
  plus 8 KiB -- and in the machine's own cell the paint plausibly out-allocates the fill; and
  its `rawverdict` negative control catches nothing. Its decisive input -- which handler owns
  most past-cap allocations in a machine -- is measured in this change's gate.
- **The recipient** (its reserve rule is this one; its recorder rule deferred): a refusal
  raised inside the trace recorder's protected call opens nothing, identified exactly by the
  innermost C frame and proven both ways. 0 of 50 in-machine refusals were the recorder's; the
  trigger to land it is a nonzero recorder count in any in-machine chain. Its `HOOK_VMEVENT`
  rule is taken.
- **The constant: 8 KiB, not 4.** The designer pinned one window and showed its floor (W21
  passes at 4 KiB, fails at 1 KiB; W16Rj fails at 1 KiB with the JIT on). Two judges asked for
  more room for a recovery nobody had measured, and the error is asymmetric: too small refuses
  a program's own catch handler inside its report, the contract THE CREDIT exists for; too
  large by 4 KiB lets a fill that never saw its refusal hold +70 strings more, in
  second-chance runs only. Two compile-time guards pin the range.

## THE RESERVE'S SIZE

The rules, as THE CREDIT's comment now states them:

- **RESERVE, after a refusal:** `LJ52_GC_RSV` (8 KiB) past the heap the refusal found -- never
  under the burst tier's top, never past cap + G. Sized **once**, at the refusal that opens the
  tier: later refusals in it shut the window and arm, as before, and cannot creep it.
- **A fresh record** (an eris reload whose live data is already past the burst top) keeps the
  whole tier, as before.
- **No credit under `HOOK_VMEVENT`**, as under `HOOK_GC`: a VM event handler's error is dropped
  with "VM handler failed" and would open the reserve for a program that never saw it.
- **Read-side clamp:** the credit is clamped to [G/2, G] where it is read, with G passed in, so
  a cap changed since the refusal re-clamps it and no path can read a credit the bound does
  not cover.

The bound, per thread class (T the cap, G = clamp(T/16, 32 KiB, 512 KiB), S = T + G/2,
L = 4 KiB the window, R = 8 KiB, K = 16 KiB the kernel's slice, u the heap at the refusal that
opened the reserve):

| who | bound on used + delta |
|---|---|
| sandbox, burst tier | S + L (unchanged) |
| sandbox, reserve opened by a refusal | max(u, S) + R + L ≤ T + G/2 + 16 KiB, and always ≤ T + G + L |
| sandbox, reserve by the fresh-record rule | T + G + L (unchanged) |
| the kernel, either tier | T + tier + K ≤ T + G + K (unchanged); 12 KiB past the sandbox's ceiling in both tiers |
| under `HOOK_GC`, `HOOK_VMEVENT`, a host GCSTOP | T (no credit, no window) |

Exception, named: when the heap was already past S + L when the tier opened (the kernel's
slice spent past the sandbox's ceiling between resumes, or the kernel's own refusal at S + K),
u is what the kernel left and the clamp at G binds -- the absolute bound is the one that holds
there. Everything is charged; `getFreeMemory` reads 0.

## Measured

**Hermetically** (the designers' prototypes, 4 KiB; the same rule in two independent
implementations gave identical aggregates to the digit): every cap whose program saw its own
refusal byte-identical, 9 399 of 9 399 over seven cells; 0 of 10 240 runs past either bound;
collections -1 %; capacity -0.06..-0.68 % per cell, all of it the former second-chance runs
(about 200 fewer strings, 42 fewer records each, the room no longer lent); the OpenOS-shaped
timer probe's stalls 21 → 0 at seed 1, but 0 → 6 and 25 → 0 at the two other seeds -- the
probe's phase, not the size: R0, R8K and R1K all read 0 of 803 over the three seeds, R4K 6 in
one six-cap pocket. The kernel-garbage probe's second-chance downs 103 → 60; its 725 downs
without a second chance are the window-overrun residual and do not move.

**The final object** (8 KiB, the VMEVENT guard; its instrumented copy proven inert on the
shipped objects' bytes and on 1 024 + 1 024 identical driver lines), through the eight cells at
seed 1 (4 096 caps for the census probe's four, 2 048 for the OpenOS-shaped and kernel-garbage
four) and the three string cells at seeds 2 and 3 (`finst/` in the archive):

| cell | seed | non-second-chance caps identical | outside, before → after | second chances | of them outside, before → after | past the new bound, before → after |
|---|---|---|---|---|---|---|
| string JIT on | 1 | 3 655 / 3 655 | 1 → 1 | 441 | 0 → 0 | 441 → 0 |
| record JIT on | 1 | 3 935 / 3 935 | 0 → 0 | 161 | 0 → 0 | 161 → 0 |
| string JIT off | 1 | 3 441 / 3 441 | 0 → 0 | 655 | 0 → 0 | 655 → 0 |
| record JIT off | 1 | 3 952 / 3 952 | 0 → 0 | 144 | 0 → 0 | 144 → 0 |
| OpenOS timer, string | 1 | 1 820 / 1 820 | 21 → 0 | 228 | 21 → 0 | 228 → 0 |
| OpenOS timer, record | 1 | 1 976 / 1 976 | 0 → 0 | 72 | 0 → 0 | 72 → 0 |
| kernel garbage, string | 1 | 1 819 / 1 819 | 828 → 763 | 229 | 103 → 38 | 229 → 0 |
| kernel garbage, record | 1 | 2 010 / 2 010 | 162 → 163 | 38 | 0 → 1 | 38 → 0 |
| OpenOS timer, string | 2 | 1 773 / 1 773 | 7 → 7 | 275 | 0 → 0 | 275 → 0 |
| string JIT on | 2 | 1 871 / 1 871 | 1 → 1 | 177 | 0 → 0 | 177 → 0 |
| string JIT off | 2 | 1 718 / 1 718 | 0 → 0 | 330 | 0 → 0 | 330 → 0 |
| OpenOS timer, string | 3 | 1 748 / 1 748 | 28 → 3 | 300 | 25 → 0 | 300 → 0 |
| string JIT on | 3 | 1 883 / 1 883 | 3 → 3 | 165 | 0 → 0 | 165 → 0 |
| string JIT off | 3 | 1 718 / 1 718 | 0 → 0 | 330 | 0 → 0 | 330 → 0 |

- Every reserve a refusal sized (36 864 of them) is exactly 8 192 B past the heap it found; the
  credit past the cap 24 624-28 800 B, i.e. G/2 + R plus where in the window the refusal fell.
- The largest excursion past cap + G went from +1.4 KB to −6.8 KB (census string), and to
  −3.1 KB in the kernel-garbage cell, where the kernel's slice, not the sandbox's reserve, sets
  it.
- Capacity over all caps 0.996-1.000 of the previous build's; the second-chance caps hold 135
  fewer strings or 30 fewer records (the 8 KiB no longer lent); collections −0.5..−1.1 %.
- The second-chance stalls of the OpenOS-shaped probe are gone at every seed (21 → 0, 0 → 0,
  25 → 0); the remaining outside landings there (0, 7, 3) are the burst-top residual on data
  that does not fit, with no second chance -- unchanged. In the kernel-garbage string cell the
  second-chance downs fall 103 → 38 and the 725 without one stay; the record cell gains one
  (a run that ended inside now meets the closer ceiling): the window-overrun residual.
- The seed-2 and seed-3 baselines were re-run here with the forensics' driver and matched the
  design round's own on 2 048 of 2 048 caps; the final driver matched its inertness runs on
  1 024 of 1 024.

**mem_test, 86 checks** (`test/native/mem_test.c`):

- **W20, W20L** -- a refusal the program never saw opens two windows of reserve, not G/2: W16R's
  program over 8 caps, the heap read at both refusals. Born failing on THE WINDOW's object:
  +16 386 B (273 objects) bought against a bound of +12 288. Now +8 279 B (137 objects), 0 past
  the bound, on both paths.
- **W21** -- a recovery that holds its data across the cycles its report costs: W17's fill until
  refused, then 32 kept lines around 100 garbage strings (~2 KB held, ~8 KB granted), then the
  drop. Born failing against the sabotage, not the shipped shim: with no room past the refusal
  (`rsvnone`) the handler is refused inside its report. This is the guard W8 turned out not to
  be: W8 runs on the main thread with no arm, so the kernel's slice pays its format.
- **W22** -- a refusal under `HOOK_VMEVENT` opens no reserve: a "bc" handler fires from the
  parser and is refused its 16 KB; the tier must still read burst and the program's 8 KB be
  refused. Born failing: THE WINDOW's object reads reserve and grants the 8 KB.
- **W7** tightened: 4 000 caught refusals that keep their data reach at most cap + G/2 + 8192 +
  two windows. THE WINDOW's object reads od_peak at G + 4 078: fails. The 8192 is a literal, as
  W19's 11 KB is: a shim that grows the reserve fails here.
- **W7m** -- W7k's kernel bound at a 1 MB cap, where G is 68 KiB and the kernel's own refusal
  sizes the tier at 58 600 B, under G: the precondition read from the shim is the one that
  holds (peak 74 960 between tier + window and tier + slice). W19, W7k and W16R read the tier
  from the shim too; the kernel's 11 KB and W7's bound stay literals.
- Fail-first: W7, W20, W20L and W22 fail on THE WINDOW's object, exactly those, in 3 of 3 runs;
  the new object passes all 86 in 30 runs (additive) and 10 (dropin) with random string-hash
  seeds, and in the negative control's fast form.
- Both `#error` guards were seen to fire (1 KiB: under one window; 16 KiB: past the old tier at
  the smallest G).

**The negative control, 41 sabotages** (`test/native/negative-control.sh`): six new --
`rsvwhole` (the whole tier again: W7 W20 W20L), `rsvnone` (no room past the refusal: W20 W20L
W21), `rsvfresh` (the fresh record's reserve halved: W11), `rsvunclamped` (the reserve read
unclamped: W7k), `rsvcreep` (re-sized at every refusal: W7 -- the only case that catches it,
which is why W7's tightening is part of the design), `novmevent` (a VM event handler gets
credit: W22) -- each caught by exactly its predicted set at the first measurement. Twelve
existing sets were re-measured on the final source and the script now expects what it
measured: W20, W20L, W21, W22 and W7m join the sets where the credit, its bound or the reserve
is involved (`stopgap`, `nocredit`, `unbounded`, `nokslice`, `closereserve`, `noceiling`,
`slicewindow`, `rawverdict`, `kernelwindow`, `noverdict`, `nogrownreset`), and `noarm` now also
stalls W16Rj/W16RjL: the reserve top is closer, so a window whose cycle nothing arms is met
with the JIT on. The confirming run: 41 of 41.

**In the machine** (`logs/runsF/`; the criteria as pre-registered in `design/d3-final.txt` §5.4,
each with its teeth): E, the previous build (THE WINDOW plus the unwinder fix), against F, this
one, interleaved by rep; the instrumented natives for the amplified and recovery cells (one
stderr line per refusal, proof and sizing), the plain ones for the batch-100 matrix and the
suites; 192 KB, OC's scale, batch 10 and junk 24 where amplified. 166 runs.

1. **The bound.** F: 0 of 30 amplified runs past G/2 + R + 2 windows = 32 768 B, the worst
   27 485. E: 21 of 30 past it, the worst 34 849 -- the teeth (at least 10 required). Holds.
2. **The creep.** In F's 22 runs with two refusals or more, the heap at the last refusal minus
   the heap at the first: median 8 270 B, max 9 108, none past R + 2 windows + the request; the
   30 reserves sized all in [G/2 + R, G/2 + R + window]. E: median 16 172, 21 of 21 past 12 288
   -- the teeth. Holds.
3. **Bad outcomes.** E 30 of 30 clean. F 29 clean and one down -- the dropin, rep 5: the paint
   absorbed three verdicts in a row (`wrapUserdata`, `checkArg`, `unwrapUserdata`), the fourth
   landed in OpenOS's `init.lua:18` and the fifth in `/lib/transforms.lua:19`, the dispatcher's
   own allocations escaping into `init` -- the map's unprotected path, the machine down. Within
   the regression bar (E's count plus 3) and the lottery's history (W 1 of 15, V 2 of 15, chainR
   0 of 15 in the JIT-on record cell): here E 0 of 20 JIT-on record runs, F 1 of 20. Second
   chances E 21 of 30 (the D record cell 9 of 15), F 22 of 30 (11 of 15): the cell is not void.
   Refusals per run moved up on F -- 13 of 30 runs with four or more against E's 6 of 30: at the
   closer reserve top the fill meets the verdict sooner, and the paint absorbs more draws before
   the fill's own; each draw costs a window and two proofs, not room (the creep says so).
4. **Capacity.** The batch-100 matrix 76 of 76 clean (F 48, E 24, stock 4). F against E like
   for like at 192 KB: array 783 against 789, closure 769 against 774, record 555 against 549,
   string 2 048 against 2 048 with the JIT on; 868/868, 834/834, 602/601, 2 210/2 210 with it
   off -- within 1 %. F against stock at least 2.6x in every 192 KB cell (stock 280, 496, 256,
   1 024); 1024 KB closures 8 020-8 081 against stock's 8 192, the 0.98-0.99x of the previous
   rounds. In the amplified cells F's second-chance runs hold less than E's by what the 8 KiB
   no longer lent is worth: 587 records against 614 (the cell's median 580 against 607) and
   2 348 strings against 2 484 -- as the census said (30 records, 135 strings) -- and 2.3x
   stock's amplified 256 and 901-1 024. The pre-registered "at most 10 records" was
   mis-estimated (8 KiB of records is about 90); the bound that matters, 8 KiB of live data,
   holds.
5. **The suites.** Additive JIT on 66/0, the dropin 63/0, JIT off 64/0, sieve 60/0, stock 47/0;
   mem-2 passes; km-1's `kernelMemory` 164 923, E's figure. mem_test 86 of 86 in 40 runs and the
   negative control 41 of 41, above. The Linux native (WSL, additive `45b25422`): mem 86/0,
   wd 35/0, penalty 6/0.
6. **Cost.** The last five batches' time F/E: JIT-on record 1.12, the dropin 1.07, JIT-off
   string 0.89 -- one cell over the 1.10 bar by 0.02, at medians of 15 runs near 1.8 ms, where
   the extra draws at the top (a window and two proofs each) show. Over the whole fill the
   collections are within 3 % (160 against 158, 180 against 175, 417 against 425), the window's
   lends 33 against 24; the idle window's arms equal (20-21 with the JIT on, 1 off), no refusal
   at idle. The bar is missed in that cell; the per-growth path is untouched and the draws are
   THE WINDOW's.
7. **The recovery.** Void as pre-registered (E's control runs were refused too), measured
   instead against stock. Level 3 -- a traceback, the tty, OpenOS's `event.onError`, while
   holding: stock 0 of 6 clean (record 0 of 3, string 0 of 3), E 2 of 6 (0 of 3, 2 of 3), F 3 of
   10 (0 of 5, 3 of 5); level 1, the traceback only, on F 0 of 3, all three after a second
   chance. Every refused recovery is one of two things. After a second chance the catch comes
   at the reserve top with no room: F 7 of 7 such runs, E 2 of 2, at the first allocation of
   the recovery. Or the recovery holds more than the reserve: the JIT-on record cell's held
   16.2-16.3 KB on E and 8.8-11.1 KB on F at the refusal, where the JIT-off string cell's
   completed holding 11.9 KB on E and 8.5 KB on F. The cells confound the shape with the JIT,
   and the instrument shows the JIT's own allocations in the recovery: one recorder-absorbed
   900 B refusal, the trace assembler's, in F's record cell -- the first in-machine recorder
   refusal ever observed; it opened nothing, the reserve being open already. Stock, its live
   data at the cap, recovers in none. So this build is at least stock in every recovery cell
   and below E only where a recovery after an own refusal needs between 8 and 16 KiB -- no such
   run occurred; E's own-refusal record recoveries needed more than 16 KiB.
8. **The instrument's own questions.** First refusals on F: `checkArg` 11, `wrapUserdata` 8,
   `unwrapUserdata` 3, the fill's own 3 of 25; on E 9, 9, 3, 3 of 24 -- the in-machine absorber
   is the kernel's per-call closure, as in `runsR`. Refusals on the kernel thread: 0. Requests
   the size of a string-table doubling: 0. Recorder-absorbed: 1 (above), the trigger the
   synthesis named for landing the recorder rule.

## The recovery, found on the way

The gate's recovery cell was pre-registered as "a recovery that formats while holding (a
traceback, the tty, OpenOS's `event.onError`) must be clean on F, with the control clean too
or the cell is void". The first runs voided it: the control (the old 16 KiB reserve) was refused
as well. The instrumented control shows why, and it is not the reserve's size:

1. The reserve was opened by the paint's absorbed refusal (`=machine:1261`), and the fill, which
   never heard, spent all of it: the heap after each of the ~70 proven cycles that followed --
   live data, by definition -- climbed 16 KB to the reserve top.
2. The fill's own first refusal then came at the reserve top, live data 53 B past it.
3. The recovery's first allocation crossed the top and was lent by the window; THE CADENCE at
   the top proves a cycle every ~100 B, so the two-proof verdict formed within ~150 B and
   refused the recovery's next crossing: a 44 B traceback, at level 1.

So after a second chance there is no recovery room on either build -- and on stock, whose fill
is refused with its live data at the cap, there is none either: the gate's recovery cells
read stock 0 of 6 clean, E 2 of 6, F 3 of 10 (item 7 above). A recovery after the program's
**own** first refusal is W21's case and holds when it fits the reserve; the recovery measured
here held 8.5-12 KB with the JIT off and more than 16 KB with it on.

## What is left

- **The reserve top's lottery stays.** A refusal the paint, the dispatcher or the recorder
  absorbs still opens the reserve for a fill that never saw it; the fill now holds 8 KiB plus a
  window more, and then meets the verdict wherever it falls, with the same number of draws as
  before. History: 3 of 46 second-chance JIT-on record runs down. This change bounds the prize,
  not the draw. The verdict's address is the lever for the draw, deferred on the evidence
  above and on the two inputs this gate measures.
- **A recovery that holds after a second chance** is refused, as on stock. A recovery that
  holds more than 8 KiB after its own first refusal is refused inside its report, where the
  previous build allowed G/2 and stock allows nothing.
- **The kernel-overrun residual** is untouched: the kernel's slice taking the heap more than a
  window past the sandbox's top between resumes is refused at the dispatcher's `table.pack`.
- **The recorder** still opens the (now bounded) reserve: 23 of 2 192 hermetic second chances,
  0 of 50 in `runsR` and 1 of about 300 refusals in this gate (a 900 B trace copy in a JIT-on
  recovery, opening nothing). The trigger the synthesis named has fired once; the rule
  (`design/identify/identify.diff`, exact and proven both ways) is the next change if it
  fires again, not this one.
- **The cost bar** missed by 0.02 in one amplified cell: the draws at the top, each a window
  and two proofs. A silent past-cap cadence was a design-round variant (−11 % cycles) and is the
  follow-up if it matters.
- **THE WINDOW's own residuals** are unchanged: the burst-top landing on data that does not fit,
  the never-verdict band, the near-wall cost, a verdict on garbage pinned across two cycles.
- **8 KiB is a margin, not a measurement.** No recovery that fits between 4 and 8 KiB was
  measured; the in-machine recovery either fails for the reason above or, after an own
  refusal, fits in far less (W21's 2 KB).
