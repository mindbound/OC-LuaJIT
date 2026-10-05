# d2-prevent: prevention first, then the smallest lend the residual still needs

Design for the roadmap row "A refusal at a credit tier's top can land outside the program's handler"
(round 2, 2026-10-04). Angle: remove each proximate mechanism (M1-M3 of u2-repro.md) where it
arises, measure each fix alone and together, and add a lend only if what remains needs one.

Everything here was prototyped and measured against copies of `native/lj52shim.c` at HEAD d9080d4.
The repo was only read. Work directory: `scratchpad/wall2/d2-prevent/` (paths below are relative
to it unless stated).

## 0. The answer in one page

- **Prevention alone does not close the row.** Arming earlier (a margin under the tier top, a re-arm
  at the proof, and arming when the kernel's growth reaches the sandbox's top) cuts the probe sweep
  from 422 outside refusals to 52. But:
  - On the W16 program it only cuts 168 to 88, and it turns stalls into sandbox-downs (146+22 → 11+77).
  - It doubles the cycles per fill at a 1 KB margin.
  - mem_test W16 still fails on every prevention-only variant.
- **Why prevention runs out.** Traced with an allocator ring (§2.2), every remaining case has the
  same shape. The last cycle ran at a checkpoint that still pinned garbage:
  - a frame not yet popped, or
  - a value about to be overwritten (`stage = 'filling/'..n` runs the cycle before the old string is
    released; the kernel's `res = table.pack(resume())` does the same with the previous `res`).

  The next allocations reach the top before any checkpoint. No arming rule can put a cycle between
  a CAT and its assignment, between a GCtab and its hash part, or between a resume and OpenOS's
  `table.pack`. **A lend is needed after all.**
- **The design that results is small:**
  1. **THE VERDICT.** Every proof records whether it left the heap past the tier top of the thread
     that observed it. The kernel's top includes its slice.
  2. **THE LEND.** While the verdict is open, a *sandbox* growth past its tier top is granted up to
     `LJ52_GC_LEND` = 1 KB more. It arms through the existing cadence.
  3. **The M1 fix, kept from the prevention work.** A proof that leaves the heap past that top shuts
     the lend and **re-arms at once**, so the next checkpoint re-takes the verdict.

  The margin and the kernel-side arm (the M2/M3 prevention fixes) add nothing measurable once the
  lend exists, and they cost cycles. They are dropped.
- **Size.** About 10 code lines in the shim: 1 field, 1 constant, 1 line in the credit, 5 lines at
  the proof, and 2 more WALLSTATS values. Zero LuaJIT lines, and the collector gate is untouched.
- **Measured, final object (`v/FIN/lj52shim.o`, md5 `cb996c9e`) against stage C (`0259f0d1`):**
  - **probe2 sweep, 16 384 caps:**
    - default: 422 outside (all covered) → **0**;
    - legacy path 422 → 0; no paint 221 → 0; heartbeat 437 → 0; control 145 → 0;
    - junk 8/48/96: 136/88/56 → 0/0/0;
    - cap = base + 128 KB: 336 → 1 (a 32 KB string-table growth that no collection covers);
    - cap = base + 1.5 MB (G ≈ 99 KB): 540 → 0;
    - JIT on: 574 (514 covered) → **17 (2 covered, by 0 and 16 B)**.
  - **W16 program, 4 096 caps:** 168 → 0 (JIT off), 596 → 0 (JIT on), 168 → 0 (legacy).
  - **mem_test** (repo cases + W16 + new W17, C6b; W7 re-scoped): **71 checks, 0 failures, in 30 of
    30 random-seed runs**. Stage C fails W16 only.
  - **Cost:**
    - +6 to 9% full cycles per fill (+2.5 to 6.6% at equal fill length): about two cycles per tier
      top reached;
    - W4 and W12 unchanged (39 and 21 cycles);
    - whole-run time ×1.043;
    - last-five-batches / first-five ratio +5 to 6%.

---

## 1. Method and instrument checks

- **Builds.** Compile and link lines are exactly the task's (build-native.sh's line + `-DLJ52_ADDITIVE`;
  run-mem.sh's link). Scripts:
  - `bv.sh` builds a variant: shim, instrumented shim, `lj_repro_Cf/If.exe` and `mem_test.exe`.
    Warnings are an error.
  - `bring.sh` builds the ring variant.
  - `mkproto.py` makes the switchable prototype: `P_PROOFFALL`, `P_M12`, `P_M3`, `P_LEND`,
    `P_VERDICT`, `P_NOPEEK`, `P_MARGIN`.
  - `mkfinal.py` makes the final change, with no switches.
  - `mkmt.py` makes the test copy, `mksabo.py` the sabotages.
- **Object identity.** `v/C0/lj52shim.o` is built from the repo source with this line. It is
  `0259f0d14032e4920e7e7b110d102f62`, byte-identical to `wall2/objC`.
  - The switchable source with no switch defined (`P0`) gives a TSV byte-identical to C0's over all
    16 384 runs.
  - FIN's driver base equals C0's on every shape, so FIN's sweep is phase-aligned with stage C's.
- **Reference counts moved from u2's.** `repro/lj_repro.c` changed after u2's `out5/If_a.tsv` was
  made: it now sets a registry field before the base is read, so the base is 40 B higher. Stage C
  therefore reads **422** outside, not u2's 431. The per-shape split is in §6.2; the mechanism mix is
  the same. u2 §5's record-shape reproducers (off 10816 M1, 10864 M2, 10928 M3) still reproduce at
  the same offsets; the other nine were not re-checked. All comparisons below are C0 vs variant from
  the same driver.
- **Sweeps.**
  - `sweep.sh`: `probe2.lua`, 4 shapes × offsets 0..65 535 step 16, cap = base + 384 KB + off, seed 1,
    JIT off, arm on, paint on. Then `repro/sitepass.py` on every outside run. "Covered" is the site
    pass's: two collections just before the refused site, then live + whole object ≤ top.
  - `sweep16.sh`: the W16 program (`w16p.lua`, a copy of `w16probe.lua` that measures the live set at
    a stall or down), 4 096 caps. "Covered" is W16's own test: live + 256 B ≤ cap + G/2.
- **Rings.** The 256-entry ring shows the last 48 allocator calls. `lj_repro_big.c` plus an 8 192-entry
  ring was used to look back past a later refusal (§4.1).
- **Fresh directories only.** Every measurement is under `out/`. Two empty directories
  (`out/FIN_w16`, `out/FIN_probe2`) are left from a failed build. They hold only a truncated TSV and
  are not cited; the FIN runs are `out/FIN1_*`, `out/FIN_*` (variants) and `out/mt*`, `out/sabo*`,
  `out/rob1`, `out/t5`, `out/timing2.txt`.

---

## 2. Prevention first: each fix alone and together

### 2.1 The fixes, as built (`mkproto.py`)

| switch | mechanism | rule |
|---|---|---|
| `P_PROOFFALL` ("F") | M1: THE CADENCE never re-arms at `used == gc_low` | A proof falls through into THE CADENCE on the same call instead of returning. In Regime P this re-arms iff the proof left the heap past the calling thread's tier top. |
| `P_M12` (margin) | M1/M2: the last cycle ran inside the batch; the next request does not fit | Regime P, sandbox call: also arm when `tops - used < P_MARGIN` (default 1 KB). `tops` = the sandbox's tier top. |
| `P_M3` | M3: the kernel spends its slice near the sandbox's top without arming | Regime P, kernel call while a resume is armed (`wd_depth > 0`): also arm when `tops - used < P_M3MARGIN` (default 1 KB). |

### 2.2 What they achieve (measured; covered = all outside runs, in every row)

**probe2, 16 384 runs:**

| variant | outside | sites 1/2/3 (stage / timer record / dispatcher pack) | collects per fill, record/array/string/closure |
|---|---|---|---|
| C0 (stage C) | **422** (217 stalls, 205 downs) | 41/176/205 | 31.8 / 28.4 / 80.0 / 29.8 |
| F alone | 422 (identical counts) | 41/176/205 | 31.8 / 28.4 / 80.0 / 29.8 |
| margin alone (1 KB) | 252 | 0/180/72 | 45.8 / 37.1 / 122.7 / 38.1 |
| F + margin ("A1") | 234 | 0/52/182 | 53.3 / 41.0 / 158.0 / 42.0 |
| M3 alone | 217 | 41/176/**0** | 31.8 / 28.4 / 80.4 / 29.8 |
| F + margin + M3 ("A1M3") | **52** | 0/52/0 | 52.9 / 41.1 / 158.8 / 42.1 |

**The W16 program, 4 096 caps:**

| variant | stall + down | covered | collects per fill |
|---|---|---|---|
| C0 | 146 + 22 = **168** | 168 | 81.8 |
| A1 | 11 + **77** = 88 | 88 | 156.5 |
| M3 | 146 + 11 = 157 | 157 | 81.8 |
| A1M3 | 11 + **77** = 88 | 88 | 156.5 |

mem_test W16 (96 caps, one random-seed run each): C0 7 stalls; A1 2 stalls + 3 downs; M3 7 stalls;
A1M3 2 stalls + 3 downs. **Every variant FAILS W16.**

**Reading the tables:**
- Each fix does what it was aimed at, on the program it was aimed at:
  - the margin removes every stage-string stall;
  - M3 removes every probe2 down.
- On the W16 program (no `pcall(paint)`, so a different checkpoint pattern) the margin turns stalls
  into downs, and M3 then does nothing.
- The cost is high: at a 1 KB margin, about 2× the full cycles per fill (R9).

**What is left, from the ring (`v/A1M3`, `v/A1M3L1k`; §1):**
1. *The CAT runs the cycle before the assignment.* At probe2 record off 10816 the margin armed at
   the stage string. Its CAT post-check ran the cycle while the **old** `stage` string was still
   referenced (−120 B freed, 92 B left). The proof was observed one call late, at the 64 B GCtab of
   event.timer's record, and re-armed. The 192 B hash part then came before any checkpoint and was
   refused (top − used = 160 B). Live + 256 B fits with 60 B to spare.
2. *The kernel's pack runs the cycle before its assignment.* On the W16 program (off 96), the
   sandbox's step ends on a lend-free heap. The kernel's `res = table.pack(resume())` check ran the
   cycle while the previous `res` was still in its slot. The proof was observed at the depth-0 36 B
   `"suspended"` string from `coroutine.status`, 16 B under the top. The next resume's
   `table.pack(coroutine.yield())` allocates first and was refused. 284 B of that heap was garbage.

There is no allocator call between such a cycle and the next request, so no arming rule can make a
checkpoint fall in between. The only remedy that stays inside C1-C7 is to grant that request and
let the cycle it arms, which runs at the next checkpoint after the assignment or frame pop, decide.

### 2.3 The lend: how small it can be, and which prevention parts it still needs

The lend is gated by THE VERDICT (§3). "V1" judges the verdict against the observing thread's top;
"V0" ignores the thread; "np" means no peek (§3.3).

| variant | probe2 outside | W16 prog outside (covered) | W16 prog collects |
|---|---|---|---|
| lend 1 KB alone, V0 | — | 43 (24) | 85.6 |
| lend 1 KB, V1, no F | 46 | 32 (13) | 85.6 |
| A1M3 + lend 1 KB, V0 | — | 41 (11 downs) | 161.2 |
| A1 + lend 1 KB, V1 | **0** | 9 (0) | 161.3 |
| A1M3 + lend 1 KB, V1 | 0 | 9 (0) | 161.3 |
| F + margin 512/256/128/64/16/0 + lend 1 KB, V1 | 0 each | 9 (0) each | 120.1 / 101.0 / 92.5 / 88.9 / 86.6 / 86.1 |
| margin 64 + lend 1 KB, V1, **no F** | 30 | 32 (13) | — |
| F + margin 64 + lend **128**, V1 | 214 | 85 (55) | 88.7 |
| F + margin 64 + lend **64**, V1 | 361 | 166 (136) | 88.4 |
| F + margin 64 + lend 1 KB, **V0** | 18 (downs) | 41 (11) | 88.9 |
| **F + lend 1 KB, V1** (no margin, no M3) | **0** | 9 (0) | 86.1 |
| F + lend 256, V1 | 32 (downs) | 9 (0) | 86.1 |
| F + lend 512, V1 | 0 | 9 (0) | 86.1 |
| **F + lend 1 KB, V1, np** | **0** | **0 (0)** | 86.1 |
| F + lend 256 / 512, V1, np | 32 / 0 | 0 / 0 | 86.1 |
| lend 1 KB, V1, np, no F | 46 | 32 (13) | 85.6 |

**The break points** (the cheap mitigation tested where it BREAKS):
- the re-arm at the proof is necessary (without it: 30 to 46 outside, 13 covered);
- the verdict must be the observing thread's (V0: 18 downs, 11 covered);
- the lend must be at least 256 B to 512 B (128 B: 214; 64 B: 361; 256 B: 32 downs);
- the margin and M3 are not needed once the lend exists, and every byte of margin costs cycles.

**Peek or not:**
- Peeking at a completed-but-unobserved cycle before the grant leaves 9 stalls on the W16 program.
  None is W16-covered, but in each the 40 B stage string would have fitted. The peek takes the word
  of a cycle that ran **inside the batch's frame** (232 B of churn pinned) as final.
- Reading the last observed proof (one call late, like every proof) lends the stage string. Its own
  CAT post-check then re-runs the cycle with the frame popped. Result: 0 outside.
- The no-peek version is both simpler and better.

The final design is the last bolded row: **F (made explicit) + lend 1 KB + V1, no peek**.

---

## 3. The rule

### 3.1 Definitions

- **Tier top of a thread:**

  `top(thread) = T + (RESERVE ? G : G/2) + (kernel(thread) ? K : 0)`

  Here T is the cap, `G = clamp(T >> 4, 32 KiB, 512 KiB)`, K = `LJ52_GC_KSLICE` = 16 KiB, and
  `kernel(thread) = wd_depth == 0 || cur_L == wd_by[0]` (unchanged). Write `tops` for the sandbox's
  top (no K).
- **THE VERDICT** (`gc_lendshut`, 0 at birth). Recorded at every PROOF, i.e. at the allocator call
  that observes the latch (white flipped, GCSpause), by
  `gc_lendshut := (U > top(observing thread))`. U is that call's figure, as for `gc_low`.
- **THE LEND.** `LJ52_GC_LEND` = 1024 B. It is added to the credit of a **sandbox** growth iff
  `gc_lendshut == 0`.

### 3.2 Transitions

```
growth d>0, capped, chargeable, norefuse==0, not HOOK_GC, not GCSTOP:
  credit = (RESERVE ? G : G/2) + (kernel ? K : 0) + (!kernel && !shut ? LEND : 0)
  refuse iff U + d > T + credit              (unchanged form; refusal path unchanged)
  grant  -> charge; pressure(GROW, U+d)       -> THE CADENCE arms any growth past tops (3.4)
PROOF (armed, white flipped, GCSpause), any kind:
  ... as at HEAD (UNARMED, gc_hyst, gc_low = U, RESERVE closes iff U <= T, the flush predicate) ...
  shut := U > top(observing thread)
  shut ? arm(WALL)                           -- re-take the verdict at the next checkpoint
```

### 3.3 Why this rule, mechanism by mechanism (u2-repro §4)

- **M1, the stage string after an in-frame proof.** The in-frame proof found U ≤ tops (live + pinned
  churn), so the verdict is open. The stage string is lent and armed. Its CAT post-check runs the
  cycle with the batch's frame popped (ring: −252 B), and the record's next allocations fit.
- **M2, the timer record's hash part after its GCtab armed.** The verdict is open, so the 192 B is
  lent. The next checkpoint (paint's CAT, or the kernel's pack) runs the cycle that the GCtab armed.
- **M3, the kernel's slice crowding the sandbox's top.** The kernel's proof is judged against
  `tops + K`, so the kernel's working set (its current `res`, its pinned previous `res`) does not
  shut the sandbox's lend. The sandbox's `table.pack` is lent, and its own post-check runs the cycle
  (ring: −716 B).
- **A program whose LIVE data reaches the top.** Its crossing is lent and armed. The next checkpoint's
  cycle finds `U > tops`, which shuts the lend and re-arms. The following crossing is refused, at the
  first allocation after a proof that found the heap past the top. When the program fills inside a
  handler, that refusal lands inside it.

  W17 measures this: a fill of 64 B live tables is refused 87 B past G/2. A lend that ignored the
  verdict would run to G/2 + 1 KB.

### 3.4 Arming a lent crossing needs no new line

THE CADENCE already arms any unarmed growth with U > tops:
- **Regime F:** `T - U < w` holds for U > T.
- **Regime B:** `U > T` arms.
- **Regime P:** `top - U < (top - gc_low) >> 1`.
  - If `gc_low ≤ top`, the left side is negative and the right side is not, so it arms.
  - If `gc_low > top` (a kernel proof inside K), then `U ≥ gc_low` while unarmed (gc_low is a running
    minimum since the proof). So `U - top ≥ gc_low - top > (gc_low - top)/2`, and it arms.
  - The exception is the 1-byte edge `gc_low = top + 1 = U`, which arms at the next growth.
  - This relies on arithmetic right shift of a negative value (u2-shim-now inconsistency 10), as
    HEAD already does.

The re-arm at the proof is written explicitly so as **not** to rely on that shift.

---

## 4. The code change

Unified diff against `native/lj52shim.c` at d9080d4. It is `diffs/lj52shim.diff`, produced by
`mkfinal.py`. The ~33-line comment is part of the change; the code is ~10 lines.

```diff
--- a/native/lj52shim.c
+++ b/native/lj52shim.c
@@ -274,6 +274,8 @@
   int           gc_armby;      /* why the armed cycle was armed: LJ52_ARM_*   */
   int           gc_hyst;       /* a cycle has been proven: gc_low is valid    */
   long long     gc_low;        /* used at the last proof, lowered by frees    */
+  int           gc_lendshut;   /* THE VERDICT: the last proof left the heap   */
+                               /* past its tier top; no lend until one does not */
   long long     gc_seentotal;  /* the cap the last allocator call was under   */
   volatile long gc_overdrafts; /* growths granted past the cap, on credit     */
   long long     gc_odpeak;     /* the largest excursion past the cap, bytes   */
@@ -965,6 +967,39 @@
  * the tries (mem_test W9, printed, not asserted), is refused where PUC would
  * collect and succeed; any checkpoint between the tries cures it.
  *
+ * THE LEND AT THE TOP (2026-10-04, round 2; docs/roadmap.md, "A refusal at a
+ * credit tier's top can land outside the program's handler").  A tier top
+ * refuses live data PLUS the garbage since the last proven cycle PLUS what
+ * the frame of that cycle's checkpoint still pinned, at whichever allocation
+ * comes next -- and between a program's handlers that is often one with no
+ * checkpoint before it: the probe's stage string (CAT allocates first),
+ * event.timer's record (its hash part follows its GCtab with no check),
+ * OpenOS's table.pack after a resume, which the kernel's slice may already
+ * have crowded.  Stock collects there and carries on (wall2/repro: 422 such
+ * refusals in 16384 probe runs on stage C, every one covered by garbage; 0
+ * on PUC).  So a SANDBOX growth past its tier top is lent up to
+ * LJ52_GC_LEND more, while THE VERDICT is open: the last proof left the heap
+ * under the tier top of the thread that observed it -- the kernel's top
+ * includes its slice, because the kernel's own working set between resumes
+ * is not the sandbox's to answer for.  The crossing arms (THE CADENCE arms
+ * any growth past the top); that cycle runs at the next checkpoint, after
+ * the frame that pinned the garbage has returned, and its proof is the next
+ * verdict.  A proof that leaves the heap past the top shuts the lend -- the
+ * next crossing is refused, as before this change -- and arms again at once,
+ * so the checkpoint after it re-takes the verdict instead of leaving the
+ * word to a cycle that ran inside a frame (THE CADENCE never re-arms at
+ * used == gc_low).  The verdict is read as the last proof left it, one
+ * allocator call late like every proof (GCSpause above); peeking at a
+ * completed cycle before the grant was measured and is worse: it takes an
+ * in-frame cycle's word as final.  Bounded absolutely: used + delta <=
+ * total + G + LJ52_GC_LEND for the sandbox, inside the kernel's bound since
+ * the lend is under the slice, so caught refusals cannot ratchet it (W7).
+ * Not the kernel's (it has the slice), never under HOOK_GC or GCSTOP (the
+ * credit is 0 there).  The size is the longest run of allocations with no
+ * checkpoint between them in code outside a handler: 256 B in the probe
+ * (event.timer's record), where 128 B fails; 1 KB leaves room for OpenOS's
+ * handler copy.  mem_test W16.
+ *
  * THE CADENCE (2026-10-04).  Until this change, once a proven cycle left the
  * heap inside the watermark, the very next allocator call armed again, so
  * every GC checkpoint paid a whole O(heap) cycle: 20-120x stock's time over
@@ -1018,6 +1053,7 @@
 #define LJ52_GC_ODMIN  (32 * 1024)
 #define LJ52_GC_ODMAX  (512 * 1024)
 #define LJ52_GC_KSLICE (16 * 1024)      /* the kernel's own, past the credit */
+#define LJ52_GC_LEND   1024             /* the sandbox's, past its tier: THE LEND */
 #define LJ52_GC_HYSTSHIFT 1             /* re-arm after half the headroom    */
 #define LJ52_GC_FLUSHSHIFT 1            /* flush inside half the watermark   */
 #define LJ52_OD_BURST   0               /* credit tiers                      */
@@ -1094,6 +1130,7 @@
   c = lj52_gc_odmax(total);
   if (!lj52_gc_reserve(M, total, used)) c >>= 1;
   if (lj52_gc_kernel(M, g)) c += LJ52_GC_KSLICE;
+  if (!M->gc_lendshut && !lj52_gc_kernel(M, g)) c += LJ52_GC_LEND;   /* THE LEND */
   return c;
 }
 
