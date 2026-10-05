# j2-safety: the judge's verdict on round 2, through the lens of safety and correctness

The row is "A refusal at a credit tier's top can land outside the program's handler". Three designs were judged, each with its prototype:
- **d2-lend**: THE WINDOW;
- **d2-verdict**: the loan and the verdict;
- **d2-prevent**: prevention first, then a 1 KiB lend.

**Lens.** The bound (R5) and the ratchet (W7) under adversarial sandbox code, VM safety (C1-C7), the kernel never dying on the sandbox's refusal, refusals no earlier than stock's, and any way the new rule can wedge, thrash, spin, or take the host down.

**How the work was done.** The repo was never edited. All of the judge's work is in `scratchpad/wall2/j2s/` (paths below are relative to it). Nothing was cleared, and every pass went to a fresh directory.

---

## 0. Bottom line

| | lend | verdict | prevent |
|---|---|---|---|
| FATAL findings | none | **2** | none |
| score /10 | **7** | **3** | **6** |

- **lend (recommended base):** the only design with no outside landing in any JIT-on mem_test case I ran (W16Rj).
- **verdict:**
  - **FATAL 1.** At caps above 2 MiB the KERNEL is refused for the sandbox's live data, on machine.lua's unprotected `table.pack(coroutine.resume(...))`.
  - **FATAL 2.** In one realistic probe configuration it makes a latent LuaJIT unwinder segfault frequent: about 1 cap in 6, against 1 in 2048 on stage C.
- **prevent:** the smallest change and the kernel's full slack. Its residual with the JIT on is real: lend's W16Rj fails on it every time.

**Recommendation.** Build lend. Make its arm explicit. Add the judge's K1/K8 kernel tests and an unwinder-crash census to the gate. Open a row for the unwinder segfault before anything ships. Do not build verdict as written. §5 has the details.

---

## 1. What I re-ran (verification, not trust)

**Objects.** Each prototype was rebuilt from its source with build-native.sh's line plus `-DLJ52_ADDITIVE` (`d2-verdict/mk.sh obj`). Every rebuild matches its designer's md5 **byte for byte**:

| object | md5 |
|---|---|
| stage C | `0259f0d1` |
| lend | `2e1d8f6e` |
| verdict | `e387460a` |
| prevent | `cb996c9e` |

Each compiles warning-clean. Their diffs against `native/lj52shim.c` (md5 `5ed6e33a`, HEAD d9080d4) match the diffs printed in the designs (`obj/*.o`).

**mem_test, a 5 × 4 cross matrix.** The repo suite, u2's W16 copy and each design's `mem_test_d2.c` were each run against every object (`run1/`). The four pairs that matter were then run 10 more times with the random string-hash seed (`run2/`).

| test file \ object | stage C | lend | verdict | prevent |
|---|---|---|---|---|
| lend's (72) | FAIL W16 W16R W16Rj (10/10) | **72/72 (10/10)** | FAIL **W16Rj** (10/10: 2 covered downs) | FAIL **W16Rj** (10/10: 6 covered stalls) |
| verdict's (70) | FAIL W16 W17 | FAIL W7 (re-scope) | **70/70 (10/10)** | FAIL W7 (re-scope) |
| prevent's (71) | FAIL W16 | 71/71 | FAIL C6b, W17 (design-specific bounds) | **71/71 (10/10)** |
| repo (68) | 68/68 | FAIL W7 (re-scope) | 68/68 | FAIL W7 (re-scope) |
| u2 W16 (69) | FAIL W16 | FAIL W7 (re-scope) | 69/69 | FAIL W7 (re-scope) |

Each designer's own claim reproduces. Two cross results are new:
- Lend's W16Rj (W16's program in the reserve tier, JIT on) fails deterministically on both verdict and prevent.
- Verdict's W17 passes on lend and on prevent.

The W16 "covered" measure undercounts the live set after a stall by up to 3.9 KB (d2-verdict §7.1). So the W16Rj failures are **PLAUSIBLE** outside landings rather than proven covered ones. They agree with each design's own JIT-on residual (verdict 43, prevent 17 in 16 384).

