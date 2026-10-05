# The window: a refusal only when a collection would not make room (2026-10-05)

**The last row of the collector at the wall, narrowed to a residual of its own: in every
hermetic sweep with the JIT off, no refusal that a collection would have covered lands
outside the program's handler any more, and in the machine's amplified probe the bad
outcomes fell from 15 of 50 to 1-2 of 50.** What remains -- a refusal some other handler
absorbed opens the reserve tier for a program that never saw it, and the reserve top's
refusal can still land outside a handler -- has its own roadmap row.

- **What was wrong.** Since stage B we refused when live data plus the garbage since the
  last proven cycle crossed a tier's top, at whichever allocation got there first. Stock
  PUC collects at the refusal and retries. So some of our refusals came early, where stock
  would have carried on, and some landed in code with no handler: the capacity probe's step
  between batches (a stall), or OpenOS's dispatcher (a machine down).
- **THE WINDOW.**
  - A sandbox growth past its tier's top is now lent, at most 4 KiB further, and arms the
    cycle that decides it.
  - A proof that finds the heap back under the top shuts the window.
  - Only data that survived two consecutive cycles past the top -- the verdict -- has its
    next crossing refused.

  Zero LuaJIT lines; about 60 lines of shim code.
- **Hermetically:**
  - outside-handler refusals 423 of 16 384 → 0 with the JIT off, and 625 → 0 with it on
    (one sweep; the first reproduction, run from another directory, read 431); stock PUC
    0 of 90 112;
  - the window's own tests (the six W16 cases and W17) fail on stage C in every run; the
    other new checks (the kernel's and the fresh record's) pass there; all 81 pass on the
    new object in every run.
- **In the machine, an amplified capacity probe** (batch 10, so that between-batch code is a
  large share of the bytes):
  - stage C 15 bad runs of 50 (11 machines down, 4 stalls), THE WINDOW 1 of 50 (one-sided
    Fisher p = 0.00009); after the code review's fixes, 2 of 50 (p = 0.0005), both in the
    same JIT-on record cells -- one more than the gate's own bar of at most 1 there;
  - stock stalls too at that batch size, 2 of 20.
- **The standard matrix** (batch 100): every run clean, THE WINDOW 48 of 48 and stock 20 of
  20 (chain C had a stall in 49); after the fixes, 48 of 48 again.
- **Cost:**
  - near the wall, 1.16x stage C's time (median, same chain; 0.63-1.33x);
  - collections over a fill +11-19 % at 192 KB;
  - idle unchanged at 192 and 1024 KB; at 256 KB with the JIT on, 4-5 arms per idle window
    (up to 17) against chain C's 0, cause not separated (the probe or the window).
- **Found on the way: a LuaJIT process crash** in the Windows unwinder, reachable on stage C,
  which would take the whole JVM down. Root-caused and confirmed; the fix is a three-line
  LuaJIT patch, ready but not part of this change. It has its own roadmap row.

All harness runs: ocelot-brain, JDK 8, pinned to the performance cores (`affrun C03C03`),
the watchdog kernel on ours, OC's own on stock, at OC's `ramScaleFor64Bit` 1.8.
- **Stage C:** additive `05d133cf`, dropin `4cb483a5`, shim object `0259f0d1`.
- **THE WINDOW as first built (W):** additive `6b2ff4ae`, dropin `bc4c8250`, shim object
  `d1242186`.
- **After the code review (V):** additive `ae3e414b`, dropin `7fa4e8f9`, shim objects
  `082ff068` (additive) and `332dc85c` (dropin).

Archive: [runs/2026-10-05-window/](runs/2026-10-05-window/).

## What the stalls were

The row was opened on stage B's and C's capacity matrices: 3 stalls and 1 dropin machine
down in 68 of our runs on stage B, 1 stall in 49 on stage C, 0 in 40 on stock. A survey of
those five logs (`design/u2-stalls.md`) corrected two things the row had said.

