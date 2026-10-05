# d2-lend: THE WINDOW, or "lend until the post-crossing proof"

This is design round 2 for the row "A refusal at a credit tier's top can land outside the program's handler" (docs/roadmap.md:159).

**The angle.** "Lend until the post-crossing proof", worked out so that it covers M1 to M3, plus M4 with the JIT on.

**Code and builds.**
- HEAD is d9080d4. The repo was only read; everything was built and run in `scratchpad/wall2/d2-lend/` (paths below are relative to it).
- **Prototype:** `final2/lj52shim.c`, made by `mkd2final.py` from `lj52shim.orig.c` (a byte copy of `native/lj52shim.c`).
- **Diff:** `final2/d2-lend.diff`.
- **Object:** md5 `2e1d8f6e…`. It is warning-clean with build-native.sh's line plus `-DLJ52_ADDITIVE`. That same line, applied to the unmodified source, reproduces stage C's `0259f0d1` byte for byte (`origsrc/`).

**Test copy.** `mem_test_d2.c`, made by `mkmt.py`, is the repo's mem_test plus u2-repro's W16, plus W16R, W16Rj and W7k (new), with W7 re-scoped (§7).

**Probe forms.**
- `w16probe_m.lua` and `w16rprobe_m.lua`: the W16 program, and that program carried into the reserve tier, each measuring the live set where it lands.
- `probe2t.lua`: the timing copy of the probe.

**Directory layout.**
- Every measurement is in its own `out*/` directory; nothing was cleared.
- The exploration's variants are `src_v*` and `mkd2*.py` (§9).
- `final/` holds a kept earlier final, with two arm lines that §9 shows to be redundant.

## 0. Summary

**The rule.** A **sandbox** growth that would pass its tier's top S (cap + G/2, or cap + G in the reserve tier) is **lent**, up to `LJ52_GC_LEND` = 4 KiB past S. THE CADENCE arms at that grant, as it already arms any unarmed growth past S. The window stays open until a proven cycle says what the heap holds:
- **back under S:** shut, because garbage covered the crossing;
- **past S even without the bytes granted since the *previous* proof** (data that survived two consecutive cycles): **the verdict**, and further crossings are refused while that proof's heap stays past the current S;
- **anything else:** it stays open.

**Three supporting rules.**
- A cycle that has ended is proven **before** the next growth is judged.
- A refusal **shuts** the window, so the cycle it arms decides the next crossing.
- The kernel gets **no window**: its 16 KiB slice lies past every window, and its tops stay hard.

**The bound** over every thread is unchanged: used + delta ≤ cap + G + KSLICE. The sandbox's own refinement moves from cap + G to cap + G + 4 KiB.

**Measured, against the stage-C object (fixed seed, 4 096 caps per shape unless stated).** Each entry reads stage C's outside landings, garbage-covered in brackets, then the prototype's.