**Sabotage spot-checks** (`sab.py`, `sab_results.txt`). These are my own exact-line edits on copies, built and linked with each design's suite. All ten failing sets match the designers' tables:

| design | sabotage | fails |
|---|---|---|
| lend | kernelwindow | W7k |
| lend | refusalkeeps | W16Rj |
| lend | rawverdict | W16 W16R W16Rj |
| lend | nowindow | W16 W16R W16Rj |
| verdict | noverdict | W12 W17 |
| verdict | latelatch | W16 |
| verdict | nolend | W16 W8 |
| prevent | noverdictarm | W16 |
| prevent | lendkernel | C6b |
| prevent | nolend | W16 |

**Reduced probe2 sweep** (`sweep/*.tsv`). Driver: u2's `lj_repro.c`, fixed seed, `LUA_PATH` pinned, 4 shapes × 1024 caps at a 64 B step. Each cell gives outside landings, stall / down:

| config | stage C | lend | verdict | prevent |
|---|---|---|---|---|
| default (JIT off) | 104 (54/50) | **0** | **0** | **0** |
| legacy (dropin) | 104 | 0 | 0 | 0 |
| batch 10 (amplified) | 1299 | 0 | 0 | 0 |
| JIT on | 169 | **0** | 11 | 8 |
| batch 10, JIT on | 1184 | 16 | process **crashed** at shape 3 (see F-V2) | 18 |

The JIT-off claims of all three designs hold. Classifying the JIT-on landings as "covered" was not attempted: the site pass is weak with the JIT on.

---

## 2. Adversarial cases I built (`adv_main.c`, appended to mem_test's helpers → `adv.c`; binaries `bin/adv_<obj>.exe`)

Everything runs as the sandbox, a coroutine resumed under an outermost `_OCLJ_WATCHDOG.arm`, unless it says kernel.

### K1: the kernel's allocations after a sandbox crossing with no checkpoint (`k1/`)

**Setup.**
1. The sandbox fills live tables to 1 KiB under verdict's burst level (T + G/2 + G/32).
2. It crosses in one of two ways:
   - mode 1: one array doubling, +32 KiB (rawset);
   - mode 2: `A .. B` of two pre-made strings.
3. It yields.
4. The kernel then makes the probe's packs: first while still armed, as machine.lua does, then at depth 0.

**Result:**
- Stage C, lend and prevent: **0 kernel refusals** at every cap (628 KB to 10.6 MB), in C mode and in legacy mode.
- Verdict: the kernel **is refused** at caps of 3.77 MB, 5.35 MB and 10.6 MB (G = 235 K, 334 K and 512 K), legacy included.
  - In mode 2 the refused allocation is the **first** `table.pack` after the resume.

**Commands:**
- `bin/adv_verdict.exe K1 4096 2 1 -1024 5000` reports `first_pack_refused=1`.
- `bin/adv_verdict.exe K1 4096 1 1` reports `kernel_refused_armed=1`.
- The same arguments on `adv_lend`, `adv_prevent` and `adv_C` report 0.

### K2: live data at the burst top, then churn (`k2/`)

A one-sided sweep of the "thrash" question. The sandbox fills to T + G/2 − x0 and keeps one A-byte crossing. It then runs 2000 protected concatenations of C bytes.

**No wedge, no spin, and no bailout in any cell.**

Lend and verdict both have a band where every iteration costs one full cycle and nothing is refused. In `bin/adv_lend.exe K2 384 16 300 2000 -100`:

| object | cycles in 2000 iterations | refused | tier | time |
|---|---|---|---|---|
| lend | 2000 | never | BURST | 69 ms |
| verdict | 1998 | never | BURST | 71 ms |
| stage C | 76 | once (in the fill) | RESERVE | 3 ms |
| prevent | 76 | once | RESERVE | 2 ms |

There, lend's live set, measured inside the coroutine, is **41 B past S**, and lend never refuses. Its verdict needs `U − grown > S`, and a churn per cycle at least as large as the excess never satisfies that. §3 has the reading.