- **Every bad run had a second refusal, and the bad outcome came at the second.**
  - Across all 116 of our capacity runs with data in chains B and C (the 68 + 49 above,
    less stage B's one boot failure, which never reached the fill), the refusal count and
    the credit tier split exactly. The 95 single-refusal runs stayed in the burst tier. The 21
    multi-refusal runs reached the reserve tier, holding about G/2 more live data.
  - In those, the first refusal was caught by something other than the fill's `pcall` -- the
    probe's `pcall(paint)`, the JIT recorder, OpenOS's error path. It opened the reserve
    tier and the fill went on.
  - All five bad outcomes were at that second crossing (5 of 21); none was at a first (0 of
    116).
  - Stock has no reserve tier, so a refusal it absorbs does not give the fill more room.
- **The stage string was not the site.**
  - In all four stalls the painted rows show the stage string of the last step assigned and
    the next step never counted.
  - That leaves `event.timer(0, step)` (about 0.8 KB in 8 allocations) or the 80-byte
    closure handed to `pcall`.
  - The stage-B note named the stage string; it was wrong there.
- **OpenOS keeps the machine up through a stall.**
  - Its dispatcher calls timers under `pcall` and removes a one-shot timer before calling
    it, so the chain breaks; the heartbeat is never removed.
  - Once the chain breaks nothing references the held data, which is why a stalled
    machine's heap ends near its pre-fill live set.

## The hermetic reproduction

The probe's shape, run with no JVM against the shim object (`design/u2-repro.md`):
- a sandbox coroutine resumed under the watchdog's arm;
- a fill inside `pcall`, with a churn string per object;
- between batches, outside any handler: the stage string, event.timer's record, and the
  dispatcher's `table.pack(coroutine.yield())`.

Results:
- **Stage C:** 431 of 16 384 caps (4 shapes x 64 KB of cap offsets) refused outside the
  batch's handler -- 219 stalls, 212 sandbox downs.
- **Every one was garbage-covered:** two collections taken in place just before the refused
  allocation left room for the whole object, with 100-1 140 B to spare.
- **Stock PUC 5.2.4,** the same program over the same rooms, in ten variants: 0 of 90 112.
- **Deterministic:** the only run-to-run variation is LuaJIT's random string-hash seed;
  twelve (shape, offset) pairs reproduce in 20 of 20 random-seed runs.

Three mechanisms, traced with an allocator ring:
- **M1:** the last cycle ran at a checkpoint inside the batch, while the batch's frame still
  held its churn in registers, and freed nothing. The next request after the batch returned
  did not fit, and the cadence never re-arms at `used == gc_low`.
- **M2:** an object allocated in two parts (a table, then its hash part) with no checkpoint
  between. The first part armed, the second was refused.
- **M3:** between resumes the kernel spent its 16 KB slice past the sandbox's top without
  arming, and the sandbox's first allocation after the resume was refused.

**The root of all three:** we refuse when `used` passes the top -- live data, everything since
the last proof, and what the deciding checkpoint's frame still pinned -- before any checkpoint
can collect. The single-request form of this was already documented (W9); these are its
multi-allocation forms.

## THE WINDOW

Three designs were prototyped against the reproduction and judged (`design/`):
- **d2-lend:** lend past the top until a proof decides;
- **d2-verdict:** a re-derived state machine;
- **d2-prevent:** fix each mechanism where it arises.

What the judges found:
- **Prevention alone did not close it.** Each leftover case had a checkpoint that ran with
  garbage still pinned, and the allocations after it reached the top before any other could
  run.
- **The verdict design had two fatal defects.**
  - Its loan could exceed the kernel's slice, so at caps over 2 MiB the kernel could be
    refused for the sandbox's data.
  - It made the unwinder crash (below) frequent.
- **Both judges recommended d2-lend;** the synthesis grafted their fixes onto it.

**The rule** (`native/lj52shim.c`, THE WINDOW):

- **The lend.** A sandbox growth that would pass its tier's top S (cap + G/2, or cap + G in
  the reserve tier) is lent, at most `LJ52_GC_LEND` = 4 KiB past S, and arms the cycle that
  will decide it.
