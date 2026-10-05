# d2-final: THE WINDOW, the design to build

Roadmap row: "A refusal at a credit tier's top can land outside the program's handler" (docs/roadmap.md:159), round 2, synthesis.

**Base.** Both judges recommended d2-lend's `final2` (THE WINDOW): safety 7/10, practice 8/10. This document builds it with the grafts the judges named. Each graft is either taken, or rejected with a measured reason (§9). A new prototype was built and measured from scratch.

**Where everything is.**
- All work is in `scratchpad/wall2/d2-final/`; paths below are relative to it.
- The repo was never edited: it is at HEAD d9080d4 and `git status` is clean.
- Every diff below passes `git apply --check` against it.
- Nothing was cleared; each measurement went to a fresh `out*/` directory.

**Objects** (build-native.sh's compile line plus `-DLJ52_ADDITIVE`):

| object | md5 | note |
|---|---|---|
| stage C | `0259f0d1…` | Rebuilt here byte for byte from the repo source with that line (`origsrc/`). |
| final | `d124218684bc7fbf3bb2fd150bf237f5` | Source `lj52shim.c`, md5 `5612639c…`. Warning-clean under `-Wall -Wextra`. |
| d2-lend `final2` | `2e1d8f6e…` | Used here only as a same-run reference for timing. |

---

## 0. In one page

**The rule.** A growth by the sandbox that would pass its tier's top S is lent. S is cap + G/2 in the burst tier and cap + G in the reserve tier, with G = clamp(cap/16, 32 KiB, 512 KiB).
- The lend goes up to `LJ52_GC_LEND` = 4 KiB past S, and it arms the cycle that will decide it.
- The window stays open until a proven cycle says what the heap holds:
  - back under S: the window shuts;
  - past S even without the bytes granted since the previous proof, i.e. data that survived two consecutive cycles: **the verdict**, and the next crossing is refused;
  - otherwise it stays open.
- A growth that would pass the cap first observes a cycle that has ended (**the look**), so the decision reaches the first allocation after the deciding cycle.
- A refusal shuts the window.
- The kernel gets no window: its 16 KiB slice lies past every window, and this is checked at compile time.

**The bound.** Every thread: used + delta ≤ cap + G + 16 KiB, unchanged. The sandbox's own bound moves from cap + G to cap + G + 4 KiB.

**What changed from `final2`.** Every item was measured.

| change | where it came from | effect |
|---|---|---|
| The window arms its own cycle | safety graft 1 | — |
| The look is a named function, `lj52_gc_look` | practice graft 2, in spirit | — |
| The look runs only on the slow path | this synthesis | Below the cap the allocator is stage C's, byte for byte. Idle cost is identical to stage C's, where `final2` was +1. |
| `#error` if `LJ52_GC_LEND > LJ52_GC_KSLICE` | both judges | — |
| `_OCLJ_WALLSTATS` grows 9 → 13: window, lends, win, refused | this synthesis | `refused` is the last refused request's size. It is a diagnostic for the tests and the in-machine attribution, not logic: every JIT-off sweep TSV is byte-identical with and without it. |

The tests take every graft except one (§9). The W16 family's "covered" is judged with R1's own words: live data, measured with the sandbox suspended where it landed, plus the refused request.

**Measured: final against stage C.** All hermetic, fixed string-hash seed unless stated.

| measure | stage C | final |
|---|---|---|
| mem_test_final, 76 checks, random seeds | 10/10 runs fail exactly W16, W16R, W16Rj, W17 | **30/30 pass** |
| probe2 outside the handler, 16 384 caps, JIT off | 423, all garbage-covered | **0** |
| probe2, JIT on | 625 | **0** |
| amplified (batch 10), JIT off | 5 274 | **0** |
| amplified (batch 10), JIT on, 16 384 caps | 2 206 in 12 881 (the process crashes at string off 9488) | **1**, not covered |
| W16 reserve-tier form, JIT on | 1 847 | **0** |
| "second chances" (≥ 2 refusals), JIT on | 2 899 / 16 384 | 182 |
| unwinder crash census, one process per cap | 1 / 4 096 (off 9488, fixed and random seed alike) | **0 / 18 432** |
| last five batches: time | 1.00× | **1.14–1.24×** (d2-lend `final2`, same run: 1.15–1.32×) |
| last five batches: cycles | 1.00× | 1.17–1.25× |
| capacity, like for like | — | ≥ stage C in every shape |
| idle below the cap | — | identical to stage C |

**FATALs.** Both were verdict's, and neither is inherited (§10):
- The kernel refused at caps above 2 MiB is impossible here: the window is a constant ≤ the slice. W18 pins it at 4 and 10 MB.
- The unwinder segfault: the final object reaches it 0 times in 18 432 processes. It stays latent on stage C (1 in 4 096) and needs its own row.

**Open for the user** (§12):
1. The kernel's guaranteed room drops from 16 to 12 KiB.
2. The unwinder crash: open its own row.
3. The never-verdict churn band.
4. Near-wall cost of 1.14–1.24×.
5. The in-machine gate, specified in §8, must run before anything lands.

**Residual** (§13): a crossing whose window is overrun before a checkpoint can prove its cycle, or whose verdict rests on garbage pinned across two consecutive cycles, is still refused wherever it lands — measured mainly as kernel garbage between resumes (0 at 512 B per resume, 85 of 4 096 sandbox downs at 2 KB), and 0–7 JIT-on landings per sweep with the live data at the top.

---

## 1. The rule

**Notation.**
- T: the cap the call sees (`M->total` in C mode, Java's `total` in legacy).
- U: the accounted heap before the call.
- d: the growth.
- G = clamp(T >> 4, 32 KiB, 512 KiB).
- K = `LJ52_GC_KSLICE` = 16 KiB.
- L = `LJ52_GC_LEND` = 4 KiB.
- S: the sandbox's tier top, T + G/2 in BURST and T + G in RESERVE. This is T plus `lj52_gc_credit()` for a sandbox thread.
- The kernel (wd_depth 0, or the thread that made the outermost arm) has tops S + K, as before.

**A growth (d > 0)**, accounted, outside norefuse:

1. **The look** (`lj52_gc_look`), only when U + d > T (the slow path).
   - If a cycle is armed and has ended (white flipped, GCSpause), it is proven now, before the decision. Its figure is the heap the cycle left.
   - It is the armed branch of `lj52_gc_pressure`, called as a FREE so that the valve does not count it.
2. **Fast test, then the credit** (unchanged): U + d ≤ T + credit is granted.
3. **Otherwise the window** (`lj52_gc_lend`). It is never used by the kernel's thread, and never under HOOK_GC or a host GCSTOP (credit 0 there as before).
   - U + d > S + L: refused (**the ceiling**).
   - `gc_win == 2` and `gc_low > S`: refused (**the verdict**). This is read against the current S, so a raised cap or an opened reserve tier voids it.
   - Otherwise lend: `gc_win = 1`, `gc_lends++`, arm the cycle if unarmed (why = WALL), grant and charge.
4. **Refuse.** `gc_refdelta = d` (diagnostic), then today's `lj52_gc_refused` plus one line: `gc_win = 0`.

**Every granted growth** adds d to `gc_grown`, the bytes granted since the last proof.

**At every proof** (the armed branch of `lj52_gc_pressure`, any kind). After today's work (gc_low = U, the tier repaid if U ≤ T), if the window is open, with S for the tier as it now stands:
- U ≤ S: `gc_win = 0`, shut;
- U − `gc_grown` > S: `gc_win = 2`, the verdict;
- otherwise `gc_win = 1`.

Then `gc_grown = 0`.

**Why each part is there.** Each part was measured in this round; the table also shows what test removing it fails.

| part | without it | sabotage → fails |
|---|---|---|
| lend past S | stage C: 423 outside / 16 384 (probe2), 169 (W16 form) | nowindow → W16 W16R W16Rj W17 W19 |
| the ceiling S + L | the bound goes | noceiling → W7 W11 W18 W19 |
| two-cycle verdict | a proof run at the batch's last checkpoint counts the frame's junk | rawverdict → W16 W16R W16Rj |
| the look | the decision reaches the second allocation after the deciding cycle, a between-batch one (event.timer's record in W16). Without it: probe-form W16 sweep 30 outside, reserve form 29 (all covered), JIT-on 7 / 11 / 11 / 6 | nolook → W16 W16R |
| a refusal shuts | the caught refusal's own cycle never decides | refusalkeeps → W16Rj W19 |
| no kernel window | the kernel's tops stop being hard | kernelwindow → C6b W7k |
| the window's own arm | nothing alone (THE CADENCE arms the same grant through regime P) | nolendarm → none; nocadencetop → none; both → W17 |

---

## 2. The code change

`native/lj52shim.c`:
- +170 / −21 lines. Of those, 54 added and 3 removed are code; the rest are comments.
- Zero LuaJIT lines. The collector gate's grep (build-native.sh:299-301, :340) finds 0 matches.
- Every negative-control.sh anchor is still present exactly once, the closereserve line at its 6-space indent included.
- `lj52shim.h` is unchanged.

This is the full diff (`d2-final-shim.diff`):

```diff
--- a/native/lj52shim.c
+++ b/native/lj52shim.c
@@ -277,6 +277,10 @@
   long long     gc_seentotal;  /* the cap the last allocator call was under   */
   volatile long gc_overdrafts; /* growths granted past the cap, on credit     */
   long long     gc_odpeak;     /* the largest excursion past the cap, bytes   */
+  int           gc_win;        /* THE WINDOW: 0 shut, 1 open, 2 the verdict   */
+  long long     gc_grown;      /* bytes granted since the last proof          */
+  volatile long gc_lends;      /* growths lent past a tier's top: diagnostics */
+  long long     gc_refdelta;   /* the last refused request, bytes: diagnostics */
   /* -- the trace flush under pressure; see FLUSHING TRACES below -- */
   int           gc_flush_wanted;  /* a PROVEN cycle left headroom short:      */
                                   /* flush at the next safe point (wd_arm)    */
@@ -294,10 +298,13 @@
 #define LJ52_GP_FREE 0                  /* a free or a shrink               */
 #define LJ52_GP_GROW 1                  /* a growth that was granted        */
 #define LJ52_GP_TRY  2                  /* a growth that was refused        */
-/* THE CREDIT at the cap, and the refusal that opens its reserve tier; both
- * defined with the collector, below the LuaJIT-internal includes. */
+/* THE CREDIT at the cap, the refusal that opens its reserve tier, and THE
+ * WINDOW past a tier's top (its look and its lend); all defined with the
+ * collector, below the LuaJIT-internal includes. */
 static long long lj52_gc_credit(lj52_mem *M, long long total, long long used);
 static void lj52_gc_refused(lj52_mem *M, long long total, long long used);
+static void lj52_gc_look(lj52_mem *M, long long total, long long used);
+static int lj52_gc_lend(lj52_mem *M, long long total, long long used, long long delta);
 
 /* The record for L, or NULL for a state this shim did not create. */
 static lj52_mem *lj52_memof(lua_State *L) {
@@ -344,6 +351,9 @@
  *      knowing whether realloc succeeded, so a failed resize permanently
  *      inflates the machine's usage.  Ours charges after the fact.
  *
+ * And it refuses later than the cap: THE CREDIT and THE WINDOW lend a
+ * bounded excursion past it, and arm the collector to repay it.
+ *
  * norefuse is the other half of this change; see lj52_pushcfunction. */
 /* The Java side stores used/total as jint, so that is what crosses the JNI
  * boundary -- but the arithmetic in between is done in long long and saturated
@@ -395,14 +405,19 @@
       M->used += delta;
       return NULL;
     }
+    if (acct && delta > 0 && M->total - M->used < delta)
+      lj52_gc_look(M, M->total, M->used);   /* THE WINDOW: a finished cycle first */
     if (acct && delta > 0 && !M->norefuse && M->total - M->used < delta
-        && M->total + lj52_gc_credit(M, M->total, M->used) - M->used < delta) {
+        && M->total + lj52_gc_credit(M, M->total, M->used) - M->used < delta
+        && !lj52_gc_lend(M, M->total, M->used, delta)) {
+      M->gc_refdelta = delta;
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
@@ -457,12 +472,16 @@
     M->used += delta;
     return NULL;
   }
+  if (delta > 0 && total - used < delta)
+    lj52_gc_look(M, total, used);           /* THE WINDOW: a finished cycle first */
   if (!(total <= 0 || delta <= 0 || total - used >= delta || M->norefuse
-        || total + lj52_gc_credit(M, total, used) - used >= delta)) {
+        || total + lj52_gc_credit(M, total, used) - used >= delta
+        || lj52_gc_lend(M, total, used, delta))) {
     /* We are at the wall, past the credit too.  We still do not collect
      * here -- C1/C5/C6 -- but the refusal arms, from any headroom, and opens
      * the credit's reserve tier for whatever the program does next: see
      * THE CREDIT, in the collector section. */
+    M->gc_refdelta = delta;
     lj52_gc_refused(M, total, used);
     return NULL;                        /* -> lj_err_mem -> LUA_ERRMEM */
   }
@@ -470,6 +489,7 @@
   if (p != NULL) {
     M->setmem(env, obj, lj52_clampi(used + delta));
     M->used += delta;
+    if (delta > 0) M->gc_grown += delta;
     lj52_gc_pressure(M, total, used + delta, delta > 0 ? LJ52_GP_GROW : LJ52_GP_FREE);
   }
   return p;
@@ -934,8 +954,9 @@
  * bounded credit, charged like any other, and the collector armed to repay
  * it at the next checkpoint.  G = total/16, clamped to 32 KB..512 KB:
  *   - BURST, the default tier: up to G/2 past the cap.  Before any refusal
- *     the heap stops at total + G/2, so when the refusal comes at least G/2
- *     is left for what the program does next;
+ *     the heap stops at total + G/2 (+ THE WINDOW below, for the sandbox),
+ *     so when the refusal comes at least G/2 (G/2 - LJ52_GC_LEND) is left
+ *     for what the program does next;
  *   - RESERVE, after a refusal: up to G.  The refusal opens it; a proof that
  *     finds the heap back under the cap closes it.  A proof that does not --
  *     the cycle ran before the program dropped its data -- leaves it open,
@@ -953,17 +974,20 @@
  *     land too), or the thread that made the outermost arm (the kernel after
  *     coroutine.resume returned and before the disarm; cur_L is restored to
  *     the resumer, vm_x64.dasc:1625).  The sandbox that spent both tiers
- *     cannot take the kernel down with it on the table.pack it does after
- *     every resume (machine.lua).
+ *     and its window cannot take the kernel down with it on the table.pack
+ *     it does after every resume (machine.lua): the kernel keeps
+ *     LJ52_GC_KSLICE - LJ52_GC_LEND past the sandbox's ceiling.
  * No credit at all where nothing could repay it: under HOOK_GC (a finalizer;
  * PUC's cap is hard there too) and under a host GCSTOP.  The bound is
- * absolute, not incremental: used + delta <= total + G (+ the slice) for
- * every growth outside the norefuse window, so caught refusals cannot
- * ratchet it (mem_test W7), and the excursion is charged -- getFreeMemory
- * reads 0, both Java sides clamp it there.  What it does not fix: a single
- * request larger than headroom + credit, retried with no checkpoint between
- * the tries (mem_test W9, printed, not asserted), is refused where PUC would
- * collect and succeed; any checkpoint between the tries cures it.
+ * absolute, not incremental: used + delta <= total + G + the slice for
+ * every growth outside the norefuse window -- the sandbox's own, total + G
+ * + LJ52_GC_LEND, inside it -- so caught refusals cannot ratchet it
+ * (mem_test W7, W7k), and the excursion is charged -- getFreeMemory reads
+ * 0, both Java sides clamp it there.  What it does not fix: a single
+ * request larger than headroom + credit (+ the window), retried with no
+ * checkpoint between the tries (mem_test W9, printed, not asserted), is
+ * refused where PUC would collect and succeed; any checkpoint between the
+ * tries cures it.
  *
  * THE CADENCE (2026-10-04).  Until this change, once a proven cycle left the
  * heap inside the watermark, the very next allocator call armed again, so
@@ -978,7 +1002,12 @@
  *     to the top of the current tier -- the kernel's slice included, when it
  *     is the kernel allocating -- has halved since that proof.  Halving, not
  *     every grant: a program holding data past the cap pays log2 cycles per
- *     tier, and one that drops its data is repaid within half the tier.
+ *     tier, and one that drops its data is repaid within half the tier;
+ *   - past the tier's top itself, THE WINDOW below arms instead: each
+ *     sandbox crossing it lends demands the cycle that decides it, so a
+ *     program whose live data and newest garbage straddle the top pays a
+ *     cycle per crossing there -- stock's rate, which collects at every
+ *     allocation that does not fit.
  * mem_test W4: 20000 64-byte tables over 256 KB live with 64 KB of headroom
  * took 10000 full cycles (one per checkpoint pair) before; the bound now is
  * three times stock's count.  A fill of 512 KB of live 64-byte tables to
@@ -999,6 +1028,69 @@
  * proof inside the watermark; halving the gate gives it that, at log2
  * cost.
  *
+ * THE WINDOW (2026-10-05; docs/roadmap.md, "A refusal at a credit tier's
+ * top can land outside the program's handler").  THE CREDIT moved the
+ * refusal from the cap to a tier's top, but it still came at whichever
+ * allocation first found used + delta past that top -- and `used` is the
+ * live data PLUS everything allocated since the last proven cycle PLUS what
+ * the frame of that cycle's checkpoint still pinned.  So refusals were
+ * spread over the allocation sites by bytes, and some landed where the
+ * program has no handler -- the capacity probe's step between batches (a
+ * stall), OpenOS's dispatcher after a resume (the sandbox down) -- although
+ * a collection would have made room: 431 of 16384 hermetic probe runs on
+ * stage C, every one garbage-covered; 0 on PUC, which collects at the
+ * refusal and retries (mem_test W16, W16R, W16Rj).  We cannot collect there
+ * (C1-C7).  So a SANDBOX growth past its tier's top S (total + G/2, or
+ * total + G in the reserve tier) is LENT, up to LJ52_GC_LEND past S, and
+ * arms the cycle that will decide it; the window stays open until a proven
+ * cycle says what the heap holds:
+ *   - back under S: the window shuts -- garbage covered the crossing;
+ *   - past S even without the bytes granted since the PREVIOUS proof, i.e.
+ *     data that survived two consecutive cycles: THE VERDICT, and every
+ *     further crossing is refused while that proof's heap stays past the
+ *     current S (a raised cap or an opened reserve tier voids it);
+ *   - otherwise it stays open.  The excess is no older than the previous
+ *     proof, and the frame that allocated it may still pin it: a cycle run
+ *     at a check inside a loop marks that frame's registers (lj_gc.c:
+ *     309-313), so its proof counts junk that is dead the moment the loop's
+ *     function returns (W16: the batch's last checkpoint, then the stage
+ *     string outside the handler; a verdict on that one proof refused it).
+ * THE LOOK: a growth that would pass the cap first proves a cycle that has
+ * ended, so a proof's figure is the heap the cycle left, not that plus the
+ * request that observed it, and its decision reaches the first allocation
+ * after that cycle -- most often in the code whose checkpoint ran it --
+ * not the second: read one call late, it reached the allocation after the
+ * batch had returned -- event.timer's record, outside the handler (W16,
+ * W16R; in the hermetic W16 sweeps, 30 and 29 landings outside the handler
+ * without it, 0 with it).
+ * A refusal shuts the window, so the cycle it arms decides the next
+ * crossing: a caught refusal in the reserve tier opens no room, and without
+ * this the program's next allocation -- its "done/..." string, allocate-
+ * first -- was refused before any checkpoint could run (W16Rj).  The
+ * window arms its own cycle: THE CADENCE would arm the same grant (regime
+ * P: top - used < 0), but once a proof has left the heap past the top it
+ * gets there by right-shifting a negative number.
+ * The kernel gets no window (C6b, W7k): its slice lies past every window
+ * (LJ52_GC_LEND <= LJ52_GC_KSLICE, checked at compile time), so it keeps
+ * LJ52_GC_KSLICE - LJ52_GC_LEND past the sandbox's ceiling (W19); and when
+ * its slice took the heap past S between resumes, the sandbox's next
+ * allocation -- the dispatcher's table.pack -- is a crossing like any
+ * other, lent, its cycle run at that call's own check.  No window under
+ * HOOK_GC or a host GCSTOP, as no credit.  Nothing of it crosses eris: it
+ * is shut on a fresh record, decided anew at every proof, and read against
+ * the current top.  The bound stays absolute: the sandbox's used + delta <=
+ * total + G + LJ52_GC_LEND, every thread's <= total + G + LJ52_GC_KSLICE as
+ * before, so caught refusals cannot ratchet it (W7, re-scoped to G + the
+ * window; W7k).  What it costs: a cycle per crossing while live data plus
+ * the newest junk straddles a top; and a program whose live data sits past
+ * S by less than its own garbage per cycle never gets the verdict -- lent
+ * within the ceiling, a cycle per crossing, never refused.  What it does
+ * not fix: a window overrun before a checkpoint proves its cycle (more than
+ * LJ52_GC_LEND with no checkpoint, a single request past S + LJ52_GC_LEND,
+ * or the kernel spending more than that of its slice past S between
+ * resumes), and garbage pinned across two consecutive cycles, are still
+ * refused wherever they land.
+ *
  * THE VALVE COUNTS ATTEMPTS.  LJ52_GC_ARMCAP counts allocator calls that
  * try to GROW (granted or refused), never frees or shrinks.  An armed cycle
  * that sweeps more than 65 536 dead blocks -- one sweep of a machine full of
@@ -1018,6 +1110,10 @@
 #define LJ52_GC_ODMIN  (32 * 1024)
 #define LJ52_GC_ODMAX  (512 * 1024)
 #define LJ52_GC_KSLICE (16 * 1024)      /* the kernel's own, past the credit */
+#define LJ52_GC_LEND   (4 * 1024)       /* THE WINDOW; <= KSLICE: the bound  */
+#if LJ52_GC_LEND > LJ52_GC_KSLICE
+#error "THE WINDOW must sit inside the kernel's slice, or the bound over every thread moves"
+#endif
 #define LJ52_GC_HYSTSHIFT 1             /* re-arm after half the headroom    */
 #define LJ52_GC_FLUSHSHIFT 1            /* flush inside half the watermark   */
 #define LJ52_OD_BURST   0               /* credit tiers                      */
@@ -1097,6 +1193,42 @@
   return c;
 }
 
+/* THE WINDOW's look: a growth that would pass the cap first sees whether
+ * the armed cycle has ended, so the proof's figure is the heap that cycle
+ * left -- not that plus the request -- and the window is decided before the
+ * request is judged.  It is the armed branch of lj52_gc_pressure, with its
+ * guards (norefuse, HOOK_GC, GCSTOP: nothing is observed there), as a FREE:
+ * a look is not an attempt, and the valve must not count it.  The park
+ * reset it can run is the one the same call's GROW or TRY would run a
+ * moment later, against the same gc.total (LuaJIT adds the block only after
+ * the allocator returns).  Only on the slow path: below the cap the call
+ * is the stage-C allocator's, unchanged. */
+static void lj52_gc_look(lj52_mem *M, long long total, long long used)
+{
+  if (M->gc_armed) lj52_gc_pressure(M, total, used, LJ52_GP_FREE);
+}
+
+/* THE WINDOW: lend a sandbox growth the credit refused?  Up to LJ52_GC_LEND
+ * past the top it was refused at, unless the verdict stands, and arm the
+ * cycle that will decide it.  Never the kernel's, never under HOOK_GC or a
+ * host GCSTOP. */
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
+  if (!M->gc_armed) lj52_gc_arm(M, g, LJ52_ARM_WALL);   /* the window's cycle */
+  return 1;
+}
+
 /* A refusal: counted, the valve and the proof seen to first, then the
  * reserve tier opened and the collector armed -- from ANY headroom, so the
  * garbage that would have covered the request is collected at the next
@@ -1111,6 +1243,7 @@
   g = G(M->L);
   if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) return;
   M->gc_odstate = LJ52_OD_RESERVE;
+  M->gc_win = 0;                        /* THE WINDOW: its cycle decides anew */
   if (M->gc_armed) M->gc_armby = LJ52_ARM_WALL;
   else lj52_gc_arm(M, g, LJ52_ARM_WALL);
 }
@@ -1155,6 +1288,12 @@
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
@@ -1879,7 +2018,8 @@
 }
 
 /* _OCLJ_WALLSTATS() -> overdrafts, od_peak, od_state, park_resets,
- *                      od_limit, kernel_slice, gc_low, armby, hyst
+ *                      od_limit, kernel_slice, gc_low, armby, hyst,
+ *                      window, lends, win, refused
  *
  * The collector at the wall (docs/roadmap.md; THE CREDIT, THE CADENCE and
  * THE PARK RESET in the collector section).  overdrafts counts growths lent
@@ -1891,9 +2031,14 @@
  * last proof left (lowered by frees), why the last cycle was armed (0 gate,
  * 1 wall or refusal, 2 the flush), and whether a cycle has been proven at
  * all -- what the harness's mem-2 needed to see why a hold got no cycle
- * (2026-10-04).  A separate
- * global, not more _OCLJ_GCSTATS positions: twenty values is LUA_MINSTACK,
- * which is what lets that one push without a checkstack.  Read-only,
+ * (2026-10-04).  window is THE WINDOW's LJ52_GC_LEND (the sandbox's bound is
+ * then used <= cap + od_limit + window), lends the growths it lent, win its
+ * state (0 shut, 1 open, 2 the verdict), refused the size of the last
+ * refused request (what a landing outside a handler was asking for: the
+ * hermetic W16 cases judge "covered" by it, and a capacity run's stall is
+ * attributed by it).  A separate global, not more
+ * _OCLJ_GCSTATS positions: twenty values is LUA_MINSTACK, which is what
+ * lets that one push without a checkstack.  Read-only,
  * allocates nothing, raw global -- the sandbox never sees it. */
 static int lj52_wallstats(lua_State *L) {
   lj52_mem *M = lj52_memof(L);
@@ -1906,7 +2051,11 @@
   lua_pushnumber(L, M ? (lua_Number)M->gc_low : -1);
   lua_pushinteger(L, M ? M->gc_armby : -1);
   lua_pushinteger(L, M ? M->gc_hyst : -1);
-  return 9;
+  lua_pushinteger(L, M ? LJ52_GC_LEND : -1);
+  lua_pushinteger(L, M ? M->gc_lends : -1);
+  lua_pushinteger(L, M ? M->gc_win : -1);
+  lua_pushnumber(L, M ? (lua_Number)M->gc_refdelta : -1);
+  return 13;
 }
 
 /* Installed by lj52_newstate as the raw global _OCLJ_WATCHDOG. */
```

---

## 3. The bound (R5)

For every growth granted outside the norefuse window:

    sandbox thread:              U + d  <=  T + G(T) + L
    kernel thread:               U + d  <=  T + G(T) + K
    under HOOK_GC or GCSTOP:     U + d  <=  T
    every thread (L <= K):       U + d  <=  T + G(T) + K  <=  T + 512 KiB + 16 KiB      (unchanged)

    G(T) = clamp(floor(T/16), 32 KiB, 512 KiB),  K = 16 KiB,  L = 4 KiB,
    L <= K enforced at compile time (#if LJ52_GC_LEND > LJ52_GC_KSLICE -> #error; seen to fire at L = 64 KiB).

**Derivation.** A growth is granted on exactly one of three paths:
1. **The fast test:** U + d ≤ T.
2. **The credit:** U + d ≤ T + c, with c ∈ {G/2, G}, plus K for the kernel's thread, and 0 under HOOK_GC or GCSTOP.
3. **The lend.** `lj52_gc_lend` returns 1 only if all of these hold: the thread is not the kernel's; HOOK_GC and GCSTOP are clear; U + d ≤ T + c_sandbox + L, with c_sandbox ≤ G.

So every right-hand side is T plus a function of the tier (one bit, raised only by a refusal, idempotently), the thread, and the two host states. `gc_win` only chooses between lending and refusing under that ceiling. `gc_refdelta`, `gc_lends` and `gc_grown` never enter a ceiling. The verdict can only refuse.

**Properties.**
- **Absolute:** caught refusals cannot ratchet the bound (W7: 3 955 caught refusals, od_peak 36 846 = G + 4 078).
- **Charged:** the lent bytes are in `used`, so getFreeMemory reads 0.
- **What lies outside it:** the same as today — the norefuse window (~1.5 KB, not in od_peak) and a cap set under the heap.

**Measured.**

| case | od_peak | margin |
|---|---|---|
| W7, sandbox | G + 4 078 | 18 B under G + L |
| W7k, kernel | 49 140 = G + K − 12 | — |
| W19 (sandbox's peak before the kernel allocates) | G + 4 080 | — |
| probe sweeps, largest excursion (any thread) | G + 3 080 (batch 10) | — |
| kernel-pressure sweep (6 KB/resume), every thread | G + 11 536 | ≤ G + K |

---

## 4. Every transition

**State.**
- ARM ∈ {UNARMED, ARMED}
- TIER ∈ {BURST, RESERVE}
- HIST: FRESH, or PROVEN(gc_low)
- WIN ∈ {0 shut, 1 open, 2 verdict}
- GROWN
- FLAG
- refdelta (diagnostic)

| event | transition |
|---|---|
| growth with U + d ≤ T | Unchanged from stage C: grant, GROWN += d, `pressure(GROW)`. No look. A proof is observed post-grant, as at stage C. Since U + d ≤ T < S, any open window shuts. |
| growth with U + d > T, record ARMED | `lj52_gc_look` → `pressure(FREE)`: a PROOF if the cycle completed, else the park reset (the same one this call's GROW/TRY would run, against the same gc.total). Not counted by the valve. Nothing happens under norefuse, HOOK_GC or GCSTOP (pressure's guards). |
| growth with T < U + d ≤ T + credit | Grant, GROW. |
| sandbox growth, T + credit < U + d ≤ S + L, no standing verdict | LEND: WIN = 1, lends++, arm(WALL) if unarmed (an armed record is not relabelled: a pending FLUSH cycle keeps its label, so its proof raises no flag), grant, GROWN += d, `pressure(GROW)`. |
| sandbox growth past S + L, or WIN = 2 and gc_low > S | REFUSE. |
| kernel growth past its top S + K | REFUSE (no window). |
| REFUSE | refdelta = d; refusals++; `pressure(TRY)`; past the guards: TIER = RESERVE, **WIN = 0**, arm or relabel WALL (all as today except WIN). |
| PROOF (white flipped at GCSpause; any kind) | As today: UNARMED, collects++, gc_low = U, U ≤ T → BURST, FLAG if armby ≠ FLUSH and T − U < w/2. Then if WIN ≠ 0: WIN = (U ≤ S) ? 0 : (U − GROWN > S) ? 2 : 1, against the sandbox's S for the tier after the repay. Then GROWN = 0. |
| unarmed pressure (THE CADENCE) | Unchanged in code. Past S, regime P also arms any unarmed growth. The window's own arm makes that redundant, and makes it independent of regime P's right shift of a negative distance (u2-shim-now inconsistency 10). |
| valve bailout | As today. WIN and GROWN untouched. The next lend re-arms. |
| free | `pressure(FREE)` before the free, as today (it may prove). |
| **on trace** | The same allocator calls. A lend writes record fields and arms (two VM scalars, as the cadence does). The window's cycle bails at atomic on trace and completes at the trace exit (u2-checkpoints §3). Its proof is read at the next slow-path growth, before the decision. The exit's snapshot restore is lent only within S + L. No collection in the allocator (C1-C7). |
| **JIT recorder** | Recorder allocations are the running thread's. A sandbox's crossing is lent within S + L, so far fewer refusals are absorbed silently by `trace_abort`: second chances with the JIT on fell from 2 899 to 182 of 16 384. |
| **HOOK_GC** (a finalizer) | Credit 0, no window, no look (pressure returns at its guard). Hard cap at T. WIN untouched. |
| **host GCSTOP** (eris persist/unpersist) | The same as HOOK_GC (`threshold == LJ_MAX_MEM`). |
| **norefuse** (`lj52_pushcfunction`) | The predicate is skipped and the look's pressure returns at its guard. Granted and charged as today. GROWN counts it, which is harmless (it only biases the verdict toward open). |
| **csync / legacy** | The same rule with Java's per-call T and U: the look, `|| lj52_gc_lend(...)` in the predicate, refdelta, GROWN. Measured: every legacy sweep is byte-identical to C mode. |
| **cap change** (settotal, Java's total, OC's Int.MaxValue around persist) | Nothing written. The verdict is read against the current S. |
| **fresh record** (eris load) | `calloc`: WIN = 0, GROWN = 0, refdelta = 0. The fresh-record RESERVE rule is unchanged: it is reached through `lj52_gc_credit`, which the lend calls. Nothing must cross eris. |
| **the kernel's slice** | The kernel's tops stay S + K, hard. It keeps K − L = 12 KiB past the sandbox's ceiling (W19 grants an 11 KiB table; d2's K8: 13 KB granted, 14 KB refused). When its slice took the heap past S between resumes, the sandbox's next growth is a crossing: lent within S + L, and its cycle runs at that call's check. |
| **the flush predicate** | Unchanged. A window's cycle is armed WALL, so its proof can raise FLAG like any wall proof. Flushes stay bounded at one per resume, because FLAG is consumed at `lj52_wd_arm`. W13-W15 pass. |
| **THE CADENCE** | Unchanged in code. The comment gains a bullet (§5). |

---

## 5. The comment blocks

These are the texts in the final source. THE CREDIT and THE CADENCE are extended; THE WINDOW is new, placed after NO BACK-OFF.

### THE CREDIT (extended: BURST bullet, kernel-slice bullet, bound sentence)

```
 * THE CREDIT (2026-10-04).  PUC Lua, refused at the cap, runs a full
 * collection inside luaM_realloc_ and tries again; a program that catches
 * "not enough memory" and drops its data therefore carries on.  We cannot
 * collect inside the allocator (C1-C7), so until this change the program's
 * own NEXT allocation -- the error message it builds, the string it formats
 * -- was refused too, before any checkpoint could collect what it dropped:
 * 20 of 60 capacity runs at OC's default scale ended that way or with the
 * machine down, against 0 of 20 on stock (bench/results-ramscale-
 * 2026-10-03.md).  So a growth that would pass the cap is LENT up to a
 * bounded credit, charged like any other, and the collector armed to repay
 * it at the next checkpoint.  G = total/16, clamped to 32 KB..512 KB:
 *   - BURST, the default tier: up to G/2 past the cap.  Before any refusal
 *     the heap stops at total + G/2 (+ THE WINDOW below, for the sandbox),
 *     so when the refusal comes at least G/2 (G/2 - LJ52_GC_LEND) is left
 *     for what the program does next;
 *   - RESERVE, after a refusal: up to G.  The refusal opens it; a proof that
 *     finds the heap back under the cap closes it.  A proof that does not --
 *     the cycle ran before the program dropped its data -- leaves it open,
 *     which is what lets "catch, format the message, drop, carry on" work;
 *   - a record that has proven no cycle yet and finds the live data
 *     already past total + G/2 (a state eris loaded, with its cap restored
 *     under what the machine held when it was saved: the record is fresh,
 *     the bytes are not) takes the RESERVE tier, so the first allocation
 *     after a load is not refused for history the record never saw.  Only
 *     a fresh record: in one that has run cycles, the heap passes total +
 *     G/2 legitimately on the kernel's slice below, and taking that as a
 *     reserve would spend the second tier before any refusal;
 *   - THE KERNEL'S SLICE: LJ52_GC_KSLICE more, for the kernel only -- no
 *     resume armed (wd_depth 0: between resumes, where Java's signal pushes
 *     land too), or the thread that made the outermost arm (the kernel after
 *     coroutine.resume returned and before the disarm; cur_L is restored to
 *     the resumer, vm_x64.dasc:1625).  The sandbox that spent both tiers
 *     and its window cannot take the kernel down with it on the table.pack
 *     it does after every resume (machine.lua): the kernel keeps
 *     LJ52_GC_KSLICE - LJ52_GC_LEND past the sandbox's ceiling.
 * No credit at all where nothing could repay it: under HOOK_GC (a finalizer;
 * PUC's cap is hard there too) and under a host GCSTOP.  The bound is
 * absolute, not incremental: used + delta <= total + G + the slice for
 * every growth outside the norefuse window -- the sandbox's own, total + G
 * + LJ52_GC_LEND, inside it -- so caught refusals cannot ratchet it
 * (mem_test W7, W7k), and the excursion is charged -- getFreeMemory reads
 * 0, both Java sides clamp it there.  What it does not fix: a single
 * request larger than headroom + credit (+ the window), retried with no
 * checkpoint between the tries (mem_test W9, printed, not asserted), is
 * refused where PUC would collect and succeed; any checkpoint between the
 * tries cures it.
```

### THE CADENCE (extended: the fourth bullet)

```
 * THE CADENCE (2026-10-04).  Until this change, once a proven cycle left the
 * heap inside the watermark, the very next allocator call armed again, so
 * every GC checkpoint paid a whole O(heap) cycle: 20-120x stock's time over
 * the last quarter of a fill.  Stock collects once per (cap - live) bytes.
 * The arm while unarmed is now:
 *   - no cycle proven yet: headroom < w, as before;
 *   - below the cap: headroom < min(w, (total - gc_low)/2) -- re-arm after
 *     half the post-cycle headroom is used, two cycles per (cap - live)
 *     bytes, twice stock's count; and a growth past the cap always arms;
 *   - past the cap (the last proof left the heap there): when the distance
 *     to the top of the current tier -- the kernel's slice included, when it
 *     is the kernel allocating -- has halved since that proof.  Halving, not
 *     every grant: a program holding data past the cap pays log2 cycles per
 *     tier, and one that drops its data is repaid within half the tier;
 *   - past the tier's top itself, THE WINDOW below arms instead: each
 *     sandbox crossing it lends demands the cycle that decides it, so a
 *     program whose live data and newest garbage straddle the top pays a
 *     cycle per crossing there -- stock's rate, which collects at every
 *     allocation that does not fit.
```

### THE WINDOW (new)

```
 * THE WINDOW (2026-10-05; docs/roadmap.md, "A refusal at a credit tier's
 * top can land outside the program's handler").  THE CREDIT moved the
 * refusal from the cap to a tier's top, but it still came at whichever
 * allocation first found used + delta past that top -- and `used` is the
 * live data PLUS everything allocated since the last proven cycle PLUS what
 * the frame of that cycle's checkpoint still pinned.  So refusals were
 * spread over the allocation sites by bytes, and some landed where the
 * program has no handler -- the capacity probe's step between batches (a
 * stall), OpenOS's dispatcher after a resume (the sandbox down) -- although
 * a collection would have made room: 431 of 16384 hermetic probe runs on
 * stage C, every one garbage-covered; 0 on PUC, which collects at the
 * refusal and retries (mem_test W16, W16R, W16Rj).  We cannot collect there
 * (C1-C7).  So a SANDBOX growth past its tier's top S (total + G/2, or
 * total + G in the reserve tier) is LENT, up to LJ52_GC_LEND past S, and
 * arms the cycle that will decide it; the window stays open until a proven
 * cycle says what the heap holds:
 *   - back under S: the window shuts -- garbage covered the crossing;
 *   - past S even without the bytes granted since the PREVIOUS proof, i.e.
 *     data that survived two consecutive cycles: THE VERDICT, and every
 *     further crossing is refused while that proof's heap stays past the
 *     current S (a raised cap or an opened reserve tier voids it);
 *   - otherwise it stays open.  The excess is no older than the previous
 *     proof, and the frame that allocated it may still pin it: a cycle run
 *     at a check inside a loop marks that frame's registers (lj_gc.c:
 *     309-313), so its proof counts junk that is dead the moment the loop's
 *     function returns (W16: the batch's last checkpoint, then the stage
 *     string outside the handler; a verdict on that one proof refused it).
 * THE LOOK: a growth that would pass the cap first proves a cycle that has
 * ended, so a proof's figure is the heap the cycle left, not that plus the
 * request that observed it, and its decision reaches the first allocation
 * after that cycle -- most often in the code whose checkpoint ran it --
 * not the second: read one call late, it reached the allocation after the
 * batch had returned -- event.timer's record, outside the handler (W16,
 * W16R; in the hermetic W16 sweeps, 30 and 29 landings outside the handler
 * without it, 0 with it).
 * A refusal shuts the window, so the cycle it arms decides the next
 * crossing: a caught refusal in the reserve tier opens no room, and without
 * this the program's next allocation -- its "done/..." string, allocate-
 * first -- was refused before any checkpoint could run (W16Rj).  The
 * window arms its own cycle: THE CADENCE would arm the same grant (regime
 * P: top - used < 0), but once a proof has left the heap past the top it
 * gets there by right-shifting a negative number.
 * The kernel gets no window (C6b, W7k): its slice lies past every window
 * (LJ52_GC_LEND <= LJ52_GC_KSLICE, checked at compile time), so it keeps
 * LJ52_GC_KSLICE - LJ52_GC_LEND past the sandbox's ceiling (W19); and when
 * its slice took the heap past S between resumes, the sandbox's next
 * allocation -- the dispatcher's table.pack -- is a crossing like any
 * other, lent, its cycle run at that call's own check.  No window under
 * HOOK_GC or a host GCSTOP, as no credit.  Nothing of it crosses eris: it
 * is shut on a fresh record, decided anew at every proof, and read against
 * the current top.  The bound stays absolute: the sandbox's used + delta <=
 * total + G + LJ52_GC_LEND, every thread's <= total + G + LJ52_GC_KSLICE as
 * before, so caught refusals cannot ratchet it (W7, re-scoped to G + the
 * window; W7k).  What it costs: a cycle per crossing while live data plus
 * the newest junk straddles a top; and a program whose live data sits past
 * S by less than its own garbage per cycle never gets the verdict -- lent
 * within the ceiling, a cycle per crossing, never refused.  What it does
 * not fix: a window overrun before a checkpoint proves its cycle (more than
 * LJ52_GC_LEND with no checkpoint, a single request past S + LJ52_GC_LEND,
 * or the kernel spending more than that of its slice past S between
 * resumes), and garbage pinned across two consecutive cycles, are still
 * refused wherever they land.
```

**The other comment changes** are in the diff (§2):
- the allocator header ("And it refuses later than the cap…");
- the `lj52_gc_look` and `lj52_gc_lend` heads;
- the `_OCLJ_WALLSTATS` doc, now 13 values.

---

## 6. Measured

**Instruments.**
- **Builds.** The objects were built with build-native.sh's line; the test binaries were linked with run-mem.sh's line (`mk.sh`). The probe drivers are u2's `repro/lj_repro.c` (`build_drv.sh`): `_Xf` has a fixed string-hash seed, `_X` a random one.
- **LUA_PATH.** Every sweep ran from `d2-final/` with `LUA_PATH='?.lua'`, so stage C, final and the variants are phase-aligned. Stage C therefore reads 423 here against u2's 431.
- **"Covered".** Live measured in place (two collections where the run landed, frames as they stand) plus 256 B fits under the tier's top. This is d2-lend's `summ.sh` rule, in `summ.py`.
- **Machine state.** Nothing else ran during timing; no JVM was resident (checked with tasklist).

### 6.1 mem_test (`mem_test_final.c`, 76 checks = the repo's 68 + W16, W16R, W16Rj, W17, W7k, C6b, W18, W19)

| object | runs | result |
|---|---|---|
| final | 30, random seed | **30/30: checks=76 failures=0** (`out11/`) |
| stage C | 10, random seed | 10/10 fail **exactly W16, W16R, W16Rj, W17** (`out11/`). Covered outside landings: W16 7 (10/10 runs); W16R 5 or 6; W16Rj 27. W17 od_peak 16 377 ≤ G/2. |
| final, others' test files (3 runs each) | — | d2-lend's 72/72; d2-prevent's 71/71; d2-verdict's 70 except W7; the repo's 68 except W7; u2's `mem_test_w16.c` 69 except W7. W16 there reads "inside 96". W7's failure is the re-scope (od_peak 36 846 > G); on stage C, u2's W16 fails with 6–7 covered. |

Runtime ~3.4 s, against the repo's ~0.3–1 s.

**Readings that moved** (final; stage C in brackets):

| case | final | stage C |
|---|---|---|
| W12, worst W1 round | 22 cycles, bound 32 | 21 |
| W4, near phase | 39 collects, bound 61 | 39 |
| W7 | collects +4 028 for 3 955 refusals; od_peak 36 846 | +3 976; 32 710 |
| W17 | od_peak 16 553 = G/2 + 169 | 16 377 |
| W19 | the sandbox reached G + 4 080 | G − 56 |

W19 also: the kernel's 1 408-slot (11 KiB) table is granted armed and at depth 0. On stage C the kernel gets a 1 920-slot (15 KiB) table.

**Unchanged readings:**
- W1, W1L, W1j: `not enough memory|256|3`, collects +22.
- W8 `err: …`, W2b, W2c, W2d, W3, W10 `true|true|2|true`.
- W11: 64 B lent, 32 KB refused.
- C6, M6b, M5/C3a: used 272 904 against credit 49 152.
- W13-W15.
- W9 (INFO): still 20 tries. It runs as the kernel, and its single request is past any window.

### 6.2 Outside the handler, hermetic sweeps (`out6/summary.txt`, `out7/`, `out12/`)

Each cell gives outside landings (stall/down), with the garbage-covered count after "cov". NL is the final minus the look.

| configuration (runs) | stage C | final | NL |
|---|---|---|---|
| probe2 default (16 384) | 423 (219/204) cov 423 | **0** | 0 |
| heartbeat every 3rd resume | 440 cov 440 | 0 | 0 |
| no pcall(paint) | 224 cov 224 | 0 | 0 |
| legacy (dropin) path | 423 | 0, byte-identical to C mode | 0 |
| string-hash seed 7 | 423 | 0 | 0 |
| JIT on | 625 cov 395 | **0** | 7 |
| junk 8 / junk 96 (4 096 each) | 102 / 50 | 0 / 0 | 0 / 0 |
| cap +1 MB / +2 MB (4 096) | 123 / 116 | 0 / 0 | 0 / 0 |
| cap +1 MB, JIT on (4 096) | 105 cov 91 | 0 (an earlier run: 3, none covered; JIT-on sweeps vary run to run) | 6 |
| amplified batch 10 | 5 274 cov 4 829 | **0** | 0 |
| amplified batch 10, JIT on | 2 206 cov 1 553 in 12 881 (crash at string off 9488 ends it) | **1**, not covered | — |
| W16 program (4 096) | 169 cov 169 | 0 | 30 |
| W16 program, JIT on | 473 cov 236 | 0 | 11 |
| W16, reserve tier | 169 cov 169 | 0 | 29 cov 29 |
| W16, reserve tier, JIT on | 1 847 cov 1 804 | **0** | 11 cov 11 |
| W16, reserve tier, legacy | 169 | 0 | 29 |
| OpenOS-shaped event.timer, 3 checkArg closures (j2-practice's probe; 8 192) | 175 | 0 | — |
| the same, JIT on | 338 cov 181 | 7, none covered | — |
| kernel garbage 512 B per resume (4 096) | 406 | **0** | — |
| kernel garbage 2 KB per resume | 1 318 | 85 downs, none covered | — |
| kernel garbage 6 KB per resume | 2 043 | 1 550 | — |

**Collects per run** (all shapes):
- default: 42.5 → 50.3 (+18 %);
- batch 10: 52.7 → 64.9 (+23 %);
- reserve form: 113.1 → 145.1 (+28 %);
- JIT on: 39.4 → 41.0.

**Second chances** (≥ 2 refusals in a run), probe2 with the JIT on: 2 899 → 182 of 16 384. These are the precondition of every bad in-machine outcome (u2-stalls §0.1).

### 6.3 The unwinder crash census (one process per cap; probe2, JIT on; `census/`)

| configuration | stage C | final |
|---|---|---|
| string, batch 10, fixed seed, 4 096 caps (16 B steps) | **1** (off 9488, exit 139) | 0 |
| string, batch 10, random seed, 4 096 caps | **1** (off 9488) | 0 |
| string batch 5; string junk 8 batch 10; record / closure / array batch 10 (2 048 each) | — | 0 each |

The final object ran 18 432 processes with 0 crashes. The census can fail: it caught stage C's crash, which reproduces at off 9488 regardless of seed.

### 6.4 Cost (R9, R12; `out8/last5.txt`, `out9/idle.txt`)

The last five batches were measured with d2-lend's `probe2t.lua`: 2 048 caps per shape at 32 B steps, JIT off, 5 interleaved reps in rotated order.

| shape | last-five time: final / stage C | d2-lend `final2` / stage C (same run) | cycles in the last five: final / stage C |
|---|---|---|---|
| array | 1.144 | 1.145 | 1.172 |
| closure | 1.177 | 1.168 | 1.169 |
| record | 1.202 | 1.229 | 1.206 |
| string | 1.235 | 1.315 | 1.254 |

Per-rep overall means: stage C 2 345–2 436 µs, final 2 887–2 949 µs, `final2` 2 988–3 144 µs.

**Idle** (j2-practice's `idle.lua`: 128 KB live, 50 junk strings per resume, 3 000 resumes).
- Below the cap, at 40, 80, 120 and 200 KB headroom, arms are 293 / 147 / 98 / 69: **identical to stage C** (`final2` was +1 at 40).
- Past the cap, with live 4, 8, 12, 15 and 24 KB past it, stage C runs 979 / 1 469 / 2 994 / 12 475 / 1 469 cycles; the final runs 985 / 1 482 / 2 994 / 13 604 / 1 482. The 15 KB case (1 KB under the burst top) is stage C's own thrash, +9 %.

**Capacity** (mean objects held at an inside refusal; single-refusal runs, like for like):

| shape | stage C | final |
|---|---|---|
| array | 2 060.2 | 2 061.0 |
| closure | 2 000.4 | 2 001.4 |
| record | 1 383.5 | 1 383.6 |
| string | 5 244.8 | 5 245.3 |

- Minima: final ≥ stage C in every shape.
- JIT on, string: the headline figure is 5 152.9 against 5 274.2, but like for like it is 5 144.2 against 5 126.8. Stage C's surplus came from runs whose first refusal the recorder absorbed.

**The churn band** (j2-safety's K2, `out10/k2.txt`): live data 41 B past S, 300 B of churn per iteration, 2 000 iterations.
- Final: **2 000 cycles, never refused**, 66 ms, heap ≤ S + 1 153.
- Stage C: 76 cycles and 3 ms, because it refused once (in the fill, with the garbage uncollected) and moved to the reserve tier.
- With live data 116 B *under* S, the final still runs 2 000 cycles. That is stock's rate: stock collects at every allocation that does not fit.

---

## 7. Test plan

All code is in Appendix A (`d2-final-mem_test.diff` against `test/native/mem_test.c`, generated by `mkmt_final.py`).

### 7.1 New cases

All are on a fresh state, in C mode unless stated. Each table gives the expected result on stage C (`wall2/objC`, `0259f0d1`) and on the final object, both measured.

**W16, u2-repro §7, with two changes.**

What it does:
- Sweeps 96 caps from base + 384 KB, 64 B apart.
- Runs the capacity probe's program as a sandbox coroutine resumed under the watchdog's arm: a fill inside pcall, then outside any handler the stage string and event.timer's record, with the dispatcher's `table.pack(coroutine.yield())` before any handler at all.

The two changes:
- **(a) The live set counts the sandbox's stack.** A stall records, then `coroutine.yield('stop')`, and the kernel stops resuming. Measured equal, run for run, to the probe's in-place measure (`mkdbg_measure.py`).
- **(b) "Covered" means the live set plus the refused request fits under cap + G/2.** The refused request is `_OCLJ_WALLSTATS[13]`. On a shim without that field it falls back to the largest outside object, measured, as before.

Why (b): with (a) alone, the look's sabotage passed every case. Its only landing fits its actual request, the 64 B GCtab of event.timer's record, but not 256 B (§9).

| stage C | final |
|---|---|
| FAIL: 7 covered stalls, 10/10 runs | PASS: inside 96 |

**W16R and W16Rj** (d2-lend): W16's program carried into the reserve tier. The step's handler absorbs the first refusal and the fill goes on. At the second refusal it records and drops its data. Landings are judged against the tier they happened in. W16Rj is the same with the JIT on. Both use 96 × 64, and both carry changes (a) and (b).

| case | stage C | final |
|---|---|---|
| W16R | FAIL, 5–6 covered | PASS, inside 96 |
| W16Rj | FAIL, 27 covered (32 stalls, 8 downs) | PASS, inside 96 |

**W17** (d2-verdict's setup, with d2-prevent's bound): as the sandbox, fill live 64 B tables into a pre-sized 8 192-slot holder under pcall, cap = used + 256 KB. It asserts: one refusal, caught, and G/2 < od_peak ≤ G/2 + window/2. The window is `WALLSTATS[10]`, read as 0 on stage C.

| stage C | final |
|---|---|
| FAIL: od_peak 16 377, refused at the top with the garbage uncollected | PASS: od_peak 16 553 |

**W7k** (d2-lend, with the precondition the safety judge asked for): W7's 4 000 caught attempts made by the kernel. It asserts:
- od_peak ≤ G + K and used ≤ cap + G + K + 2 KiB;
- **and od_peak > G + window**: the kernel went past the sandbox's ceiling, so the case is not vacuous.

| stage C | final |
|---|---|
| PASS: 49 140 | PASS: 49 140 |

**C6b** (d2-prevent's, with `WALLSTATS[12]` win). The kernel (C frames, depth 0) sits at its BURST top T + G/2 + K == used, with the record in BURST and no verdict standing. A raw push must be LUA_ERRMEM. The preconditions are asserted.

| stage C | final |
|---|---|
| PASS (win −1) | PASS (win 0) |

**W18** (j2-safety's K1). Four runs:

| cap | crossing | mode |
|---|---|---|
| 4 MB | array doubling (+32 KB, rawset) | C |
| 4 MB | 20 KB concatenation | legacy |
| 10 MB | doubling | legacy |
| 10 MB | concatenation | C |

In each, the sandbox fills to S − 1 KB, crosses with that one allocation (no checkpoint precedes it) and keeps it live, then yields. The kernel then packs once armed (machine.lua's own pack), 6 more times armed, and 6 after the disarm. It asserts that the kernel is never refused. The crossing is refused at the ceiling in all four.

| stage C | final |
|---|---|
| PASS | PASS (kernel refused 0/0/0 in all four) |

**W19** (j2-safety's K8):
- The sandbox makes 8 000 caught single-table attempts at cap = base + 256 KB.
- It asserts that the sandbox reached G + window − 1 KB before the kernel allocates; that is the precondition.
- The kernel then makes one table of (K − window − 1 KiB) of array, armed and at depth 0. Both must be granted.

| stage C | final |
|---|---|
| PASS: reached G − 56; 15 KiB granted | PASS: reached G + 4 080; 11 KiB granted |

### 7.2 Existing cases that change

**W7.** "Cannot push the heap past cap + G" becomes "… past cap + G + the window".
- It asserts peak ≤ od_limit + window, window ≤ kernel_slice, and used ≤ cap + G + window + 2 KiB.
- Reason: the sandbox's bound moves by L, deliberately. The bound over every thread does not move, and W7k now pins it.
- On a shim without the window, `WALLSTATS[10]` reads −1 and is taken as 0, so W7 is unchanged there (it passes on stage C).

**WALLSTATS** returns 13 values instead of 9. No existing mem_test reader reads past 9.

**The mem_test header** (lines 1-90) should list W7k, W16-W19 and C6b. Not done in the diff: documentation only.

### 7.3 Negative-control sabotages (Appendix B: `d2-final-negctl.diff`)

**How the sets were measured** (`sabotage_final.py`, `sab/run3` and `sab/run4`, identical):
- the exact-line edits below, compiled with negative-control.sh's own `build_variant_mem` line (`gcc -c -O2`, no `-Wall`, no `-DLJ52_ADDITIVE`);
- linked with `mem_test_final.c`.

**Checks on the script itself:**
- Every new `sed` expression was run with GNU sed on the final source. Each produced exactly the edit that was measured, and its marker.
- `sh -n` passes.
- The script as a whole was not run: it builds the security and watchdog halves too.

**Existing sabotages whose expected set changes** (anything not listed is unchanged; norefuse still dies after M5):

| # | name | expected set now | added, and why |
|---|---|---|---|
| 4.1 | stopgap | today's 42 + **C6b W7k W16 W16R W16Rj W17 W19** | Nothing is refused, so no fill stops inside a handler, no window opens and no kernel bound is met. W18 passes: with nothing refused, the kernel is not refused either. |
| 4.6 | nocredit | today's 8 + **W16 W16R W16Rj W17 W18 W19 W7k** | The window's tops are the credit's. The kernel's slice is part of the credit, so W7k, W18 and W19 fail. |
| 4.8 | nohyst | W4 W12 (unchanged) | Now runs with `MEMTEST_CFLAGS="-DW16_N=8 -DW16R_N=8"`. 65 s with it, 174 s without. |
| 4.9 | unbounded | today's 9 + **C6b W7k W17** | The kernel's top passes the whole cap; the live fill runs far past the top. Runs with the same flags: 56 s (d2-lend: past 300 s at 96 caps). |
| 4.10 | nokslice | W10 + **W16R W16Rj W19 W7k** | The kernel's per-resume pack after the sandbox's second refusal has no room; the kernel's bound and its room go. |
| 4.12 | closereserve | W8 W11 + **W16Rj W19 W7k** | The absorbed first refusal's room is lost at the next proof, and neither sandbox nor kernel reaches the reserve top they are checked at. |

**New sabotages** (one exact line each, unless stated):

| # | name | edit | must fail exactly |
|---|---|---|---|
| 4.14 | nowindow | the ceiling line → `return 0;` (refuse at the top: stage C) | W16 W16R W16Rj W17 W19 |
| 4.15 | noceiling | the ceiling line removed | W7 W11 W18 W19 |
| 4.16 | slicewindow | the ceiling at `top + LJ52_GC_KSLICE` (the size the `#error` forbids for the constant) | W7 W19 |
| 4.17 | rawverdict | `M->gc_win = used <= top ? 0 : 2;` | W16 W16R W16Rj |
| 4.18 | nolook | `lj52_gc_look`'s body → no-op | W16 W16R |
| 4.19 | refusalkeeps | `M->gc_win = 0;` in `lj52_gc_refused` removed | W16Rj W19 |
| 4.20 | kernelwindow | `lj52_gc_kernel(M, g)` dropped from the lend's guard | C6b W7k |
| 4.21 | noarm (two lines) | the window's arm removed, and regime P's arm restricted to `used <= top` | W17 |

Measured but **not** added, because each fails nothing:
- the window's arm alone (nolendarm);
- regime P past the top alone (nocadencetop).

Each alone arms the window's cycle. The explicit arm is there so that this does not rest on a right shift of a negative number.

The compile-time guard replaces d2-lend's `bigwindow` sabotage, which can no longer compile. Seen to fire: `#error "THE WINDOW must sit inside the kernel's slice…"` at L = 64 KiB.

### 7.4 The hermetic gate (for the implementer, before and after landing)

1. `mem_test` 30× with random seeds: 76/76 every time. Then 10× on stage C: exactly W16, W16R, W16Rj, W17. This is the fail-first run.
2. negative-control.sh with the edits above.
3. The sweep set (`sweep.sh <tag>`, about 2 minutes on 24 cores).
   - Expect 0 outside landings in every JIT-off configuration.
   - With the JIT on, expect ≤ 10 per configuration, and none covered.
4. The crash census (`census1.sh`, `census2.sh`, one process per cap). **Any exit 139 is a stop.**

---

## 8. The in-machine gate (R10, R12)

Not run in this task: no JVM, and a long chain belongs to the main session. Appendix C is the full harness change. It compiles with the harness's own scalac line (`scalac/`: exit 0, the same 5 deprecation warnings as the unmodified file); it was not run.

### 8.1 Changes

**`test/native/OcljSmoke.scala`, CapacityAutorunLua:**
- `local BATCH = %%BATCH%%`, and churn `uniq(%%JUNK%%, count)`.
- Four number-only counters, painted on row 19 as `OCLJCAPX=entered/timed/pf/oe`:
  - `entered`, at step's first statement;
  - `timed = count`, after `event.timer` returns;
  - `pf`, a refused paint, at both paint sites;
  - `oe`, from a wrapped `event.onError`.

**`test/native/OcljSmoke.scala`, the knobs:**
- `capBatch` and `capJunk` come from `OCLJ_CAP_BATCH` (default 100) and `OCLJ_CAP_JUNK` (default 24).
- They are validated next to the shape: 1..1000 and 8..200.
- They are substituted where `%%SHAPE%%` is.

**`test/native/OcljSmoke.scala`, capacityProbe:**
- `_OCLJ_WALLSTATS` is read to 13 values.
- `CAP-GC` gains `window=`, `lends=+`, `win=` and `refused=`.
- A new `CAP-X|` line carries:
  - batch, junk and `OCLJCAPX`;
  - the trace start/abort counts before and after the fill;
  - `class=` one of CLEAN, STALL, RECOVERY-REFUSED, DOWN, OTHER;
  - `site=` for a stall: closure if `entered == batches + 1`, event.timer if `timed < count`.

**The launcher** (`bench/runs/2026-10-04-wall/scripts/cap.sh`, or its successor):
- Two optional arguments: `BATCH="${9:-100}" JUNK="${10:-24}"`.
- `OCLJ_CAP_BATCH="$BATCH" OCLJ_CAP_JUNK="$JUNK"` added to the env line before `sh test/native/smoke-test.sh`, and recorded in `args.txt`.
- `chainlib.sh`'s `run()` passes `$9 $10` through and greps `CAP-X|` with the other lines.

**PROC-DEATH.** The chain classifies a run as PROC-DEATH when it printed no `CAP-X|` line and either its `exit.txt` is non-zero or an `hs_err_pid*.log` appeared. The JVM's cwd is the repo root (cap.sh `cd "$REPO"`), so the chain moves any `$REPO/hs_err_pid*.log` into the run directory after every run.

### 8.2 Matrix

All on a 192 KB stick at `ramScaleFor64Bit` 1.8 (G at its 32 KB floor, as hermetically), with `OCLJ_CAP_BATCH=10` and `OCLJ_CAP_JUNK=24`.

**Builds:**
- S: stock PUC, OC's own;
- C: stage C, additive and dropin (the positive control);
- W: the final, additive and dropin.

**Cells:**

| build | arms | shapes | reps per cell | runs |
|---|---|---|---|---|
| S | stock | string, record | 10 | 20 |
| C | O (JIT off throughout), D (JIT on), L (dropin, JIT on) | string, record | 10 for O and D; 5 for L | 50 |
| W | O, D, L | string, record | 10 for O and D; 5 for L | 50 |

That is 120 runs.

**Run order:**
- Interleave by rep: S, C, W within each (shape, arm).
- Run stage C's D-string cells **last**. Stage C reaches the unwinder crash hermetically (§6.3), and a JVM death there must not stop the chain.

**Alongside: the standard matrix at BATCH 100.** Use chain C's layout (S, ours D and O on 192 KB × 3 reps, 256 and 1024 KB × 1, four shapes; L on 192 and 1024 KB), with W in place of C: 68 runs. It is for R12 (capacity, last five against a same-run stock) and for the idle window (`CAP-IDLE`).

**Hermetic expectation at batch 10.**
- Stage C: 14 % (record) to 83 % (string) of runs outside the handler, JIT off.
- Final: 0 with the JIT off, ≤ 0.01 % with it on.
- PUC: 0 in 90 112 hermetic runs (u2-repro).

### 8.3 Pass criterion (all must hold)

**(a) The gate can fail.** Stage C shows ≥ 7 STALL + DOWN + PROC-DEATH in its 50 amplified runs.
- At 5–6, add 10 reps per stage-C and W cell before judging.
- Below 5, the amplification did not transfer, and the gate is **void**, not passed.
- 7 is the smallest count for which 0 of 50 reaches one-sided Fisher p < 0.01 (p = 0.0062).

**(b) The final:**
- 0 STALL, DOWN or RECOVERY-REFUSED in the O cells (20 runs);
- ≤ 1 STALL + DOWN in the D + L cells (30 runs), each attributed by `CAP-X site=`, `CAP-GC refused=` and od_peak (live data at the top: od_peak within 256 B of od_limit/2 or od_limit);
- **0 PROC-DEATH anywhere**;
- one-sided Fisher p < 0.01 against stage C over the 50 amplified runs each (1 against ≥ 9; 0 against ≥ 7).

**(c) Stock:** 0 STALL + DOWN in its 20 runs.

**(d) BATCH-100 matrix:**
- the final's capacity ≥ stock's in every cell;
- the final's single-refusal held count ≥ chain C's like for like, minus 1 %;
- 0 STALL + DOWN (chain C had 1 in 49).

**(e) Last five:** the ratio to same-run stock is ≤ 1.35 × chain C's ratio in every cell. The hermetic factor is ≤ 1.24; whether to accept that cost is §12 question 4.

**(f) Idle:** CAP-IDLE arms per window are within ±10 % of chain C's for the same cell, with 0 refusals. Hermetically, idle below the cap is identical.

**(g) The bound:** every W run has od_peak ≤ od_limit + kslice.

---

## 9. The grafts: what was taken, and what was not

**Safety judge's grafts:**
1. **Explicit arm in the window.** Taken: `if (!M->gc_armed) lj52_gc_arm(M, g, LJ52_ARM_WALL);`. No relabel, so a pending FLUSH-armed cycle keeps its label and cannot loop the flush. Measured: redundant with the cadence (nolendarm fails nothing) and identical in every sweep.
2. **`#error` guard.** Taken, and seen to fire.
3. **K1 and K8 in mem_test.** Taken, as W18 and W19. W18 runs at 4 and 10 MB, in C mode and legacy; noceiling fails it. W19 asserts its precondition (the sandbox at its ceiling); nokslice, slicewindow, noceiling and nowindow fail it.
4. **verdict's W17; prevent's C6b precondition style for W7k.** Taken. W17 merges both designs' W17 (verdict's setup, fail-first; prevent's ≤ half-window bound). W7k asserts od_peak > G + window.
5. **Crash census in the hermetic and in-machine gates.** Taken (§6.3, §7.4, §8.3: PROC-DEATH).
6. **Optional: verdict's silent past-cap cadence.** Not taken; listed (§12 question 4).

**Practice judge's grafts:**
1. **The W16 measure fix** (record, then yield). Taken, and extended. With the fix alone, the look's sabotage passed every case: its one W16 landing (off 5824, `sab/run4/nolook`) has live 464 010 against a top of 464 110, which fits the refused request (64 B, event.timer's record) but not the 256 B criterion. "Covered" is therefore judged by the refused request (`WALLSTATS[13]`), as R1 words it. With that, nolook fails W16 and W16R again. Stage C still fails robustly, through the 256 B fallback, since it has no field 13.
2. **An explicit `lj52_gc_prove()` in place of the `pressure(FREE)` observation.** Taken in spirit, not by extraction. The observation is a named function, `lj52_gc_look`, whose comment says what it is and why it is a FREE.
   - Extracting the proof block would move negative-control 4.12's anchor off its 6-space indentation; d2-verdict had to rewrite that sed.
   - The park reset a look can run is the one the same allocator call's GROW or TRY runs a moment later, against the same gc.total.
   - The look is also restricted to the slow path. Below the cap the allocator is stage C's, and idle cost is identical.
3. **verdict's W17, prevent's W17 and C6b, prevent's L ≤ K guard.** Taken (W17 merged).
4. **W16R and W16Rj at 48 × 128.** **Rejected, with evidence.** At 48 × 128 with the measure fix, stage C's W16R reads 1–2 covered stalls (6 of 10 runs read 1): a thin fail-first margin. At 96 × 64 it reads 5–6. The time problem is handled instead by a `W16_N`/`W16R_N` override for the two slow sabotages. mem_test takes ~3.4 s.
5. **WALLSTATS read with max 11 in the harness.** Taken as 13 (Appendix C).

**Practice judge's stage-2 items** — L = clamp(G/8, 4 KiB, K), the kernel regime-P retarget at S + L, and the silent cadence: not taken (§12).

---

## 10. FATALs, and how each is resolved

- **F-V1 (d2-verdict): the kernel refused for the sandbox's lent data at caps above 2 MiB.**
  - **Cause:** the loan was G/8, which exceeds K.
  - **Resolution:** the window is a constant L = 4 KiB ≤ K, enforced at compile time. The kernel's tops are the sandbox's plus K, so the kernel keeps K − L above anything the sandbox was lent, at every cap.
  - **Pinned by W18,** at 4 and 10 MB in C mode and legacy: 0 kernel refusals. The noceiling sabotage fails it.
- **F-V2 (d2-verdict): a frequent LuaJIT unwinder segfault.** It came from delivering verdicts at check-first fast functions: 442 of 1 024 caps.
  - **Not inherited.** The final has the same look-first ordering, but with the two-cycle verdict it reached the crash in 0 of 18 432 one-process-per-cap runs over six amplified JIT-on configurations. j2-safety and j2-practice measured `final2` at 0 as well.
  - **The crash itself is latent in stage C**, which is shipped: 1 in 4 096 at string off 9488, with fixed and random seeds alike.
  - **Not root-caused.** One lead for its row, not checked: `lj_err_mem` sets `L->top` only for a Lua frame (lj_err.c:823-830); `ff_tostring` calls `lj_strfmt_num` inline having written only `L->base` (vm_x64.dasc:1383-1394), and the error message is then pushed at a stale `L->top`.
  - **The gate treats any crash as a stop:** exit 139 hermetically, and PROC-DEATH in the machine.

No FATAL was found against d2-lend by either judge, and none was found here.

---

## 11. Requirements

| R | score | why |
|---|---|---|
| R1 | **MET for every garbage-covered landing measured; PARTLY in general** | 0 garbage-covered outside landings in every sweep (§6.2). With the JIT off, 0 outside landings of any kind, except under kernel garbage past 512 B per resume (the residual). Refusals are never earlier than stock's (j2-safety's K7 found none earlier). They come later, by at most L = 4 KiB and two cycles. Not met in general for the residual (§13), for the JIT-on live-data landings (0–7 per sweep, none covered), or for the churn band (live data up to L past S, never refused). |
| R1b | **MET** | W1, W1L, W1j, W8, W2b, W2c, W2d and W10 pass. The probe's catch-format-drop path ("done") is reached in 16 384 of 16 384 runs of each of probe2's default, heartbeat, no-paint, legacy, seed-7, batch-10 and JIT-on sweeps. Stage C reaches it in 11 110–16 160. The kernel keeps K − L = 12 KiB past the sandbox's ceiling (W19), never refused (W18), down from 16 KiB (§12 question 1). |
| R5 | **MET** | The every-thread bound is unchanged; the sandbox's is cap + G + L (§3). Absolute, charged, not ratchetable. Pinned by W7, W7k, W19 and the compile-time guard. |
| R6 | **MET** | No collection in the allocator. The lend writes record fields and arms (the cadence's two VM scalars). The look is today's armed branch, with its guards. On trace, HOOK_GC, GCSTOP and norefuse are in §4. Zero LuaJIT lines. Crash census 0 / 18 432. |
| R7 | **MET** | 54 code lines; zero LuaJIT lines; the gate grep finds 0; all 13 anchors intact; the diff applies cleanly. The +4 WALLSTATS values are diagnostics. |
| R8 | **MET** | The window is transient per-record state: shut on a fresh record, decided at every proof, read against the current top. Nothing crosses eris. GCSTOP: no window, no look. The fresh-record rule is unchanged (W11; nofresh fails it). |
| R9 | **PARTLY** | Below the cap: unchanged by construction and by measurement (idle identical). Near the wall: last five 1.14–1.24×, collects +18–28 % (§6.4). The past-cap idle thrash is stage C's, +9 %. |
| R10 | **MET hermetically; the in-machine gate is specified, not run** | W16, W16R, W16Rj and W17 fail on stage C 10/10 and pass 30/30. Every new rule has a sabotage that fails it, except the window's arm, which is redundant by design. The amplified probe and the census are specified (§8). |
| R11 | **MET** | `LJ52_GC_LEND` is a compile-time constant; OC's scale is inherited; there is no knob. |
| R12 | **PARTLY** | Capacity ≥ stage C like for like and ≥ stock, hermetically. Near-wall time is not within stage C's figures (1.14–1.24× hermetically). |

---

## 12. Open questions for the user, with the evidence

**1. The kernel's guaranteed room drops from 16 to 12 KiB.**
- *Evidence:* W19 grants 11 KiB and d2's K8 grants 13 KB. Below, the window lies inside the slice.
- *Known kernel-side allocations between resumes:*
  - machine.lua's `table.pack` of a resume's results (~112 B);
  - Java's signal pushes. A network message is at most OC's packet size; 8 KB at its default is my reading of OC's settings, not checked here.
- *What is not guaranteed, before or after:* a component callback's `pushList` of n numbers grows a table to 8 × nextpow2(n) with no checkpoint (u2-checkpoints §2.7). At n = 2 048 that is 16 KB, past the old slice too.
- *Options:*
  - accept 12 KiB;
  - raise `LJ52_GC_KSLICE` to 20 KiB. This keeps 16 KiB, and moves the every-thread bound to cap + G + 20 KiB. It is one line, and changes W10's and W7k's numbers but not their verdicts (not measured).
- *Recommendation:* accept 12 KiB, and watch `CAP-GC`'s kernel figures in the gate.

**2. The unwinder segfault.**
- *Evidence:* latent on stage C (§10), and 0 on the final.
- *Recommendation:*
  - open its own roadmap row now;
  - run the gate's stage-C D-string cells last and count PROC-DEATH;
  - do not block this row on root-causing it. The final does not reach it in 18 432 hermetic tries.
- In a machine it would take the JVM down, which is why the gate stops on any instance in W.

**3. The never-verdict churn band** (§6.4).
- *What it is:* live data within (S, S + churn per cycle] is lent forever, at one full cycle per crossing, and never refused. Its heap is bounded by S + L.
- *When live data is just under S,* the same band is stock's own rate, and correct by R1.
- *One option:* also give the verdict after N consecutive open proofs that found the heap past S. Not built and not measured.
  - N = 2, as d2-lend's V2 grace, made W16 worse (35 landings), because pinned junk spans the batch's last two checkpoints.
  - N ≥ 4 is untested.
- *Recommendation:* accept it for this row, and measure N = 4 and N = 8 as a follow-up with W16, W16R, W16Rj, W17 and K2.

**4. Near-wall cost:** last five 1.14–1.24× stage C's, cycles 1.17–1.25×.
- *Option:* first try d2-verdict's silent past-cap cadence on top of the window's explicit arm. This is the arm that graft 1 now provides.
  - Verdict measured −11 % cycles with it in its own design.
  - Its risk is the one prior #3 named: the heap reaches S fuller of garbage, so checkpoint-free stretches longer than L are refused more often.
- *Recommendation:* accept the cost for this row (criterion 8.3(e)), and measure the silent cadence as stage 2.

**5. The sandbox's bound moves to cap + G + 4 KiB;** every thread's is unchanged. *Recommendation:* accept. W7 and W7k pin both.

**6. Kernel pressure past 512 B per resume.** 85 of 4 096 sandbox downs at 2 KB of kernel garbage per resume, against stage C's 1 318; 0 at 512 B.
- *Option:* d2-lend §9's kernel regime-P retarget at S + L, which costs a cycle per kernel growth while the sandbox sits at its ceiling.
- *Recommendation:* record it as the residual, and size real signal traffic in the gate. `CAP-GC refused=` and the kernel's od_peak attribute any down.

**7. Idle thrash 1 KB under a top:** 12 475 cycles in 3 000 resumes on stage C, 13 604 on the final. It exists at stage C. *Recommendation:* its own row.

**8. Run the in-machine gate before landing.** Yes. It is §8. None of the round's designs ran it, and this synthesis could not.

---

## 13. The residual, in one sentence

A crossing is still refused wherever it lands when its window is overrun before a checkpoint can prove its cycle — more than 4 KiB with no checkpoint, a single request past S + 4 KiB (W9's class), or the kernel's own garbage between resumes taking the heap more than 4 KiB past the sandbox's top before a checkpoint (85 of 4 096 sandbox downs at 2 KB of kernel garbage per resume, 0 at 512 B) — or when its verdict rests on garbage pinned across two consecutive cycles, and with the JIT on a live-data landing at the top remains possible (0–7 per 4 096–16 384-cap sweep, none garbage-covered).

---

## 14. Files and reproduction (all in `scratchpad/wall2/d2-final/`)

**Sources and diffs:**

| file | what |
|---|---|
| `lj52shim.c`, `lj52shim.o` | the final source (md5 `5612639c`) and object (`d1242186`) |
| `lj52shim.orig.c`, `origsrc/` | HEAD's source, and its rebuild to stage C's `0259f0d1` |
| `d2-final-shim.diff` | §2 |
| `mem_test_final.c`, `mkmt_final.py`, `d2-final-mem_test.diff` | the tests (Appendix A) |
| `negative-control.final.sh`, `mknegctl.py`, `d2-final-negctl.diff` | Appendix B |
| `OcljSmoke.final.scala`, `mksmoke.py`, `d2-final-smoke.diff`, `scalac/` | Appendix C, and its compile |

**Scripts:**

| file | what |
|---|---|
| `mk.sh` | `obj <c> <o>`: build-native.sh's line plus `-DLJ52_ADDITIVE`. `mem <test.c> <o> <exe>`: run-mem.sh's line. |
| `build_drv.sh <tag> <o>` | the probe drivers |
| `sweep.sh <tag> <dir>`, `summ.py <dir> <tags…>` | §6.2 |
| `census1.sh`, `census2.sh` | §6.3 |
| `last5.py` | §6.4 |
| `sabotage_final.py <run> [names]` | §7.3 |
| `mkdbg_measure.py` | the instrument check: in-place equals yield measure |

**Results:**

| directory | contents |
|---|---|
| `out1`, `out2`, `out11` | mem_test runs (`out11` is the final 30× and 10×) |
| `out3` | W16R at 96 × 64 |
| `out4`–`out7`, `out12` | sweeps (`out6/summary.txt` is §6.2) |
| `out8` | timing |
| `out9` | idle |
| `out10` | K2 |
| `census/` | the crash census |
| `sab/run1`–`run4` | sabotages (run4 is the final source) |
| `x/` | scratch: cross-runs, the guard check, debug builds |

---

## Appendix A — `test/native/mem_test.c` (d2-final-mem_test.diff)

```diff
--- a/test/native/mem_test.c
+++ b/test/native/mem_test.c
@@ -431,6 +431,9 @@
 #define WALL_ODLIMIT(L)     statn(L, "_OCLJ_WALLSTATS", 5)
 #define WALL_KSLICE(L)      statn(L, "_OCLJ_WALLSTATS", 6)
 #define WALL_LOW(L)         statn(L, "_OCLJ_WALLSTATS", 7)
+#define WALL_LEND(L)        statn(L, "_OCLJ_WALLSTATS", 10)   /* THE WINDOW; -1 before it */
+#define WALL_LENDS(L)       statn(L, "_OCLJ_WALLSTATS", 11)
+#define WALL_WIN(L)         statn(L, "_OCLJ_WALLSTATS", 12)   /* 0 shut, 1 open, 2 the verdict */
 /* lj_gc.h's GC states, by value (the shim spells GCSpause as 0 too). */
 #define W_GCSPAUSE 0
 #define W_GCSSWEEP 4
@@ -615,6 +618,239 @@
   "_OCLJ_WATCHDOG.disarm(t) "
   "__w7 = okr and fails or -1";
 
+#ifndef W16_N
+#define W16_N 96             /* caps in the sweep */
+#endif
+#ifndef W16_STEP
+#define W16_STEP 64          /* bytes between them: 96 x 64 B is one step of the fill */
+#endif
+#ifndef W16R_N
+#define W16R_N 96            /* W16R / W16Rj (at 48 x 128 stage C left 1-2 covered) */
+#endif
+#ifndef W16R_STEP
+#define W16R_STEP 64
+#endif
+/* W16's program: the capacity probe's shape (OcljSmoke.scala, OCLJ_PROBE=
+ * capacity), the residual the collector at the wall left (docs/roadmap.md, "A
+ * refusal at a credit tier's top can land outside the program's handler").  A
+ * sandbox coroutine, resumed under the watchdog's arm as machine.lua resumes
+ * it, fills 100 held 32-character strings per step INSIDE a pcall, with a
+ * churn string per object; BETWEEN steps, outside any handler of its own, it
+ * does what the probe does: the stage string, and event.timer's record for
+ * the next step -- and the dispatcher packs each signal (OpenOS's
+ * pullSignal) outside any handler at all.  The kernel's loop arms, resumes,
+ * packs the results and disarms.  __w16rec(code) records, allocating
+ * nothing: 1 refused inside the handler (the probe's normal end), 2 escaped
+ * step() into the dispatcher's pcall (the probe's STALL), 3 killed the
+ * sandbox (a machine down).  A stall then YIELDS 'stop' and the kernel stops
+ * resuming it: the sandbox stays suspended where it landed, as OpenOS's
+ * would, so the live set read after the run counts its stack (a coroutine
+ * that returned has had its stack shrunk: up to 3.9 KB under, d2-verdict).  Bounded at 400 steps (40 000 strings, ~3 MB, seven
+ * times the cap; see W1's note on bounds). */
+static const char *W16_CHUNK =
+  "local rec, held, count, stage, slot = __w16rec, {}, 0, 'filling/0', {} "
+  "__w16h = held "
+  "local function uniq(len, i) local s = tostring(i) return string.rep('x', len - #s) .. s end "
+  "local step "
+  "step = function() "
+  "  local ok = pcall(function() "
+  "    for k = 1, 100 do "
+  "      count = count + 1 held[count] = uniq(32, count) "
+  "      local junk = uniq(24, count) .. '!' "
+  "    end "
+  "  end) "
+  "  if not ok then rec(1) return end "
+  "  stage = 'filling/' .. count "
+  "  slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 } "
+  "end "
+  "slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 } "
+  "local co = coroutine.create(function() "
+  "  for r = 1, 400 do "
+  "    local sig = table.pack(coroutine.yield()) "
+  "    local hd = slot[1] "
+  "    if not hd then return end "
+  "    slot[1] = nil "
+  "    if not pcall(hd.callback) then rec(2) coroutine.yield('stop') return end "
+  "  end "
+  "end) "
+  "local cb = function() end "
+  "__w16k = function() "
+  "  for r = 1, 402 do "
+  "    local t = _OCLJ_WATCHDOG.arm(3600, cb, true) "
+  "    local res = table.pack(coroutine.resume(co, 'timer')) "
+  "    _OCLJ_WATCHDOG.disarm(t) "
+  "    if not res[1] then rec(3) return end "
+  "    if res[2] == 'stop' or coroutine.status(co) == 'dead' then return end "
+  "  end "
+  "end "
+  /* the largest single object the program allocates outside a handler: the
+   * stage string, event.timer's record, the dispatcher's pack -- measured
+   * here, with the collector stopped, so the case never hardcodes LuaJIT's
+   * object sizes.  The third round counts: the first also pays one-time
+   * allocations (the string buffer, table.pack's first call). */
+  "for round = 1, 3 do "
+  "  collectgarbage('stop') "
+  "  local c0 = collectgarbage('count') "
+  "  local s1 = 'filling/' .. (12345 + round) "
+  "  local c1 = collectgarbage('count') "
+  "  local t1 = { key = false, times = 1, callback = cb, interval = 0, timeout = 0 } "
+  "  local c2 = collectgarbage('count') "
+  "  local p1 = table.pack('timer') "
+  "  local c3 = collectgarbage('count') "
+  "  collectgarbage('restart') "
+  "  __w16dmax = math.max(c1 - c0, c2 - c1, c3 - c2) * 1024 "
+  "end";
+
+/* W16's recorder: what landed where, and the accounted figure at that
+ * moment.  A C function the chunk calls: nothing allocated. */
+static int W16_CODE = 0;
+static long long W16_USED = -1;
+static double W16_DELTA = -1;      /* the refused request, WALLSTATS[13]; -1 before it */
+static int w16_rec(lua_State *L) {
+  W16_CODE = (int)lua_tointeger(L, 1);
+  W16_USED = j_core_used(L);
+  W16_DELTA = statn(L, "_OCLJ_WALLSTATS", 13);
+  return 0;
+}
+
+/* W16R's program: W16's, carried into the RESERVE tier -- the shape every
+ * bad in-machine outcome had (scratchpad wall2/design/u2-stalls.md: each came
+ * at the reserve top, after a FIRST refusal something other than the fill
+ * absorbed).  Here the step's own handler absorbs the first refusal and the
+ * fill goes on with its data kept; at the second it records, drops its data
+ * and stops, as the capacity probe does.  The recorder keeps the FIRST thing
+ * recorded and the tier it happened in (nfail: 0 burst, 1 reserve). */
+static const char *W16R_CHUNK =
+  "local rec, held, count, stage, slot, nfail = __w16rec, {}, 0, 'filling/0', {}, 0 "
+  "__w16h = held "
+  "local function uniq(len, i) local s = tostring(i) return string.rep('x', len - #s) .. s end "
+  "local step "
+  "step = function() "
+  "  local ok = pcall(function() "
+  "    for k = 1, 100 do "
+  "      count = count + 1 held[count] = uniq(32, count) "
+  "      local junk = uniq(24, count) .. '!' "
+  "    end "
+  "  end) "
+  "  if not ok then "
+  "    nfail = nfail + 1 "
+  "    if nfail >= 2 then rec(1, nfail) held = nil __w16h = nil return end "
+  "  end "
+  "  stage = 'filling/' .. count "
+  "  slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 } "
+  "end "
+  "slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 } "
+  "local co = coroutine.create(function() "
+  "  for r = 1, 400 do "
+  "    local sig = table.pack(coroutine.yield()) "
+  "    local hd = slot[1] "
+  "    if not hd then return end "
+  "    slot[1] = nil "
+  "    if not pcall(hd.callback) then rec(2, nfail) coroutine.yield('stop') return end "
+  "  end "
+  "end) "
+  "local cb = function() end "
+  "__w16k = function() "
+  "  for r = 1, 402 do "
+  "    local t = _OCLJ_WATCHDOG.arm(3600, cb, true) "
+  "    local res = table.pack(coroutine.resume(co, 'timer')) "
+  "    _OCLJ_WATCHDOG.disarm(t) "
+  "    if not res[1] then rec(3, nfail) return end "
+  "    if res[2] == 'stop' or coroutine.status(co) == 'dead' then return end "
+  "  end "
+  "end";
+static int W16R_TIER = 0;
+static int w16r_rec(lua_State *L) {
+  if (W16_CODE == 0) {
+    W16_CODE = (int)lua_tointeger(L, 1);
+    W16R_TIER = (int)lua_tointeger(L, 2) > 0;
+    W16_USED = j_core_used(L);
+    W16_DELTA = statn(L, "_OCLJ_WALLSTATS", 13);
+  }
+  return 0;
+}
+
+/* W17's sandbox (d2-verdict): a fill of live 64-byte tables into a
+ * pre-sized holder, inside a pcall, until refused (bounded: 200 000), in a
+ * coroutine resumed under the watchdog's arm -- the sandbox's tops, no
+ * kernel slice.  The holder never grows, so every growth is a TNEW: check
+ * first, then the table, one checkpoint per object. */
+static const char *W17_CHUNK =
+  "local h, n = __w17h, 0 "
+  "local co = coroutine.create(function() "
+  "  local ok = pcall(function() while n < 200000 do n = n + 1 h[n] = {n} end end) "
+  "  coroutine.yield(ok and 1 or 0) "
+  "end) "
+  "local t = _OCLJ_WATCHDOG.arm(3600, function() end, true) "
+  "local okr, r = coroutine.resume(co) "
+  "_OCLJ_WATCHDOG.disarm(t) "
+  "__w17 = okr and r or -1";
+
+/* W18's program (j2-safety's K1): the sandbox fills live tables to
+ * __k1target (1 KB under its burst top), then crosses with ONE allocation no
+ * checkpoint precedes -- mode 1 an array doubling (+32 KB, rawset), mode 2
+ * a concatenation of two kept 10 KB strings -- and yields.  The kernel then
+ * packs, still armed (the first pack is machine.lua's own, of the resume's
+ * results) and after the disarm.  Every one protected here so the case can
+ * count; machine.lua's are not, and a refusal there is a dead machine.
+ * Bounded: 4 000 000 tables (__f is pre-sized from C, so it never grows). */
+static const char *W18_CHUNK =
+  "local f, h = __f, {} for i = 1, 4096 do h[i] = i end __h = h "
+  "local A, B = string.rep('a', __k1cat), string.rep('b', __k1cat) "
+  "local cb = function() end "
+  "local nf = 0 "
+  "__k1r = {0, 0, 0, 0, 0, 0, 0} "
+  "__k1s = false "
+  "local R = __k1r "
+  "local co = coroutine.create(function() "
+  "  local target = __k1target "
+  "  local ok = pcall(function() "
+  "    while nf < 4000000 and collectgarbage('count') * 1024 < target do nf = nf + 1 f[nf] = {nf} end "
+  "  end) "
+  "  if not ok then R[3] = R[3] + 1 end "
+  "  if __k1mode == 1 then "
+  "    if pcall(rawset, h, 4097, true) then R[4] = 1 end "
+  "  elseif __k1mode == 2 then "
+  "    local okc, s = pcall(function() return A .. B end) "
+  "    if okc then __k1s = s R[4] = 1 end "
+  "  end "
+  "  coroutine.yield() "
+  "end) "
+  "__k1run = function() "
+  "  local t = _OCLJ_WATCHDOG.arm(3600, cb, true) "
+  "  local ok0 = pcall(table.pack, coroutine.resume(co)) "
+  "  local k = ok0 and 0 or 1 R[7] = k "
+  "  for i = 1, 6 do if not pcall(table.pack, i, i, i) then k = k + 1 end end "
+  "  _OCLJ_WATCHDOG.disarm(t) "
+  "  local k2 = 0 "
+  "  for i = 1, 6 do if not pcall(table.pack, i, i, i) then k2 = k2 + 1 end end "
+  "  R[1] = k R[2] = k2 R[6] = nf "
+  "end";
+
+/* W19's program (j2-safety's K8, its window-filling mode): the sandbox
+ * makes 8 000 caught attempts to add one live table each, which leaves the
+ * heap at its reserve tier's ceiling -- top plus THE WINDOW; R[5] is the
+ * excursion it reached, read before the kernel allocates.  Then the kernel,
+ * still armed and then at depth 0, makes ONE table of __k8n array slots. */
+static const char *W19_CHUNK =
+  "local h, fails, i = __h, 0, 0 local cb = function() end "
+  "local n8 = __k8n "
+  "__k8r = {0, 0, 0, 0, 0} local R = __k8r "
+  "local co = coroutine.create(function() "
+  "  local function add1() i = i + 1 h[i] = {i} end "
+  "  for attempt = 1, 8000 do if not pcall(add1) then i = i - 1 fails = fails + 1 end end "
+  "end) "
+  "__k8run = function() "
+  "  local t = _OCLJ_WATCHDOG.arm(3600, cb, true) "
+  "  R[1] = coroutine.resume(co) and 1 or 0 "
+  "  R[5] = select(2, _OCLJ_WALLSTATS()) "
+  "  R[2] = pcall(__k8mk, n8) and 1 or 0 "
+  "  _OCLJ_WATCHDOG.disarm(t) "
+  "  R[3] = pcall(__k8mk, n8) and 1 or 0 "
+  "  R[4] = fails "
+  "end";
+static int w19_mk(lua_State *L) { lua_createtable(L, (int)lua_tointeger(L, 1), 0); return 1; }
+
 int main(void) {
   lua_State *L;
   jint used0, used1, used2, usedBeforePush, usedAfterPush;
@@ -1161,6 +1397,37 @@
     ok(rawStatus == LUA_ERRMEM && pushed && u2 > u1,
        "C6 exhausted cap: raw push refused, memo push succeeds, charged", d);
 
+    /* ---- C6b: THE WINDOW is the sandbox's: the kernel has none --------- */
+    /* (d2-prevent's case, with THE WINDOW's state.)  C6 exhausts the RESERVE
+     * top; this one exhausts the kernel's BURST top, the record in BURST and
+     * no verdict standing, where a kernel window would lend the push.  C
+     * frames at depth 0 are the kernel.  The preconditions are asserted, so
+     * the case cannot pass vacuously. */
+    lua_settop(C, 0);
+    j_settotal(C, &CS, 64 * 1024 * 1024);
+    settle_gc(C);
+    lua_gc(C, LUA_GCCOLLECT, 0);
+    settle_gc(C);
+    lua_pushcfunction(C, raw_push);     /* memo warm (C6 pushed it) */
+    lua_checkstack(C, 20);
+    {
+      double tier6 = WALL_ODSTATE(C), win6 = WALL_WIN(C), k6 = WALL_KSLICE(C);
+      long long t6;
+      int i6;
+      u0 = j_used(C, &CS);
+      t6 = u0;
+      for (i6 = 0; i6 < 8; i6++) t6 = u0 - (long long)k6 - w_odmax(t6) / 2;   /* T + G(T)/2 + K == used */
+      j_settotal(C, &CS, (jint)t6);
+      rawStatus = lua_pcall(C, 0, 1, 0);
+      lua_settop(C, 0);
+      j_settotal(C, &CS, 64 * 1024 * 1024);
+      sprintf(d, "burst tier %.0f (want 0), window %.0f (want no verdict: 0, 1, or -1 before THE WINDOW), slice %.0f; "
+                 "cap %ld = used %ld - G/2 - slice: raw push status %d (LUA_ERRMEM=%d)",
+              tier6, win6, k6, (long)t6, (long)u0, rawStatus, LUA_ERRMEM);
+      ok(tier6 == 0 && win6 != 2 && k6 > 0 && rawStatus == LUA_ERRMEM,
+         "C6b the kernel at its burst top: raw push refused (no window)", d);
+    }
+
     /* ---- C7: the accounting switched off, as jnlua's close does ------- */
     u0 = j_used(C, &CS);
     j_settotal(C, &CS, (jint)u0);       /* still not one byte to spare */
@@ -1217,7 +1484,7 @@
   {
     FakeState WS;
     lua_State *W, *Wco;
-    long long base, cap, u0, u1, H, G;
+    long long base, cap, u0, u1, H, G, w16dmax = 256;
     double coll0, coll1, bail0, refu0, arms0, st9, thr, gtot, steps, peak, lim, armedC;
     int round, allok, nreq, st2, st3, nrep;
     double cworst = 0;
@@ -1678,16 +1945,104 @@
     u1 = j_used(W, &WS);
     w_setcap(W, &WS, 64 * 1024 * 1024, 1);   /* nothing below is read at the wall */
     peak = WALL_ODPEAK(W); lim = WALL_ODLIMIT(W);
-    lua_getglobal(W, "__w7");
-    nrep = (int)lua_tointeger(W, -1);
-    lua_pop(W, 1);
-    sprintf(d, "4000 caught attempts past the wall, as the sandbox: status %d, caught %d, refusals +%.0f, collects +%.0f; "
-            "used %ld vs cap %ld; od_peak %.0f, od_limit %.0f",
-            st, nrep, GC_REFUSALS(W) - refu0, GC_COLLECTS(W) - coll0, (long)u1, (long)cap, peak, lim);
-    ok(st == 0 && nrep > 0 && GC_REFUSALS(W) > refu0 && peak >= 0 && lim > 0 && peak <= lim
-         && u1 <= cap + (long long)lim + 2048
-         && GC_COLLECTS(W) - coll0 <= 2 * (GC_REFUSALS(W) - refu0) + 24,
-       "W7 caught refusals cannot push the heap past cap + G", d);
+    {
+      double win = WALL_LEND(W), kslice = WALL_KSLICE(W);
+      if (win < 0) win = 0;                /* a shim before THE WINDOW */
+      lua_getglobal(W, "__w7");
+      nrep = (int)lua_tointeger(W, -1);
+      lua_pop(W, 1);
+      sprintf(d, "4000 caught attempts past the wall, as the sandbox: status %d, caught %d, refusals +%.0f, collects +%.0f; "
+              "used %ld vs cap %ld; od_peak %.0f, od_limit %.0f, window %.0f (slice %.0f)",
+              st, nrep, GC_REFUSALS(W) - refu0, GC_COLLECTS(W) - coll0, (long)u1, (long)cap, peak, lim, win, kslice);
+      /* The sandbox's bound is cap + G + THE WINDOW, and the window must sit
+       * inside the kernel's slice, or the bound over every thread moves. */
+      ok(st == 0 && nrep > 0 && GC_REFUSALS(W) > refu0 && peak >= 0 && lim > 0 && peak <= lim + win
+           && win <= kslice && u1 <= cap + (long long)(lim + win) + 2048
+           && GC_COLLECTS(W) - coll0 <= 2 * (GC_REFUSALS(W) - refu0) + 24,
+         "W7 caught refusals cannot push the heap past cap + G + the window", d);
+    }
+    clear_javastate(W);
+    lua_close(W);
+
+    /* ---- W7k: the bound over every thread, as the kernel ---------------- */
+    /* W7's attempts made by the kernel (main thread, no resume armed): the
+     * kernel has no window -- its slice is past every window -- so its bound
+     * stays cap + G + the slice.  Nothing else pinned it past the kernel's
+     * first refusal (d2-lend: the kernel-window sabotage passed every case). */
+    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
+    if (!W) { printf("  FAIL  W7k: no state\n"); return 1; }
+    runstr(W, "jit.off() __w7k = 0");
+    lua_gc(W, LUA_GCCOLLECT, 0);
+    lua_gc(W, LUA_GCCOLLECT, 0);
+    settle_gc(W);
+    lua_settop(W, 0);
+    cap = j_used(W, &WS) + 256 * 1024;
+    w_setcap(W, &WS, cap, 1);
+    refu0 = GC_REFUSALS(W);
+    st = runstr(W, "local h, fails, cur = {}, 0, 0 "
+                   "local function add() for k = 1, 64 do h[#h + 1] = {cur, k} end end "
+                   "for i = 1, 4000 do cur = i if not pcall(add) then fails = fails + 1 end end "
+                   "__w7k = fails");
+    lua_settop(W, 0);
+    u1 = j_used(W, &WS);
+    w_setcap(W, &WS, 64 * 1024 * 1024, 1);
+    peak = WALL_ODPEAK(W); lim = WALL_ODLIMIT(W);
+    {
+      double kslice = WALL_KSLICE(W), win = WALL_LEND(W);
+      if (win < 0) win = 0;                /* a shim before THE WINDOW */
+      lua_getglobal(W, "__w7k");
+      nrep = (int)lua_tointeger(W, -1);
+      lua_pop(W, 1);
+      sprintf(d, "4000 caught attempts past the wall, as the kernel: status %d, caught %d, refusals +%.0f; "
+              "used %ld vs cap %ld; od_peak %.0f, od_limit %.0f, window %.0f, slice %.0f",
+              st, nrep, GC_REFUSALS(W) - refu0, (long)u1, (long)cap, peak, lim, win, kslice);
+      /* Not vacuous: the kernel went past the sandbox's ceiling (G + the
+       * window) into its slice, so this is the kernel's bound being held. */
+      ok(st == 0 && nrep > 0 && GC_REFUSALS(W) > refu0 && lim > 0 && kslice > 0
+           && peak > lim + win && peak <= lim + kslice && u1 <= cap + (long long)(lim + kslice) + 2048,
+         "W7k as the kernel, past the sandbox's ceiling, under cap + G + the slice", d);
+    }
+    clear_javastate(W);
+    lua_close(W);
+
+    /* ---- W17: a live fill is refused past the top, inside half the window */
+    /* THE WINDOW (d2-final): a sandbox growth past its tier's top is lent,
+     * and the cycle armed for it decides.  A fill of LIVE data survives two
+     * consecutive cycles, so the verdict refuses it within a few objects of
+     * the top: past it -- stage C refused AT the top with its garbage
+     * uncollected (od_peak <= G/2: this case fails first there) -- and well
+     * before the window's ceiling (the window is not a third tier).  From
+     * d2-verdict's W17 and d2-prevent's W17, with THE WINDOW's bounds. */
+    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
+    if (!W) { printf("  FAIL  W17: no state\n"); return 1; }
+    runstr(W, "jit.off() __w17 = 0");
+    lua_createtable(W, 8192, 0);            /* the holder, pre-sized: 64 KB, never grown */
+    lua_setglobal(W, "__w17h");
+    lua_gc(W, LUA_GCCOLLECT, 0);
+    lua_gc(W, LUA_GCCOLLECT, 0);
+    settle_gc(W);
+    lua_settop(W, 0);
+    cap = j_used(W, &WS) + 256 * 1024;
+    w_setcap(W, &WS, cap, 1);
+    refu0 = GC_REFUSALS(W);
+    st = runstr(W, W17_CHUNK);
+    w_setcap(W, &WS, 64 * 1024 * 1024, 1);
+    peak = WALL_ODPEAK(W);
+    G = w_odmax(cap);
+    {
+      double win = WALL_LEND(W);
+      if (win < 0) win = 0;                /* a shim before THE WINDOW */
+      lua_getglobal(W, "__w17");
+      nrep = (int)lua_tointeger(W, -1);
+      lua_pop(W, 1);
+      sprintf(d, "sandbox fill of live 64 B tables, cap %ld, G %ld: status %d, caught %s, refusals +%.0f; od_peak %.0f "
+                 "(the top G/2 = %ld; half the window past it = %.0f)",
+              (long)cap, (long)G, st, nrep == 0 ? "yes" : "NO", GC_REFUSALS(W) - refu0, peak,
+              (long)(G / 2), (double)(G / 2) + win / 2);
+      ok(st == 0 && nrep == 0 && GC_REFUSALS(W) - refu0 == 1
+           && peak > (double)(G / 2) && peak <= (double)(G / 2) + win / 2,
+         "W17 a live fill is refused past the top, inside half the window", d);
+    }
     clear_javastate(W);
     lua_close(W);
 
@@ -1755,6 +2110,253 @@
     lua_settop(W, 0);
     clear_javastate(W);
     lua_close(W);
+
+    /* ---- W16: a refusal at the credit's top lands outside the handler -- */
+    w16dmax = 256;
+    /* The residual row (docs/roadmap.md, found 2026-10-04): stage B saw 3
+     * stalls and a dropin down in 68 capacity runs, stage C one stall in 49,
+     * stock none.  Hermetically (wall2/repro, 2026-10-04): with the live data
+     * inside the burst tier, the last cycle the cadence arms runs at a
+     * checkpoint inside the batch, while the batch's own churn is still in
+     * its frame; the batch returns, that churn is garbage, and the next
+     * request -- the stage string or event.timer's record (allocate-first:
+     * lj_meta_cat, lj_tab_dup's hash part), or the dispatcher's pack on the
+     * next resume after the kernel spent its slice -- does not fit under
+     * cap + G/2 and is refused before any checkpoint can collect it.  Stock
+     * collects at the refusal (lmem.c:85-93) and the request fits.
+     *
+     * The sweep moves the cap through one step's worth of the fill (100
+     * strings of ~60 B: one period of where the top falls in the program).
+     * For every run whose refusal landed OUTSIDE the batch's handler (the
+     * stall, or the sandbox killed) it collects twice and asks whether the
+     * live set, plus the request that was refused (WALLSTATS[13]; on a shim
+     * that does not report it, the LARGEST object the program allocates
+     * outside a handler, measured, not hardcoded), fits under the sandbox's
+     * burst top.  If it does, a collection at the refusal would have made
+     * room and the program would have gone on: that is the failure.  The
+     * live set is read with the sandbox still suspended where it landed (a
+     * stall yields; a killed sandbox is dead), so it counts the sandbox's
+     * stack as the program would hold it.  A refusal outside the handler
+     * that garbage could NOT have covered is stock's behaviour too and is
+     * not counted. */
+    {
+      int k, nin = 0, nstall = 0, ndown = 0, nother = 0, ncov = 0;
+      long long dmax = 0, L16, top16, off;
+      char first[200];
+      first[0] = 0;
+      for (k = 0; k < W16_N; k++) {
+        off = (long long)k * W16_STEP;
+        W = w_newstate(&WS, 64 * 1024 * 1024, 1);
+        if (!W) { printf("  FAIL  W16: no state\n"); return 1; }
+        runstr(W, "jit.off() __w16k = false __w16dmax = 0");
+        lua_pushcfunction(W, w16_rec);
+        lua_setglobal(W, "__w16rec");
+        if (runstr(W, W16_CHUNK) != 0) { printf("  FAIL  W16: the chunk: %s\n", errtop(W)); return 1; }
+        lua_getglobal(W, "__w16dmax");
+        dmax = (long long)lua_tonumber(W, -1);
+        lua_settop(W, 0);
+        lua_gc(W, LUA_GCCOLLECT, 0);
+        lua_gc(W, LUA_GCCOLLECT, 0);
+        settle_gc(W);
+        lua_getglobal(W, "__w16k");             /* on the stack while there is room */
+        base = j_used(W, &WS);
+        cap = base + 384 * 1024 + off;
+        W16_CODE = 0; W16_USED = -1; W16_DELTA = -1;
+        w_setcap(W, &WS, cap, 1);
+        st = lua_pcall(W, 0, 0, 0);
+        w_setcap(W, &WS, 64 * 1024 * 1024, 1);
+        lua_settop(W, 0);
+        lua_gc(W, LUA_GCCOLLECT, 0);
+        lua_gc(W, LUA_GCCOLLECT, 0);
+        L16 = j_used(W, &WS);                   /* the live set the refusal left */
+        top16 = cap + w_odmax(cap) / 2;         /* the sandbox's burst tier: no slice */
+        if (st != 0 || W16_CODE == 0) nother++;
+        else if (W16_CODE == 1) nin++;
+        else {
+          if (W16_CODE == 2) nstall++; else ndown++;
+          if (L16 + (W16_DELTA > 0 ? (long long)W16_DELTA : dmax) <= top16) {
+            if (ncov == 0)
+              sprintf(first, "; first at cap = base + 384 KB + %lld: %s, request %.0f, used %lld, live %lld, top %lld",
+                      off, W16_CODE == 2 ? "stall" : "sandbox down", W16_DELTA, W16_USED, L16, top16);
+            ncov++;
+          }
+        }
+        clear_javastate(W);
+        lua_close(W);
+      }
+      sprintf(d, "%d caps, base + 384 KB + 0..%d B: inside %d, stall %d, sandbox down %d, other %d; "
+                 "outside with room after a collection for the refused request (or %lld B): %d%.180s",
+              W16_N, (W16_N - 1) * W16_STEP, nin, nstall, ndown, nother, dmax, ncov, first);
+      ok(nin > 0 && ncov == 0, "W16 no refusal outside the handler that garbage covers", d);
+      w16dmax = dmax;
+    }
+
+    /* ---- W16R / W16Rj: the same, carried into the reserve tier -------- */
+    /* The in-machine stalls and the dropin's down all came at the RESERVE
+     * top (u2-stalls.md).  W16's program, but its handler absorbs the first
+     * refusal and the fill goes on, data kept; the second refusal must land
+     * inside the handler unless garbage could not have covered it.  Stage C,
+     * hermetically (d2-lend, 4096 caps): 169 outside with the JIT off, 1847
+     * with it on (all but 43 covered).  A landing is judged against the tier
+     * it happened in: cap + G/2 before the first refusal, cap + G after. */
+    for (round = 0; round < 2; round++) {
+      int k, nin = 0, nstall = 0, ndown = 0, nother = 0, ncov = 0;
+      long long dmax = w16dmax, Lr, topr, off;
+      char first[200];
+      first[0] = 0;
+      for (k = 0; k < W16R_N; k++) {
+        off = (long long)k * W16R_STEP;
+        W = w_newstate(&WS, 64 * 1024 * 1024, 1);
+        if (!W) { printf("  FAIL  W16R: no state\n"); return 1; }
+        runstr(W, round == 0 ? "jit.off() __w16k = false" : "jit.on() __w16k = false");
+        lua_pushcfunction(W, w16r_rec);
+        lua_setglobal(W, "__w16rec");
+        if (runstr(W, W16R_CHUNK) != 0) { printf("  FAIL  W16R: the chunk: %s\n", errtop(W)); return 1; }
+        lua_settop(W, 0);
+        lua_gc(W, LUA_GCCOLLECT, 0);
+        lua_gc(W, LUA_GCCOLLECT, 0);
+        settle_gc(W);
+        lua_getglobal(W, "__w16k");
+        base = j_used(W, &WS);
+        cap = base + 384 * 1024 + off;
+        W16_CODE = 0; W16_USED = -1; W16_DELTA = -1; W16R_TIER = 0;
+        w_setcap(W, &WS, cap, 1);
+        st = lua_pcall(W, 0, 0, 0);
+        w_setcap(W, &WS, 64 * 1024 * 1024, 1);
+        lua_settop(W, 0);
+        lua_gc(W, LUA_GCCOLLECT, 0);
+        lua_gc(W, LUA_GCCOLLECT, 0);
+        Lr = j_used(W, &WS);
+        topr = cap + (W16R_TIER ? w_odmax(cap) : w_odmax(cap) / 2);
+        if (st != 0 || W16_CODE == 0) nother++;
+        else if (W16_CODE == 1) nin++;
+        else {
+          if (W16_CODE == 2) nstall++; else ndown++;
+          if (Lr + (W16_DELTA > 0 ? (long long)W16_DELTA : dmax) <= topr) {
+            if (ncov == 0)
+              sprintf(first, "; first at cap = base + 384 KB + %lld: %s in the %s tier, request %.0f, used %lld, live %lld, top %lld",
+                      off, W16_CODE == 2 ? "stall" : "sandbox down", W16R_TIER ? "reserve" : "burst", W16_DELTA, W16_USED, Lr, topr);
+            ncov++;
+          }
+        }
+        clear_javastate(W);
+        lua_close(W);
+      }
+      sprintf(d, "%d caps, base + 384 KB + 0..%d B: second refusal inside %d, stall %d, sandbox down %d, other %d; "
+                 "outside with room after a collection for the refused request (or %lld B): %d%.180s",
+              W16R_N, (W16R_N - 1) * W16R_STEP, nin, nstall, ndown, nother, dmax, ncov, first);
+      ok(nin > 0 && ncov == 0, round == 0 ? "W16R the reserve tier: no refusal outside the handler that garbage covers"
+                                          : "W16Rj the same with the JIT on", d);
+    }
+
+    /* ---- W18: the kernel's packs after a sandbox crossing ---------------- */
+    /* (j2-safety's K1.)  machine.lua packs every resume's results with no
+     * handler: a kernel refusal there is a machine down.  The sandbox fills
+     * live data to 1 KB under its burst top and crosses it with one
+     * allocation no checkpoint precedes, kept live: an array doubling (+32
+     * KB) or a 20 KB concatenation.  At caps of 4 and 10 MB -- G 256 to 512
+     * KB, where a window sized by G instead of a constant would pass the
+     * kernel's slice (d2-verdict's first FATAL) -- in C mode and legacy.  The
+     * kernel is never refused: whatever the sandbox was lent stays under its
+     * ceiling, LJ52_GC_KSLICE - LJ52_GC_LEND below the kernel's top. */
+    {
+      static const long long xkb[4] = { 4096, 4096, 10240, 10240 };
+      static const int xmode[4] = { 1, 2, 1, 2 }, xho[4] = { 1, 0, 0, 1 };
+      int k, bad = 0;
+      char one[160];
+      d[0] = 0;
+      for (k = 0; k < 4; k++) {
+        double r[8];
+        long long Nf, S18;
+        int i;
+        W = w_newstate(&WS, 64 * 1024 * 1024, xho[k]);
+        if (!W) { printf("  FAIL  W18: no state\n"); return 1; }
+        runstr(W, "jit.off()");
+        Nf = 1;
+        while (Nf < (xkb[k] * 1024 + 600 * 1024) / 64 + 4096) Nf <<= 1;
+        lua_createtable(W, (int)Nf, 0);   /* the fill's holder: never grown */
+        lua_setglobal(W, "__f");
+        runstr(W, xmode[k] == 1 ? "__k1cat = 10000 __k1mode = 1 __k1target = 0"
+                                : "__k1cat = 10000 __k1mode = 2 __k1target = 0");
+        if (runstr(W, W18_CHUNK) != 0) { printf("  FAIL  W18: the chunk: %s\n", errtop(W)); return 1; }
+        lua_settop(W, 0);
+        lua_gc(W, LUA_GCCOLLECT, 0);
+        lua_gc(W, LUA_GCCOLLECT, 0);
+        settle_gc(W);
+        lua_getglobal(W, "__k1run");
+        base = j_used(W, &WS);
+        cap = base + xkb[k] * 1024;
+        S18 = cap + w_odmax(cap) / 2;
+        lua_pushnumber(W, (lua_Number)(S18 - 1024));
+        lua_setglobal(W, "__k1target");   /* an existing key: nothing allocated */
+        w_setcap(W, &WS, cap, xho[k]);
+        st = lua_pcall(W, 0, 0, 0);
+        w_setcap(W, &WS, 64 * 1024 * 1024, xho[k]);
+        peak = WALL_ODPEAK(W);
+        lua_settop(W, 0);
+        lua_getglobal(W, "__k1r");
+        for (i = 1; i <= 7; i++) { lua_rawgeti(W, -1, i); r[i] = lua_tonumber(W, -1); lua_pop(W, 1); }
+        lua_pop(W, 1);
+        if (st != 0 || r[7] != 0 || r[1] != 0 || r[2] != 0) bad++;
+        sprintf(one, "%s%lld MB %s %s: st %d, kernel refused %.0f/%.0f/%.0f, fill refused %.0f, crossing %s, peak-G/2 %.0f",
+                k ? "; " : "", xkb[k] / 1024, xmode[k] == 1 ? "doubling" : "concat", xho[k] ? "C" : "legacy",
+                st, r[7], r[1], r[2], r[3], r[4] ? "lent" : "refused", peak - (double)(w_odmax(cap) / 2));
+        strncat(d, one, sizeof d - strlen(d) - 1);
+        clear_javastate(W);
+        lua_close(W);
+      }
+      ok(bad == 0, "W18 the kernel's packs after a sandbox crossing, 4 and 10 MB", d);
+    }
+
+    /* ---- W19: the kernel's room after the sandbox spent its window ------ */
+    /* (j2-safety's K8.)  8 000 caught attempts to add one live table leave
+     * the sandbox at its reserve tier's ceiling, top plus THE WINDOW (the
+     * case asserts it got within 1 KB of it before the kernel allocates);
+     * then the kernel, still armed and then at depth 0, makes ONE table of
+     * (slice - window - 1 KB) of array.  The kernel keeps its slice less the
+     * window past the sandbox's ceiling: 12 KB, against stage C's 16. */
+    {
+      double r[6], kslice, win;
+      int i, n19;
+      W = w_newstate(&WS, 64 * 1024 * 1024, 1);
+      if (!W) { printf("  FAIL  W19: no state\n"); return 1; }
+      runstr(W, "jit.off()");
+      kslice = WALL_KSLICE(W);
+      win = WALL_LEND(W);
+      if (win < 0) win = 0;                /* a shim before THE WINDOW */
+      n19 = (int)((kslice - win - 1024) / 8);
+      lua_createtable(W, 8192, 0);
+      lua_setglobal(W, "__h");
+      lua_pushcfunction(W, w19_mk);
+      lua_setglobal(W, "__k8mk");
+      lua_pushnumber(W, (lua_Number)n19);
+      lua_setglobal(W, "__k8n");
+      if (runstr(W, W19_CHUNK) != 0) { printf("  FAIL  W19: the chunk: %s\n", errtop(W)); return 1; }
+      lua_settop(W, 0);
+      lua_gc(W, LUA_GCCOLLECT, 0);
+      lua_gc(W, LUA_GCCOLLECT, 0);
+      settle_gc(W);
+      lua_getglobal(W, "__k8run");
+      base = j_used(W, &WS);
+      cap = base + 256 * 1024;
+      G = w_odmax(cap);
+      w_setcap(W, &WS, cap, 1);
+      st = lua_pcall(W, 0, 0, 0);
+      w_setcap(W, &WS, 64 * 1024 * 1024, 1);
+      lua_settop(W, 0);
+      lua_getglobal(W, "__k8r");
+      for (i = 1; i <= 5; i++) { lua_rawgeti(W, -1, i); r[i] = lua_tonumber(W, -1); lua_pop(W, 1); }
+      lua_pop(W, 1);
+      sprintf(d, "slice %.0f, window %.0f, G %ld: sandbox resumed %.0f, refused %.0f times, reached G + %.0f; "
+                 "the kernel's one %d-slot table: armed %s, at depth 0 %s",
+              kslice, win, (long)G, r[1], r[4], r[5] - (double)G, n19,
+              r[2] == 1 ? "granted" : "REFUSED", r[3] == 1 ? "granted" : "REFUSED");
+      ok(st == 0 && r[1] == 1 && r[4] >= 2 && kslice > 0 && r[5] >= (double)G + win - 1024
+           && r[2] == 1 && r[3] == 1,
+         "W19 the kernel keeps its slice less the window", d);
+      clear_javastate(W);
+      lua_close(W);
+    }
   }
 
   /* M9 -- the M state never handed over, and nothing in the shim does it
```

## Appendix B — `test/native/negative-control.sh` (d2-final-negctl.diff)

```diff
--- a/test/native/negative-control.sh
+++ b/test/native/negative-control.sh
@@ -278,8 +278,10 @@
   d=$WORK/$v
   "$CC" -c -O2 -I"$LJ" -I"$d" -I"$OCLJ_SER" -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" "$d/lj52shim.c" -o "$d/lj52shim.o" 2>"$d/shim.err" \
     || { sed -n '1,25p' "$d/shim.err"; fail "$v: lj52shim.c did not compile"; }
+  # MEMTEST_CFLAGS: set for one variant only, when a sabotage makes the W16
+  # sweeps cost thousands of cycles a cap (nohyst, unbounded): -DW16_N=8 -DW16R_N=8.
   "$CC" -O2 -I"$LJ" -I"$d" -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" -include "$d/lj52shim.h" \
-    "$SELF_DIR/mem_test.c" "$d/lj52shim.o" "$OBJ/eris_lj.o" \
+    ${MEMTEST_CFLAGS:-} "$SELF_DIR/mem_test.c" "$d/lj52shim.o" "$OBJ/eris_lj.o" \
     "$LJ/libluajit.a" -lm -o "$d/mem_test.exe" 2>"$d/test.err" \
     || { sed -n '1,25p' "$d/test.err"; fail "$v: mem_test.c did not link"; }
 }
@@ -371,9 +373,12 @@
 #      uncharged state never arms, refuses or lends, so there is no cycle to
 #      park, restart or prove and no wall to recover at; W2c's retry succeeds
 #      anyway when nothing is ever refused
+# C6b W7k W16 W16R W16Rj W17 W19  (THE WINDOW, 2026-10-05) nothing is refused,
+#      so no fill stops inside a handler, no window opens, no kernel bound is met;
+#      W18 still passes: with nothing refused the kernel is never refused either
 expect_mem stopgap "a discarded allocator swap is caught" 1 \
-  M3 M3b M3c M4 M4c M5 M6b M7 M9 P1a P2a P2b P2c P2e P2f P2g P2h C0b C0d C3a C4b C5a C5b C6 \
-  W1 W1L W1j W2b W2d W3 W4 W5a W5b W5c W7 W8 W10 W11 W12 W13 W14 W15
+  M3 M3b M3c M4 M4c M5 M6b M7 M9 P1a P2a P2b P2c P2e P2f P2g P2h C0b C0d C3a C4b C5a C5b C6 C6b \
+  W1 W1L W1j W2b W2d W3 W4 W5a W5b W5c W7 W7k W8 W10 W11 W12 W13 W14 W15 W16 W16R W16Rj W17 W19
 
 
 # --- 4.2 nopending: drop the pre-binding bytes instead of banking them
@@ -461,8 +466,11 @@
 # 4.6 nocredit: refuse at the cap, as before the change.  Every recovery
 # fails (W1 x3, W8), the lent request (W2d), the trace exit's restore (W3),
 # the kernel after the sandbox (W10), the reload (W11).
+# Since THE WINDOW (2026-10-05): its tops are the credit's, so the W16 family
+# and W17 lose them; and the kernel's slice is part of the credit, so W7k, W18
+# and W19 (the kernel's room) go with it.
 sabotage_mem nocredit 's|^  c = lj52_gc_odmax(total);$|  return 0;  /* sabotage: no credit */|' 'sabotage: no credit'
-expect_mem nocredit "refusing at the cap again is caught" 1 W1 W1L W1j W2d W3 W8 W10 W11
+expect_mem nocredit "refusing at the cap again is caught" 1 W1 W1L W1j W2d W3 W8 W10 W11 W16 W16R W16Rj W17 W18 W19 W7k
 
 # 4.7 norefusedarm: a refusal that does not arm -- the request bigger than
 # the headroom, refused with the garbage that would cover it uncollected.
@@ -472,7 +480,8 @@
 # 4.8 nohyst: re-arm at the watermark after every proven cycle, the old
 # cadence: a full cycle per checkpoint pair near the wall (W4), and a fill
 # that costs ~1840 cycles a round (W12).
-sabotage_mem nohyst 's|^  if (!M->gc_hyst) {$|  if (1) {  /* sabotage: no hysteresis */|' 'sabotage: no hysteresis'
+# The W16 family at 8 caps: a cycle per checkpoint makes the full sweeps ~3 min.
+MEMTEST_CFLAGS="-DW16_N=8 -DW16R_N=8" sabotage_mem nohyst 's|^  if (!M->gc_hyst) {$|  if (1) {  /* sabotage: no hysteresis */|' 'sabotage: no hysteresis'
 expect_mem nohyst "the per-checkpoint re-arm is caught" 1 W4 W12
 
 # 4.9 unbounded: credit = the whole cap.  The bound is what fails: the
@@ -480,13 +489,20 @@
 # C3a), the cases that need a refusal where the credit would have run out
 # (W1 x3, W2b, W11), and the fill's cost: the whole cap lent past the cap is
 # a band of total bytes to halve through, 2921 cycles a round (W12).
-sabotage_mem unbounded 's|^  c = lj52_gc_odmax(total);$|  c = total;  /* sabotage: credit = total */|' 'sabotage: credit = total'
-expect_mem unbounded "an unbounded credit is caught" 1 C3a M5 W1 W11 W12 W1L W1j W2b W7
+# Since THE WINDOW: the kernel's burst top is past the whole cap (C6b), the
+# kernel's bound (W7k) and the live fill's refusal near the top (W17) go too.
+# The W16 family at 8 caps: under a credit of the whole cap each sweep cap
+# costs thousands of cycles (d2-lend: past 300 s at 96 caps).
+MEMTEST_CFLAGS="-DW16_N=8 -DW16R_N=8" sabotage_mem unbounded 's|^  c = lj52_gc_odmax(total);$|  c = total;  /* sabotage: credit = total */|' 'sabotage: credit = total'
+expect_mem unbounded "an unbounded credit is caught" 1 C3a C6b M5 W1 W11 W12 W17 W1L W1j W2b W7 W7k
 
 # 4.10 nokslice: the kernel's slice gone; the kernel's table.pack after the
 # sandbox spent both tiers is refused.
+# Since THE WINDOW: after the sandbox's second refusal the kernel's per-resume
+# pack has no room (W16R, W16Rj), the kernel's bound and its room are gone
+# (W7k, W19).
 sabotage_mem nokslice 's|^  if (lj52_gc_kernel(M, g)) c += LJ52_GC_KSLICE;$|  /* sabotage: no kernel slice */|' 'sabotage: no kernel slice'
-expect_mem nokslice "the kernel without its slice is caught" 1 W10
+expect_mem nokslice "the kernel without its slice is caught" 1 W10 W16R W16Rj W19 W7k
 
 # 4.11 nofresh: a fresh record past total + G/2 takes the burst tier, so the
 # first allocation after a reload is refused.
@@ -497,7 +513,10 @@
 # design's rule.  A program that allocates between the catch and the drop
 # (W8) is refused again; the reload's derived reserve is lost too (W11).
 sabotage_mem closereserve 's|^      if (used <= total) M->gc_odstate = LJ52_OD_BURST;   /\* repaid \*/$|      M->gc_odstate = LJ52_OD_BURST;  /* sabotage: every proof closes the reserve */|' 'sabotage: every proof closes the reserve'
-expect_mem closereserve "a reserve that every proof closes is caught" 1 W8 W11
+# Since THE WINDOW: the first refusal's room is lost to the next proof, so the
+# reserve-tier sweep with the JIT on lands outside (W16Rj), and neither the
+# sandbox (W19) nor the kernel (W7k) reaches the reserve top they are checked at.
+expect_mem closereserve "a reserve that every proof closes is caught" 1 W8 W11 W16Rj W19 W7k
 
 # 4.13 flushwhole: the flush asked for inside the whole watermark again, as
 # until stage C.  A machine holding live data with 100 KB free of a 300 KB
@@ -506,6 +525,54 @@
 sabotage_mem flushwhole 's|^#define LJ52_GC_FLUSHSHIFT 1 |#define LJ52_GC_FLUSHSHIFT 0 /* sabotage: the whole watermark */ |' 'sabotage: the whole watermark'
 expect_mem flushwhole "a flush asked for at the whole watermark is caught" 1 W15
 
+# --- 4.14-4.21: THE WINDOW (2026-10-05; lj52shim.c THE WINDOW) ---------
+# 4.14 nowindow: refuse at the tier's top again, as stage C did: the
+# garbage-covered refusals outside the handler come back (W16, W16R, W16Rj),
+# a live fill is refused AT the top (W17), and the sandbox no longer reaches
+# its ceiling, which W19 asserts before it measures the kernel's room.
+sabotage_mem nowindow 's|^  if (used + delta > top + LJ52_GC_LEND) return 0;      /\* the ceiling \*/$|  return 0;  /* sabotage: no window */|' 'sabotage: no window'
+expect_mem nowindow "a tier top that lends nothing is caught" 1 W16 W16R W16Rj W17 W19
+
+# 4.15 noceiling: the window lends without a ceiling -- the bound (W7), the
+# reload's 32 KB request past the reserve top (W11), the kernel refused for
+# the sandbox's lent data (W18) and left no room (W19).
+sabotage_mem noceiling 's|^  if (used + delta > top + LJ52_GC_LEND) return 0;      /\* the ceiling \*/$|  /* sabotage: no ceiling */|' 'sabotage: no ceiling'
+expect_mem noceiling "a window without a ceiling is caught" 1 W7 W11 W18 W19
+
+# 4.16 slicewindow: a window as wide as the kernel's slice (what the
+# compile-time guard forbids for LJ52_GC_LEND itself): the sandbox's bound
+# (W7) and the kernel's room after it (W19).
+sabotage_mem slicewindow 's|^  if (used + delta > top + LJ52_GC_LEND) return 0;      /\* the ceiling \*/$|  if (used + delta > top + LJ52_GC_KSLICE) return 0;  /* sabotage: a window as wide as the slice */|' 'sabotage: a window as wide as the slice'
+expect_mem slicewindow "a window as wide as the slice is caught" 1 W7 W19
+
+# 4.17 rawverdict: the verdict on one proof's raw heap, which counts the
+# junk the batch's frame still pinned at its last checkpoint.
+sabotage_mem rawverdict 's|^        M->gc_win = used <= top ? 0 : used - M->gc_grown > top ? 2 : 1;$|        M->gc_win = used <= top ? 0 : 2;  /* sabotage: the verdict on the raw heap */|' 'sabotage: the verdict on the raw heap'
+expect_mem rawverdict "a verdict on one proof is caught" 1 W16 W16R W16Rj
+
+# 4.18 nolook: the proof read one allocator call late: the decision reaches
+# the second allocation after the cycle, the stage string outside the handler.
+sabotage_mem nolook 's|^  if (M->gc_armed) lj52_gc_pressure(M, total, used, LJ52_GP_FREE);$|  (void)M; (void)total; (void)used;  /* sabotage: the proof read late */|' 'sabotage: the proof read late'
+expect_mem nolook "a proof read late is caught" 1 W16 W16R
+
+# 4.19 refusalkeeps: a refusal leaves the window's verdict standing, so the
+# program's next allocation after a caught refusal is refused before the
+# refusal's own cycle can run (W16Rj), and the sandbox never reaches its
+# ceiling (W19).
+sabotage_mem refusalkeeps 's|^  M->gc_win = 0;                        /\* THE WINDOW: its cycle decides anew \*/$|  /* sabotage: a refusal keeps the window */|' 'sabotage: a refusal keeps the window'
+expect_mem refusalkeeps "a refusal that keeps the verdict is caught" 1 W16Rj W19
+
+# 4.20 kernelwindow: the kernel lends too -- its burst top is no longer hard
+# (C6b) and its bound moves past cap + G + the slice (W7k).
+sabotage_mem kernelwindow 's|^  if ((g->hookmask \& HOOK_GC) \|\| g->gc\.threshold == LJ_MAX_MEM \|\| lj52_gc_kernel(M, g))$|  if ((g->hookmask \& HOOK_GC) \|\| g->gc.threshold == LJ_MAX_MEM)  /* sabotage: the kernel lends too */|' 'sabotage: the kernel lends too'
+expect_mem kernelwindow "a kernel window is caught" 1 C6b W7k
+
+# 4.21 noarm: nothing arms the window's cycle -- neither its own arm nor THE
+# CADENCE past the top (each alone is enough; measured: either removed alone
+# fails nothing) -- so a live fill runs on to the window's ceiling (W17).
+sabotage_mem noarm 's|^  if (!M->gc_armed) lj52_gc_arm(M, g, LJ52_ARM_WALL);   /\* the window.s cycle \*/$|  /* sabotage: the window arms nothing */|; s|^    arm = top - used < (top - M->gc_low) >> 1;$|    arm = used <= top \&\& top - used < (top - M->gc_low) >> 1;  /* sabotage: nor the cadence past the top */|' 'sabotage: nor the cadence past the top'
+expect_mem noarm "a window whose cycle nothing arms is caught" 1 W17
+
 # =====================================================================
 # 6. THE WATCHDOG.  Two sabotages, each the design's own "before" picture:
 #    one keeps OC's standing hook (the JIT thrashes), one removes the async
```

## Appendix C — `test/native/OcljSmoke.scala` (d2-final-smoke.diff; compiled, not run)

```diff
--- a/test/native/OcljSmoke.scala
+++ b/test/native/OcljSmoke.scala
@@ -3149,18 +3149,22 @@
       |local gpu = component.gpu
       |local nonce = string.format("%.4f-%d", computer.uptime(), math.random(100000, 999999))
       |local SHAPE = "%%SHAPE%%"
-      |local BATCH = 100
+      |local BATCH = %%BATCH%%
       |local n = 0
       |local stage = "armed"
       |local held, count, batches = nil, 0, 0
       |local tfirst, ring = 0, {0, 0, 0, 0, 0}
       |local freeAt, totalKB = -1, -1
+      |-- OCLJCAPX (THE WINDOW's gate): steps entered, the count when event.timer last
+      |-- returned, paints refused, errors that reached event.onError.  Numbers only.
+      |local entered, timed, pf, oe = 0, 0, 0, 0
       |local function paint()
       |  local tlast = ring[1] + ring[2] + ring[3] + ring[4] + ring[5]
       |  gpu.set(1, 15, "OCLJNONCE=" .. nonce .. " OCLJCTR=" .. n .. "        ")
       |  gpu.set(1, 16, "OCLJCAP=" .. stage .. "        ")
       |  gpu.set(1, 17, "OCLJCAPT=" .. string.format("%.4f/%.4f/%d", tfirst, tlast, batches) .. "        ")
       |  gpu.set(1, 18, "OCLJCAPF=" .. freeAt .. "/" .. totalKB .. "        ")
+      |  gpu.set(1, 19, "OCLJCAPX=" .. entered .. "/" .. timed .. "/" .. pf .. "/" .. oe .. "        ")
       |end
       |local function uniq(len, i) local s = tostring(i) return string.rep("x", len - #s) .. s end
       |local makers = {
@@ -3172,13 +3176,14 @@
       |local make = makers[SHAPE]
       |local step
       |step = function()
+      |  entered = entered + 1
       |  local t0 = os.clock()
       |  local ok, err = pcall(function()
       |    for k = 1, BATCH do
       |      local o = make(count + 1)
       |      held[count + 1] = o
       |      count = count + 1
-      |      local junk = uniq(24, count) .. "!"
+      |      local junk = uniq(%%JUNK%%, count) .. "!"
       |    end
       |  end)
       |  local dt = os.clock() - t0
@@ -3188,14 +3193,17 @@
       |  if ok and count < 2000000 then
       |    stage = "filling/" .. count
       |    event.timer(0, step)
+      |    timed = count
       |  else
       |    freeAt = math.floor(computer.freeMemory() / 1024)
       |    totalKB = math.floor(computer.totalMemory() / 1024)
       |    held = nil
       |    stage = "done/" .. count .. "/" .. (ok and "cap" or tostring(err):gsub("[ /]", "_"))
       |  end
-      |  pcall(paint)
+      |  if not pcall(paint) then pf = pf + 1 end
       |end
+      |local onError0 = event.onError
+      |event.onError = function(...) oe = oe + 1 return onError0(...) end
       |event.listen("ocljcap", function()
       |  if not make then stage = "ERR/unknown_shape_" .. SHAPE pcall(paint) return false end
       |  held = {}
@@ -3205,7 +3213,7 @@
       |end)
       |event.timer(0.05, function()
       |  n = n + 1
-      |  pcall(paint)
+      |  if not pcall(paint) then pf = pf + 1 end
       |end, math.huge)
       |""".stripMargin
 
@@ -3324,6 +3332,15 @@
 
   /** OCLJ_CAP_SHAPE for the capacity probe; refused, not defaulted, on a misspelling. */
   val capShape: String = Option(System.getenv("OCLJ_CAP_SHAPE")).map(_.trim).filter(_.nonEmpty).getOrElse("record")
+  /** OCLJ_CAP_BATCH / OCLJ_CAP_JUNK: objects per step (100) and the churn string's
+    * length (24).  The AMPLIFIED probe is BATCH 10: the code between steps -- the
+    * stage string, event.timer, paint, OpenOS's dispatcher -- becomes a tenfold
+    * larger share of the bytes, so a refusal outside the program's handler is
+    * frequent enough to count (THE WINDOW's gate, 2026-10-05).  -1: unparseable. */
+  val capBatch: Int = Option(System.getenv("OCLJ_CAP_BATCH")).map(_.trim).filter(_.nonEmpty)
+    .map(v => scala.util.Try(v.toInt).getOrElse(-1)).getOrElse(100)
+  val capJunk: Int = Option(System.getenv("OCLJ_CAP_JUNK")).map(_.trim).filter(_.nonEmpty)
+    .map(v => scala.util.Try(v.toInt).getOrElse(-1)).getOrElse(24)
 
   /**
     * The capacity probe's driver, after (d).  Three readings, in this order,
@@ -3359,7 +3376,9 @@
     // -- an allocation, which at the wall is a refusal that arms the very
     // collector being measured.
     var hasWall = false
-    def ws0(): Array[Double] = if (!ours || !hasWall) Array.fill(11)(-1.0) else m.synchronized { rawstats(mLua, "_OCLJ_WALLSTATS", 10) }
+    // 10-13 (THE WINDOW, 2026-10-05): window (LJ52_GC_LEND), lends, win (0 shut,
+    // 1 open, 2 the verdict), refused (the last refused request, bytes).
+    def ws0(): Array[Double] = if (!ours || !hasWall) Array.fill(14)(-1.0) else m.synchronized { rawstats(mLua, "_OCLJ_WALLSTATS", 13) }
     def tlive(): Int = if (!ours) -1 else jitStatsLocked(m, mLua)._5
     def d(a: Array[Double], b: Array[Double], i: Int): String =
       if (a(0) < i || b(0) < i) "n/a" else (b(i) - a(i)).toLong.toString
@@ -3373,7 +3392,7 @@
     def parked(a: Array[Double]): Boolean =
       a(0) >= 9 && a(5) == 1 && a(9) == 0 && a(8) == 0 && a(7) > a(6)
     // 1. idle window: 400 ticks, ~10 s
-    if (ours) hasWall = m.synchronized { rawstats(mLua, "_OCLJ_WALLSTATS", 10) }(0) > 0
+    if (ours) hasWall = m.synchronized { rawstats(mLua, "_OCLJ_WALLSTATS", 13) }(0) > 0
     val g0 = gs(); val w0 = ws0(); val tl0 = tlive()
     var k = 0
     while (k < 400 && m.isRunning) { ws.update(); Thread.sleep(25); k += 1 }
@@ -3395,6 +3414,11 @@
     val used = tot - fr
     p("CAP-LIVE| used=" + used + " kernelMemory=" + km + " user=" + (used - km) +
       " count(3 collects)=" + cnt + " total=" + tot + " traces_live=" + tlive())
+    // The JIT's trace events before the fill (attached for capacity runs, JIT PROBE):
+    // an abort across the fill can be a refusal the recorder absorbed (u2-stalls 4).
+    def trc(): String = if (!ours) "n/a" else
+      evalStrLocked(m, mLua, "local t = __ocljTr return t and (t.start .. '/' .. t.abort) or 'n/a'")
+    val tr0 = trc()
     // 3. the fill
     val g2 = gs(); val w2 = ws0()
     val tSig = System.currentTimeMillis()
@@ -3455,7 +3479,29 @@
     p("CAP-GC| collects=+" + d(g2, g3, 2) + " bailouts=+" + d(g2, g3, 3) +
       " overdrafts=+" + d(w2, w3, 1) + " od_peak=" + v(w3, 2) + " od_state=" + v(w3, 3) +
       " park_resets=+" + d(w2, w3, 4) + " od_limit=" + v(w3, 5) + " kslice=" + v(w3, 6) +
-      " gc_low=" + v(w3, 7) + " armby=" + v(w3, 8) + " end: " + gcState(g3) + " parked=" + parked(g3))
+      " gc_low=" + v(w3, 7) + " armby=" + v(w3, 8) +
+      " window=" + v(w3, 10) + " lends=+" + d(w2, w3, 11) + " win=" + v(w3, 12) + " refused=" + v(w3, 13) +
+      " end: " + gcState(g3) + " parked=" + parked(g3))
+    // CAP-X (THE WINDOW's gate, 2026-10-05): the amplification, the probe's own
+    // counters, the trace aborts across the fill, and the run's class.  A STALL's
+    // site from OCLJCAPX (u2-stalls 5): entered = batches + 1, the closure handed to
+    // pcall in the next step; timed < count, event.timer in this one.  A JVM that
+    // dies prints no CAP-X: the chain classifies that run PROC-DEATH.
+    val rowX = parse(txt, "OCLJCAPX").split("/")
+    def xn(i: Int): Long = try rowX(i).toLong catch { case _: Throwable => -1L }
+    val cnt0 = if (row.startsWith("filling/")) (try row.stripPrefix("filling/").toLong catch { case _: Throwable => -1L }) else -1L
+    val nb = try rowT(2).toLong catch { case _: Throwable => -1L }
+    val cls =
+      if (row.startsWith("done") && why.contains("not_enough_memory") && running) "CLEAN"
+      else if (running && row.startsWith("filling") && !rowF.matches("\\d+/\\d+")) "STALL"
+      else if (running && row.startsWith("filling")) "RECOVERY-REFUSED"
+      else if (!running && err.contains("not enough memory")) "DOWN"
+      else "OTHER"
+    val site = if (cls != "STALL") "-" else if (xn(0) == nb + 1) "closure"
+               else if (xn(0) == nb && xn(1) >= 0 && xn(1) < cnt0) "event.timer" else "?"
+    p("CAP-X| batch=" + capBatch + " junk=" + capJunk + " OCLJCAPX=" + parse(txt, "OCLJCAPX") +
+      " traces(start/abort) " + tr0 + " -> " + (if (running) trc() else "n/a") +
+      " class=" + cls + " site=" + site)
     milestone("cap-1-refusal-caught-machine-survives",
       row.startsWith("done") && why.contains("not_enough_memory") && running,
       "shape=" + capShape + " OCLJCAP=" + row + " running=" + running + " lastError=" + err +
@@ -3631,6 +3677,8 @@
     if (probeMode == "capacity") {
       if (!Set("record", "array", "string", "closure").contains(capShape))
         die("OCLJ_CAP_SHAPE must be record, array, string or closure, not '" + capShape + "'")
+      if (capBatch < 1 || capBatch > 1000) die("OCLJ_CAP_BATCH must be 1..1000, not '" + System.getenv("OCLJ_CAP_BATCH") + "'")
+      if (capJunk < 8 || capJunk > 200) die("OCLJ_CAP_JUNK must be 8..200, not '" + System.getenv("OCLJ_CAP_JUNK") + "'")
       p("!! OCLJ_PROBE=capacity: boot with the heartbeat-only autorun, then ONLY the capacity probe")
       p("!! (shape=" + capShape + "; boot caps 3000/2000 ticks for EVERY kernel, so arms are scored alike).")
     }
@@ -3689,7 +3737,9 @@
     // are still written (the planting code is shared) but nothing reads them.
     val autorunSrc =
       if (probeMode == "grace") GraceAutorunLua
-      else if (probeMode == "capacity" || probeMode == "rawrace") CapacityAutorunLua.replace("%%SHAPE%%", capShape)
+      else if (probeMode == "capacity" || probeMode == "rawrace")
+        CapacityAutorunLua.replace("%%SHAPE%%", capShape).replace("%%BATCH%%", capBatch.toString)
+          .replace("%%JUNK%%", capJunk.toString)
       else AutorunLua
     Files.write(diskDir.resolve("autorun.lua"), autorunSrc.getBytes(StandardCharsets.UTF_8))
     // The Phase-0 compute pole, planted next to autorun.lua so the sandbox can
```