### K3: the R5 bound under 14 adversarial programs (`k3/k3_b.txt`)

**Coverage:**
- programs: caught refusals in tight loops (3 000 and 20 000 iterations), mixed live and garbage, giant 50 MB requests, table growth with no checkpoint (kept live, 200×), 400 coroutines with deep stacks, string.rep and table.concat lent whole and kept, CAT on trace, drop-and-refill 200 rounds;
- JIT off and on;
- G = 32 K and 334 K;
- C mode and legacy.

**Maximum od_peak − G over every run, against each design's claimed sandbox bound:**

| design | max od_peak − G | claimed bound | margin |
|---|---|---|---|
| stage C | 0 | G | 0 |
| lend | **4 096** | G + 4 096 | exactly at the bound |
| verdict | −88 | G | ≤ G |
| prevent | **1 024** | G + 1 024 | exactly at the bound |

**Zero violations, zero bailouts, no ratchet** (prog 14 refills 200 times; prog 12 has 17 000 caught refusals).

### K4: OC's persist pattern while a window or loan is open (`k45/k4.txt`)

The sequence: Int.MaxValue cap, GCSTOP, 300 KB of garbage, GCRESTART, the cap restored.

- All four objects behave **identically**: the 6 kernel packs before any checkpoint are refused, the sandbox's resume collects, and recovery succeeds. That is C4b's known behaviour.
- Nothing design-specific was found.

### K5: a state loaded over its cap, i.e. a fresh record (`k45/k5.txt`)

- Identical across objects, except at 30 KB over (live in (T + 7G/8, T + G]):
  - **verdict** refuses the sandbox's first 64 B table, after the first proof;
  - stage C, lend and prevent grant it.
- Every design refuses the kernel at 50 KB over (past T + G + K), as stage C does.

### K7: garbage pinned by a callee's frame, refused in the caller (`k7/`)

This is R1's "no earlier than stock". Inner keeps a dead 6 KB string in a high register while it fills past the top, then returns. The outer frame then allocates with no handler.

Across a sweep of the stopping point (11 values) and both outer kinds (TNEW and CAT), **no design refused in the outer frame**. The pinned-garbage residual that every design names was **not triggered** by this construction. Where a refusal came, it was inside inner, the frame that pins the string, which is also where stock would pin it.

### K8: the kernel's room after the sandbox has spent what it may (`k8/`)

The kernel makes one `lua_createtable` of n KB, armed, then at depth 0. Results with a window-filling caught-refusal loop (mode 2):

| object | 13 KB | 14 KB | 16 KB |
|---|---|---|---|
| stage C | ok | ok | ok |
| prevent | ok | ok | ok |
| lend (G = 32 K and 121 K) | ok | **refused** | **refused** |
| verdict (G = 32 K, depth 0) | ok | **refused** | **refused** |
| verdict (G = 121 K) | ok | ok | ok |

Lend's refusal at 14 KB matches its stated K − L = 12 KiB.

### Crash census: one process per cap (`sweep/crash*.txt`)

Configuration: probe2, JIT on, batch 10, string shape.

| object | fixed seed, step 64 (1024 caps) | fixed seed, step 16 (2048 caps) | random seed |
|---|---|---|---|
| stage C | 0 | **1** (off 9488) | 0/256 |
| lend | 0 | 0 | 0/1024 |
| prevent | 0 | 0 | 0/1024 |
| verdict | **191** | **339** | **92/256** |

- At batch 100: 0 crashes for every object.
- The backtrace is identical for stage C and verdict: `err_unwind ← lj_err_unwind_win ← RaiseException ← lj_err_throw ← lj_err_mem ← lj_mem_realloc ← lj_str_new ← lj_strfmt_num ← lj_ff_tostring`. That is d2-lend §8's stage-C crash.
- Instrumented (`diag/`), the refused request in a verdict crash is a **32 B verdict refusal under vmstate INTERP, at tostring**.
- **The mechanism test:**
  - verdict with the latch read after the decision (the `latelatch` sabotage): **0/1024**;
  - verdict with X ≤ K (fix B): **194/1024**.