- **The proof decides.** At the next proof:
  - the heap back under S shuts the window: garbage covered the crossing;
  - the heap past S even without the bytes granted since the previous proof is **the
    verdict**: data that survived two consecutive cycles. The next crossing is refused, and
    that refusal shuts the window and arms a cycle, so the crossing after it is decided
    anew;
  - otherwise the window stays open.

  One proof is not enough. A cycle run at a checkpoint inside a loop marks that frame's
  registers, so it counts junk that is dead the moment the loop returns.
- **The look.** A growth that would pass the cap first proves a cycle that has ended. So the
  decision reaches the first allocation after the deciding cycle -- usually still in the code
  whose checkpoint ran it -- not the second.
- **The kernel gets no window.**
  - Its 16 KiB slice lies past every window: the shim refuses to compile with less than
    12 KiB of slice past the window. So the kernel keeps 12 KiB past the sandbox's ceiling
    (16 KiB on stage C).
  - A heap the kernel's slice took past S between resumes makes the sandbox's next
    allocation an ordinary crossing, lent.
- **The fresh-record rule ignores the window's own bytes.** A record that has proven no
  cycle, and is lent past cap + G/2, does not take that as eris history and open the reserve
  tier (W11w; a code-review fix).
- **Unchanged:**
  - no window under a finalizer or a host GCSTOP;
  - nothing crosses eris;
  - THE CADENCE and the flush are unchanged in code.

**The bound** stays absolute:

    sandbox:      used + delta  <=  cap + G + 4 KiB
    every thread: used + delta  <=  cap + G + 16 KiB      (unchanged)

The verdict can only refuse, and a refusal never changes `used`, so caught refusals cannot
ratchet it.

**What each part buys,** each measured by removing it (the negative control's sabotages):

| part | without it | fails |
|---|---|---|
| the lend past S | stage C: refused at the top | the W16 family, W17, W19 |
| the lend on the legacy (dropin) path | the dropin refuses at the top | W16L W16RL W16RjL |
| the ceiling S + 4 KiB | the bound goes | W7 W11 W11w W11wL W18 W19 |
| the two-cycle verdict | a proof at the batch's last checkpoint counts the frame's junk | the W16 family |
| the verdict at all | live data is refused only at the ceiling | W17 |
| the growth count's reset at a proof | never a verdict either | W17 |
| the look | the decision reaches event.timer's record, outside the handler | W16 W16L W16R W16RL |
| a refusal shuts the window | the caught refusal's own cycle never decides | W16Rj W16RjL W19 |
| no kernel window | the kernel's tops stop being hard | C6b W7k |
| a window as wide as the slice | the kernel loses its room | W7 W11w W11wL W19 |
| the window's own arm (with THE CADENCE's) | nothing arms the deciding cycle | W17 |

## Tests

**mem_test: 81 checks.** The 68 of stage C plus:
- W16, W16R and W16Rj, and their legacy-path twins W16L, W16RL and W16RjL;
- W17, W7k, C6b, W18 and W19;
- W11w and W11wL.

| object | runs | result |
|---|---|---|
| THE WINDOW after the review, additive `082ff068` | 30 | 81/81 every run |
| the same, dropin `332dc85c` | 5 | 81/81 every run |
| THE WINDOW as first built, `d1242186` | 5 | fails W11w and W11wL every run (the fresh-record defect); one run also W4's old time clause |
| stage C `0259f0d1` | 5 | fails exactly the six W16 cases (C and legacy) and W17 |

- **W16:** the reproduction's program over 96 caps, in C mode and on the legacy path.
  - "Covered" is R1's own test: the live set where the run landed, plus the refused request
    (`_OCLJ_WALLSTATS` 13), fits under the top.
  - It also asserts the kernel is never refused.
  - Stage C: 7 covered stalls. THE WINDOW: all 96 inside.
- **W16R, W16Rj:** the same carried into the reserve tier, JIT off and on. The fill's own
  handler absorbs the first refusal and counts it, and the fill goes on with its data kept.
  That stands in for the in-machine path -- the reserve tier an earlier refusal opened, the
  data kept -- but not for its absorber, which in the machine was not the fill's `pcall`.
  The tier comes from the shim's own refusal count, so a refusal the JIT recorder absorbs
  counts too.