@@ -1165,6 +1202,13 @@
        * flush -> re-arm -> proof -> flush loop. */
       if (M->gc_armby != LJ52_ARM_FLUSH && total - used < (w >> LJ52_GC_FLUSHSHIFT))
         M->gc_flush_wanted = 1;
+      /* THE VERDICT, against the observing thread's tier top; past it, the
+       * lend shuts and the cycle is demanded again.  See THE LEND. */
+      top = total + (M->gc_odstate == LJ52_OD_RESERVE ? lj52_gc_odmax(total)
+                                                      : lj52_gc_odmax(total) >> 1);
+      if (lj52_gc_kernel(M, g)) top += LJ52_GC_KSLICE;
+      M->gc_lendshut = used > top;
+      if (M->gc_lendshut) lj52_gc_arm(M, g, LJ52_ARM_WALL);
     } else {
       if (M->gc_moved && g->gc.state == LJ52_GCS_PAUSE && g->gc.threshold > g->gc.total) {
         /* THE PARK RESET: the old cycle ended without atomic(); start a
@@ -1879,7 +1923,8 @@
 }
 
 /* _OCLJ_WALLSTATS() -> overdrafts, od_peak, od_state, park_resets,
- *                      od_limit, kernel_slice, gc_low, armby, hyst
+ *                      od_limit, kernel_slice, gc_low, armby, hyst,
+ *                      lend, lend_shut
  *
  * The collector at the wall (docs/roadmap.md; THE CREDIT, THE CADENCE and
  * THE PARK RESET in the collector section).  overdrafts counts growths lent
@@ -1891,7 +1936,9 @@
  * last proof left (lowered by frees), why the last cycle was armed (0 gate,
  * 1 wall or refusal, 2 the flush), and whether a cycle has been proven at
  * all -- what the harness's mem-2 needed to see why a hold got no cycle
- * (2026-10-04).  A separate
+ * (2026-10-04).  lend is THE LEND's size (the sandbox's bound is used <=
+ * cap + od_limit + lend), lend_shut THE VERDICT (1: the last proof left the
+ * heap past its tier top).  A separate
  * global, not more _OCLJ_GCSTATS positions: twenty values is LUA_MINSTACK,
  * which is what lets that one push without a checkstack.  Read-only,
  * allocates nothing, raw global -- the sandbox never sees it. */
@@ -1906,7 +1953,9 @@
   lua_pushnumber(L, M ? (lua_Number)M->gc_low : -1);
   lua_pushinteger(L, M ? M->gc_armby : -1);
   lua_pushinteger(L, M ? M->gc_hyst : -1);
-  return 9;
+  lua_pushinteger(L, M ? LJ52_GC_LEND : -1);
+  lua_pushinteger(L, M ? M->gc_lendshut : -1);
+  return 11;
 }
 
 /* Installed by lj52_newstate as the raw global _OCLJ_WATCHDOG. */
```

**Notes on the diff:**
- Every negative-control.sh sed target (4.1-4.13) is textually intact; all 13 applied (`mksabo.py`).
  The new credit line is a separate statement, not an `else`, so 4.10's replacement of the KSLICE
  line still compiles.
- The flush predicate is read before the re-arm, which rewrites `gc_armby`.
- At the re-arm, `lj52_gc_arm` latches `gc_savedmul` from a `stepmul` that the proof has just
  restored, so the disarm restores the real value.
- Warning-clean under `-Wall -Wextra` (`v/FIN/cc.log` is empty).
- Optional hardening, not in the prototype: `#if LJ52_GC_LEND > LJ52_GC_KSLICE` → `#error`. The
  global bound (§5) needs L ≤ K.

---

## 5. The bound (R5)

For every growth granted by the cap predicate (capped, chargeable, outside the norefuse window):

```
sandbox thread:              U + d  <=  T + G(T) + LJ52_GC_LEND        (= T + G + 1 KiB)
kernel thread:               U + d  <=  T + G(T) + LJ52_GC_KSLICE      (unchanged)
under HOOK_GC or GCSTOP:     U + d  <=  T                              (unchanged)
hence, any thread:           U + d  <=  T + G(T) + K                   since LEND (1 KiB) <= K (16 KiB)
with G(T) = clamp(floor(T/16), 32 KiB, 512 KiB):   U + d <= T + 528 KiB at any cap
```

**Derivation:**
- The predicate is unchanged in form: refuse iff U + d > T + credit (C mode :398-399, legacy
  :460-461).
- The credit is `(RESERVE ? G : G/2) + [kernel]·K + [sandbox ∧ ¬shut]·L`. Its maximum is
  `G + L` for the sandbox and `G + K` for the kernel.
- `lj52_gc_credit` returns 0 under HOOK_GC or GCSTOP before any of this is added.
- A grant therefore satisfies `U + d ≤ T + max credit`.

**Charged.** The lent bytes go through `M->used += delta` like any grant, so getFreeMemory reads 0
past the cap (both Java sides clamp).

**No ratchet:**
1. The lend depends only on one bit, `gc_lendshut`, which is set from the heap at the last proof. It
   does not depend on `gc_refusals`, on earlier excursions, or on how often the program caught.
2. A refusal leaves `used` unchanged and does not touch the bit.
3. The ceiling `T + G + L` is absolute.

W7 (4 000 caught attempts by the sandbox) measures `od_peak` 32 798 against the bound G + L = 33 792,
and `used` 337 948 against the bound `cap + G + L + 2048`.

**Excursions the inequality does not cover (all unchanged from HEAD):**
- the norefuse window (~1.5 KB of memoised GCfuncs);
- a cap set under the heap (C4b, W11);
- pre-binding banking in legacy mode.

---

## 6. Every transition

| state / path | what the change does |
|---|---|
| **C mode / legacy (csync)** | Both paths call the same `lj52_gc_credit` and `lj52_gc_pressure`, so the behaviour is identical. Measured: the legacy sweep matches C mode, 0 outside (`out/FIN_legacy`, `out/FIN_w16legacy`). Legacy reads T and U from Java per call, as before. The verdict lives in the record. |
| **norefuse** (`lj52_pushcfunction`) | The window is never refused, so the lend is never consulted. `lj52_gc_pressure` returns at its first guard, so no proof is observed and no verdict is recorded in the window. A cycle completed inside the window is observed at the first call after it (as at HEAD). |
| **HOOK_GC** (finalizer) | The credit is 0, so there is no lend. Pressure returns early, so the verdict is unchanged. A refusal there is still ERRFIN-swallowed, as at HEAD. |
| **host GCSTOP** (eris persist/unpersist) | The same as HOOK_GC: `threshold == LJ_MAX_MEM` returns credit 0. No proofs are observed, so the verdict is frozen across the persist. |
| **on trace** | A lent crossing on trace arms. The trace's next GC check bails at atomic and the GC exit completes the cycle (u2-checkpoints §3). The exit's snapshot restore may allocate; those allocations are lent only while open and only up to `tops + L`, otherwise refused as at HEAD. A trace with only uncounted allocations (NEWREF) runs to `tops + L` and is refused inside its own loop. Bounded by L. |
| **JIT recorder** | Recorder and assembler allocations are growths of the running thread; a sandbox's are lent while open. That removes the silent recorder-absorbed refusal that opened the reserve tier at stage C (§7.5). |
| **kernel slice** | Unchanged in the credit. The kernel gets **no lend** (C6b pins this). The kernel's proofs judge the verdict against `tops + K`, so its live working set between resumes does not shut the sandbox's lend (the verdictsandbox sabotage fails W12 + W16). |
| **fresh record** (eris load, cap under the heap) | `gc_lendshut = 0` at birth (calloc), so the verdict starts open, and the fresh-record RESERVE rule applies unchanged. A fresh sandbox past `T + G/2` gets RESERVE + L. Its first crossing arms (Regime F arms past the cap), and the first proof sets the verdict. W11's 32 KB request past `T + G + L` is still refused. Nothing new has to cross eris: the verdict is re-derived at the first proof after a load. |
| **RESERVE open / close** | Unchanged: a refusal opens it; a proof that finds U ≤ T closes it. The verdict uses the tier as it stands *after* the proof's close. A refusal does not touch the verdict, so after a refusal the next proof decides against the reserve top. |
| **THE CADENCE** (Regimes F/B/P) | One new arm: at a proof that finds U past the observing thread's top. That is reachable only past `tops`, i.e. only on a lend, since the kernel cannot pass `tops + K`. Every other arm decision is untouched. Below the cap nothing changes, so an idle machine is unaffected (reasoned; the 192 KB idle count was not measured in-machine). Near the top it costs about two cycles per tier top reached (§7.6). |
| **the flush predicate** | Unchanged, and evaluated before the re-arm. The re-arm is `ARM_WALL`, so its proof may raise the flag, exactly as any wall proof past the cap does at HEAD (every proof past the cap already does). The flag is a boolean consumed at `wd_arm`, so no extra flush unless a resume intervenes. W13, W14 and W15 pass. |
| **THE VALVE / park reset / the two-flip alias** | The re-arm happens at GCSpause (`gc_moved = 0`) and resets `gc_armedcalls`. The valve and the park reset are unchanged (nopark → W5a W5b; freescount → W5c). A re-armed cycle latches the new white; two cycles with no allocator call between them cannot occur, because the second needs an arm, i.e. an allocator call. |
| **refusal path** (`lj52_gc_refused`) | Unchanged. The TRY pressure call may observe a proof and so set the verdict, with U the pre-request figure. |

---

## 7. Measured results

### 7.1 mem_test (`mem_test_d2.c` = u2's `mem_test_w16.c` + W7 re-scope + W17 + C6b; `diffs/mem_test.diff`)

| object | checks | failures |
|---|---|---|
| stage C (`v/C0mt2`) | 71 | 1: **W16** ("inside 89, stall 7 ... covered 7") |
| FIN (`v/FINmt2`) | 71 | **0**, in 30 of 30 random-seed runs (`out/rob1/FINmt2.txt`) |

**Per case, on FIN:**
- **Re-scoped: W7.** It now checks `od_peak ≤ od_limit + lend` and `used ≤ cap + od_limit + lend + 2048`.
  - The reason is that the sandbox's bound moved by `LJ52_GC_LEND`, a compile-time constant.
  - It reads the lend from WALLSTATS[10]. That value is −1 on an object without the lend, and the
    test then uses 0, so W7 is unchanged on stage C (which passes it).
  - Measured: `od_peak` 32 798 (G + 30), against G = 32 768 at HEAD.
  - Without the re-scope, FIN fails W7 by those 30 B. That is a re-scope, not a regression: the
    excursion is the lend, inside the stated bound, and the non-ratchet property holds.
- **W16:**
  - stage C: FAIL, 7 covered (and 30/30 FAIL in u2);
  - FIN: PASS, 0 covered, 30/30.
- **W17 (new):** refused at table 1656, `od_peak` 16 471 = G/2 + 87, with bound G/2 + L/2.
  - Stage C passes it too (`od_peak` 16 383): it is a guard against a wrong lend, not fail-first.
- **C6b (new):** at the kernel's burst top with the verdict open, the raw push is LUA_ERRMEM. Stage C
  and FIN both pass.
- **Everything else unchanged:**
  - W1/W1L/W1j: `"not enough memory|256|3"`, 21 collects each;
  - W8, W10 (`true|true|2|true`), W11, W2b/W2c/W2d;
  - W4: 39 collects, the same as stage C; W12: 21 cycles, the same as stage C;
  - W13/W14/W15, W5a-c, P*, C*, M*;
  - W9 (info): 20 tries on both.
- **No real regression found.**

### 7.2 probe2 sweep, per shape (inside / stall / down; outside covered by the site pass)

| shape | stage C (C0) | FIN |
|---|---|---|
| record | 4058 / 10 / 28; 38 covered of 38 | 4096 / 0 / 0 |
| array | 4043 / 30 / 23; 53 of 53 | 4096 / 0 / 0 |
| string | 3843 / 132 / 121; 253 of 253 | 4096 / 0 / 0 |
| closure | 4018 / 45 / 33; 78 of 78 | 4096 / 0 / 0 |
| **total** | 15 962 / 217 / 205: **422 outside, 422 covered** | **16 384 / 0 / 0** |

### 7.3 Variants, outside (covered), stage C → FIN

| variant | stage C | FIN |
|---|---|---|
| JIT on | 574 (514; 36 unmapped sites) | **17 (2)** (§7.4) |
| legacy (dropin) path | 422 (422) | 0 |
| no `pcall(paint)` | 221 (221) | 0 |
| heartbeat every 3rd resume | 437 (437) | 0 |
| control (stage + timer inside the pcall) | 145 (145) | 0 |
| junk 8 / 48 / 96 (4 096 runs each) | 136 / 88 / 56 | 0 / 0 / 0 |
| cap = base + 128 KB (G = 32 KB) | 336 (310 + 26 unmapped: 22 × 36 B, 4 × 32 KB of which 3 covered) | **1** (a 32 KB string-table growth; live + 32 KB > cap + G/2: not covered) |
| cap = base + 1.5 MB (G = 99 KB) | 540 (540) | 0 |
| W16 program, JIT off | 168 (168) | 0 |
| W16 program, JIT on | 596 (236) | 0 |
| W16 program, legacy | 168 (168) | 0 |

### 7.4 What remains with the JIT on (17 of 16 384)

- All 17 are stalls refused with the verdict **shut** (credit = G/2, so no lend). That means a proof
  had found the heap past the top.
- At the site, live + the whole object exceeds the top by 104-328 B in 15 cases, so they are not
  covered.
- In two cases (string, off 61 488 and 61 504) the stage string fits by 0 and 16 B.
- The site pass is weaker with the JIT on (u2 §9: the measuring branch changes the trace). These two
  are the residual named in §8.

### 7.5 Event mix (where refusals land)

- `3,1,6` means `pcall(paint)` absorbed a refusal, and then the fill was refused inside its own
  handler.

  | sweep | stage C | FIN |
  |---|---|---|
  | JIT off | 82 | 126 |
  | JIT on | 151 | 245 |
  | heartbeat | 71 | 126 |

  These are the cases that stalled at stage C: the step's out-of-handler allocations are now lent,
  and the next shut-verdict allocation falls in paint's pcall. Stock PUC shows the same `3,1,6`
  pattern (u2-repro §2).
- The M4 class `1,2` (JIT on: an inside refusal, then the done string refused at the reserve top)
  goes 36 → 0.
- **Recorder-absorbed refusals.** With the JIT on, stage C's string runs carry 1.91 refusals per run
  against FIN's 1.14 (summary column). Stage C's first refusal is often swallowed by the trace
  recorder and silently opens the reserve tier for the fill. That is the "second chance" u2-stalls
  ties to every in-machine bad outcome. FIN lends those crossings.
- **Consequence for capacity (R12).** In JIT-on string runs that end `1,6` on both objects, FIN's
  fill stops **132.6 objects earlier** on average (about G/2 of string-shape live data). Mean held at
  the refusal is 5285.5 → 5170.7 (−2.2%).
  - JIT-on record: −2.1 objects.
  - JIT off, every shape is ≥ stage C: record 1383.1 → 1383.5, array 2060.1 → 2061.0,
    string 5245.1 → 5248.9, closure 2000.6 → 2001.5.

### 7.6 Cost (R9, R12)

- **Full cycles per fill**, mean C0 → FIN (`summ.py` collects; ratio in brackets):

  | sweep | record | array | string | closure |
  |---|---|---|---|---|
  | probe2 | 31.8 → 34.5 (×1.086) | 28.4 → 30.2 (×1.064) | 80.0 → 86.7 (×1.084) | 29.8 → 31.5 (×1.060) |
  | same-count inside runs | ×1.066 | ×1.026 | — | ×1.025 |
  | JIT on | ×1.044 | ×1.024 | ×0.909 (shorter fills, §7.5) | ×1.051 |

  - The W16 program: 81.8 → 86.1 (×1.053).
  - This is about **+2 cycles per tier top reached**: the lent crossing's cycle, plus the re-take
    after a proof past the top. THE CADENCE's log2 halving per tier is otherwise untouched.
  - For comparison, the prevention-only margin cost ×1.5-2.0 (§2.2).
- **mem_test W4:** near 39 cycles (bound 61), far 0, the same as stage C; the time ratio is noisy at
  `clock()` resolution (C0 3.0, FIN 2.0). **W12:** 21 cycles on both.
- **Whole-run wall time** (`out/timing2.txt`): 4 alternating pairs, record+string, 4 096 runs each.
  FIN/C0 = 1.043 (pairs 1.052, 1.042, 1.040, 1.039). No Minecraft or Java process was running.
- **Last-five / first-five batch time** (`probe2t.lua`: probe2 with a QueryPerformanceCounter clock,
  2 × 512 runs per shape, `out/t5/`):

  | | array | closure | record | string |
  |---|---|---|---|---|
  | stage C | 4.89 | 8.29 | 7.37 | 25.44 |
  | FIN | 5.15 (+5%) | 8.79 (+6%) | 7.80 (+6%) | 26.81 (+5%) |

---

## 8. The residual, in one sentence

What this still does not fix: a crossing that comes after a proof which found the heap past the
tier top only because that proof's checkpoint still pinned garbage (a frame, an unassigned slot) is
refused before the re-armed cycle can re-take the verdict (2 marginal cases in 16 384 with the JIT
on, none with it off), and, as at HEAD, a single request larger than the headroom plus the credit
plus the lend is refused where stock would collect and succeed (W9; a 32 KB string-table growth).

---

## 9. Score against R1-R12

| R | score | why |
|---|---|---|
| **R1** | **PARTLY (close)** | A crossing is refused only after a full cycle has been proven and has left the heap past the top. Its figure is live + garbage that the proving checkpoint pinned + bytes allocated after it, so the residual of §8 remains. Measured: 0 covered outside refusals in every JIT-off sweep, 2 marginal with the JIT on. **Earlier than stock?** No, in program order, as long as the pinned garbage < G/2: `U > top = T + G/2` at a proof implies live > T + G/2 − pinned > T, and stock refuses at live + d > T. The lend only moves refusals later, by at most L. |
| **R1b** | **MET** | W1/W1L/W1j/W2b/W2c/W8 pass unchanged. W10 passes. The lend is the sandbox's only; the kernel's slice is untouched, and the kernel's verdict includes K. |
| **R5** | **MET** | §5: sandbox `U + d ≤ T + G + 1 KiB`; kernel `≤ T + G + K`; any thread `≤ T + G + K` because L ≤ K. Charged. No ratchet: one heap-derived bit and an absolute ceiling. W7 re-scoped to G + L and passes; C6b pins no kernel lend. |
| **R6** | **MET** | No collection in the allocator. The only VM writes are `lj52_gc_arm`'s two scalars, which already run from the allocator at HEAD. No new reads of VM state (the verdict reads U and the tier). On trace, GCSTOP, HOOK_GC: §6. |
| **R7** | **MET** | Zero LuaJIT lines; about 10 shim code lines; the collector gate is unchanged (no `lua_gc`, no new LuaJIT header). |
| **R8** | **MET** | The verdict lives in the record. It is frozen under GCSTOP and starts open on a fresh record (the safe default, re-derived at the first proof). The fresh-record rule is unchanged (W11, nofresh → W11). |
| **R9** | **PARTLY** | Far from the wall nothing changes: the lend is consulted only on the slow path, and the verdict only at proofs. Near the wall: about +2 cycles per tier top, measured +6-9% cycles per fill and ×1.043 whole-run time. W4 and W12 unchanged. Idle on a 192 KB stick: unchanged by construction (the new arm needs U past `tops`), not measured in-machine. |
| **R10** | **PARTLY** | Hermetic and fail-first: W16 FAILs on stage C (u2: 30/30; here 7 covered), PASSes on FIN 30/30. New W17 and C6b. W7 re-scoped with its reason. Five new sabotages, each caught; three existing expected sets grow (§10.3). The in-machine gate is designed but **not run** (§10.4). |
| **R11** | **MET** | No knob: `LJ52_GC_LEND` is a compile-time constant; `ramScaleFor64Bit` is inherited. |
| **R12** | **PARTLY** | JIT off, capacity ≥ stage C in every shape (+0.4 to +3.8 objects). With the JIT on, the string shape holds 2.2% fewer objects than stage C, because stage C's recorder-absorbed refusal no longer opens the reserve (§7.5). That is still about G/2 of live data above where stock refuses (at the cap). Last-five-batch time +5-6% hermetically. Both need the in-machine matrix. |

---

## 10. Test plan

### 10.1 New hermetic cases (mem_test.c)

| case | asserts | stage C | FIN |
|---|---|---|---|
| **W16** (u2-repro §7, unchanged) | No outside refusal that a collection would have covered, over 96 caps of one fill step. | **FAIL**: 7 covered stalls; 30/30 FAIL (u2) | PASS 30/30 |
| **W17** (new) | A sandbox filling live 64 B tables (holder pre-sized), one refusal: `G/2 − 256 ≤ od_peak ≤ G/2 + lend/2`. The lend is not a third tier. | PASS (16 383) | PASS (16 471) |
| **C6b** (new) | The kernel (C frames, depth 0) at its BURST top `T + G/2 + K == used`, verdict open, record in BURST: a raw push is LUA_ERRMEM. The preconditions are asserted, so it cannot pass vacuously. | PASS | PASS |

### 10.2 Changed case

- **W7:** `od_peak ≤ od_limit + lend` and `used ≤ cap + od_limit + lend + 2048`. The bound moved by
  the constant L. On an object without the lend, the lend reads as 0.
- **Also proposed:** expose `LJ52_GC_LEND` in the harness's CAP-GC line (WALLSTATS[10], [11]).

### 10.3 Negative controls

Built from FIN with `mksabo.py`; failing ids measured with `mem_test_d2.c` (`out/sabo2/`).

**New:**

| # | name | edit | FAIL set |
|---|---|---|---|
| 4.14 | nolend | `#define LJ52_GC_LEND   1024` → `0` | **W16** (30/30) |
| 4.15 | lendall | the credit line without `!M->gc_lendshut &&` (a third tier) | **W16 W17** |
| 4.16 | noverdictarm | `if (M->gc_lendshut) lj52_gc_arm(M, g, LJ52_ARM_WALL);` removed | **W16** (30/30) |
| 4.17 | verdictsandbox | the verdict's `if (lj52_gc_kernel(M, g)) top += LJ52_GC_KSLICE;` removed | **W12 W16** (30/30) |
| 4.18 | lendkernel | the credit line without `&& !lj52_gc_kernel(M, g)` | **C6b** |

**Existing 4.1-4.13 with the new test file:** every expected set holds as in negative-control.sh,
except three that **grow**:
- stopgap: + C6b W16 W17;
- nocredit: + W16 W17;
- unbounded: + C6b W17.

norefuse still dies after M5 (exit 127, reached M5, no summary). nopending, nopark, freescount,
norefusedarm, nohyst, nokslice, nofresh, closereserve and flushwhole are unchanged.

### 10.4 In-machine gate (designed, not run here)

- **The capacity matrix** (R12): stage C vs FIN vs stock, both JIT arms, every stick.
  - Expected: no stall or down in our runs.
  - Capacity ≥ stock in every cell.
  - Watch the JIT-on string cells for the −2% of §7.5.
  - Last-five ratio within about 1.06 of stage C's.
  - Report `lend_shut` and `od_peak − G` in CAP-GC.
- **The amplified probe** (R10): the capacity probe with `BATCH = 10` and the step's
  stage/`event.timer`/paint kept. That gives 10× as many batch boundaries per byte; with
  `junk = 8` the garbage fraction is ~3% (u2 §2's worst).
  - Hermetic expectation from u2's per-boundary rates: stage C around 10-25% of runs outside,
    stock 0, FIN about 0.
  - Count stalls (OCLJCAPF −1/−1 with `batches = N`) and downs per 20-run cell.
  - Gate: FIN's rate is not distinguishable from stock's 0 (one-sided Fisher p > 0.2).

---

## 11. Not checked / caveats

- **No in-machine run.** OpenOS's real dispatcher (`copy` loop, `event.onError`), machine.lua and
  Java's signal pushes were modelled by u2's programs, not run. 1 KB covers the probe's 256 B run
  with margin. OpenOS's handler-copy loop (no checkpoint, about 8-24 B per handler × nextpow2) was
  sized from u2-checkpoints, not measured.
- **The JIT-on site pass is weaker** (u2 §9). The 2 "covered" cases of §7.4 are marginal (0 and 16 B
  of slack).
- **The 1-byte edge** of §3.4 (Regime P with `gc_low = top + 1 = U`) arms at the next growth; it was
  never observed.
- **The −2.2% JIT-on string capacity** is attributed to recorder-absorbed refusals from the
  refusal-count difference (1.91 → 1.14 per run). The recorder was not instrumented to confirm it.
- **Caps tried:** base + 128 KB, + 384 KB and + 1.5 MB. The 512 KB-ceiling regime (caps ≥ 8 MB) and
  batch sizes other than 100 were not swept.
- **Timing caveats.** W4's own time ratio uses `clock()` and is noisy at this scale. The last-five
  measurement is hermetic, and its absolute numbers depend on this machine.
- **The negative-control build line** in the script omits `-DLJ52_ADDITIVE` and `-Wall`. My sabotage
  builds used the task's line (warnings tolerated for stopgap and nofresh, whose own edits leave
  unused parameters).

## 12. Files

- **Design inputs read:** REQUIREMENTS.md, u2-repro.md, u2-shim-now.md, u2-checkpoints.md,
  u2-stalls.md, u2-priors.md.
- **The final change:**
  - `d2-prevent/srcF/lj52shim.c`
  - `d2-prevent/diffs/lj52shim.diff`
  - `d2-prevent/mkfinal.py`
  - object `d2-prevent/v/FIN/lj52shim.o` (md5 `cb996c9e`)
- **Tests:** `d2-prevent/mem_test_d2.c`, `d2-prevent/diffs/mem_test.diff`, `d2-prevent/mkmt.py`,
  `d2-prevent/mksabo.py` → `sabsrc/*`.
- **Prototype:** `d2-prevent/mkproto.py` → `srcP/lj52shim.c`. Variants are in `v/<name>/`, each with
  its `-D` flags in `defs.txt`.
- **Harness:** `bv.sh`, `bring.sh`, `sweep.sh`, `sweep16.sh`, `summ.py`, `summ16.py`, `w16p.lua`,
  `probe2t.lua`, `lj_repro_big.c`.
- **Measurements:**
  - `out/<variant>_probe2/` and `out/<variant>_w16/` (summary*.txt, If*.tsv, site.tsv);
  - `out/C0_*`, `out/FIN_*` and `out/FIN1_*` (variants);
  - `out/mt1`, `out/mt2`, `out/mt3` (mem_test logs);
  - `out/sabo1`, `out/sabo2` (sabotages);
  - `out/rob1` (30-run robustness);
  - `out/t5`, `out/timing2.txt` (time).
