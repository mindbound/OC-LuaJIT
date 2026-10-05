# j2-practice: judge's verdict, round 2 (lens: practice and testability)

Row: "A refusal at a credit tier's top can land outside the program's handler" (HEAD d9080d4).
Designs judged: `d2-lend.md` (THE WINDOW), `d2-verdict.md` (the loan and the verdict),
`d2-prevent.md` (prevention, then a 1 KB lend). I read all six survey documents and all three
designs in full, plus the code they change. The repo was not touched.

All my work is in `scratchpad/wall2/j2p/` (written `J/` below). Every measurement went to a fresh
`out*/` directory, and nothing was cleared.

---------------------------------------------------------------------------------------------

## 0. Verdict in one page

| design | score | build? | one line |
|---|---|---|---|
| **lend** (THE WINDOW) | **8 / 10** | **yes, as the base** | The only design that also fixes the in-machine path: the reserve top after an absorbed first refusal (W16R with the JIT on: 0 of 4 096). It survives every cross-test and stress I added. It costs +20 to 32 % cycles in the last five batches. |
| prevent | 6 / 10 | no; graft its tests | The smallest and cheapest change (11 code lines, +7 to 10 % cycles). It does not fix the in-machine path: 264 of 4 096 W16R runs stall with the JIT on, live data at the reserve top. It is the least robust to kernel pressure. |
| verdict | 3 / 10 | no; graft three pieces | Cheapest in cycles (−13 to −16 %). **FATAL:** its refusal placement makes a LuaJIT unwinder segfault the common outcome in an amplified JIT-on cell (442 of 1 024 caps; stage C 1, lend 0, prevent 0). It also adds live-data outside landings that stage C refused inside. |

**Why lend wins under this lens.** u2-stalls says every bad in-machine outcome came at the
**reserve** top after a first refusal that something other than the fill's pcall absorbed (paint, the
JIT recorder, OpenOS). That is lend's W16R and W16Rj shape. I ran each design's tests against every
other design's object (a 4 × 4 matrix):
- **W16Rj (lend's test) fails on verdict and on prevent, 3 of 3 runs each.**
- The probe-form sweep agrees. With the JIT on, the reserve-tier program has these outside landings:
  - stage C: 1 847;
  - lend: **0**;
  - prevent: **264**, all with live data within 52 B of the reserve top;
  - verdict: **104** sandbox downs.

Lend also leaves the fewest "second chances" with the JIT on, meaning runs with two or more refusals:
- stage C: 3 000 of 16 384;
- lend: 204;
- verdict: 155;
- prevent: 796, of which 563 were absorbed by the recorder.

**Recommendation.** Build lend's `final2`. Before landing, graft:
- verdict's W16 measure fix;
- verdict's explicit `prove()` in place of lend's `pressure(FREE)` observation;
- verdict's W17, and prevent's W17 and C6b, as extra pins;
- prevent's compile-time L ≤ K guard.

Then run the amplified in-machine gate (§8) with stage C as the positive control. Open the unwinder
crash as its own row **before** the gate's JIT-on string cells are run, because stage C reaches it too.

---------------------------------------------------------------------------------------------

## 1. What I re-ran (verify, do not trust)

**Builds.**
- Each design's source compiled with build-native.sh's line plus `-DLJ52_ADDITIVE`. Each reproduces
  its claimed object **byte for byte**, warning-clean:
  - stage C: `0259f0d1`;
  - lend: `2e1d8f6e`;
  - verdict: `e387460a`;
  - prevent: `cb996c9e`.
- The collector gate's own grep (`codegrep` from build-native.sh:299-301, the pattern from :340)
  finds **0** matches in all four.

**Diff size (`J/*.diff` against HEAD).**

| design | lines | non-comment lines |
|---|---|---|
| lend | +101 / −6 | +40 / −3 |
| verdict | +157 / −61 | +50 / −25 |
| prevent | +52 / −3 | +11 / −1 |

**Sabotage anchors** (`J/anchors.py`). All 13 of negative-control.sh's anchors are present exactly
once in lend and in prevent. In verdict:
- **closereserve's anchor is gone** (re-indented into `lj52_gc_prove`);
- **nocredit's anchor now sits in `lj52_gc_levels`**, so the stock `return 0;` edit would leave
  `*level` unset (verdict §8.3 says so).

### 1.1 mem_test, 4 × 4 cross-matrix

Each design's test file was linked against each object (`J/bin/mt_<test>_<obj>.exe`, run-mem.sh's
link line). Each cell ran 3×; each design's own file also ran 10× (`J/out1`, `J/out8`). Results were
identical in every run.