- **W17:** a live fill must be refused past the top, within half the window.
- **W7k, C6b, W18, W19:** the kernel.
  - W7k: its bound.
  - C6b: its hard top.
  - W18: at 4 and 10 MB caps, a sandbox crossing larger than the window (a 32 KB doubling or
    a 20 KB concatenation, from S - 1 KB) is refused at the ceiling, and the kernel's packs
    after it are never refused. Its output equals stage C's; it fails when the window lends
    past its ceiling (noceiling) or the kernel loses its slice (nocredit).
  - W19: 11 KiB of room past the sandbox's ceiling, a fixed size.
- **W11w:** a fresh record at S - 1 KB, one table whose hash part would pass the ceiling: it
  must be refused, not granted on a reserve tier no refusal opened.
- **W7** is re-scoped, deliberately, from "cannot push the heap past cap + G" to "past cap + G
  + the window". The bound over every thread is unchanged, and W7k pins it.
- **W4's time ratio is now printed, not asserted.** It was two `clock()` readings of a few
  milliseconds at 1 ms resolution. It flaked twice under load, once inside a negative-control
  sabotage W4 has nothing to do with. Its cycle count, the deterministic measure, still is
  asserted.

**The negative control: all 35 controls pass,** each sabotage failing exactly its expected
set. Eleven sabotages are new, listed in the table above. Five older ones now also fail
new cases that depend on what they remove: stopgap fails every new case but W18; nocredit
the W16 family, W17, W18, W19 and W7k; nokslice the W16 family, W19 and W7k (W16 asserts the
kernel is never refused); closereserve W16Rj, W16RjL, W19 and W7k; unbounded C6b, W17 and
W7k.

**The native gates on the final build:** mem 81/0, watchdog 35/0, shim, security, race and
penalty pass, negative control 35/35.

**Hermetic sweeps** (THE WINDOW as first built; fixed string-hash seed unless stated;
outside-handler landings):

| configuration | stage C | THE WINDOW |
|---|---|---|
| probe, 16 384 caps, JIT off | 423, all garbage-covered | 0 |
| the same, JIT on | 625 | 0 |
| legacy (dropin) path | 423 | 0 |
| amplified, batch 10, JIT off | 5 274 | 0 |
| amplified, batch 10, JIT on | 2 206 in 12 881 (the process crashed at string off 9488) | 1, not covered |
| OpenOS-shaped `event.timer` probe, 8 192 caps, JIT on | 338 | 7, none covered |
| W16's program, reserve tier, JIT on | 1 847 | 0 |
| runs with two or more refusals, JIT on | 2 899 | 182 |
| kernel garbage 2 KB per resume | 1 318 | 85, none garbage-covered |
| unwinder crash census, one process per cap | 1 in 4 096 | 0 in 18 432 |

## In the machine

**The full suite** on THE WINDOW, as first built and again after the review:
- additive JIT on 66/0, the dropin 63/0, JIT off 64/0, sieve only 60/0, stock 47/0;
- `mem-2` passes on the additive and the dropin;
- `km-1` reads 0 traces at the baseline, and `kernelMemory` 164 923 B (dropin 164 247 B), as
  on stage C.

**The gate: an amplified capacity probe.** At the probe's own batch of 100 objects a stall
was rare -- 1 in 49 of stage C's runs -- too rare to show a difference. So:
- **The batch size and churn length are settable** (`OCLJ_CAP_BATCH`, `OCLJ_CAP_JUNK`). At a
  batch of 10, the code between steps -- the stage string, `event.timer`, the dispatcher --
  carries ten times the share of the bytes, so a refusal outside the handler is frequent
  where the rule allows it.
- **The probe paints four number-only counters** (`OCLJCAPX`: steps entered, the count when
  `event.timer` last returned, refused paints, errors that reached `event.onError`).
- **The harness prints a `CAP-X` line** with the run's class and, for a stall, its site. A JVM
  that dies prints no `CAP-X`; the chain counts that run as a process death.