*probe2 (the capacity probe's shape), 16 384 runs per configuration:*

| configuration | stage C | prototype |
|---|---|---|
| default | 431 (431) | **0** |
| heartbeat | 438 | 0 |
| no paint | 221 | 0 |
| legacy (dropin) | 431 | 0 |
| seed 7 | 427 | 0 |
| JIT on | 508 (342) | **0** |

*Larger caps, other junk lengths, and the amplified probe:*

| configuration | stage C | prototype |
|---|---|---|
| 1 MB cap | 114 | 0 |
| 2 MB cap | 123 | 0 |
| junk 8 | 100 | 0 |
| junk 96 | 50 | 0 |
| batch 10 (amplified, 16 384 runs) | 5 271 (4 826) | **0** |

*The W16 program, and W16 carried into the reserve tier (first refusal absorbed, data kept):*

| configuration | stage C | prototype |
|---|---|---|
| W16, JIT off | 168 (168) | **0** |
| W16, JIT on | 473 (236) | **0** |
| reserve tier, JIT off | 169 (169) | **0** |
| reserve tier, JIT on | 1 847 (1 804) | **0** |

**The exception.** It is in two JIT-on configurations:
- 4 runs in the 1 MB-cap JIT-on configuration;
- 9 in batch-10 JIT-on.

All 13 are not covered: live data 40 to 700 B past S. That is stock's class (§6.2).

**Test results.**
- **mem_test (`mem_test_d2.c`, 72 checks):** the prototype passes all 72 in **30 of 30** random-seed runs.
- **Stage C on the same copy:** it fails **exactly W16, W16R and W16Rj** in 10 of 10 runs.
- **Sabotages:** every new rule has a sabotage that fails a case (§7.3), and every existing sabotage still fails its expected set, some with W16, W16R, W16Rj or W7k added for stated reasons.

**Costs.**
- **Cycles per fill:** +16 to +26 % (string 80.0 → 100.8).
- **Last five batches:** cycles +20 to +32 %, time 1.15 to 1.28× (§6.3).
- **Capacity:** ≥ stage C's like for like (§6.4).

**Unplanned finding.** The stage-C object **segfaults** in LuaJIT's unwinder on one cap (string, JIT on, batch 10, off 10 688). The crash is in `err_unwind`, unwinding a refusal raised in `lj_str_new` under `tostring` (§8). It is reported, not investigated.

## 1. The rule

**Notation.**
- T: the cap.
- G: `lj52_gc_odmax(T)` = clamp(T/16, 32 KiB, 512 KiB).
- K: `LJ52_GC_KSLICE`, 16 KiB.
- L: `LJ52_GC_LEND`, 4 KiB.
- S: the sandbox's tier top. S = T + G/2 in BURST and T + G in RESERVE, which is `T + lj52_gc_credit()` for a sandbox thread.
- The kernel's top is S + K, as today.

**A growth (delta > 0)** that is accounted, outside norefuse, and not under HOOK_GC or a host GCSTOP:

1. **The proof first.** If the record is armed, `lj52_gc_pressure(FREE)` runs before the decision.
   - A cycle that has completed (white flipped, GCSpause) is proven now, and its figure is the heap the cycle left. Today it is that heap plus the request that observed it.
   - FREE because this is an observation, not an attempt: the valve does not count it.
2. **Fast test, then credit:** today's rules, unchanged.
3. **Otherwise THE WINDOW** (`lj52_gc_lend`).
   - It never lends to the kernel (`wd_depth == 0` or `cur_L == wd_by[0]`), and never under HOOK_GC or GCSTOP.
   - **The ceiling:** U + d > S + L is refused.
   - **The verdict:** `gc_win == 2` and `gc_low > S` is refused. It is read against the current S, so a raised cap or a newly opened reserve tier voids it.
   - **Otherwise LEND:** `gc_win = 1`, `gc_lends++`, grant and charge.
   - It arms nothing itself. The grant's own `pressure(GROW)` runs THE CADENCE, which arms any unarmed growth past S:
     - in regime P, `top − used < 0`. Either `(top − gc_low)/2 ≥ 0`, or `gc_low > top`, and then `top − used ≤ top − gc_low < (top − gc_low)/2`, because an unarmed record keeps `gc_low ≤ used` (frees lower it). The sabotage `nolendarm` and the `out16/` sweeps showed the lend's own arm made no difference;
     - in regimes F and B, any growth past the cap arms.
4. **Refuse:** today's path plus one line, `gc_win = 0`. The window shuts, so the cycle this refusal arms decides the next crossing.

**Every granted growth** adds delta to `gc_grown`, the bytes granted since the last proof (one add in each mode's grant path).

**At every proof** (the armed branch of `lj52_gc_pressure`, any kind), after today's work (`gc_low = U`, the tier repaid if U ≤ T, the flush flag): if the window is open, with S for the tier as just updated,
- U ≤ S → `gc_win = 0`: **shut**.
- U − `gc_grown` > S → `gc_win = 2`: **the verdict**. What this cycle and the previous one both kept is past the top.
- Otherwise `gc_win = 1`: **open**. The excess is no older than the previous proof, and the frame that allocated it may still pin it.

Then `gc_grown = 0`.

### Why each part is there (each found by measurement; §9 has the path)

| part | without it |
|---|---|
| lend at the crossing (V1) | stage C: 431 outside in probe2, 168 in the W16 program |
| proof read before the decision | V1, reading the proof after the grant: 18 sandbox downs in probe2, all at the dispatcher's pack. **Ring, record off 10864, seq 10068:** the cycle left the heap at 473 906, under S = 473 970. The kernel's 80 B pack then observed the proof post-grant (473 986): a false verdict, and the sandbox's pack was refused. **Sabotage `lateproof`:** fails W16 and W16R. |
| the two-cycle verdict | Verdict on the raw heap: probe2 0 outside, but the W16 program 19 / 4 096 (§9). **Ring, W16 off 16:** the window's cycle ran at the batch's last checkpoint (the check-after of `.. '!'`) while that frame held its junk. The proof found U = S + 4, and the stage string was refused outside the handler, with the live set 228 B under S once that frame was gone. A "two over-proofs" grace was worse (35 / 4 096): both over-proofs fell on the last two checkpoints of the last iteration. **Sabotage `rawverdict`:** fails W16, W16R and W16Rj. |
| a refusal shuts the window | Reserve tier, JIT on: 21 / 4 096 stalls without it. **Ring, off 576:** the caught refusal in the reserve tier opened no room, the verdict stood, and the program's next allocation (the stage string, allocate-first) was refused before the refusal's own cycle could run. This is u2-repro's M4 (`done/…` at the reserve top). **Sabotage `refusalkeeps`:** fails W16Rj. |
| the kernel gets no window | It keeps R5's constant over every thread. **Sabotage `kernelwindow`:** fails W7k. |

### Answers to the angle's questions

- **The ceiling, and how the tiers layer.**
  - *Sandbox:* BURST is S = T + G/2 with its window to T + G/2 + L; RESERVE is S = T + G with its window to T + G + L.
  - *Kernel:* T + G/2 + K and T + G + K, hard.
  - *Fixed constant:* L = 4 KiB ≤ K. The window lies inside the kernel's slice, so the constant over every thread is unchanged and the kernel keeps ≥ K − L = 12 KiB after the sandbox's window (W10).
  - *Stage B's recovery:* the first sandbox refusal comes at U ≤ T + G/2 + L. The reserve tier then leaves ≥ G/2 − L (12 KiB at the floor) before its top, and G/2 before its window's ceiling.
- **What opens a window.** Any sandbox growth that the fast test and the credit refuse, while no verdict stands.
  - **M1:** the stage string after the batch's last proof.
  - **M2:** TDUP's hash part after its `GCtab`.
  - **M3:** the dispatcher's pack after the kernel spent its slice. The window does not depend on who first took the heap past S. The kernel's crossing opens nothing: the sandbox's next allocation is a crossing like any other, lent, and the cycle armed at its grant runs at its check.
  - I built a kernel-side arm for M3 and measured it redundant (§9): 0 difference in any sweep.
- **A proof taken while a frame pins garbage.** It cannot give a verdict on what it pinned if that was allocated after the previous proof: the verdict subtracts `gc_grown`. Garbage pinned across two consecutive cycles (a stale register that outlives two checkpoints) can still give a false verdict. That is half of the residual (§5).
- **What C6 and W7 must become.**
  - **C6 and M6b:** unchanged. They run as the kernel, which has no window.
  - **W7:** re-scoped to the sandbox's new bound, peak ≤ G + window, with window ≤ slice asserted.
  - **W7k (new):** pins the bound over every thread, which nothing pinned before: the `kernelwindow` sabotage passed every existing case.

## 2. The code change

The unified diff of `final2/lj52shim.c` against `native/lj52shim.c` at d9080d4 has 107 changed lines. About 43 are code; the rest are comments.
- **LuaJIT:** zero lines.
- **Collector gate:** untouched. The new code calls `lj52_gc_pressure` and `lj52_gc_credit` only.
- **Sabotage anchors:** every line `test/native/negative-control.sh` seds on is still present exactly once.
- **WALLSTATS:** grows from 9 to 11 values, adding `window` (L) and `lends`. Both allocate nothing.

```diff
--- a/native/lj52shim.c
+++ b/native/lj52shim.c
@@ -277,6 +277,9 @@
   long long     gc_seentotal;  /* the cap the last allocator call was under   */
   volatile long gc_overdrafts; /* growths granted past the cap, on credit     */
   long long     gc_odpeak;     /* the largest excursion past the cap, bytes   */
+  int           gc_win;        /* THE WINDOW: 0 shut, 1 open, 2 the verdict   */
+  long long     gc_grown;      /* bytes granted since the last proof          */
+  volatile long gc_lends;      /* growths lent past a tier's top: diagnostics */
   /* -- the trace flush under pressure; see FLUSHING TRACES below -- */
   int           gc_flush_wanted;  /* a PROVEN cycle left headroom short:      */
                                   /* flush at the next safe point (wd_arm)    */
@@ -298,6 +301,7 @@
  * defined with the collector, below the LuaJIT-internal includes. */
 static long long lj52_gc_credit(lj52_mem *M, long long total, long long used);
 static void lj52_gc_refused(lj52_mem *M, long long total, long long used);
+static int lj52_gc_lend(lj52_mem *M, long long total, long long used, long long delta);
 
 /* The record for L, or NULL for a state this shim did not create. */
 static lj52_mem *lj52_memof(lua_State *L) {
@@ -344,6 +348,9 @@
  *      knowing whether realloc succeeded, so a failed resize permanently
  *      inflates the machine's usage.  Ours charges after the fact.
  *
+ * And it refuses later than the cap: THE CREDIT and THE WINDOW lend a
+ * bounded excursion past it, and arm the collector to repay it.
+ *
  * norefuse is the other half of this change; see lj52_pushcfunction. */
 /* The Java side stores used/total as jint, so that is what crosses the JNI
  * boundary -- but the arithmetic in between is done in long long and saturated
@@ -395,14 +402,18 @@
       M->used += delta;
       return NULL;
     }
+    if (acct && delta > 0 && M->gc_armed)   /* a cycle that ended is proven */
+      lj52_gc_pressure(M, M->total, M->used, LJ52_GP_FREE);   /* FIRST: THE WINDOW */
     if (acct && delta > 0 && !M->norefuse && M->total - M->used < delta
-        && M->total + lj52_gc_credit(M, M->total, M->used) - M->used < delta) {
+        && M->total + lj52_gc_credit(M, M->total, M->used) - M->used < delta
+        && !lj52_gc_lend(M, M->total, M->used, delta)) {
       lj52_gc_refused(M, M->total, M->used);
       return NULL;                      /* -> lj_err_mem -> LUA_ERRMEM */
     }
     p = lj52_back(M, ptr, osize, nsize);
     if (p != NULL) {
       M->used += delta;
+      if (delta > 0) M->gc_grown += delta;
       if (acct) lj52_gc_pressure(M, M->total, M->used, delta > 0 ? LJ52_GP_GROW : LJ52_GP_FREE);
     }
     return p;
@@ -457,8 +468,11 @@
     M->used += delta;
     return NULL;
   }
+  if (delta > 0 && M->gc_armed)             /* the proof FIRST: THE WINDOW */
+    lj52_gc_pressure(M, total, used, LJ52_GP_FREE);
   if (!(total <= 0 || delta <= 0 || total - used >= delta || M->norefuse
-        || total + lj52_gc_credit(M, total, used) - used >= delta)) {
+        || total + lj52_gc_credit(M, total, used) - used >= delta
+        || lj52_gc_lend(M, total, used, delta))) {
     /* We are at the wall, past the credit too.  We still do not collect
      * here -- C1/C5/C6 -- but the refusal arms, from any headroom, and opens
      * the credit's reserve tier for whatever the program does next: see
@@ -470,6 +484,7 @@
   if (p != NULL) {
     M->setmem(env, obj, lj52_clampi(used + delta));
     M->used += delta;
+    if (delta > 0) M->gc_grown += delta;
     lj52_gc_pressure(M, total, used + delta, delta > 0 ? LJ52_GP_GROW : LJ52_GP_FREE);
   }
   return p;
@@ -957,7 +972,8 @@
  *     every resume (machine.lua).
  * No credit at all where nothing could repay it: under HOOK_GC (a finalizer;
  * PUC's cap is hard there too) and under a host GCSTOP.  The bound is
- * absolute, not incremental: used + delta <= total + G (+ the slice) for
+ * absolute, not incremental: used + delta <= total + G (+ the slice; the
+ * sandbox's WINDOW below stays inside it) for
  * every growth outside the norefuse window, so caught refusals cannot
  * ratchet it (mem_test W7), and the excursion is charged -- getFreeMemory
  * reads 0, both Java sides clamp it there.  What it does not fix: a single
@@ -999,6 +1015,54 @@
  * proof inside the watermark; halving the gate gives it that, at log2
  * cost.
  *
+ * THE WINDOW (2026-10-04, round 2; docs/roadmap.md, "A refusal at a credit
+ * tier's top can land outside the program's handler").  The credit moved the
+ * refusal from the cap to a tier's top, but it still came at whichever
+ * allocation first found used + delta past that top, and `used` is the live
+ * data PLUS everything allocated since the last proven cycle -- so refusals
+ * were spread over the allocation sites by bytes, and some landed where the
+ * program has no handler (the capacity probe's step between batches: a
+ * stall; OpenOS's dispatcher: the sandbox down) although a collection would
+ * have made room (mem_test W16, W16R).  PUC collects at the refusal and
+ * retries; we cannot (C1-C7).  So a SANDBOX growth past its tier's top is
+ * LENT, up to LJ52_GC_LEND past it -- and THE CADENCE arms at the grant, as
+ * it arms any unarmed growth past that top (regime P: top - used < 0; F and
+ * B: past the cap) -- and the window stays open until a proven cycle says
+ * what the heap holds:
+ *   - the heap back under the top: the window shuts -- garbage covered it;
+ *   - the heap past the top even without what was granted since the
+ *     PREVIOUS proof, i.e. data that survived two consecutive cycles: the
+ *     verdict, and every further crossing is refused while that proof's
+ *     heap stays past the current top;
+ *   - otherwise it stays open.  The excess is the newest allocation, and the
+ *     frame that made it may still pin it: a cycle run at a check inside a
+ *     loop marks that frame's registers (lj_gc.c:309-313), so its proof finds
+ *     junk that is dead the moment the loop's function returns (W16: the
+ *     batch's last checkpoint, then the stage string outside the handler).
+ * A cycle that ended is proven BEFORE the next growth is judged (the two
+ * lines ahead of each refusal predicate), so a proof's figure is the heap the
+ * cycle left, not that plus the request that observed it: the kernel's
+ * table.pack right after a cycle made false verdicts before this.  A refusal
+ * shuts the window, so the cycle it arms decides the next crossing: a caught
+ * refusal in the reserve tier opens no room, and without this the program's
+ * next allocation -- its "done/..." string, allocate-first -- was refused
+ * before any checkpoint could run (W16R with the JIT on).
+ * The kernel gets no window: its slice is past every window (LJ52_GC_LEND <=
+ * LJ52_GC_KSLICE) and its tops stay hard (W7k).  When the kernel's slice has
+ * taken the heap past the sandbox's top between resumes, the sandbox's next
+ * allocation -- the dispatcher's table.pack -- is a crossing like any other:
+ * lent, and the cycle armed at its grant runs at its check.
+ * No window under HOOK_GC or a host GCSTOP, as no credit.  The bound stays
+ * absolute: the sandbox's used + delta <= total + G + LJ52_GC_LEND, every
+ * thread's <= total + G + LJ52_GC_KSLICE, so caught refusals cannot ratchet
+ * it (W7, re-scoped to G + the window; W7k).  What it costs: while the live data
+ * plus the newest junk straddles the top, a cycle per crossing -- stock's
+ * rate there, which collects at every refused allocation.  What it does not
+ * fix: a crossing whose window is overrun before a checkpoint proves a cycle
+ * (more than LJ52_GC_LEND in one checkpoint-free stretch, or the kernel
+ * spending more than that of its slice between resumes), and garbage pinned
+ * across two consecutive cycles, are still refused wherever they land.
+ *
  * THE VALVE COUNTS ATTEMPTS.  LJ52_GC_ARMCAP counts allocator calls that
  * try to GROW (granted or refused), never frees or shrinks.  An armed cycle
  * that sweeps more than 65 536 dead blocks -- one sweep of a machine full of
@@ -1018,6 +1082,7 @@
 #define LJ52_GC_ODMIN  (32 * 1024)
 #define LJ52_GC_ODMAX  (512 * 1024)
 #define LJ52_GC_KSLICE (16 * 1024)      /* the kernel's own, past the credit */
+#define LJ52_GC_LEND   (4 * 1024)       /* THE WINDOW; <= KSLICE: the bound  */
 #define LJ52_GC_HYSTSHIFT 1             /* re-arm after half the headroom    */
 #define LJ52_GC_FLUSHSHIFT 1            /* flush inside half the watermark   */
 #define LJ52_OD_BURST   0               /* credit tiers                      */
@@ -1097,6 +1162,26 @@
   return c;
 }
 
+/* THE WINDOW: lend a sandbox growth the credit refused?  Up to LJ52_GC_LEND
+ * past the top it was refused at, unless the verdict stands.  Never the
+ * kernel's, never under HOOK_GC or a host GCSTOP.  It arms nothing itself:
+ * the grant's own pressure call does (THE CADENCE, past the top). */
+static int lj52_gc_lend(lj52_mem *M, long long total, long long used, long long delta)
+{
+  global_State *g;
+  long long top;
+  if (M->L == NULL || total <= 0) return 0;
+  g = G(M->L);
+  if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM || lj52_gc_kernel(M, g))
+    return 0;
+  top = total + lj52_gc_credit(M, total, used);
+  if (used + delta > top + LJ52_GC_LEND) return 0;      /* the ceiling */
+  if (M->gc_win == 2 && M->gc_low > top) return 0;      /* the verdict */
+  M->gc_win = 1;
+  M->gc_lends++;
+  return 1;
+}
+
 /* A refusal: counted, the valve and the proof seen to first, then the
  * reserve tier opened and the collector armed -- from ANY headroom, so the
  * garbage that would have covered the request is collected at the next
@@ -1111,6 +1196,7 @@
   g = G(M->L);
   if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) return;
   M->gc_odstate = LJ52_OD_RESERVE;
+  M->gc_win = 0;                        /* THE WINDOW: its cycle decides anew */
   if (M->gc_armed) M->gc_armby = LJ52_ARM_WALL;
   else lj52_gc_arm(M, g, LJ52_ARM_WALL);
 }
@@ -1155,6 +1241,12 @@
       M->gc_hyst = 1;
       M->gc_low = used;
       if (used <= total) M->gc_odstate = LJ52_OD_BURST;   /* repaid */
+      if (M->gc_win) {   /* THE WINDOW: shut, open, or the verdict */
+        top = total + (M->gc_odstate == LJ52_OD_RESERVE ? lj52_gc_odmax(total)
+                                                        : lj52_gc_odmax(total) >> 1);
+        M->gc_win = used <= top ? 0 : used - M->gc_grown > top ? 2 : 1;
+      }
+      M->gc_grown = 0;
       /* THE FLUSH PREDICATE -- at the proof, never at the arm.  The cycle
        * has run to completion and `used` is the heap as it stands after it.
        * Headroom still short means garbage was not what filled the machine,
@@ -1879,7 +1971,8 @@
 }
 
 /* _OCLJ_WALLSTATS() -> overdrafts, od_peak, od_state, park_resets,
- *                      od_limit, kernel_slice, gc_low, armby, hyst
+ *                      od_limit, kernel_slice, gc_low, armby, hyst,
+ *                      window, lends
  *
  * The collector at the wall (docs/roadmap.md; THE CREDIT, THE CADENCE and
  * THE PARK RESET in the collector section).  overdrafts counts growths lent
@@ -1891,7 +1984,8 @@
  * last proof left (lowered by frees), why the last cycle was armed (0 gate,
  * 1 wall or refusal, 2 the flush), and whether a cycle has been proven at
  * all -- what the harness's mem-2 needed to see why a hold got no cycle
- * (2026-10-04).  A separate
+ * (2026-10-04).  window is THE WINDOW's LJ52_GC_LEND (the sandbox's bound is
+ * then used <= cap + od_limit + window), lends the growths it lent.  A separate
  * global, not more _OCLJ_GCSTATS positions: twenty values is LUA_MINSTACK,
  * which is what lets that one push without a checkstack.  Read-only,
  * allocates nothing, raw global -- the sandbox never sees it. */
@@ -1906,7 +2000,9 @@
   lua_pushnumber(L, M ? (lua_Number)M->gc_low : -1);
   lua_pushinteger(L, M ? M->gc_armby : -1);
   lua_pushinteger(L, M ? M->gc_hyst : -1);
-  return 9;
+  lua_pushinteger(L, M ? LJ52_GC_LEND : -1);
+  lua_pushinteger(L, M ? M->gc_lends : -1);
+  return 11;
 }
 
 /* Installed by lj52_newstate as the raw global _OCLJ_WATCHDOG. */
```

## 3. The bound (R5)

For every growth granted outside the norefuse window:

    sandbox thread:              used + delta  <=  T + G(T) + L
    kernel thread:               used + delta  <=  T + G(T) + K
    under HOOK_GC or GCSTOP:     used + delta  <=  T
    every thread (L <= K):       used + delta  <=  T + G(T) + K  <=  T + 512 KiB + 16 KiB     (unchanged)

    with L = 4 KiB, K = 16 KiB, G(T) = clamp(T/16, 32 KiB, 512 KiB).

**Derivation.** A growth is granted on exactly one of three paths:
- **(a)** U + d ≤ T (the fast test);
- **(b)** U + d ≤ T + c, the credit: c ∈ {G/2, G}, + K for the kernel, 0 under HOOK_GC or GCSTOP;
- **(c)** the lend. This returns 1 only if the thread is not the kernel's, HOOK_GC and GCSTOP are clear, and U + d ≤ T + c_sandbox + L with c_sandbox ≤ G.

**Properties.**
- **Absolute.** The right-hand sides depend only on T, the tier (RESERVE is the maximum, reached only by refusals, and idempotent) and the thread. `gc_win` chooses only between lending and refusing under that ceiling. So caught refusals cannot ratchet it: a refusal shuts the window, and at most the next crossing is lent, still under the same ceiling.
- **Charged.** The lent bytes are in `used`, so getFreeMemory reads 0.
- **Outside the bound, as today:** the norefuse window and a cap set under the heap.

**Measured.**
- **W7**, 4000 caught attempts as the sandbox: od_peak 36 846 = G + 4 078 ≤ G + L. The window filled to its ceiling, one lent growth per refusal.
- **W7k**, the same as the kernel: od_peak 49 140 = G + K − 12.
- **Probe sweeps:** the largest sandbox excursion was G + 1 888 (record, JIT on: 34 656 − 32 768).

## 4. Every transition

State: ARM ∈ {UNARMED, ARMED}, TIER ∈ {BURST, RESERVE}, HIST (FRESH, or PROVEN with `gc_low`), WIN ∈ {0 shut, 1 open, 2 verdict}, GROWN, FLAG.

| event | transition |
|---|---|
| growth, record ARMED | first `pressure(FREE)`: PROOF (below) if the cycle completed, else the park reset; not counted by the valve |
| growth, U + d ≤ T + credit | grant; GROWN += d; `pressure(GROW)` as today |
| sandbox growth, T + credit < U + d ≤ S + L, no standing verdict | LEND: WIN = 1; lends++; grant; GROWN += d; `pressure(GROW)`: THE CADENCE arms if unarmed (past S, regime P always arms; F and B arm past T) |
| sandbox growth past S + L, or under the verdict (WIN = 2 and `gc_low` > S) | REFUSE |
| kernel growth past S + K | REFUSE (no window) |
| REFUSE | refusals++; `pressure(TRY)`; past the guards (busy, norefuse, no L, T ≤ 0, HOOK_GC, GCSTOP): TIER = RESERVE, **WIN = 0**, arm or relabel WALL. All as today except WIN. |
| PROOF (white flipped at GCSpause; any kind, including the observation before a growth) | as today (UNARMED, collects++, `gc_low` = U, U ≤ T → BURST, FLAG if armby ≠ FLUSH and T − U < w/2); then if WIN ≠ 0, WIN = (U ≤ S) ? 0 : (U − GROWN > S) ? 2 : 1; then GROWN = 0 |
| unarmed pressure (THE CADENCE) | unchanged |
| valve bailout | as today (UNARMED, no proof). WIN and GROWN untouched; the next lend's grant re-arms through the cadence. |
| free | `pressure(FREE)` before the free, as today (it may PROVE) |
| **on trace** | The same allocator calls. A lend only grants; the cadence's arm writes the same two scalars it writes today. The window's cycle bails at atomic on trace and completes at the trace exit (u2-checkpoints §3); its proof is read at the next growth, before the decision. No collection in the allocator (C1). |
| **HOOK_GC** (a finalizer) | credit 0, lend 0; `pressure` and `refused` return at their guards: hard cap T, WIN untouched |
| **host GCSTOP** (eris persist/unpersist) | the same as HOOK_GC (`threshold == LJ_MAX_MEM`) |
| **norefuse** (`lj52_pushcfunction`) | the predicate is skipped, and the observation's `pressure` returns at its guard: granted and charged as today; GROWN counts it (harmless) |
| **csync / legacy** | The same rule: the legacy predicate gains `|| lj52_gc_lend(M, total, used, delta)` with Java's per-call T and U, as the credit has, and a GROWN add on its grant path. Measured identical to C mode (probe2 legacy: 0 outside; reserve form legacy: 0). |
| **cap change** (settotal, Java's total, OC's Int.MaxValue around persist) | Nothing written. The verdict is read against the current S, so a raised cap voids it. A lowered cap with WIN 0 or 1 lends up to S + L, then the proofs decide. |
| **fresh record** (eris load) | `calloc`: WIN = 0, GROWN = 0. The fresh-record rule is unchanged (it is reached through `lj52_gc_credit`, before the lend). The first crossing after a load opens a window like any other; nothing must cross eris. |
| **the kernel slice** | The kernel's tops stay S + K, hard, and it gets no window. The sandbox's ceiling S + L lies inside the slice. When the kernel's slice took the heap past S between resumes, the sandbox's first growth is a crossing: lent if within S + L. |
| **the flush predicate** | Unchanged. A window's cycle is armed by the cadence (why = WALL past the cap), so its proof can raise FLAG exactly as today's wall proofs do. |
| **THE CADENCE** | Unchanged in code. Its existing "any unarmed growth past S arms" is what arms every window. Cost: §6.3. |

## 5. The residual, in one sentence

A crossing is still refused wherever it lands in two cases:
- its window is overrun before a checkpoint proves a cycle: more than `LJ52_GC_LEND` in one checkpoint-free stretch (a table or stack growth, a large allocate-first result), a single request past S + L (W9's class), or the kernel spending more than L of its slice past the sandbox's top between resumes with no checkpoint;
- the garbage that tips a proof past the top was pinned across two consecutive cycles (a stale register that outlives two checkpoints), so the verdict is false where the refused allocation would have found room.

## 6. Measured

**Builds.** Both the prototype object (F2) and the stage-C object (`wall2/objC`, md5 `0259f0d1`) are linked exactly as run-mem.sh links mem_test. `lj_repro.c` is u2-repro's driver, built with `-DFIXSEED` and the `--wrap` (fixed string-hash seed 1) unless stated.

**Machine state.** Two resident JVMs were idle (4 % CPU load) while this ran. The timing figures (§6.3) are A/B interleaved ratios, three repetitions; the counts do not depend on load.

### 6.1 mem_test (`mem_test_d2.c`, 72 checks)

**The prototype (F2), 30 runs, random string-hash seed:**
- 30 of 30 read `checks=72 failures=0` (`out19/F2_*.log`).
- **W16:** inside 96, outside 0, every run.
- **W16R and W16Rj:** second refusal inside 96 of 96, every run.

**Stage C, 10 runs, the same copy:** 10 of 10 read `checks=72 failures=3`, exactly W16, W16R and W16Rj (`out19/C_*.log`).
- **W16:** 6 covered stalls (9 runs) or 7 (1 run).
- **W16R:** 5 (7 runs) or 6 (3 runs).
- **W16Rj:** every run inside 56, stall 32, sandbox down 8, with 34 covered.
- **W7, re-scoped:** passes on stage C too (window reads 0).
- **W7k:** passes on both.

**Numbers that moved** (prototype; stage C in brackets):

| case | prototype | stage C |
|---|---|---|
| W12, worst W1 round | 23 cycles (bound 32) | 21 |
| W4, near phase | 40 collects (bound 61) | 39 |
| W7 | collects +4029 for 3955 refusals; od_peak 36 846 (G + 4 078) | +3976; 32 710 |
| W7k | od_peak 49 140 = G + K − 12; used 353 930 against cap 304 790 | — |

**Unchanged:**
- **W9** (INFO) still reads "tries made 20". It runs as the kernel, so it has no window, and its single request is past any window anyway.
- **W1, W1L, W1j, W8, W2b, W2c, W2d, W3, W10, W11, C6 and M6b:** pass with the same results.

### 6.2 Outside-the-handler landings, the sweeps

Classified by the run's first terminal event. "Covered" means that the live set, measured where the run landed (two collections in place), plus 256 B (W16's largest outside object) fits under the tier's top. In the no-arm configuration the program runs as the kernel, whose top is + K, so "covered" there is not meaningful.

#### probe2 (the capacity probe's shape): 4 shapes x 4096 caps (off 0..65535 step 16, cap = base + 384 KB + off) unless stated

| configuration | shape | runs (C / F2) | stage C: outside (stall/down) [covered] | prototype: outside (stall/down) [covered] | collects/run C -> F2 |
|---|---|---|---|---|---|
| default (JIT off, arm, paint) | array | 4096 / 4096 | 53 (30/23) [53] | 0 (0/0) [0] | 28.4 -> 33.3 |
|  | closure | 4096 / 4096 | 78 (45/33) [78] | 0 (0/0) [0] | 29.8 -> 34.7 |
|  | record | 4096 / 4096 | 47 (12/35) [47] | 0 (0/0) [0] | 31.8 -> 39.1 |
|  | string | 4096 / 4096 | 253 (132/121) [253] | 0 (0/0) [0] | 80.0 -> 100.8 |
| heartbeat every 3rd resume | array | 4096 / 4096 | 53 (30/23) [53] | 0 (0/0) [0] | 28.5 -> 33.4 |
|  | closure | 4096 / 4096 | 79 (45/34) [79] | 0 (0/0) [0] | 29.9 -> 34.8 |
|  | record | 4096 / 4096 | 42 (11/31) [42] | 0 (0/0) [0] | 31.9 -> 39.2 |
|  | string | 4096 / 4096 | 264 (132/132) [264] | 0 (0/0) [0] | 80.5 -> 101.4 |
| no pcall(paint) | array | 4096 / 4096 | 24 (24/0) [24] | 0 (0/0) [0] | 28.3 -> 33.2 |
|  | closure | 4096 / 4096 | 39 (39/0) [39] | 0 (0/0) [0] | 29.4 -> 34.3 |
|  | record | 4096 / 4096 | 15 (13/2) [15] | 0 (0/0) [0] | 31.8 -> 38.7 |
|  | string | 4096 / 4096 | 143 (132/11) [143] | 0 (0/0) [0] | 79.0 -> 99.1 |
| JIT on | array | 4096 / 4096 | 54 (26/28) [49] | 0 (0/0) [0] | 25.0 -> 27.6 |
|  | closure | 4096 / 4096 | 52 (30/22) [52] | 0 (0/0) [0] | 30.9 -> 35.6 |
|  | record | 4096 / 4096 | 57 (18/39) [51] | 0 (0/0) [0] | 28.7 -> 33.2 |
|  | string | 4096 / 4096 | 345 (166/179) [190] | 0 (0/0) [0] | 74.3 -> 72.0 |
| legacy (dropin) path | array | 4096 / 4096 | 53 (30/23) [53] | 0 (0/0) [0] | 28.4 -> 33.3 |
|  | closure | 4096 / 4096 | 78 (45/33) [78] | 0 (0/0) [0] | 29.8 -> 34.7 |
|  | record | 4096 / 4096 | 47 (12/35) [47] | 0 (0/0) [0] | 31.8 -> 39.1 |
|  | string | 4096 / 4096 | 253 (132/121) [253] | 0 (0/0) [0] | 80.0 -> 100.8 |
| string-hash seed 7 | array | 4096 / 4096 | 53 (30/23) [53] | 0 (0/0) [0] | 28.4 -> 33.3 |
|  | closure | 4096 / 4096 | 78 (45/33) [78] | 0 (0/0) [0] | 29.8 -> 34.7 |
|  | record | 4096 / 4096 | 43 (12/31) [43] | 0 (0/0) [0] | 31.8 -> 39.1 |
|  | string | 4096 / 4096 | 253 (132/121) [253] | 0 (0/0) [0] | 80.0 -> 100.8 |
| cap base + 1 MB (G ~ 72 KB), 1024/shape | array | 1024 / 1024 | 21 (9/12) [21] | 0 (0/0) [0] | 39.9 -> 46.3 |
|  | closure | 1024 / 1024 | 19 (7/12) [19] | 0 (0/0) [0] | 38.0 -> 44.5 |
|  | record | 1024 / 1024 | 11 (3/8) [11] | 0 (0/0) [0] | 35.6 -> 42.9 |
|  | string | 1024 / 1024 | 63 (31/32) [60] | 0 (0/0) [0] | 92.0 -> 112.6 |
| cap base + 1 MB, JIT on, 1024/shape | array | 1024 / 1024 | 18 (3/15) [18] | 0 (0/0) [0] | 36.3 -> 38.8 |
|  | closure | 1024 / 1024 | 19 (9/10) [19] | 0 (0/0) [0] | 40.9 -> 46.8 |
|  | record | 1024 / 1024 | 9 (4/5) [9] | 4 (4/0) [0] | 33.8 -> 37.8 |
|  | string | 1024 / 1024 | 63 (37/26) [50] | 0 (0/0) [0] | 90.5 -> 85.6 |
| cap base + 2 MB (G ~ 136 KB), 1024/shape | array | 1024 / 1024 | 24 (12/12) [24] | 0 (0/0) [0] | 43.4 -> 49.9 |
|  | closure | 1024 / 1024 | 19 (11/8) [19] | 0 (0/0) [0] | 42.1 -> 48.6 |
|  | record | 1024 / 1024 | 11 (5/6) [11] | 0 (0/0) [0] | 39.0 -> 46.0 |
|  | string | 1024 / 1024 | 69 (33/36) [69] | 0 (0/0) [0] | 99.8 -> 120.9 |
| junk 8, 1024/shape | array | 1024 / 1024 | 12 (8/4) [12] | 0 (0/0) [0] | 25.3 -> 29.7 |
|  | closure | 1024 / 1024 | 15 (6/9) [15] | 0 (0/0) [0] | 26.2 -> 30.5 |
|  | record | 1024 / 1024 | 11 (6/5) [11] | 0 (0/0) [0] | 29.8 -> 36.1 |
|  | string | 1024 / 1024 | 62 (31/31) [62] | 0 (0/0) [0] | 69.0 -> 86.9 |
| junk 96, 1024/shape | array | 1024 / 1024 | 3 (0/3) [3] | 0 (0/0) [0] | 43.6 -> 52.5 |
|  | closure | 1024 / 1024 | 6 (0/6) [6] | 0 (0/0) [0] | 44.6 -> 53.5 |
|  | record | 1024 / 1024 | 4 (0/4) [4] | 0 (0/0) [0] | 45.0 -> 56.1 |
|  | string | 1024 / 1024 | 37 (17/20) [37] | 0 (0/0) [0] | 136.9 -> 176.0 |
| AMPLIFIED: batch 10 | array | 4096 / 4096 | 672 (364/308) [672] | 0 (0/0) [0] | 35.1 -> 41.5 |
|  | closure | 4096 / 4096 | 648 (426/222) [584] | 0 (0/0) [0] | 36.1 -> 42.3 |
|  | record | 4096 / 4096 | 565 (198/367) [565] | 0 (0/0) [0] | 37.1 -> 46.0 |
|  | string | 4096 / 4096 | 3386 (1417/1969) [3005] | 0 (0/0) [0] | 102.5 -> 137.5 |
| AMPLIFIED: batch 10, JIT on (stage C crashed, sec. 8) | array | 4096 / 4096 | 432 (276/156) [374] | 0 (0/0) [0] | 38.4 -> 42.0 |
|  | closure | 0 / 4096 | 0 (0/0) [0] | 0 (0/0) [0] | 0.0 -> 44.9 |
|  | record | 4096 / 4096 | 444 (158/286) [431] | 0 (0/0) [0] | 42.3 -> 45.9 |
|  | string | 526 / 4096 | 375 (140/235) [106] | 9 (9/0) [0] | 126.9 -> 140.2 |
| no watchdog arm (all kernel context; harness-only) | array | 4096 / 4096 | 30 (30/0) [0] +8 other | 26 (26/0) [0] +8 other | 29.8 -> 32.0 |
|  | closure | 4096 / 4096 | 30 (30/0) [0] +8 other | 24 (24/0) [0] +8 other | 31.0 -> 33.4 |
|  | record | 4096 / 4096 | 18 (15/3) [0] +14 other | 25 (25/0) [0] +8 other | 33.4 -> 36.7 |
|  | string | 4096 / 4096 | 132 (121/11) [0] +33 other | 66 (66/0) [0] +22 other | 84.6 -> 93.4 |

#### The W16 program (`w16probe_m.lua`) and its reserve-tier form (`w16rprobe_m.lua`): 4096 caps each

| configuration | shape | runs (C / F2) | stage C: outside (stall/down) [covered] | prototype: outside (stall/down) [covered] | collects/run C -> F2 |
|---|---|---|---|---|---|
| W16 program, JIT off | all | 4096 / 4096 | 168 (146/22) [168] | 0 (0/0) [0] | 81.8 -> 102.6 |
| W16 program, JIT on | all | 4096 / 4096 | 473 (242/231) [236] | 0 (0/0) [0] | 74.3 -> 77.4 |
| W16 in the reserve tier, JIT off | all | 4096 / 4096 | 169 (147/22) [169] | 0 (0/0) [0] | 113.1 -> 149.9 |
| W16 in the reserve tier, JIT on | all | 4096 / 4096 | 1847 (1485/362) [1804] | 0 (0/0) [0] | 86.2 -> 102.5 |
| W16 in the reserve tier, legacy | all | 4096 / 4096 | 169 (147/22) [169] | 0 (0/0) [0] | 113.1 -> 149.9 |

**Reading.**
- **Every armed configuration** goes to 0 garbage-covered outside landings: from 431 (default), 508 (JIT on), 5 271 (the amplified batch-10 probe) and 1 847 (reserve tier, JIT on).
- **The capacity probe's "done" path** is reached by every prototype run in every probe2 configuration. In the default sweep it was 16 384 of 16 384, against stage C's 15 953. That is R1b, measured on the sandbox.

**Non-covered outside landings remain in two JIT-on configurations:**
- 4 record stalls in the 1 MB-cap JIT-on configuration (live 40 to 700 B past S);
- 9 string stalls in batch-10 JIT-on (live 304 to 368 B past S).

In both, the live data really is past the top. That is stock's class: the program's data does not fit, and the refusal lands where the deciding cycle ran. W16's criterion does not count them. Whether they would be covered with the dispatcher's frame gone, and where they came from, was not traced.

**No arm.** The configuration with no watchdog arm (everything is kernel context, which the shipped kernel never does: `patch-machine-lua.lua` arms every resume and refuses to run without `_OCLJ_WATCHDOG`) keeps 141 stalls (stage C: 210 outside). There is no window by design.

### 6.3 Cost (R9, R12)

**Cycles per fill** (probe2, default, all 4 096 caps per shape):

| shape | stage C | prototype | change |
|---|---|---|---|
| array | 28.4 | 33.3 | +17 % |
| closure | 29.8 | 34.7 | +16 % |
| record | 31.8 | 39.1 | +23 % |
| string | 80.0 | 100.8 | +26 % |

- **JIT on:** array 25.0 → 27.6, closure 30.9 → 35.6, record 28.7 → 33.2, string 74.3 → 72.0.
- **Reserve-tier form** (both tiers' windows): 113.1 → 149.9 (+33 %).
- **Far from the wall:** nothing changes. The window opens only past a tier's top. The hot path gains one branch per growth while armed and one add per grant.
- **At idle:** a machine under its cap never crosses a top, so there is no window and no new arm.

**The last five batches** (`probe2t.lua`: real `os.clock`, which has 1 ms resolution here, and the cycle counter read at each batch's end):
- 1 024 caps per shape, three interleaved repetitions (`out18/`).
- Means over all three repetitions; stage C's means exclude its outside-landing runs, which never report.

| shape | time, stage C → prototype (µs) | ratio | cycles in the last five batches, stage C → prototype |
|---|---|---|---|
| array | 1 025 → 1 241 | 1.21× | 24.3 → 29.2 |
| closure | 1 790 → 2 063 | 1.15× | 25.4 → 30.4 |
| record | 1 600 → 1 933 | 1.21× | 29.7 → 36.8 |
| string | 5 297 → 6 795 | 1.28× | 62.5 → 82.7 |

Per-repetition overall means: stage C 2 281, 2 435 and 2 476 µs; prototype 2 949, 3 040 and 3 034 µs, so a ratio of 1.23 to 1.29.

**Where the extra cycles go.** They come in the band where the live data plus the newest junk straddles the top. There, each crossing is lent and THE CADENCE arms, so a cycle runs per checkpoint until the two-cycle verdict.
- **Stock's rate in the same band:** it collects at every allocation that does not fit.
- **Stage C:** it refused at the first crossing, which is exactly the refusal this design removes.
- **Applied to the in-machine figure:** stage C's last-five ratio to stock was 0.9 to 3.2× in most cells (results-wall §stage C). The hermetic factor of 1.15 to 1.28× would put the prototype at about 1.0 to 4.1× stock, which is not "within stage C's ratios". That is measured hermetically only.

### 6.4 Capacity (R12)

**Mean objects held at the refusal** (probe2, 4 096 caps per shape):

| shape | stage C | prototype | minimum, stage C → prototype |
|---|---|---|---|
| array | 2 060.1 | 2 061.2 | 1 941 → 1 942 |
| closure | 2 000.6 | 2 001.7 | 1 866 → 1 868 |
| record | 1 383.1 | 1 383.6 | 1 288 → 1 290 |
| string | 5 245.1 | 5 249.0 | 4 695 → 4 699 |

**JIT on.** The prototype's string mean is 2.6 % lower (5 151.4 against 5 287.3). The reason is the refusal counts:
- In stage C, 2 139 of 4 096 string runs had their first refusal absorbed (most plausibly by the JIT recorder, u2-stalls §4) and filled on into the reserve tier (mean 5 432).
- With the window, 141 did.
- Like for like (one refusal), the prototype holds 5 141 against stage C's 5 129.

The "second chance" u2-stalls §0.1 names, which preceded every bad in-machine outcome, mostly disappears.

**Against stock.** Capacity is unaffected relative to stock: 1.5 to 2.8× (u2-stalls).

## 7. Test plan

### 7.1 New cases (in `mem_test_d2.c`, generated by `mkmt.py`)

- **W16:** u2-repro's case, unchanged. It fails on stage C (10/10 runs here, 30/30 in u2-repro) and passes on the prototype (30/30).
- **W16R:** W16's program carried into the reserve tier.
  - The step's handler absorbs the first refusal and the fill goes on with its data kept.
  - At the second refusal it records, drops its data and stops, as the probe does.
  - The recorder is first-wins, so an aftermath refusal cannot overwrite the program's own result. The tier is passed in.
  - "Covered" is judged against the tier the landing happened in (cap + G/2 before the first refusal, cap + G after).
  - Same sweep as W16 (96 caps × 64 B).
  - Stage C: 5 or 6 covered stalls in every run. Prototype: 0.
- **W16Rj:** W16R with the JIT on. Stage C: 32 stalls and 8 downs, 34 covered, in every run. Prototype: 0. This is the in-machine shape: u2-stalls' bad outcomes all came at the reserve top, and JIT-on runs absorb more first refusals.
- **W7k:** W7's 4 000 caught attempts made by the kernel (main thread, no arm). It asserts `od_peak ≤ G + slice` and `used ≤ cap + G + slice + 2 KiB`. It pins the bound over every thread, which nothing pinned past the kernel's first refusal before: the `kernelwindow` sabotage passed all 69 existing cases.

**Cost of the suite:** mem_test goes from 0.32 s to about 3.1 s. Each W16-form sweep costs about 0.7 to 1 s. Running W16R at 48 × 128 is an option if that matters.

### 7.2 Changed cases

**W7:** "caught refusals cannot push the heap past cap + G" becomes "… past cap + G + the window". It asserts `peak ≤ od_limit + window`, `window ≤ kernel_slice` and `used ≤ cap + G + window + 2 KiB`.
- **Reason:** the sandbox's bound moved by L, deliberately. The constant over every thread did not, and W7k pins it.
- **Old shims:** on a shim without the window, WALLSTATS[10] reads −1 and is taken as 0, so W7 is unchanged there.

**WALLSTATS** gains `window` (10) and `lends` (11). No existing reader reads past position 9.

**Unchanged, and passing on the prototype:** the 66 other cases, C6 and M6b among them. Those run as the kernel, which has no window.

### 7.3 Sabotages

The run is `sabotage.py`, output in `out19/sabotage.txt`.
- **Method:** exact-line replacement on `final2/lj52shim.c`, the same lines `negative-control.sh` seds, built without `-Wall` as negative-control.sh does, and run with `mem_test_d2.c`.
- **unbounded** was built with `W16_N = 8`. With the full W16_N, the four W16-form sweeps under a credit of the whole cap cost thousands of cycles per cap and passed 300 s.

| sabotage | negative-control.sh's expected set | measured on the prototype + mem_test_d2 | why it moved |
|---|---|---|---|
| 4.1 stopgap | 42 ids | the same 42 + W16 W16R W16Rj W7k | an uncharged state never refuses: the sweeps record nothing inside, and W7k reads no refusals |
| 4.2 nopending | M4b M5 M3c C0b | the same | — |
| 4.3 norefuse | dies after M5 | dies after M5 (exit 0xE24C4A04, M5 passed, no summary) | — |
| 4.4 nopark | W5a W5b | the same | — |
| 4.5 freescount | W5c | the same | — |
| 4.6 nocredit | W1 W1L W1j W2d W3 W8 W10 W11 | the same + W16 W16R W16Rj | A window over a zero credit sits at the cap + L. The proof reads the tier's top, so the verdict rarely fires and refusals come at the ceiling, wherever they land. |
| 4.7 norefusedarm | W2b W2c | the same | — |
| 4.8 nohyst | W4 W12 | the same | — |
| 4.9 unbounded | C3a M5 W1 W11 W12 W1L W1j W2b W7 | the same + W7k | the kernel's bound too |
| 4.10 nokslice | W10 | the same + W16R W16Rj | after the sandbox's second refusal, the kernel's per-resume `table.pack` has no slice (the same failure as W10, in the sweep) |
| 4.11 nofresh | W11 | the same | — |
| 4.12 closereserve | W8 W11 | the same + W16Rj | every proof closes the reserve, so the absorbed first refusal's room is lost |
| 4.13 flushwhole | W15 | the same | — |

**New sabotages:**

| sabotage | edit | measured fails |
|---|---|---|
| nowindow | `lj52_gc_lend` returns 0 | W16 W16R W16Rj |
| noceiling | the ceiling line removed | W7 W11 |
| bigwindow | `LJ52_GC_LEND` 64 KiB (past the slice) | W7 W11 |
| rawverdict | the verdict on the raw heap (`U > S`, no `gc_grown`) | W16 W16R W16Rj |
| lateproof | the observation before the decision removed (both modes) | W16 W16R |
| refusalkeeps | a refusal does not shut the window | W16Rj |
| kernelwindow | the kernel lends too | W7k |

**Housekeeping for negative-control.sh:**
- Its expected sets for 4.1, 4.6, 4.9, 4.10 and 4.12 need the additions above.
- The seven new ones go after 4.13.
- Each new sed target is one textually unique line of the diff:
  - `the ceiling` and `the verdict`, in `lj52_gc_lend`;
  - `M->gc_win = used <= top ? 0 : used - M->gc_grown > top ? 2 : 1;`;
  - the two `/* ... THE WINDOW */` observation lines;
  - `M->gc_win = 0;` in `lj52_gc_refused`;
  - the `lj52_gc_kernel` test in `lj52_gc_lend`.

### 7.4 The in-machine gate (proposed, not run)

1. **The capacity matrix** (`OCLJ_PROBE=capacity`, chains B and C's cells, D/E/O/L arms, stock alongside):
   - stalls and downs at 0 against stage C's 1 in 49 and stage B's 4 in 68;
   - capacity ≥ stage C's like for like;
   - the last-five ratio to stock (the R12 question above);
   - the `CAP-GC` line extended with WALLSTATS `window` and `lends`, and the sandbox's od_peak ≤ G + window.
2. **An amplified probe**, the hermetic analogue measured above as batch 10 (stage C 5 271 / 16 384 outside, the prototype 0):
   - `OCLJ_PROBE=capacity` with BATCH = 10, so the between-batch code (stage string, `event.timer`, `pcall(paint)`, OpenOS's dispatcher) is a tenfold larger share of the bytes, and the stall rate against stock is measurable in a 40-run matrix;
   - plus a JIT-on cell, since the reserve-top landings are JIT-heavy (W16Rj).
3. **Add u2-stalls §5's probe counters** (`entered`, `timed`, `pf`) to attribute any landing that remains.

## 8. An unplanned finding: the stage-C object crashes the process (JIT on)

`out20/`. `lj_repro_Cxf.exe probe2.lua string 10688 10688 16 384 1 1 1 0 0 -1 24 10` (stage-C object, fixed seed 1, JIT on, batch 10) **segfaults**, deterministically. The neighbours 10672 and 10704 do not.

**gdb backtrace:**

    #0 err_unwind  #1 lj_err_unwind_win  ... RaiseException
    #6 lj_err_throw  #7 lj_err_mem  #8 lj_mem_realloc  #9 lj_str_new
    #10 lj_strfmt_num  #11 lj_ff_tostring  #12 lj_ff_coroutine_resume  #13 lua_pcall  #14 main

So a refusal raised in `lj_str_new`'s `lj_mem_realloc` — by its name, the string table's growth — under `tostring(number)`, inside the resumed sandbox, crashed LuaJIT's own unwinder.

**Counts and limits.**
- **Stage C:** 1 crash in 1 024 caps of that configuration (step 64).
- **Prototype:** 0 in the same 1 024, and none in its full 16 384-run batch-10 JIT-on sweep.
- **Why the prototype misses it:** it refuses elsewhere on that trajectory, so this shows only that the crash is reachable, not that the window prevents it.
- **Not investigated:**
  - whether it is the harness (lj_repro's C recorder or its coroutine);
  - a LuaJIT unwinding bug for an ERRMEM raised from a fast function's C path with the JIT on;
  - whether it reproduces in a machine (where it would take the JVM down).

It deserves its own row.

## 9. How the rule was reached (the variants, each measured)

| variant | change | probe2 outside | W16 program outside | other |
|---|---|---|---|---|
| stage C | — | 431 | 168 | reserve + JIT 1 847 |
| V1 (`src_v1`) | lend past S up to L, every lend arms; verdict "last proof's heap > S"; proof read after the grant | 18 downs (all covered by ~100 B) | — | mem_test W16 FAIL 2 downs; W7 FAIL by design |
| V1 + proof first (`src`) | read a completed cycle before the decision | 0 | 19 (11 stalls, 8 downs; covered for the actual 40/80 B request, not for 256 B) | W16 1/96 |
| V2 (`src_v2`) | verdict at the second consecutive over-proof (a grace) | 0 | **35** stalls (worse) | both over-proofs fell on the last iteration's last two checkpoints |
| V3 (`src_v3`) | the two-cycle verdict (`U − gc_grown > S`) | 0 | 0 | reserve + JIT: 21 stalls (M4 shape) |
| V4 (`src_v4`) | V3 + a refusal shuts the window | 0 | 0 | reserve ± JIT 0; probe2 JIT 0 |
| final (`final/`) | V4, the lend's top read from the credit, comments | 0 | 0 | as V4 |
| **final2** (`final2/`) | final minus the lend's own arm and a regime-P line that armed the kernel's crossing of S | 0 | 0 | identical counts in every configuration (`out16/`: sabotages `nolendarm`, `nokarm`, `noarms` against final); collects within 0.1 per run |

**Why the two arms went:**
- **The lend's arm:** THE CADENCE's existing rule arms any unarmed growth past S, and the grant's own pressure call follows every lend.
- **The kernel-crossing arm:** it was meant for M3's general form (the kernel spending more than L of its slice between resumes). It fires only once per crossing from under S. A proof that finds the heap a few bytes past S, as the kernel's own live `res` makes it, stops it, so it cannot keep the heap under S + L.
- **What would cover that case** (not built): retargeting the kernel's regime-P halving at S + L instead of S + K. It costs a cycle per kernel growth while the sandbox sits at its ceiling.

## 10. Requirements

| R | score | why |
|---|---|---|
| R1 | **MET for every measured shape; PARTLY in general** | A crossing that garbage covers is lent, and refused only after two consecutive cycles left the data past the top: 0 garbage-covered outside landings in every armed configuration (§6.2). Refusals come later than stock's in program order (our tops are ≥ cap + G/2). Not met in general for the residual (§5): the window overrun, and garbage pinned across two cycles. 13 non-covered JIT-on outside landings in 20 480 runs are stock's class. |
| R1b | MET | W1, W1L, W1j, W8, W2b, W2c and W10 pass. Every prototype probe2 run reaches the program's "done" path (16 384 of 16 384, stage C 15 953). The room after the first sandbox refusal is ≥ G/2 − L before the reserve top. The kernel keeps ≥ K − L after the sandbox's window (W10). |
| R5 | MET | Every thread: used + delta ≤ T + G + K, unchanged (W7k). Sandbox: ≤ T + G + L (W7 re-scoped, `window ≤ slice` asserted). Absolute, charged, not ratchetable (§3). Measured: sandbox od_peak ≤ G + 4 078 (W7), kernel ≤ G + K − 12 (W7k). |
| R6 | MET | No collection in the allocator. The lend writes only record fields; arming is THE CADENCE's existing arm. The observation before a growth runs today's armed branch (two compares, maybe the stepmul restore). On trace, HOOK_GC, GCSTOP, norefuse and the valve are defined in §4. |
| R7 | MET | Zero LuaJIT lines; about 43 code lines in the shim; the collector gate untouched; every sabotage anchor intact and unique. |
| R8 | MET | The window state is transient: shut by every refusal, decided at every proof, zero on a fresh record. The verdict is read against the current top, so the Int.MaxValue persist cap, cap changes and GCSTOP need nothing. The fresh-record rule is unchanged. |
| R9 | **PARTLY** | Unchanged far from the wall and at idle. At the wall, +16 to +26 % cycles per fill and +20 to +32 % in the last five batches (§6.3): a cycle per crossing while live data plus the newest junk straddles the top (stock's rate there) instead of stage C's halving-then-refuse. W4 40 (39), W12 23 (21), within their bounds. |
| R10 | MET (hermetic); in-machine gate proposed | W16 fails on stage C 10/10 and passes 30/30. The new W16R and W16Rj fail on stage C 10/10 and pass 30/30. W7 is re-scoped with a reason. Each new rule has a sabotage that fails (§7.3). The amplified probe was measured hermetically (batch 10: 5 271 → 0); the in-machine matrix was not run. |
| R11 | MET | `LJ52_GC_LEND` is a compile-time constant; there is no knob; OC's RAM scale is inherited. |
| R12 | **PARTLY** | Capacity ≥ stage C's like for like, and far above stock. Near-wall time is 1.15 to 1.28× stage C's hermetically, so not within stage C's ratios. Measured hermetically only. |

## 11. Not checked, and caveats

- **Nothing ran in a machine.** OpenOS's real dispatcher and `event.timer` are modelled (u2-repro §9). The amplified-probe and matrix figures are hermetic.
- **The 13 non-covered JIT-on outside landings** (§6.2) were not traced; with frames gone some might be covered.
- **The stage-C crash (§8)** was not investigated beyond the backtrace.
- **"Covered" here is measured in place** (frames intact) for the probe forms, and after the frames are gone for mem_test's W16. The two can differ by a stale register (§1, the pinned-frame answer).
- **A cycle already in progress when a window opens** (its mark begun before the crossing) can give the window's first proof. It would need a second over-proof to become a verdict. I did not measure how often a window opens mid-cycle; near the wall the shim's stepmul-0 cycles start and finish inside one checkpoint, so it should be rare off trace.
- **L = 4 KiB was not tuned.** It must stay ≤ K; I did not sweep 1, 2 or 8 KiB. W7's measured peak sits 18 B under its new bound, because the window fills to its ceiling in W7's loop by construction.
- **Timing used a 1 ms clock** (means over thousands of runs) with two idle JVMs resident; the ratios are interleaved, same-run.