- So the rule that delivers a cycle's verdict to the very allocation whose check-first GC step ran that cycle is what makes the crash frequent. This is labelled inference: the unwinder bug itself was not root-caused.

---

## 3. Findings

### d2-verdict

**F-V1. FATAL: the kernel is refused for the sandbox's live data at caps above 2 MiB.**
- **Where:** `d2-verdict/lj52shim.c:1154-1157`, `:1209`.
- **Why:** The kernel's level is the sandbox's level + K. The sandbox's ceiling is the sandbox's level + X, with X = G/8. When G > 128 KiB, X > K, and the sandbox can be lent live data past the kernel's level.
  - The next proof then sets gc_verdict = 1 with gc_low past the kernel's level.
  - If the first growth past a level after that proof is the kernel's, the kernel is refused (`:1209`).
- **Machine path:** machine.lua's `local result = table.pack(coroutine.resume(co, ...))` is unprotected (`native/kernel/patch-machine-lua.lua:278-282`), so the machine goes down.
- **Reach:** the sandbox needs one crossing allocation of more than K + ε with no checkpoint before it yields. In K1 that was an array doubling or a 10-32 KB concatenation.
- **Repro:** `j2s/bin/adv_verdict.exe K1 4096 2 1 -1024 5000` gives `first_pack_refused=1`. In legacy mode (4th argument 0) it is the same.
- **The design's own tests miss it:** W10 and the sweeps run at G ≤ 99 KiB.
- **Fix B, measured** (`j2s/fix/verdict_B.c`): clamping x to K gives K1 0 refusals at 3.77, 5.35 and 10.6 MB, and 70/70 on verdict's suite. It shrinks the loan at large caps, and that effect was not measured.
- **Fix A** (the kernel never takes a verdict) **fails W12**: 111 cycles. W1 runs as the kernel.

**F-V2. FATAL (hermetic; mechanism inferred; transfer to a real machine not checked): a frequent process segfault in LuaJIT's Windows unwinder.**
- **Rate:** 339 of 2048 string-shape caps with JIT on and batch 10 (fixed seed), and 92 of 256 with the production random seed.
- **Comparison:** stage C, lend and prevent show 1, 0 and 0 under the same conditions.
- **Where:** prove-first in the grant (`:1203`) plus the verdict line (`:1209`) refuse tostring's allocation immediately after tostring's own GC check ran the armed cycle. The latelatch variant removes the crash (0/1024).
- **Why it is fatal:** inside OC a segfault is the JVM process. The amplified probe with the JIT on is exactly the R10 in-machine gate's configuration.
- **Repro:** `cd j2s/sweep; LUA_PATH='?.lua' ../bin/lj_repro_verdictf.exe probe2.lua string 128 128 16 384 1 1 1 0 0 -1 24 10` exits 139. It is deterministic; I ran it three times.
- **The latent bug** is present on stage C: `../bin/lj_repro_Cf.exe ... string 9488 9488 ...` also exits 139.

**F-V3. Major: the room after the first refusal shrinks.**
- From the burst ceiling (T + 21G/32) to the reserve level (T + 7G/8) is 7G/32. That is **7 KiB at the floor**, against stage C's 16 KiB. The loan adds 4 KiB, but under a verdict check.
- W1 and W8 pass. OpenOS's `event.onError` path (`io.open` on /tmp) was not sized by anyone.

**F-V4. Major: the kernel's room at the floor drops to about 13 KB.** K8: a 14 KB request at depth 0 is refused, where stage C grants 16 KB.

**F-V5. Major: outside landings with the JIT on remain.**
- Lend's W16Rj on verdict: 2 covered sandbox downs, 10/10.
- My sweep: 11/4096 (JIT on, batch 100).