The layout:
- a 192 KB stick, scale 1.8 (G at its 32 KB floor), batch 10, churn 24;
- stock S, stage C, THE WINDOW W;
- arms O (JIT off throughout), D (JIT on) and L (the dropin);
- string and record shapes, 10 reps (L 5), interleaved by rep, with stage C's JIT-on string
  cells last, because hermetically it reaches the unwinder crash.

120 runs:

| | record | string | bad / runs |
|---|---|---|---|
| stock S | 10 clean | 8 clean, **2 stalls** | 2 / 20 |
| stage C, O | 10 clean | 3 clean, **4 down, 3 stalls** | 7 / 20 |
| stage C, D | 3 clean, **6 down, 1 stall** | 10 clean | 7 / 20 |
| stage C, L | 4 clean, **1 down** | 5 clean | 1 / 10 |
| **W, O** | 10 clean | 10 clean | **0 / 20** |
| **W, D** | 9 clean, **1 down** | 10 clean | **1 / 20** |
| **W, L** | 5 clean | 5 clean | **0 / 10** |
| **V (after the review), O** | 10 clean | 10 clean | **0 / 20** |
| **V, D** | 8 clean, **2 down** | 10 clean | **2 / 20** |
| **V, L** | 5 clean | 5 clean | **0 / 10** |

- **Stage C 15 of 50 bad, THE WINDOW 1 of 50:** one-sided Fisher p = 0.00009, and each half
  clears 0.01 on its own:
  - JIT-off cells 0 of 20 against 7 of 20, p = 0.004;
  - JIT-on record cells 1 of 15 against 8 of 15, p = 0.007.

  After the review's fixes (V): 2 of 50, p = 0.0005; JIT off 0 of 20 (p = 0.004), JIT-on
  record 2 of 15 (p = 0.025). No JVM died anywhere.
- **Judged by its own pre-registered criterion** (`design/d2-final.md` §8.3, all must hold),
  the gate did not pass on either build. These parts held: stage C at least 7 bad (15), 0 bad
  in THE WINDOW's JIT-off cells, no process death, p < 0.01 overall. These failed: (b)'s
  attribution test (every down's od_peak is 1.6-2.6 KB past a tier's top, against a 256 B
  bar -- a test that cannot work for THE WINDOW, below); on V, (b)'s count (2 downs in the
  JIT-on and dropin cells, against at most 1); (c), stock clean (it stalled 2 of 20); and
  (d), capacity at least stock's in every matrix cell (1024 KB closures 0.98-0.99x). The
  significance stands; the rest is the residual and the probe's own limits, stated below.
- **The JIT-on string cells carry no signal.** Every run ended at or one object past the
  holder table's array doubling, refused inside the fill. Stage C's 15 all stopped at 2 048
  objects. On W, 10 of 15 were refused the doubling's 16 KB request; the other 5 were granted
  it and refused a 52 B request at 2 049 (V: 11 and 4). Stage C was 0 of 15 bad there, so
  these cells cannot tell the builds apart.