| test file → / object ↓ | R (repo + W16) | Lt (lend's) | Vt (verdict's) | Pt (prevent's) |
|---|---|---|---|---|
| stage C | FAIL W16 | FAIL W16 W16R W16Rj | FAIL W16 W17 | FAIL W16 |
| lend | FAIL W7 (re-scope) | **pass 72/72** | FAIL W7 (re-scope) | **pass 71/71** |
| verdict | pass 69/69 | **FAIL W16Rj** | **pass 70/70** | FAIL C6b W17 (by design) |
| prevent | FAIL W7 (re-scope) | **FAIL W16Rj** | FAIL W7 (re-scope) | **pass 71/71** |

Reading the matrix:
- **Lend passes every design-neutral case the others wrote:** verdict's W17 (fail-first on stage C),
  prevent's W17 ("the lend is not a third tier") and prevent's C6b (the kernel gets no lend).
- Verdict fails C6b because it lends to the kernel, and fails prevent's W17 because of its PIN. Both
  are deliberate.

W16Rj detail (`J/out1/Lt_*`):
- verdict: 2 burst-tier sandbox downs;
- prevent: 6 reserve-tier stalls ("used 474758 > top 474754").

The W16 family's "covered" figure is measured after the run, and it undercounts live data once the
sandbox coroutine has died (verdict §7.1: up to 3.9 KB). My in-place probe measure (§2) puts
prevent's stalls **at** the reserve top: not garbage-covered, but real stalls. So W16Rj fails prevent
for an instrument reason while flagging a real outcome. See F-L3.

### 1.2 Sabotages, rebuilt independently

`J/sab.py` makes my own exact one-line edits (`J/sab/*.log`, 2 runs each). Every designer's claim
reproduced exactly:

| design | sabotage | failing set |
|---|---|---|
| lend | nowindow | W16 W16R W16Rj |
| lend | rawverdict | W16 W16R W16Rj |
| lend | lateproof | W16 W16R |
| lend | refusalkeeps | W16Rj |
| prevent | nolend | W16 |
| prevent | noverdictarm | W16 |
| verdict | nolend | W8 W16 |
| verdict | nopin | W16 |
| verdict | latelatch | W16 |
| verdict | noverdict | W12 W17 |

### 1.3 Probe sweeps

**Setup.** Driver: `repro/lj_repro.c`, fixed seed, built against each object (`J/bin/rp_*.exe`).
"Covered" means live + 256 B ≤ the top, with live measured in place for stalls and after the
coroutine's death for downs. The down measure is optimistic by the dead stack. Summaries come from
`J/summ.py`.

| sweep (outside landings: stall + down) | stage C | lend | verdict | prevent |
|---|---|---|---|---|
| probe2, 16 384 caps, JIT off (`out3`) | 431 | 0 | 0 | 0 |
| probe2, JIT on | 508 | 0 | 21 | 17 |
| W16 program, 4 096, JIT off (`out2`) | 168 | 0 | **22** (11 + 11), none covered at G/2 | 0 |
| W16 program, JIT on | 473 | 0 | **104 downs** | 0 |
| W16R (reserve tier), JIT off | 169 | 0 | 22 | 0 |
| **W16R, JIT on (the in-machine shape)** | **1 847** | **0** | **104** | **264** |
| batch 10, JIT off, 4 096 (`out3`) | 1 299 | 0 | 0 | 0 |
| batch 10, JIT on, 16 384 (`out5` b10j16) | ≥ 1 906 + **crash** | 9 | 17 + **crash** | 99 |
| batch 5 / batch 10 junk 8, JIT on, 4 096 each | many + crash | 9 / 6 | 39 / 14 + crash | 36 / 7 |
| OpenOS-shaped `event.timer`, JIT off / on, 8 192 (`out10`) | 176 / 209 | 0 / 7 | 0 / 14 | 0 / 7 |
| kernel garbage per resume, 512 B / 2 KB, 4 096 (`out9`) | 407 / 1 311 | **0 / 85** | 0 / 241 | **71 / 1 045** |

Two of these rows are mine, not the designers':
- The OpenOS-shaped `event.timer` probe (`J/probe2oe.lua`) adds u2-stalls §1.2's three `checkArg`
  closures with two upvalues each. That is the site the painted rows point to, not the stage string.
- The kernel-pressure probe (`J/probe2k_*.lua`) is M3's general form: in a real machine, Java's
  signal pushes between resumes.

**Verdict's 104 downs** in the W16 program with the JIT on are not in its document, which reports
the W16 program with the JIT off only.
- I traced them with a refusal-printing copy (`J/mktrace.py`, `J/bin/rpT_*.exe`, `J2TRACE=1`).
- Each is a refusal **on the verdict**: an 80 B dispatcher `table.pack`, `gc_low` 84 B past the
  level.
- After the coroutine's death the heap was 2.2 KB lower, which is more than PIN (1 KB) covers.
- Command: `cd J && J2TRACE=1 ./bin/rpT_verdict.exe w16probe_err2.lua record 3408 3408 16 384 1 1 1 0 0 -1`

Every residual landing of lend and prevent outside the reserve-tier sweep is uncovered at the burst
top, i.e. stock's class by R1's letter:
- lend's 9 amplified JIT-on stalls: live 560 to 624 B past cap + G/2;
- prevent's 264 W16R JIT-on stalls: live within −52..+4 B of cap + G, 3 refusals each.

### 1.4 The crash

**What happens.** With batch 10, the JIT on and the string shape, these segfault deterministically
(3 of 3 reruns):
- **verdict: 442 of 1 024 caps** (`J/out4/crash_verdict.txt`, one process per cap);
- stage C: 1 of 1 024 (off 10 688, lend's §8);
- lend: 0;
- prevent: 0.

Verdict also crashes in batch 5 and in batch 10 with junk 8. Lend and prevent did not crash in any
of my 64 sweep processes, which include the 4 096-cap batch-10 JIT-on sweep (`J/out5/rc.txt`). No
object crashed at batch 100.

**Where.** gdb gives the same stack lend found on stage C:

    err_unwind <- lj_err_unwind_win <- RaiseException <- lj_err_throw <- lj_err_mem
    <- lj_mem_realloc <- lj_str_new <- lj_strfmt_num <- lj_ff_tostring <- lj_ff_coroutine_resume

The traced copy shows the refusal just before the crash: a 32 B request, interpreted, refused on the
verdict (heap 18 448 past the cap, against a level of 17 408).

    cd J && ./bin/rp_verdict.exe probe2.lua string 256 256 64 384 1 1 1 0 0 -1 24 10    # rc 139

**Root cause.** Not investigated: whether this is a LuaJIT unwinding bug for ERRMEM in a JIT-on
fast-function path, or something in the harness.
- What is measured: the shim's refusal placement decides how often it is reached.
- What is inferred: in a machine on Windows it would take the JVM down. Not run.

### 1.5 Cost

**Idle below the cap** (`J/idle.lua`, `J/out7/idle.txt`; 128 KB live, 50 garbage strings per resume,
3 000 resumes). Arms and collects are **identical** for all four objects at caps 40, 80, 120 and
200 KB over live (lend +1 at 40 KB). So R9's idle clause holds by measurement, not only by
construction.

**Idle past the cap** (`out7/idle_past.txt`). With live 15 KB past the cap (1 KB under the burst
top):
- stage C runs 12 475 cycles in 3 000 resumes; prevent the same;
- lend runs 13 604;
- verdict runs 3 055.

This thrash already exists at stage C (the halving degenerates near the top); it is not new to lend
or prevent. Verdict, being silent past the cap, is 4× cheaper here.

**Near the wall** (`J/out6`, lend's `probe2t.lua`, 2 048 caps, 5 interleaved repetitions in rotated
order, nothing else running, no Java process).

| vs stage C | lend | verdict | prevent |
|---|---|---|---|
| whole-run time | ×1.168 | ×0.942 | ×1.074 |
| last-five time (array / closure / record / string) | 1.12 / 1.22 / 1.22 / 1.34 | 0.85 / 0.91 / 0.88 / 0.88 | 1.00 / 1.09 / 1.08 / 1.14 |
| cycles in the last five batches (exact) | +20 / +20 / +24 / +32 % | −13 / −12 / −13 / −16 % | +7 / +8 / +10 / +10 % |
| collects per fill | +17 to +26 % | −11 % | +6 to +9 % |

**JIT-on string capacity, like for like** (runs with one refusal, inside):
- stage C 5 137.8, lend 5 140.9, verdict 5 161.3, prevent 5 139.7.

The 2 to 3 % headline deficit of every design comes entirely from stage C's recorder-absorbed second
refusals (its multi-refusal runs hold 5 450).

---------------------------------------------------------------------------------------------

## 2. The in-machine path (u2-stalls): does the design change it?

The forensics in four facts:
- 5 bad runs out of 116;
- all at the **reserve** top;
- each after a first refusal absorbed by something other than the fill's pcall;
- the dropin's last proof found live data 769 B under the reserve top.

Two things have to change: the absorbed first refusal, i.e. the second chance (a), and what happens
when live data reaches the reserve top at a batch boundary (b).

| | (a) second chances, JIT on (stage C 3 000 / 16 384) | (b) W16R, JIT on (stage C 1 847 / 4 096) | kernel garbage 2 KB per resume (stage C 1 311 / 4 096) |
|---|---|---|---|
| lend | 204 (35 recorder) | **0** | 85 |
| verdict | 155 (18 recorder) | 104 (burst-tier downs) | 241 |
| prevent | 796 (563 recorder) | **264** (live within 52 B of the top) | 1 045 |

**Lend changes both (a) and (b).**
- A refusal shuts the window, and the verdict needs data that survived two cycles. Together these
  push a live-at-the-top crossing at a batch boundary into the next handler.
- The 4 KiB window outlasts the probe's outside code and OpenOS's `event.timer` (0.81 KB).

**Prevent changes (a) only partly; at the reserve top it refuses at the next allocation**, as stage C
does.
- Its 1 KiB lend shuts on any proof past the top.
- Recorder allocations larger than that are still refused and absorbed (563 runs).

**Verdict** delivers the verdict to "the first growth past the level after a proof", wherever that is:
- it reaches `pcall(paint)` (133 paint-absorbed first refusals with the JIT off, against stage C's
  81);
- it reaches the dispatcher (the 104 downs);
- it reaches `tostring` in amplified string loops (the crash).

---------------------------------------------------------------------------------------------

## 3. lend (d2-lend.md, `final2/`): 8 / 10

| R | score | evidence |
|---|---|---|
| R1 | PARTLY | 0 garbage-covered outside landings in every sweep I ran, plus 0 of any kind at the reserve top (W16R JIT on). The JIT-on residual is uncovered: 9 of 16 384 amplified, 7 of 8 192 OpenOS-shaped. Refusals are later than stock by at most L = 4 KiB and two cycles, which the design states and bounds. |
| R1b | MET | W1, W1L, W1j, W8, W2b, W2c and W10 pass 13 of 13 (`out1`, `out8`). Every probe2 run reaches "done" (16 384 of 16 384). |
| R5 | MET | Sandbox `U+d ≤ T+G+4 KiB`, every thread `≤ T+G+K` unchanged. W7 (re-scoped) shows od_peak 36 846 = G + 4 078. W7k shows 49 140. Absolute, charged. |
| R6 | MET | Gate clean. No collection in the allocator. 0 crashes in every crash search. On-trace, HOOK_GC and GCSTOP are defined in its §4. |
| R7 | MET | 40 code lines, zero LuaJIT lines, every anchor intact. One wart: the proof is observed through a disguised `pressure(FREE)` call (F-L4). |
| R8 | MET | The window state is transient and per record: shut by a refusal, decided at each proof, `calloc` zero on a fresh record. The verdict is read against the current top. |
| R9 | PARTLY | Idle below the cap identical (`out7`). Near the wall: last-five cycles +20 to 32 %, time 1.12 to 1.34×, whole run 1.17×. Not within stage C's figures. |
| R10 | PARTLY | Fail-first is strong. W16, W16R and W16Rj fail on stage C (10 of 10) and pass on lend; 4 of 4 new sabotages verified. But the W16 family's covered measure has the dead-stack hole, and the in-machine gate was not run. |
| R11 | MET | `LJ52_GC_LEND` is a compile-time constant. |
| R12 | PARTLY | Capacity ≥ stage C like for like, and ≥ stock. Near-wall time is 1.12 to 1.34× stage C's, hermetic only. |

**FATAL:** none found.

**Major findings.**
- **F-L1, cost.** Lend's cost is a cycle per checkpoint while the heap is in the window: THE CADENCE's
  regime P arms on every growth past S. That is prior #10's "every grant arms", confined to a 4 KiB
  band. Measured +20 to 32 % cycles in the last five batches.
- **F-L2, test infrastructure.** mem_test goes from 0.99 s to 3.07 s (measured). Under negative-control
  4.9 (unbounded), lend's own run needed `W16_N = 8`, because the full suite ran past 300 s
  (d2-lend §7.3). negative-control.sh therefore needs a per-sabotage override or a timeout.
  - Fix: run W16R and W16Rj at 48 × 128.
- **F-L3, instrument.** The W16 family's "covered" uses live after the run, which undercounts after a
  stall or down because the dead coroutine's stack shrinks (verdict §7.1, §8.2).
  - My cross-run shows it: prevent's W16Rj stall reads 2 955 B of slack in mem_test, while the
    in-place probe measure at the analogous cap reads not covered by 4 B.
  - Lend passes only because it has no outside landings at all. A future change that leaves live-data
    landings would fail these tests for the wrong reason.
  - Graft verdict's fix: on an outside landing the coroutine records and yields.
- **F-L4, reviewability.**
  - Lend's "proof first" is `lj52_gc_pressure(M, …, LJ52_GP_FREE)` before every growth while armed
    (`final2/lj52shim.c`, the two lines marked `THE WINDOW` ahead of each refusal predicate). An
    observation dressed as a free also runs the park-reset test.
  - Verdict's extracted `lj52_gc_prove()`, called from the decision (`d2-verdict/lj52shim.c`,
    `lj52_gc_grant`), says what it means.
- **F-L5, residuals I measured.**
  - Kernel pressure past L between resumes: 85 of 4 096 downs at 2 KB of kernel garbage per resume;
    every design fails at 6 KB.
  - The two-cycle verdict subtracts gross growth (`gc_grown`). It is conservative, so in churning
    programs most refusals come at the ceiling S + L. That is bounded, but it is why the window fills
    to its ceiling in W7.

---------------------------------------------------------------------------------------------

## 4. prevent (d2-prevent.md, `srcF/`): 6 / 10

| R | score | evidence |
|---|---|---|
| R1 | PARTLY | 0 outside landings in every sweep with the JIT off. With the JIT on it leaves live-data landings at the reserve top: W16R 264 of 4 096, amplified 99 of 16 384, and 71 of 4 096 at only 512 B of kernel garbage per resume. Never earlier than stock (its §9 argument holds). |
| R1b | MET | W1, W8, W2b, W2c and W10 pass 13 of 13; the kernel slice is untouched. |
| R5 | MET | Sandbox `≤ T+G+1 KiB`, every thread unchanged. W7 re-scoped: od_peak G + 30. |
| R6 | MET | Gate clean, scalar writes only, 0 crashes found. |
| R7 | MET | 11 code lines, the smallest of the three. All 13 anchors intact. |
| R8 | MET | One record bit; open on a fresh record; frozen under GCSTOP. |
| R9 | PARTLY | Idle below the cap identical. Last-five cycles +7 to 10 %, time 1.00 to 1.14×, whole run 1.07× (the design claimed 1.043 on two shapes). |
| R10 | PARTLY | W16 is fail-first and 2 of 2 new sabotages verified. W17 and C6b are guards that pass on stage C. Fails lend's W16Rj 3 of 3. In-machine gate not run. |
| R11 | MET | Constant `LJ52_GC_LEND`. |
| R12 | PARTLY | JIT-on string −2.2 % headline (like for like equal); time +5 to 14 %. |

**FATAL:** none.

**Major findings.**
- **F-P1, the in-machine path is not fixed.** W16R with the JIT on gives 264 stalls with live data at
  the reserve top, and 796 second chances with the JIT on. That is the u2-stalls class.
  - Command: `cd J && ./bin/rp_prevent.exe w16rprobe_m.lua record 0 65535 16 384 1 1 1 0 0 -1 | python summ.py /dev/stdin`
- **F-P2, the 1 KiB lend is brittle to kernel pressure.** At 2 KB of kernel garbage per resume:
  1 045 of 4 096 outside landings (lend 85).
- **F-P3, re-arm while past the top.** A sandbox-observed proof past the top re-arms at once, so
  holding live data in (top, top + L] costs a cycle per checkpoint until a refusal. Stage C has the
  same thrash in the equivalent state; it is not new.

---------------------------------------------------------------------------------------------

## 5. verdict (d2-verdict.md): 3 / 10

| R | score | evidence |
|---|---|---|
| R1 | PARTLY | 0 garbage-covered landings on probe2 with the JIT off, but it moves live-data refusals outside that stage C made inside: W16 program 22 of 4 096 with the JIT off and 104 with the JIT on. That is priors §6.2's trade, garbage-covered outside for live-data outside. |
| R1b | MET | W1, W8, W2b, W2c and W10 pass; `noreserve` shows RESERVE is load-bearing. |
| R5 | MET | `U+d ≤ ceiling ≤ T+G+K`. W7 od_peak 28 750. |
| R6 | PARTLY | C1 to C7 respected and the gate is clean, but its placement reaches a LuaJIT unwinder segfault in 442 of 1 024 caps of an amplified JIT-on cell (§1.4). |
| R7 | PARTLY | +157 / −61. It replaces the credit, extracts the proof, deletes a cadence branch and lends to the kernel. 2 sabotage seds change, 2 existing expected sets change, and one new line no test pins (`armedlowstale`). |
| R8 | MET | Verdict bit in the record; fresh-record rule unchanged. |
| R9 | MET | Idle below the cap identical. Near the wall −13 to −16 % cycles, time 0.85 to 0.91×. 4× cheaper idling past the cap. |
| R10 | PARTLY | W16 and W17 are fail-first and 4 of 4 sabotages verified. The covered-measure hole is self-reported. Fails lend's W16Rj. In-machine not run. |
| R11 | MET | Shifts of G. |
| R12 | PARTLY | Capacity ≥ stage C with the JIT off; JIT-on string −2.3 % headline. Hermetic only. |

**FATAL.**
- **F-V1, the crash.** §1.4: 442 of 1 024 caps segfault at batch 10, JIT on, string, plus crashes in
  two further amplified cells.
  - This is exactly the amplified in-machine gate R10 asks for, and it would likely take the JVM down
    (inference).
  - The root cause is latent at stage C (1 of 1 024), but verdict's rule makes it the common outcome.
  - Unshippable as written until that crash is root-caused and fixed, or until verdict is shown not
    to reach it in-machine.

**Major findings.**
- **F-V2.** The 104 JIT-on downs and the 22 JIT-off landings on the W16 program are refusals on the
  verdict, delivered to the dispatcher or the stage string after a cycle whose heap included more
  pinned memory than PIN. The design does not report the JIT-on W16 figure.
- **F-V3, defence in depth.** Deleting THE CADENCE past the cap removes a second repayment path.
  norefusedarm's expected set grows by W1, W1L and W1j (verdict §8.3), because only a refusal's arm
  repays a drop before the reserve level.
- **F-V4, the kernel is now lent.** Prevent's C6b fails. Its BURST ceiling 21G/32 + K exceeds od_limit
  at the G floor, so W1's peak check needs re-scoping (§4 of the design).

---------------------------------------------------------------------------------------------

## 6. Test changes, and whether each is honest

**lend**
- W7 is re-scoped to G + window, with window ≤ slice asserted. Honest: the sandbox's bound moved by a
  stated constant, and the new W7k pins the bound over every thread, which nothing pinned before.
- Four new cases.
- Five existing expected sets grow, each with a stated reason (d2-lend §7.3).
- Seven new sabotages; I verified 4 of them.

**prevent**
- W7 is re-scoped the same way: honest.
- W17 and C6b are guards, not fail-first, and are labelled so.
- Three expected sets grow.

**verdict**
- No existing check changes to pass: honest, and the smallest test churn.
- But the negative-control script needs:
  - a new nocredit edit;
  - a re-indented closereserve sed;
  - changed norefusedarm and unbounded sets: +W1 W1L W1j, and +C6 M6b M7 W17 W8 / −W12.
- `armedlowstale` catches nothing.

**All three** need WALLSTATS read with max 11 in OcljSmoke.scala (`rawstats(…, 10)` at :510,
:3362, :3376) for the new fields.

---------------------------------------------------------------------------------------------

## 7. Documentation burden

| design | what has to be written or changed |
|---|---|
| lend | A ~48-line THE WINDOW block, a 2-line allocator-header note and the WALLSTATS doc. In mem_test: W16, W16R, W16Rj (~160 lines each, sharing a chunk) and W7k. In negative-control: 5 set edits and 7 new sabotage blocks. Roadmap row, results doc. Moderate. |
| prevent | A ~33-line block, the WALLSTATS doc, 3 set edits and 5 sabotage blocks. Lowest. |
| verdict | Rewrites THE CREDIT (tiers become levels and ceilings) and THE CADENCE's third bullet (the documented "log2 cycles per tier" past the cap goes). Adds a ~40-line paragraph. Renames `lj52_gc_credit` (also cited in `bench/results-wall-2026-10-04.md`). Edits mem_test comments that cite G/2, and W12 and W1. Four negative-control edits plus 6 blocks. Highest. |

---------------------------------------------------------------------------------------------

## 8. The in-machine gate, concretely (R10, R12)

Not run by me (no JVM run in this task).

### 8.1 Changes to the probe and the harness

**`OcljSmoke.scala`, CapacityAutorunLua (:3143-3210).**
- `local BATCH = 100` becomes `%%BATCH%%`, and the churn length `uniq(24, …)` becomes `%%JUNK%%`.
- Both are substituted at `CapacityAutorunLua.replace("%%SHAPE%%", capShape)` (:3692) from
  `OCLJ_CAP_BATCH` (default 100) and `OCLJ_CAP_JUNK` (default 24), and validated beside the shape
  check (:3632).
- Add u2-stalls §5's attribution counters. All are number upvalues, painted by `paint()` on a new
  row 19, `OCLJCAPX=entered/timed/pf/oe`; the heartbeat keeps painting after a stall:
  - `entered = entered + 1` as step's first statement;
  - `timed = count` after `event.timer` returns;
  - `pf = pf + 1` when `pcall(paint)` fails (both sites);
  - a wrapped `event.onError` that counts `oe`.

**Harness.**
- Parse row 19.
- Classify each run:
  - CLEAN: `done/…/not_enough_memory`, machine up;
  - STALL: `filling`, `OCLJCAPF -1/-1`, machine up after the 8 000 ticks;
  - DOWN: machine stopped, lastError "not enough memory";
  - **PROC-DEATH:** the JVM exited. This is the §1.4 crash. One JVM per run already isolates it;
    the chain script must record it rather than stop.
- Read WALLSTATS with max 11 and print the design's fields (lend: `window`, `lends`) on CAP-GC.
- Read `__ocljTr.abort` **before** `finish()` (u2-stalls §5: today it is read after).

### 8.2 Matrix

- DLLs:
  - stock S (expected 0);
  - stage C (the **positive control**);
  - the candidate.
- Cells: shapes {string, record}, 192 KB stick (G at the floor, where the hermetic exposure was
  measured), arms {O (JIT off), D (JIT on)}, BATCH 10, junk 24.
- 10 reps per cell: 40 runs per DLL, 120 in all.
- Alongside it, the standard capacity matrix at BATCH 100 (chains B and C's layout) for R12 and for
  the idle window (CAP-IDLE arms and flushes per 10 s, expected unchanged; `out7` shows identical
  arms below the cap).

**Hermetic expectation at batch 10** (`out3`, `out5`):
- stage C: 16 to 83 % of runs outside, by shape;
- lend: 0 with the JIT off and ≤ 0.2 % with it on;
- stock (PUC): 0 in 90 112 runs (u2-repro).

### 8.3 Pass criterion

All five must hold.
- (a) **The gate must be able to fail:** stage C shows ≥ 5 STALL + DOWN in its 40 runs. If it does
  not, the amplification did not transfer and the gate is **void**, not passed.
- (b) The candidate:
  - 0 STALL + DOWN in the O cells;
  - ≤ 1 in the D cells, each attributed by OCLJCAPX;
  - 0 PROC-DEATH;
  - one-sided Fisher p < 0.01 against stage C (0 of 40 against ≥ 7 of 40 gives p ≈ 0.006).
- (c) Stock 0.
- (d) Capacity ≥ stock in every cell of the BATCH 100 matrix.
- (e) Last-five ratio to stock ≤ 1.35 × stage C's ratio. 1.35 is lend's measured hermetic factor;
  whether to accept it is open question 1.

**Run order.** The D-string cell may crash the JVM on stage C. Root-cause §1.4 first, or run the
D-string cells last and count deaths.

---------------------------------------------------------------------------------------------

## 9. Recommendation

**Build:** lend's `final2` (THE WINDOW: lend 4 KiB past the tier top, two-cycle verdict, refusal
shuts the window, the kernel gets no window).

**Graft before landing:**
1. **The W16 measure fix** (verdict §8.2) in W16, W16R and W16Rj: on an outside landing, record, then
   `coroutine.yield()` so the stack counts. Without it, F-L3.
2. **An explicit `lj52_gc_prove()`** (verdict's extraction), called before the decision in place of
   lend's two `pressure(FREE)` observation lines. Re-run lend's `lateproof` sabotage, which fails
   W16 and W16R today.
3. **Tests:** verdict's W17 (fail-first on stage C; passes on lend), and prevent's W17 and C6b (both
   pass on lend). Prevent's `#if LJ52_GC_LEND > LJ52_GC_KSLICE #error`.
4. **Test infrastructure:**
   - W16R and W16Rj at 48 × 128;
   - a `W16_N` override for negative-control 4.9;
   - WALLSTATS max 11 in the harness.

**Stage 2 (measure, do not assume):**
- verdict's silent cadence past the cap, with lend's own lend-arm restored (final had it), to win
  back R9;
- L = clamp(G/8, 4 KiB, K) for large caps and kernel pressure;
- lend §9's kernel regime-P retarget at S + L for M3's general form.

**Drop:**
- verdict's levels, ceilings and PIN, and its kernel loan;
- prevent's rule, whose verdict bit and re-arm lend's window states subsume.

---------------------------------------------------------------------------------------------

## 10. Open questions for the user

1. **Lend's near-wall cost:** last-five 1.12 to 1.34×, whole run 1.17× stage C, hermetic. Accept it
   as the price of 0 outside landings, or require the stage-2 cadence experiment first?
2. **The unwinder segfault** (§1.4) is reachable on the shipped stage-C object (1 of 1 024 amplified)
   and is the common outcome under verdict. Open it as its own row, and root-cause it before the
   amplified JIT-on in-machine cells run?
3. **The sandbox's bound** moves to cap + G + 4 KiB (W7 re-scoped); every-thread cap + G + K is
   unchanged. Accept?
4. **Kernel pressure:** signal payloads above about 2 KB per resume still cause sandbox downs under
   lend (85 of 4 096 at 2 KB). Build the kernel retarget now or record it as residual?
5. **Idle past the cap** with live data within about 1 KB of the burst top runs a full cycle per
   ~500 B of garbage. This exists at stage C (12 475 cycles in 3 000 idle resumes). A separate row?

---------------------------------------------------------------------------------------------

## 11. Caveats (what I did not verify)

- Nothing ran in a machine.
- I did not root-cause the crash, or check whether lend or prevent can reach it in configurations I
  did not sweep.
- "Covered" for downs uses the after-death live set (optimistic).
- My sweeps use `repro/lj_repro.c` as it stands; prevent notes its base moved by 40 B since u2. My
  stage-C counts match lend's to the run (431, 508), which used the same driver.
- My kernel-pressure and OpenOS-timer probes are my own models, not OpenOS.
- I verified 10 of the designers' sabotages, not all of them.
- Timing uses a 1 ms `os.clock`, averaged over about 2 500 runs per cell, 5 interleaved repetitions.

**Files.**

| path | contents |
|---|---|
| `J/src/*/lj52shim.c`, `J/obj/*.o`, `J/*.diff` | sources, objects and diffs |
| `J/tests/{R,Lt,Vt,Pt}.c`, `J/bin/mt_*` | the cross-matrix |
| `J/out1`, `J/out8` | mem_test logs |
| `J/out2`, `out3`, `out5`, `out9`, `out10` | sweeps |
| `J/out4` | the crash search |
| `J/out6` | timing |
| `J/out7` | idle |
| `J/sab/` | my sabotages |
| `J/mktrace.py`, `J/bin/rpT_*` | the traced builds |
| `J/summ.py`, `J/last5.py` | summarisers |