**F-V6. Minor:**
- A reloaded state with live data in (T + 7G/8, T + G] is refused at its first growth after the first proof (K5, 30 KB over), where stage C grants it.
- The largest diff of the three (+159/−61): it rewrites `lj52_gc_credit` and THE CADENCE's past-cap branch.
- negative-control.sh needs three edits: the nocredit and unbounded targets, and the closereserve indentation.
- The K2 band of one cycle per iteration also exists here: 1998 cycles in one cell.

### d2-lend

**F-L1. Major: the kernel's guaranteed slack drops from 16 to 12 KiB.**
- This is by design (L ≤ K, `d2-lend/final2/lj52shim.c:1085`). K8 measures it: 13 KB passes; 14 KB is refused both armed and at depth 0, at G = 32 K and at G = 121 K. Stage C and prevent grant 16 KB.
- No realistic kernel request near 12 KB is known to me. Java's signal pushes (a modem message of at most 8 KB) fit. It is still a 25% cut of the margin that stops the dropin's down from recurring.

**F-L2. Major (R1 and R9): the never-verdict band.**
- The verdict is `U − gc_grown > S` (`:1247`). A program whose live data sits past S by less than its own churn per cycle is lent forever. With regime P arming every growth past S, it pays one full cycle per checkpoint.
- K2: 2000 cycles for 2000 iterations, no refusal, live S + 41 B, 23× stage C's time.
- It is bounded by S + L, and it is stock's emergency-GC rate in the garbage-covered part of the band. The contract deviation (live past the top, never refused) is at most about L/2.

**F-L3. Major (R9): near-wall cost.**
- The designer measured +16 to +26% cycles per fill and 1.15 to 1.28× time over the last five batches, hermetically.
- My W4 and W12 match theirs: 40 and 23.

**F-L4. Minor:**
- The window's arm relies on THE CADENCE's regime-P arithmetic, including a right shift of a negative value: u2-shim-now inconsistency 10, implementation-defined in C. The designer removed the window's own arm as redundant (`d2-lend.md` §9).
- `gc_grown` counts every thread's growth, below the cap too. That biases toward lending and is harmless under the ceiling.
- 16/4096 outside landings with JIT on and batch 10 in my sweep; the designer counts 13 not covered.

### d2-prevent

**F-P1. Major: outside landings with the JIT on, in the reserve tier.**
- Lend's W16Rj on prevent: 6 covered stalls, 10/10.
- My sweep: 8/4096 (JIT on) and 18/4096 (JIT on, batch 10). The designer's own count is 17/16 384 with the JIT on.

**F-P2. Major: the smallest margin against check-free runs outside a handler.**
- `LJ52_GC_LEND` is 1 KiB (`srcF/lj52shim.c:1056`), sized to the probe's 256 B record. 128 B already failed.
- OpenOS's handler-copy loop and `event.onError` were not measured. Any run longer than 1 KiB with no checkpoint near the top is the overrun residual.

**F-P3. Minor:**
- No peek: a proof observed post-grant by the sandbox's own request can shut the lend falsely (U − d ≤ S < U). The designer measured 0 with the JIT off.
- The re-arm at every proof past the top (`:1211`) costs one cycle per checkpoint while the heap stays past the observing thread's top. That is no worse than stage C's negative-shift arms in the same state.
- W17 is not fail-first: it passes on stage C.

---

## 4. Scores

### R1: refusals only when live data plus the request does not fit; never earlier than stock

| design | score | evidence |
|---|---|---|
| lend | **PARTLY** | 0 outside in every JIT-off sweep and in W16, W16R and W16Rj; K7 found no early refusal; but K2's band admits live data past S without a refusal, and JIT-on batch 10 leaves 16/4096. |
| verdict | **PARTLY** | 0 outside with the JIT off; but W16Rj fails (2 covered) and the JIT-on sweep shows 11/4096; refusals come at a raised level (T + G/2 + G/32), and it refuses a reloaded sandbox at T + 7G/8. |
| prevent | **PARTLY** | 0 outside with the JIT off and K7 clean; but W16Rj fails with 6 covered stalls, deterministically, and the JIT-on sweeps show 8 and 18 in 4096. |

### R1b: stage B's recovery stays; the kernel never dies on the sandbox's refusal