- **THE WINDOW's downs** -- one on W (`g-record-r10-W-D`), two on V (`r8`, `r9`) -- are the
  residual the design names, the verdict's refusal on data that survived two proven
  cycles. W's:
  - a refusal absorbed by the probe's own `pcall(paint)` (`OCLJCAPX` pf = 1) opened the
    reserve tier for a fill that never saw it;
  - the fill went on until the last proof found the heap 1 092 B past the reserve top
    (`gc_low` 552 678 against cap + G = 551 586);
  - the verdict's refusal then landed where no handler caught it.

  Its excursion stayed in the bound (od_peak G + 1 648 B, under G + 4 KiB). V's two are the
  same: a paint-absorbed refusal, the reserve tier, a last proof 200 B and 2 068 B past its
  top, a 56 B refusal outside any handler. The shim counted 5, 4 and 3 refusals in the three
  downs against pf = 1 each (in every clean run, refusals = pf + 1); where the extra ones
  landed is not known -- the count includes the error's way out, and the painted pf is the
  last successful paint's -- so which absorbed refusal opened the reserve tier is not
  established either. The machine
  cannot tell live data from garbage pinned across two cycles, and the gate's pre-registered
  attribution test (od_peak within 256 B of a tier's top) cannot work for THE WINDOW: od_peak
  is a whole-run maximum that includes the lend, and most clean runs fail it too.
- **With the JIT on, the amplified record runs often had a second chance:** 12 of 15 on W and
  9 of 15 on V had a refusal absorbed by the paint, against 161 of 4 096 in the matching
  hermetic sweep; 3 of those 21 went down. One reading -- an armed cycle completes only at
  a compiled loop's exit, so the verdict's refusal lands just after the batch -- is not
  checked, and can only explain the record contrast: with the JIT off the amplified string
  cells took the same path (W 3 of 10, V 8 of 10, all clean), the record cells never (0 of
  20).

  At the probe's own batch of 100: none of W's 28 JIT-on matrix runs had a second refusal;
  3 of V's 28 did, all at 1024 KB (two string, one closure; stage C's JIT-on runs reached
  the reserve tier in that string cell too), and chain T's W JIT-on 1024 KB closure runs did
  in 3 of 4. All ended clean.
- **Stock stalls too at batch 10:** 2 of 10 string runs, both at a step's entry, each after
  several refusals its paint absorbed.
  - Stock refuses at the allocation where its live data first fails to fit, and at batch 10
    that is often between batches.
  - THE WINDOW refuses at the first growth after the cycle that decided it, and on this probe
    it did no worse than stock (1 of 50 against 2 of 20).
  - The gate had assumed stock would be clean at batch 10; stock had been measured only at
    batch 100.

**The standard matrix** (batch 100, chain C's layout with THE WINDOW for stage C; 68 runs,
`runsG/matrix`): every run clean -- THE WINDOW 48 of 48 (JIT on, JIT off, the dropin; 192, 256
and 1024 KB), stock 20 of 20. Chain C had a stall in 49.

- **The excursion** stayed in the burst tier plus the window: od_peak at most 16.8 KB of a
  32 KB G at 192 KB, 20.7 of 39.8 KB at 256 KB, 64.8 of 128.3 KB at 1024 KB.
- **Idle** at 192 and 1024 KB is stage C's: at 192 KB with the JIT on a median of 20 arms per
  400-tick window (W 20-98, V 20-21; stage C under the same probe in chain T 20-100) and at
  most one flush; JIT off 0-4 arms; 1024 KB 0. At 256 KB with the JIT on it is not: a median
  of 5 arms (1-17) on W and 4 (0-8) on V, against chain C's 0 in all four runs. Chain C ran
  the old probe and chain T has no 256 KB cell, so the probe's new footprint is not ruled
  out; the cause is not separated. No idle window refused anything.
- **Capacity** is at least stock's in every cell but one: 1024 KB closures read 0.98-0.99x
  against a stock reading of 8 192. Stock read 7 313 there in chain C; it lands on either side
  of its holder table's doubling, and our absolute figure equals stage C's (8 084 against
  8 088 JIT off, 8 025 against 8 028 on the dropin).
- **The probe changed** (the code review): its new counters, row 19's paint and the onError
  wrapper add about 1.1 KB of live data and a fifth paint per step, and with the same stage-C
  native its JIT-off record and string cells go from one refusal to two (code outside the
  fill absorbs the first: the paint, in 9 of 10 runs). So batch-100 numbers compare only with a baseline taken under the same probe: chain
  T, below, not chain C.

**The cost near the wall, in the same chain** (`runsT`): stage C and THE WINDOW interleaved
with stock, 5 reps at 192 KB and 4 at 1024 KB, 136 runs, every one clean. The last five
batches' time (s, median):

| stick | shape | stock | stage C D / O | THE WINDOW D / O | THE WINDOW over stage C |
|---|---|---|---|---|---|
| 192 KB | record | 0.0015 | 0.0024 / 0.0032 | 0.0023 / 0.0029 | 0.96 / 0.91 |
| 192 KB | array | 0.0015 | 0.0019 / 0.0022 | 0.0022 / 0.0028 | 1.16 / 1.27 |
| 192 KB | string | 0.0017 | 0.0024 / 0.0044 | 0.0032 / 0.0052 | 1.33 / 1.18 |
| 192 KB | closure | 0.0020 | 0.0024 / 0.0030 | 0.0029 / 0.0029 | 1.21 / 0.97 |
| 1024 KB | record | 0.0034 | 0.0087 | 0.0107 | 1.23 |
| 1024 KB | array | 0.0037 | 0.0046 | 0.0029 | 0.63 |
| 1024 KB | closure | 0.0048 | 0.0092 | 0.0066 | 0.72 |

- **THE WINDOW over stage C: median 1.16x, range 0.63-1.33x** -- the hermetic figure was
  1.14-1.24x. Over same-run stock: 0.8-3.2x.
- **Collections over the fill:** 192 KB 52 against 47 (JIT on) and 50 against 42 (JIT off);
  1024 KB 54 against 55. The window arms a cycle per crossing it lends, and its verdict takes
  a second.
- **Capacity, like for like,** equals stage C's (192 KB JIT on: record 553 against 545, array
  786 against 791, string 2 048 both, closure 766 against 771; 1024 KB within 1 %) -- except
  the JIT-off record and string cells, where stage C holds more (659 against 602, 2 485
  against 2 215). There stage C's first refusal is absorbed outside the fill -- by the
  probe's paint in 9 of the 10 runs; in one neither the paint nor event.onError saw it -- and
  that opens the reserve tier: the second-chance path. THE WINDOW refuses inside the batch, and its 602
  matches the 605 chain C read under the old probe. At least stock's in every cell: 1.05-3.07x.

**After the review's fixes** (`runsV`): the full suite again 5 of 5; the standard
matrix's V cells 48 of 48 clean, idle and collection work as W's (192 KB JIT on: 20 arms per
idle window, 48 collects over the fill).

## The code review

Four reviewers looked at the change -- the shim, the tests and sabotages, the harness, and a
completeness critic -- and an independent verifier checked each finding.
- 18 findings: 16 confirmed (four downgraded from major), all minor; 2 refuted.
- Every confirmed one is fixed in this change.

**The defect:**
- **The window tripped the fresh-record rule.** On a record that had proven no cycle -- just
  created, or just loaded -- a lent array part took the heap past cap + G/2. The next
  allocation's credit then read that as eris history and opened the reserve tier with no
  refusal: a table was granted at G/2 + 13 KB.
- **The fix:** the rule now ignores a record whose window is open (`!gc_win`). W11w and W11wL
  fail on the first build and pass now.

**The test gaps:**
- **The legacy (dropin) path's window was untested:** removing it passed 76/76. The W16
  family now runs on the legacy path too, and sabotage 4.22 removes the legacy window.
- **The W16 family did not assert that the kernel is never refused.** It does now.
- **W16R and W16Rj judged the tier by the program's own refusal count.** They now use the
  shim's, which includes refusals the JIT recorder absorbs.
- **W19 derived its kernel request from the window.** It now asks a fixed 11 KiB, and the shim
  pins the 12 KiB at compile time.
- **The verdict and the growth count's reset had no sabotage.** They have now (4.23, 4.24).

**The comments:**
- **The verdict comment** said every further crossing is refused. The code refuses one, then
  decides anew. Corrected.
- **The clause that reads the verdict against the current top** is reached by no test: a
  sandbox growth usually consumes a verdict within one allocator call. A kernel growth
  (granted from its slice, never through the window) or a free can fall between the proof
  and the sandbox's next crossing, but no test arranges it. The comment says so.

**The harness:**
- **The classes:** a machine stopped for another reason gets its own counted class, STOPPED;
  a stall's "closure" site is renamed step-entry, because it covers the kernel's resume
  wrapper and stack regrowth too.