| design | score | evidence |
|---|---|---|
| lend | **MET** | W1, W1L, W1j, W8, W2b, W2c and W10 pass; no kernel refusal in K1 or K5; the kernel keeps 12 KiB (K8), down from 16 (F-L1). |
| verdict | **NOT MET** | The kernel's first pack after a resume is refused at caps above 2 MiB (F-V1); recovery room is 7 KiB (F-V3). |
| prevent | **MET** | W1 to W10 pass; the kernel keeps 16 KB in K8 and is never refused in K1. |

### R5: a bounded ceiling, charged, not ratchetable

| design | score | evidence |
|---|---|---|
| lend | **MET** | K3: max od_peak = G + 4096 = exactly its stated sandbox bound, over 14 programs × JIT × 2 caps × legacy; W7 and W7k pass; zero bailouts. |
| verdict | **MET** | K3 max od_peak ≤ G; W7 od_peak 28 750. |
| prevent | **MET** | K3 max od_peak = G + 1024, exactly at its bound; W7 re-scoped and passing. |

### R6: VM safety, C1-C7

| design | score | evidence |
|---|---|---|
| lend | **MET** | No collection in the allocator. The pre-decision observation is today's `lj52_gc_pressure` (scalar writes, guards intact). HOOK_GC and GCSTOP return before the window (`:1175`). No crash in 7168 census caps. |
| verdict | **PARTLY** | No collection and only scalar writes, but delivering a verdict to a fast function's allocation right after its own GC step turns a latent unwinder segfault into a frequent one (F-V2). |
| prevent | **MET** | The re-arm happens only at a proof, i.e. at GCSpause, never inside a step; HOOK_GC and GCSTOP leave the credit at 0; no crash in the census. |

### R7: minimal and reviewable

| design | score | evidence |
|---|---|---|
| lend | **MET** | About 43 code lines; zero LuaJIT; the gate untouched; every sabotage anchor unique. |
| verdict | **PARTLY** | Zero LuaJIT and the gate passes, but +159/−61 rewrites the credit and THE CADENCE, and moves three negative-control targets. |
| prevent | **MET** | About 10 code lines; zero LuaJIT; every anchor intact. |

### R8: persistence and host states

| design | score | evidence |
|---|---|---|
| lend | **MET** | The window is transient record state, zero on a fresh record; K4 and K5 match stage C. |
| verdict | **MET** | The verdict lives in the record; K4 matches stage C. K5's 30 KB-over refusal is a minor regression. |
| prevent | **MET** | One record bit, frozen under GCSTOP; K4 and K5 match stage C. |

### R9: cost unchanged far from the wall; near it within stage C's figures

| design | score | evidence |
|---|---|---|
| lend | **PARTLY** | Designer: 1.15 to 1.28× time over the last five batches; K2's band costs 23×. |
| verdict | **PARTLY** | −11% cycles overall (designer), but K2 shows the same one-cycle-per-iteration band (1998 against 76). |
| prevent | **PARTLY** | +6 to 9% cycles and 1.04× time (designer); no K2 band. |

### R10: testable fail-first

| design | score | evidence |
|---|---|---|
| lend | **PARTLY** | W16, W16R and W16Rj fail 10/10 on stage C and pass 10/10; sabotages verified; no in-machine gate run. |
| verdict | **PARTLY** | W16 and W17 verified, but no test reaches G > 128 KiB or JIT on with batch 10, where both FATALs live; no in-machine run. |
| prevent | **PARTLY** | W16 verified; W17 is not fail-first; no in-machine run. |

### R11 and R12

| design | R11 | R12 |
|---|---|---|
| lend | **MET**: compile-time L, no knob. | **PARTLY**: capacity ≥ stage C like for like (designer); time over. |
| verdict | **MET**: X and PIN are shifts of G. | **PARTLY**: designer capacity ≥ C; recovery room and the kernel's room shrink. |
| prevent | **MET**. | **PARTLY**: −2.2% string capacity with the JIT on (designer). |

### Overall scores