- **The comments** state the probe's footprint and what the trace counts span.
- **The chain:** a crash dump now outranks a failed boot milestone.
- **Comparability:** the probe's additions change its default behaviour slightly, so
  batch-100 results compare only with same-probe baselines.

## What is left

- **The residual** (the code comment's own words). A crossing is still refused wherever it
  lands when its window is overrun before a checkpoint can prove its cycle:
  - more than 4 KiB with no checkpoint;
  - a single request past S + 4 KiB (W9's class);
  - the kernel spending more than 4 KiB of its slice past S between resumes.

  So is one whose verdict rests on garbage pinned across two consecutive cycles.
- **In the machine, the second-chance path stays:** a refusal absorbed by code outside the
  fill opens the reserve tier. With the JIT on, the reserve top's refusal can then land
  outside a handler: 3 downs in 30 amplified JIT-on record runs across the two builds,
  against 8 bad in 15 on stage C. With the JIT off it took the path in the amplified string
  cells (W 3 of 10, V 8 of 10) and at batch 100 in a few JIT-on 1024 KB runs, all clean. Its
  own roadmap row.
- **Hermetically with the JIT on,** THE WINDOW still lands 0-7 times per sweep outside the
  handler with live data at the top, none garbage-covered.
- **The never-verdict band:** live data past S by less than its own garbage per cycle is lent
  within the ceiling, at one cycle per crossing, and never refused. That is stock's rate,
  which collects at every allocation that does not fit.
- **The kernel** keeps 12 KiB past the sandbox's ceiling, down from 16 KiB.
- **Near-wall cost:** about 1.16x stage C's. A design-round variant (a silent past-cap
  cadence) measured −11 % cycles and is a possible follow-up.
- **Idle 1 KB under a top** thrashes on stage C too (hermetic, +9 % here).

## The unwinder crash

Found by the design round: a process crash (exit 139) inside LuaJIT's Windows unwinder.
- **Where:** reachable from the shipped stage-C shim, but how often depends on the binary's
  layout. The design round's sweeps hit it on stage C a few times, with the same backtrace
  as the rejected design's crashes (1 of 4 096 caps at string off 9 488 in the final
  census, fixed and random seed alike; once at off 10 688 in another sweep). It did not
  reproduce under verification on current binaries: 0 of 40 at off 9 488, 0 of 64 and 0 of
  512 elsewhere.
- **How often:** frequent under one rejected design (17-43 %), never under THE WINDOW (0 of
  18 432).
- **Status:** root-caused by an investigator and confirmed by an adversarial verifier, both
  on the rejected design's shim linked over stage C's LuaJIT library -- the same LuaJIT
  (`crash/report.md`, `crash/verdict.md`).

**The cause:** a latent LuaJIT bug, not a shim bug.
1. `tostring` of a number runs interpreted as a fast function. It sets `L->base` but not
   `L->top` before calling `lj_strfmt_num` (`vm_x64.dasc:1385`). `fff_fallback` and
   `fff_gcstep` set both.
2. When our allocator refuses the result string, `lj_err_mem` skips its top refresh for a
   non-Lua frame (`lj_err.c:823-830`) and pushes the error message at the stale top: the
   frame's own slot.
3. `err_unwind` then reads that string as a frame link and dereferences it.
4. The same class exists in `string.char`, `sub`, `reverse`, `lower` and `upper`.
5. It needs the JIT on: 0 of 256 caps with it off, 83 of 256 with it on (on the rejected
   design's shim, where it is frequent).

**What it means for a player:** ordinary sandbox code near the RAM cap can trigger it, and in
a machine it takes down the whole JVM.

**The fix:** three lines in `lj_err_mem` that clamp a stale top up to the frame's base. It is
generic, so it covers every such fast function.
- Crashes drop 83 → 0 of 256 caps against the verifier's control, and 59 → 0 of 256 plus 0
  of 1 536 more against the investigator's (both on the rejected design's shim).
- mem_test still passes 76/76 with it linked in.

It is in `crash/patch-fastfunc-errmem-top.sh`, in the shape of the project's other LuaJIT
patches. It is not applied here: it gets its own roadmap row and change.