| design | score | reason |
|---|---|---|
| lend | **7/10** | No FATAL. The best outside-landing record, including W16Rj with the JIT on. Bound exact. Strongest tests. Costs are R9 and 4 KiB of kernel slack. |
| prevent | **6/10** | No FATAL. Smallest change, full kernel slack. A JIT-on residual that lend's test exposes, and the thinnest overrun margin. |
| verdict | **3/10** | Two FATALs as written. The R1 idea is clean, but per-thread levels with X > K and prove-first delivery at check-first fast functions both fail on host safety. |

---

## 5. Recommendation

**Build d2-lend (THE WINDOW).**

**Graft:**
1. **Make the window's arm explicit.** Restore the arm in `lj52_gc_lend`, as in the designer's `final/`, measured identical. Then a window's cycle no longer depends on regime-P's right shift of a negative value (F-L4).
2. **Compile-time guards:** add `#if LJ52_GC_LEND > LJ52_GC_KSLICE` → `#error` (prevent's suggestion). Lend's own comment already states L ≤ K.
3. **Kernel tests.** Add the judge's K1 (a sandbox crossing with no checkpoint, then the kernel's first pack, at caps of 4 and 10 MB) and K8 (the kernel's room after a window-filling caught-refusal loop) to mem_test, with lend's bound K − L.
4. **Test grafts:**
   - verdict's **W17** (a live fill refused within a few tables of the top; lend passes it), with lend's bound;
   - prevent's **C6b** precondition-asserting style for W7k.
5. **Gates:** put the **unwinder-crash census** (probe2, string, JIT on, batch 10, one process per cap) in the hermetic gate and in the in-machine amplified probe. Exit 139 anywhere is a stop.
6. **Optional, R9 only, measure before adopting:** verdict's silent past-cap cadence, which needs graft 1 first. Verdict showed the halving adds cycles once crossings arm. Unmeasured on lend.

**Drop:**
- verdict's per-thread level/ceiling with X = G/8;
- delivering a verdict to the allocation whose check-first step ran the proving cycle;
- prevent's 1 KiB lend as the base (it remains a fallback if the kernel's slack is judged sacred).

**Open questions for the user:**
1. Lend's kernel slack falls from 16 to 12 KiB. Accept it, or raise `LJ52_GC_KSLICE` to 20 KiB? The latter moves the every-thread bound to T + G + 20 KiB.
2. The unwinder segfault: d2-lend §8, and here 1/2048 on stage C, ~17% on verdict. Open its own row and require it root-caused (or shown not to transfer in-machine) before any of these ships?
3. Lend's never-verdict band (F-L2, bounded by L/2 past the top, one cycle per checkpoint): accept it, or tighten the verdict? One option is to cap consecutive open proofs.
4. Accept about 15-28% more near-wall time for zero outside landings, or try graft 6 first?
5. None of the three ran the in-machine gate. Run it, with the census, before deciding?

---

## 6. Instruments and caveats

- **Census ran its fail-first.** The crash census is one process per cap and reads the exit code. It caught verdict's crashes and stage C's one, so it can fail.
- **K-case harness:**
  - K tests report od_peak, which skips the norefuse window, as every design's bound does.
  - K2 and K7's live measures carry the dead-coroutine-stack undercount W16 has (about 1.7 KB). K2's "S + 41" comes from the in-coroutine measure.
- **K1 depends on phase.** It needs the sandbox's fill to end within about 1-2 KB under verdict's level (target offsets −512 and −1024 hit; −2048 and −4096 did not). That is the realistic "live data at the level" case, not a broad band.
- **Not done:**
  - the JIT-on "covered" classification;
  - an in-machine run;
  - root-causing the unwinder bug;
  - the finalizer path, by test. By code reading, all three return before lending under HOOK_GC (lend `:1175`; verdict's grant `:1202`; prevent's credit `:1129`).
- **Reproduce:** every command is above. The binaries are in `j2s/bin` and the outputs in `j2s/{run1,run2,k1,k2,k3,k45,k7,k8,sweep,sab,fix,diag}`.
