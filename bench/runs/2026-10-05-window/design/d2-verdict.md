# d2-verdict: refuse only on the verdict of a cycle — the loan, the verdict, and a cadence that goes quiet past the cap

The roadmap row: "A refusal at a credit tier's top can land outside the program's handler". This design starts from R1 instead of patching the tiers. **A growth under the ceiling is never refused unless a cycle has finished and found the heap still past the level.** The tiers, the room after a refusal, the kernel's slice and the cadence then follow from that rule.

A prototype exists, in scratch only. It changes zero LuaJIT lines, compiles warning-clean with build-native.sh's line, and passes build-native.sh's collector gate. It was measured against the stage-C object (0259f0d1) with the survey's hermetic instruments, made stricter here (§7.1).

Everything is in `scratchpad/wall2/d2-verdict/` unless stated otherwise. The proposed source is `lj52shim.c` (md5 cff2651d); its object `bin-final2/lj52shim.o` is md5 e387460a. The diff is `lj52shim.diff`. The tests are in `mem_test_d2.c`: the repo's mem_test plus W16 plus a new W17.

## 0. In one page

**The rule.** The rule has three parts:
- A growth past the tier's **level** is **lent**, up to the tier's **ceiling**, and arms the cycle that will judge it.
- Every proof records a **verdict**: `gc_low`, the heap the cycle left, lowered by any later free.
- The **first** growth past the level after a proof takes that verdict, and only that growth does. It is refused if the verdict is over the level. Otherwise it is lent and judged afresh.

A growth past the ceiling is refused, with or without a verdict.

**Levels.** G = clamp(T/16, 32 KB, 512 KB) as before. X = G/8 (the loan) and PIN = G/32 (the pin). The kernel's slice K = 16 KB raises both the level and the ceiling.

| tier | level | ceiling |
|---|---|---|
| BURST | T + G/2 + PIN | level + X = T + 21G/32 |
| RESERVE | ceiling − X = T + 7G/8 | T + G |

**The cadence past the cap is now silent.** The loan's own arm replaces the halving. This was measured: with the loan in place the halving changed no refusal anywhere and only added cycles.

**Measured results, stage C → this design.** Same driver, same directory, fixed seed.

| measurement | stage C | this design |
|---|---|---|
| probe2 sweep, 16 384 caps, JIT off: outside the handler | 423, all 423 garbage-covered (site pass) | **0** |
| W16 program, 4 096 caps: outside | 157, all covered | **11, none covered** (live data past the contract top; §6) |
| mem_test (69 checks) | 68 (W16 fails) | **69** |
| mem_test_d2, 30 random-seed runs | fails W16 and W17 in 30 of 30 | passes all 70 in 30 of 30 |

Configuration variants of the probe2 sweep, outside the handler:

| variant | stage C | this design |
|---|---|---|
| JIT on | 642 | 43; survey class M4 ("1,2"): 17 → 0 |
| legacy (dropin) path | 423 | 0, byte-identical to C mode |
| heartbeat every 3rd resume | 440 | 0 |
| no paint | 224 | 0 |
| cap +1.5 MB (G ≈ 99 KB) | 135 of 4 096 | 0 |

Cost on the probe sweep:
- **Cycles:** 696 261 → 619 661 (−11%).
- **Wall time:** ratio 0.94 (four alternated reps).
- **Capacity:** median held objects ≥ stage C's in every shape.
- **Sandbox peak past the cap:** 32 768 → 28 876.

**The residual, in one sentence.** When live data, not garbage, crosses the level within one checkpoint of a handler's exit, the refusal is delivered at the first growth after the cycle that judges it, and that growth can be outside the handler. Measured: 11 of 4 096 caps on the W16 program, 0 of 16 384 on probe2 with the JIT off, 43 with it on. None of the outside landings is garbage-covered wherever the site pass can measure.

## 1. The rule, as a small state machine

### 1.1 State

Each item is per record, not in global_State.

| state | values | written by |
|---|---|---|
| tier | BURST / RESERVE: one bit, as before | RESERVE: a refusal; the fresh-record rule. BURST: a proof with used ≤ T |
| armed | a cycle demanded, not yet proven (unchanged mechanics: stepmul 0, threshold = gc.total, white latched) | the loan; a refusal; the below-cap cadence; the flush |
| gc_low | the heap the last proof left, lowered by every later call that sees less (**armed or not**: §5.11) | the proof; any pressure call |
| **gc_verdict** | one bit: a proof that no growth past the level has yet taken (new field) | set by every proof; cleared by the first growth past the level |

### 1.2 The levels

`lj52_gc_levels(M, g, T, U, &level)` returns the ceiling and writes the level. It depends on the cap, the tier and the thread only; it never depends on history.

```
c = G;  x = G >> 3                                  // X
BURST:    c = G/2 + G/32 + x                        // level G/2 + PIN, ceiling + X
RESERVE:  c = G                                     // ceiling G, level G - X
kernel:   c += K                                    // the slice raises both
level = T + c - x;  ceiling = T + c
```

### 1.3 A growth that would pass the cap

This is the slow path, when U + d > T. It runs in `lj52_gc_grant`, which replaces `lj52_gc_credit`. In C mode the allocator calls it after `!norefuse && T − U < d`. In legacy mode the same call runs with Java's figures.

```
if no state, T <= 0, HOOK_GC or GCSTOP:   refuse              (credit 0, as before)
if armed: read the latch -> PROOF(U) if the cycle completed     (the proof FIRST)
(level, ceiling) = levels(tier, thread)
if U + d <= level:                         grant              (not a crossing)
v = gc_verdict; gc_verdict = 0                                (this growth takes the verdict)
if U + d > ceiling:                        refuse             (THE BOUND)
if v and gc_low > level:                   refuse             (THE VERDICT)
armed ? relabel WALL : arm(WALL);          grant              (THE LOAN + the cycle that judges it)
```

A refusal is handled as at stage C, unchanged: count it, TRY pressure, then (unless under HOOK_GC or GCSTOP) set tier = RESERVE and arm (or relabel the pending cycle WALL).

### 1.4 PROOF

PROOF is `lj52_gc_prove`, extracted unchanged from the armed branch plus one line. It fires when the white has flipped since the arm and the collector is at GCSpause. It then:
- restores stepmul;
- sets armed = 0, increments collects and sets hyst = 1;
- sets gc_low = U;
- **sets gc_verdict = 1**;
- sets tier = BURST if U ≤ T;
- runs the flush predicate as before.

### 1.5 THE CADENCE (unarmed pressure calls)

- **No cycle proven yet:** arm iff T − U < w (unchanged).
- **gc_low < T:** arm iff U > T or T − U < min(w, (T − gc_low)/2) (unchanged).
- **gc_low ≥ T (past the cap): never arm.** The loan arms instead. Stage C halved the distance to the tier's top here.

### 1.6 What a refusal means now

A growth under the ceiling is refused only when a cycle has done all of the following:
- it completed after the previous delivered verdict;
- it left the heap past this thread's level;
- no free since then has taken the heap below that point.

The refused growth is the first growth past the level after that cycle. In BURST the level is PIN above the contract's burst top T + G/2. The pinned garbage a cycle can wrongly count is a returned frame's dead slots, measured at 128-300 B. While that stays ≤ PIN, a verdict refusal implies live data > T + G/2, where stock with its cap at that top refuses too (§2, §6).

## 2. The angle's questions, settled

**Is the BURST/RESERVE split still needed once refusals follow a proof? Yes. RESERVE is now exactly "the room after a real refusal".**

A program that catches the refusal and formats its message before dropping its data (W8) runs a cycle while the data is still held. That cycle's verdict is "over". If the level did not rise after the refusal, the next growth (the `string.rep` after the drop) would be refused on that verdict. This is round 1's FATAL J:121 ("recovery refused") reached by another road.

The sabotage `noreserve` (a refusal opens no reserve) fails W8 and only W8, measured.

So the room after a refusal must be:
- **judged by no cycle**: a raised level, not a longer loan;
- **absolute**: tied to the tier, not counted from the refusal, so it cannot ratchet.

Here it is 7G/32 (7 KB at the floor) from the burst ceiling to the reserve level, plus the reserve's own G/8 loan.

What RESERVE does not need to do any more is protect against garbage-covered refusals at the BURST top. There are none: a crossing is lent and judged.

**Per-thread levels or one top?** Per-thread levels, with K added to both the level and the ceiling. The verdict is compared with the level of the thread that receives it. So a kernel growth under its own level neither consumes nor triggers a sandbox's over-verdict.

M3 (the kernel spends its slice near the sandbox's top, and the sandbox's first allocation after the resume is refused) needed no slice change. The sandbox's first growth past its level is now lent and judged like any other. M3's runs (record off 10928, etc.) are all inside now.

With a single level (K on the ceiling only), the kernel would receive verdicts at the sandbox's level and could be refused for the sandbox's data, which the slice exists to prevent. That is reasoned, not measured.

**Can the cadence's past-the-cap branch be simplified? It can be deleted.** M1's gap (no re-arm at used == gc_low) closes regardless, because the crossing arms in the grant.

With the loan arming every crossing, the halving only added cycles. Measured:
- probe2 cycles: 793 171 with the halving against 619 661 without;
- W12: 23 → 14;
- the same refusals at the same places: 0 of 16 384 runs differ in held count, events or cycles between "no halving" and "silent";
- mem_test lines identical between the two.

Repayment after a drop now happens at the first crossing of the level. W1 and W8 still repay within G/64 + 64 tables (W8: 91 814 B after them, under the 1 090 690 cap).

**The cleanest invariant that makes W7 and R5 obvious.** There are two halves:
1. Every granted growth outside the norefuse window satisfies U + d ≤ ceiling(T, tier, thread), and the ceiling is a function of those three alone.
2. Every refused growth under the ceiling is the first growth past the level after a proof whose heap was past the level.

(1) gives R5 and W7 directly: the tier is one bit that only a refusal raises (idempotently) and only a proof under the cap lowers, and gc_verdict is one bit that each delivery clears. Nothing counts refusals, so nothing can ratchet.

(2) is R1, minus the pinned-garbage and deferral terms in §6.

## 3. The code change

The prototype's unified diff against `C:/Users/astro/Downloads/OC-LuaJIT/native/lj52shim.c` at HEAD d9080d4, also saved as `d2-verdict/lj52shim.diff`. Applied, it gives `d2-verdict/lj52shim.c`, md5 cff2651d.

```diff
diff --git a/native/lj52shim.c b/native/lj52shim.c
index 64092cf..48c8c15 100644
--- a/native/lj52shim.c
+++ b/native/lj52shim.c
@@ -271,9 +271,11 @@ typedef struct lj52_mem {
   volatile long gc_parkresets; /* parked arms restarted; THE PARK RESET below */
   /* -- the collector at the wall: THE CREDIT and THE CADENCE below -- */
   int           gc_odstate;    /* LJ52_OD_BURST, or _RESERVE after a refusal  */
+                               /* (or for a fresh record past the burst level) */
   int           gc_armby;      /* why the armed cycle was armed: LJ52_ARM_*   */
   int           gc_hyst;       /* a cycle has been proven: gc_low is valid    */
   long long     gc_low;        /* used at the last proof, lowered by frees    */
+  int           gc_verdict;    /* a proof not yet delivered: THE VERDICT      */
   long long     gc_seentotal;  /* the cap the last allocator call was under   */
   volatile long gc_overdrafts; /* growths granted past the cap, on credit     */
   long long     gc_odpeak;     /* the largest excursion past the cap, bytes   */
@@ -294,9 +296,10 @@ static void lj52_gc_pressure(lj52_mem *M, long long total, long long used, int k
 #define LJ52_GP_FREE 0                  /* a free or a shrink               */
 #define LJ52_GP_GROW 1                  /* a growth that was granted        */
 #define LJ52_GP_TRY  2                  /* a growth that was refused        */
-/* THE CREDIT at the cap, and the refusal that opens its reserve tier; both
- * defined with the collector, below the LuaJIT-internal includes. */
-static long long lj52_gc_credit(lj52_mem *M, long long total, long long used);
+/* THE LOAN past the cap and THE VERDICT that ends it, and the refusal that
+ * opens the reserve tier; defined with the collector, below the
+ * LuaJIT-internal includes. */
+static int lj52_gc_grant(lj52_mem *M, long long total, long long used, long long delta);
 static void lj52_gc_refused(lj52_mem *M, long long total, long long used);
 
 /* The record for L, or NULL for a state this shim did not create. */
@@ -396,7 +399,7 @@ static void *lj52_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
       return NULL;
     }
     if (acct && delta > 0 && !M->norefuse && M->total - M->used < delta
-        && M->total + lj52_gc_credit(M, M->total, M->used) - M->used < delta) {
+        && !lj52_gc_grant(M, M->total, M->used, delta)) {
       lj52_gc_refused(M, M->total, M->used);
       return NULL;                      /* -> lj_err_mem -> LUA_ERRMEM */
     }
@@ -458,11 +461,12 @@ static void *lj52_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
     return NULL;
   }
   if (!(total <= 0 || delta <= 0 || total - used >= delta || M->norefuse
-        || total + lj52_gc_credit(M, total, used) - used >= delta)) {
-    /* We are at the wall, past the credit too.  We still do not collect
-     * here -- C1/C5/C6 -- but the refusal arms, from any headroom, and opens
-     * the credit's reserve tier for whatever the program does next: see
-     * THE CREDIT, in the collector section. */
+        || lj52_gc_grant(M, total, used, delta))) {
+    /* We are at the wall: past the loan's ceiling, or judged by a cycle that
+     * found the heap still over the level.  We still do not collect here --
+     * C1/C5/C6 -- but the refusal arms, from any headroom, and opens the
+     * reserve tier for whatever the program does next: see THE LOAN AND
+     * THE VERDICT, in the collector section. */
     lj52_gc_refused(M, total, used);
     return NULL;                        /* -> lj_err_mem -> LUA_ERRMEM */
   }
@@ -932,11 +936,15 @@ static void *lj52_back(lj52_mem *M, void *ptr, size_t osize, size_t nsize) {
  * machine down, against 0 of 20 on stock (bench/results-ramscale-
  * 2026-10-03.md).  So a growth that would pass the cap is LENT up to a
  * bounded credit, charged like any other, and the collector armed to repay
- * it at the next checkpoint.  G = total/16, clamped to 32 KB..512 KB:
- *   - BURST, the default tier: up to G/2 past the cap.  Before any refusal
- *     the heap stops at total + G/2, so when the refusal comes at least G/2
- *     is left for what the program does next;
- *   - RESERVE, after a refusal: up to G.  The refusal opens it; a proof that
+ * it at the next checkpoint.  G = total/16, clamped to 32 KB..512 KB,
+ * X = G/8 (THE LOAN, below) and PIN = G/32 (THE PIN, below).  Each tier has
+ * a LEVEL and a CEILING:
+ *   - BURST, the default tier: the level G/2 + PIN past the cap, the
+ *     ceiling X above it.  Before any refusal the heap stops at that
+ *     ceiling, so when the refusal comes 7G/32 is left under the reserve's
+ *     level for what the program does next, judged by no cycle;
+ *   - RESERVE, after a refusal: the level G - X, the ceiling G.  The refusal
+ *     opens it; a proof that
  *     finds the heap back under the cap closes it.  A proof that does not --
  *     the cycle ran before the program dropped its data -- leaves it open,
  *     which is what lets "catch, format the message, drop, carry on" work;
@@ -948,7 +956,7 @@ static void *lj52_back(lj52_mem *M, void *ptr, size_t osize, size_t nsize) {
  *     a fresh record: in one that has run cycles, the heap passes total +
  *     G/2 legitimately on the kernel's slice below, and taking that as a
  *     reserve would spend the second tier before any refusal;
- *   - THE KERNEL'S SLICE: LJ52_GC_KSLICE more, for the kernel only -- no
+ *   - THE KERNEL'S SLICE: LJ52_GC_KSLICE more on both, for the kernel only -- no
  *     resume armed (wd_depth 0: between resumes, where Java's signal pushes
  *     land too), or the thread that made the outermost arm (the kernel after
  *     coroutine.resume returned and before the disarm; cur_L is restored to
@@ -957,13 +965,55 @@ static void *lj52_back(lj52_mem *M, void *ptr, size_t osize, size_t nsize) {
  *     every resume (machine.lua).
  * No credit at all where nothing could repay it: under HOOK_GC (a finalizer;
  * PUC's cap is hard there too) and under a host GCSTOP.  The bound is
- * absolute, not incremental: used + delta <= total + G (+ the slice) for
- * every growth outside the norefuse window, so caught refusals cannot
- * ratchet it (mem_test W7), and the excursion is charged -- getFreeMemory
- * reads 0, both Java sides clamp it there.  What it does not fix: a single
- * request larger than headroom + credit, retried with no checkpoint between
- * the tries (mem_test W9, printed, not asserted), is refused where PUC would
- * collect and succeed; any checkpoint between the tries cures it.
+ * absolute, not incremental: used + delta <= the tier's ceiling <= total + G
+ * (+ the slice) for every growth outside the norefuse window, the tier is
+ * one bit that only a refusal raises and only a proof under the cap lowers,
+ * so caught refusals cannot ratchet it (mem_test W7), and the excursion is
+ * charged -- getFreeMemory reads 0, both Java sides clamp it there.  What it
+ * does not fix: a single request that alone passes the ceiling, retried
+ * with no checkpoint between the tries (mem_test W9, printed, not
+ * asserted), is refused where PUC would collect and succeed; any
+ * checkpoint between the tries cures it.
+ *
+ * THE LOAN AND THE VERDICT (2026-10-04, round 2: docs/roadmap.md, "a refusal
+ * at a credit tier's top can land outside the program's handler").  Stock
+ * refuses only when, after the full collection it runs at the refusal, the
+ * live data plus the request does not fit.  Refusing a growth because it
+ * passes a tier's top refuses live data PLUS the garbage since the last
+ * cycle PLUS what the frame still pins, at whichever allocation comes next
+ * -- 2.6% of the hermetic probe's caps refused outside its handler, every
+ * one of them covered by garbage, against stock's 0 (wall2/repro).  So no
+ * growth under the ceiling is refused except on the VERDICT of a cycle:
+ *   - a growth that would take the heap past the tier's LEVEL is LENT, up
+ *     to the ceiling, and the cycle armed (or an armed one relabelled) --
+ *     the cycle that will judge it, at the next checkpoint;
+ *   - every proof records a verdict: the heap it found (gc_low, lowered by
+ *     any free since, so a verdict never outlives the heap it judged);
+ *   - the FIRST growth past the level after a proof takes the verdict, and
+ *     only that one: refused if the cycle left the heap past the level
+ *     (nothing the cycle could free would make room: stock refuses there
+ *     too), lent and judged afresh if it did not.  The proof is read BEFORE
+ *     the decision, so a check-first site -- TNEW, FNEW, tostring -- runs
+ *     the cycle and judges its own allocation, as stock does;
+ *   - past the ceiling: refused, verdict or not (THE BOUND).
+ * So a crossing that garbage covers is never refused (the cycle frees the
+ * garbage and the verdict is "under"), and a refusal under the ceiling
+ * means the heap a full cycle left was past the level.  THE PIN: a cycle
+ * marks every slot of every frame on the stack (lj_gc_step_fixtop sets
+ * L->top to the frame's top, lj_gc.c:760-764), so the heap it leaves can
+ * still count a returned frame's dead temporaries -- a batch's churn
+ * strings when the cycle ran at its last checkpoint, the kernel's previous
+ * table.pack result in a slot not yet overwritten -- that the request it
+ * judges would no longer see (wall2/d2-verdict: 4-12 B over the level, 128-
+ * 300 B pinned).  The burst level therefore sits PIN = G/32 above G/2: a
+ * verdict refuses only when the heap exceeds total + G/2 by more than PIN,
+ * so with no more than PIN pinned the live data alone was past total +
+ * G/2, where stock with its cap there refuses too.  X = G/8 covers the
+ * bytes between a crossing and the next checkpoint in ordinary code; a
+ * loop that grows a table with no checkpoint spends it and meets the
+ * ceiling, as it met the top before.  Each verdict refuses at most once:
+ * the next attempt is lent and judged by a cycle of its own, one full
+ * cycle per refusal, which is stock's price too.
  *
  * THE CADENCE (2026-10-04).  Until this change, once a proven cycle left the
  * heap inside the watermark, the very next allocator call armed again, so
@@ -974,15 +1024,22 @@ static void *lj52_back(lj52_mem *M, void *ptr, size_t osize, size_t nsize) {
  *   - below the cap: headroom < min(w, (total - gc_low)/2) -- re-arm after
  *     half the post-cycle headroom is used, two cycles per (cap - live)
  *     bytes, twice stock's count; and a growth past the cap always arms;
- *   - past the cap (the last proof left the heap there): when the distance
- *     to the top of the current tier -- the kernel's slice included, when it
- *     is the kernel allocating -- has halved since that proof.  Halving, not
- *     every grant: a program holding data past the cap pays log2 cycles per
- *     tier, and one that drops its data is repaid within half the tier.
+ *   - past the cap (the last proof left the heap there): never.  THE LOAN
+ *     arms: the first growth past the tier's level -- the kernel's slice
+ *     included, when it is the kernel allocating -- arms the cycle that
+ *     judges it, so a program holding data past the cap pays one cycle per
+ *     crossing of the level, and one that drops its data is repaid at the
+ *     first.  Until round 2 this was a halving of the distance to the
+ *     tier's top since the proof; with the loan arming every crossing the
+ *     halving only added cycles (wall2/d2-verdict: 793 171 against 619 661
+ *     over the probe sweep, the same refusals at the same places; W12 23
+ *     against 14), and it never re-armed at used == gc_low, the gap the
+ *     residual's first mechanism went through.
  * mem_test W4: 20000 64-byte tables over 256 KB live with 64 KB of headroom
  * took 10000 full cycles (one per checkpoint pair) before; the bound now is
  * three times stock's count.  A fill of 512 KB of live 64-byte tables to
- * the refusal costs 21 full cycles, against 1554 before (W12).
+ * the refusal costs 14 full cycles (21 with the halving), against 1554
+ * before (W12).
  *
  * NO BACK-OFF.  The design review proposed suspending pre-emptive cycles
  * once one freed less than half of what was allocated since the proof
@@ -1018,6 +1075,8 @@ static void *lj52_back(lj52_mem *M, void *ptr, size_t osize, size_t nsize) {
 #define LJ52_GC_ODMIN  (32 * 1024)
 #define LJ52_GC_ODMAX  (512 * 1024)
 #define LJ52_GC_KSLICE (16 * 1024)      /* the kernel's own, past the credit */
+#define LJ52_GC_LENDSHIFT 3             /* THE LOAN: X = G/8 past the level  */
+#define LJ52_GC_PINSHIFT 5              /* THE PIN: G/32 above the burst top */
 #define LJ52_GC_HYSTSHIFT 1             /* re-arm after half the headroom    */
 #define LJ52_GC_FLUSHSHIFT 1            /* flush inside half the watermark   */
 #define LJ52_OD_BURST   0               /* credit tiers                      */
@@ -1082,19 +1141,75 @@ static int lj52_gc_kernel(lj52_mem *M, global_State *g)
   return M->wd_depth == 0 || gco2th(gcref(g->cur_L)) == M->wd_by[0];
 }
 
-/* How far past the cap this growth may go.  Read only on the slow path, when
- * the growth would not otherwise fit. */
-static long long lj52_gc_credit(lj52_mem *M, long long total, long long used)
+/* THE LEVELS of this record's tier, for the thread allocating: returns the
+ * CEILING no growth may pass, and writes the LEVEL past which a growth is a
+ * loan that only a verdict may refuse.  BURST: the level G/2 + PIN past the
+ * cap, the ceiling X above it; RESERVE: the ceiling G, the level G - X; the
+ * kernel's slice raises both.  See THE LOAN AND THE VERDICT. */
+static long long lj52_gc_levels(lj52_mem *M, global_State *g, long long total,
+                                long long used, long long *level)
+{
+  long long c, x;
+  c = lj52_gc_odmax(total);
+  x = c >> LJ52_GC_LENDSHIFT;
+  if (!lj52_gc_reserve(M, total, used)) c = (c >> 1) + (c >> LJ52_GC_PINSHIFT) + x;
+  if (lj52_gc_kernel(M, g)) c += LJ52_GC_KSLICE;
+  *level = total + c - x;
+  return total + c;
+}
+
+/* THE PROOF: the armed cycle has run -- the white flipped since the arm and
+ * the collector is back at the pause.  Disarms, records the heap the cycle
+ * left (gc_low) as THE VERDICT, closes the reserve if that heap is under the
+ * cap, and raises the flush flag.  Called while armed, by lj52_gc_pressure
+ * after every allocator call and by lj52_gc_grant BEFORE it decides, so the
+ * first growth after a cycle is judged by that cycle, not one call late. */
+static void lj52_gc_prove(lj52_mem *M, global_State *g, long long total, long long used)
+{
+  long long w;
+  if (g->gc.currentwhite == M->gc_white || g->gc.state != LJ52_GCS_PAUSE) return;
+  if (g->gc.stepmul == 0) g->gc.stepmul = M->gc_savedmul;
+  M->gc_armed = 0;
+  M->gc_collects++;
+  M->gc_hyst = 1;
+  M->gc_low = used;
+  M->gc_verdict = 1;
+  if (used <= total) M->gc_odstate = LJ52_OD_BURST;   /* repaid */
+  /* THE FLUSH PREDICATE -- at the proof, never at the arm.  The cycle
+   * has run to completion and `used` is the heap as it stands after it.
+   * Headroom still short means garbage was not what filled the machine,
+   * and resident trace metadata is the reclaimable part no cycle can
+   * touch.  A flag only: the flush itself must wait for the safe point.
+   * See FLUSHING TRACES UNDER MEMORY PRESSURE above.  Never raised by
+   * the proof of a cycle the flush itself armed: that is the
+   * flush -> re-arm -> proof -> flush loop. */
+  w = total / 4;
+  if (w < LJ52_GC_WMIN) w = LJ52_GC_WMIN;
+  if (M->gc_armby != LJ52_ARM_FLUSH && total - used < (w >> LJ52_GC_FLUSHSHIFT))
+    M->gc_flush_wanted = 1;
+}
+
+/* A growth that would pass the cap: grant it (1) or refuse it (0).  See THE
+ * LOAN AND THE VERDICT.  Nothing past the cap where nothing could repay a
+ * loan: under HOOK_GC (a finalizer) and under a host GCSTOP. */
+static int lj52_gc_grant(lj52_mem *M, long long total, long long used, long long delta)
 {
   global_State *g;
-  long long c;
+  long long level, ceiling;
+  int verdict;
   if (M->L == NULL || total <= 0) return 0;
   g = G(M->L);
   if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) return 0;
-  c = lj52_gc_odmax(total);
-  if (!lj52_gc_reserve(M, total, used)) c >>= 1;
-  if (lj52_gc_kernel(M, g)) c += LJ52_GC_KSLICE;
-  return c;
+  if (M->gc_armed) lj52_gc_prove(M, g, total, used);   /* the proof first */
+  ceiling = lj52_gc_levels(M, g, total, used, &level);
+  if (used + delta <= level) return 1;                 /* under the level */
+  verdict = M->gc_verdict;                             /* this growth takes it */
+  M->gc_verdict = 0;
+  if (used + delta > ceiling) return 0;                /* THE BOUND */
+  if (verdict && M->gc_low > level) return 0;          /* THE VERDICT: over */
+  if (M->gc_armed) M->gc_armby = LJ52_ARM_WALL;        /* THE LOAN, and the */
+  else lj52_gc_arm(M, g, LJ52_ARM_WALL);               /* cycle to judge it */
+  return 1;
 }
 
 /* A refusal: counted, the valve and the proof seen to first, then the
@@ -1118,7 +1233,7 @@ static void lj52_gc_refused(lj52_mem *M, long long total, long long used)
 static void lj52_gc_pressure(lj52_mem *M, long long total, long long used, int kind)
 {
   global_State *g;
-  long long w, gate, top;
+  long long w, gate;
   int arm;
 
   /* gc_busy guards nothing today -- this function calls nothing that can
@@ -1145,27 +1260,14 @@ static void lj52_gc_pressure(lj52_mem *M, long long total, long long used, int k
   }
   w = total / 4;
   if (w < LJ52_GC_WMIN) w = LJ52_GC_WMIN;
+  /* The lowest heap since the last proof, armed or not: THE VERDICT judges
+   * the heap the cycle left, never one the program has since freed. */
+  if (M->gc_hyst && used < M->gc_low) M->gc_low = used;
 
   if (M->gc_armed) {
     if (g->gc.state != LJ52_GCS_PAUSE) M->gc_moved = 1;
-    if (g->gc.currentwhite != M->gc_white && g->gc.state == LJ52_GCS_PAUSE) {
-      if (g->gc.stepmul == 0) g->gc.stepmul = M->gc_savedmul;
-      M->gc_armed = 0;
-      M->gc_collects++;
-      M->gc_hyst = 1;
-      M->gc_low = used;
-      if (used <= total) M->gc_odstate = LJ52_OD_BURST;   /* repaid */
-      /* THE FLUSH PREDICATE -- at the proof, never at the arm.  The cycle
-       * has run to completion and `used` is the heap as it stands after it.
-       * Headroom still short means garbage was not what filled the machine,
-       * and resident trace metadata is the reclaimable part no cycle can
-       * touch.  A flag only: the flush itself must wait for the safe point.
-       * See FLUSHING TRACES UNDER MEMORY PRESSURE above.  Never raised by
-       * the proof of a cycle the flush itself armed: that is the
-       * flush -> re-arm -> proof -> flush loop. */
-      if (M->gc_armby != LJ52_ARM_FLUSH && total - used < (w >> LJ52_GC_FLUSHSHIFT))
-        M->gc_flush_wanted = 1;
-    } else {
+    lj52_gc_prove(M, g, total, used);
+    if (M->gc_armed) {
       if (M->gc_moved && g->gc.state == LJ52_GCS_PAUSE && g->gc.threshold > g->gc.total) {
         /* THE PARK RESET: the old cycle ended without atomic(); start a
          * fresh one at the next checkpoint.  See above. */
@@ -1189,8 +1291,7 @@ static void lj52_gc_pressure(lj52_mem *M, long long total, long long used, int k
     return;
   }
 
-  /* THE CADENCE; see above. */
-  if (M->gc_hyst && used < M->gc_low) M->gc_low = used;
+  /* THE CADENCE; see above.  Past the cap it is silent: THE LOAN arms. */
   if (!M->gc_hyst) {
     arm = total - used < w;
   } else if (M->gc_low < total) {
@@ -1198,10 +1299,7 @@ static void lj52_gc_pressure(lj52_mem *M, long long total, long long used, int k
     if (gate > w) gate = w;
     arm = used > total || total - used < gate;
   } else {
-    top = total + (M->gc_odstate == LJ52_OD_RESERVE ? lj52_gc_odmax(total)
-                                                    : lj52_gc_odmax(total) >> 1);
-    if (lj52_gc_kernel(M, g)) top += LJ52_GC_KSLICE;   /* where the kernel is refused */
-    arm = top - used < (top - M->gc_low) >> 1;
+    arm = 0;
   }
   if (arm) lj52_gc_arm(M, g, used > total ? LJ52_ARM_WALL : LJ52_ARM_GATE);
   M->gc_busy = 0;
```

### 3.1 What the diff is, line by line

The whole change is in `native/lj52shim.c`: +159 / −61 lines, most of it comment. Zero LuaJIT lines; `lj52shim.h` is unchanged.

- **New field:** `gc_verdict`.
- **New constants:** `LJ52_GC_LENDSHIFT 3` (X) and `LJ52_GC_PINSHIFT 5` (PIN).
- **Replaced function:** `lj52_gc_credit` becomes `lj52_gc_grant`.
- **New function:** `lj52_gc_levels`, used by the grant only.
- **Extracted function:** `lj52_gc_prove`, the old proof block plus `gc_verdict = 1`.
- **Allocator:** the two refusal predicates now call `lj52_gc_grant` (C mode and legacy).
- **gc_low lowering:** moved above the armed branch.
- **Cadence:** the past-the-cap branch deleted (`arm = 0`) and `top` removed.
- **Comments:** THE CREDIT gains levels and ceilings; a new paragraph, THE LOAN AND THE VERDICT; THE CADENCE's third bullet; the allocator's legacy comment.

Lines unchanged, which sabotages still target textually:
- park reset, valve, `if (!M->gc_hyst) {`;
- the fresh-record `if`;
- `else lj52_gc_arm(M, g, LJ52_ARM_WALL);` in `lj52_gc_refused`;
- `LJ52_GC_FLUSHSHIFT`;
- the norefuse lines.

`if (used <= total) M->gc_odstate = LJ52_OD_BURST;   /* repaid */` is unchanged in text but now sits in `lj52_gc_prove` at 2-space indentation. negative-control.sh's closereserve sed needs its leading spaces changed (§8.3).

## 4. The bound (R5)

For every growth granted outside the norefuse window, with G = clamp(⌊T/16⌋, 32 KiB, 512 KiB), K = 16 KiB and integer shifts:

```
U + d  <=  ceiling(T, tier, thread)  <=  T + G + K  <=  T + 528 KiB

ceiling(T, BURST,   sandbox) = T + (G>>1) + (G>>5) + (G>>3)        (= T + 21G/32 at G = 32 KiB)
ceiling(T, BURST,   kernel)  = T + (G>>1) + (G>>5) + (G>>3) + K
ceiling(T, RESERVE, sandbox) = T + G
ceiling(T, RESERVE, kernel)  = T + G + K
under HOOK_GC or a host GCSTOP:  U + d <= T                      (no loan)
```

**Derivation.**
- On the slow path (U + d > T) a growth is granted only by `lj52_gc_grant`. That function returns 1 only on its "under the level" line (level < ceiling) or after its BOUND line has passed (U + d ≤ ceiling). Every other path returns 0.
- Legacy mode applies the same function to Java's T and U.
- Under HOOK_GC or GCSTOP the function returns 0, so only the fast path (U + d ≤ T) grants.
- Hence at any instant U − T ≤ max(G + K + NR, an excursion inherited from a cap change). NR is the norefuse window, about 1.5 KB of memoised GCfuncs.
- That is the same global bound as stage C (u2-shim-now §2). The sandbox's BURST excursion is 21G/32 instead of G/2: deeper by 5G/32, which is 5 KiB at the floor and 80 KiB at the 512 KiB clamp. RESERVE is unchanged at G.

**No ratchet.**
- The ceiling reads only T, the tier bit and the thread.
- A refusal can only set the tier to RESERVE, the maximum, and that is idempotent.
- `gc_verdict` is one bit, cleared by each delivery.
- No counter of refusals or attempts enters the decision.

W7 measures it: 4 000 caught attempts as the sandbox, 3 955 refusals, used 333 260 against cap 304 510 + G 32 768 + 2 048, and od_peak 28 750 ≤ od_limit 32 768. At stage C od_peak was 32 710.

**Charged.** Every lent byte goes through `M->used += delta` exactly as before, so getFreeMemory reads 0.

**W1's peak check.** W1 compares its peak with od_limit, the sandbox's bound, on a kernel-thread test (inconsistency 11). It still holds by margin: 53 163 ≤ 68 177. The kernel's BURST ceiling 21G/32 + K exceeds G when G < 46.5 KiB, so at the floor a kernel-context fill could exceed od_limit without breaking the bound. §8.2 re-scopes the check.

## 5. Every transition

1. **On trace.**
   - A compiled allocation reaches the same allocator, so a crossing is lent and arms.
   - The trace's next `asm_gc_check` fires (threshold = gc.total). `lj_gc_step_jit` bails at atomic, and the GC guard exits.
   - `lj_trace_exit` restores the snapshot. Its allocations are lent within the ceiling.
   - The exit then completes the cycle, and the first allocator call after it proves.
   - A trace with no counted allocations reaches no on-trace check; its loan runs to the next interpreter or C checkpoint, bounded by the ceiling (X bytes).
   - JIT-internal allocations (vmstate RECORD or ASM) can receive a verdict, and trace_abort swallows it. vmstate cannot separate them: RECORD stays set while the interpreter executes the instruction being recorded (lj_trace.c:700, 717; no reset until :746/758). This is part of the residual (§6, JIT-on numbers).
2. **Host GCSTOP** (threshold = LJ_MAX_MEM).
   - `lj52_gc_grant` returns 0 before reading the latch: no loan, refusal at T.
   - `lj52_gc_refused` returns before touching the tier or arming.
   - `lj52_gc_pressure` returns at its guard.
   - A pending loan's cycle waits for GCRESTART (threshold = total, stepmul still 0, so the next checkpoint runs it) or for a COLLECT, which flips the white and proves.
   - Unchanged from stage C.
3. **HOOK_GC** (inside a finalizer): the same as GCSTOP. No loan and no verdict delivered inside a finalizer; its refusals become ERRFIN as before.
4. **norefuse** (`lj52_pushcfunction`):
   - The allocator skips the predicate, so no grant call and no verdict is consumed.
   - Pressure returns at its first guard: no proof observed, no arm, no gc_low change.
   - The bytes are charged (NR in §4).
   - The sabotage `norefuse` still dies after M5, measured (§8.3).
5. **csync / legacy:** one function for both modes, fed Java's figures in legacy. Measured: the legacy sweep is byte-identical to C mode on both objects (40 213 JNI round-trips per run confirm the mode).
6. **The kernel's slice:** +K on the level and the ceiling (`lj52_gc_levels`), with the thread classified as before (`wd_depth == 0 || cur_L == wd_by[0]`). The verdict is compared with the receiving thread's level.
7. **The fresh-record rule:** unchanged. `!gc_hyst && U > T + G/2` opens RESERVE inside `lj52_gc_reserve`, now reached through `lj52_gc_levels`. The threshold is the contract top G/2, not G/2 + PIN, so it errs toward RESERVE. W11 passes: 64 B lent, 32 KB refused.
8. **The flush predicate:** unchanged, now in `lj52_gc_prove`. `armby != FLUSH && T − U < w/2` raises the flag.
   - A pending FLUSH-armed cycle that a crossing relabels WALL can raise it, as at stage C (inconsistency 7).
   - Fewer cycles run past the cap, but any one proof there raises the flag. W13-W15 pass.
9. **THE CADENCE:** below the cap unchanged; past the cap silent (§1.5).
   - Idle behaviour below the cap, which is where a 192 KB stick idles, is unchanged by construction.
   - A machine idling past the cap now arms only when it crosses its level. Stage C armed log2 times per tier.
10. **Park reset, valve, wd_arm/disarm, the flush at the safe point:** unchanged.
    - A loan whose cycle bails (valve) ends with no verdict. The next crossing lends again and re-arms, bounded by the ceiling. A bailout is a bug signal, as before.
11. **gc_low while armed.** gc_low is now lowered on every pressure call, armed or not, so a verdict never judges a heap the program has since freed.
    - The cadence is unaffected: a proof overwrites gc_low, so the change only matters between a proof and the next proof, and after a bailout.
    - Not pinned by any test: the sabotage `armedlowstale` fails nothing (§8.3, §10).
12. **The verdict's lifetime.**
    - Set at every proof.
    - Taken by the first slow-path growth past the level of the thread allocating. The growth is refused if the verdict is over the level, and the verdict is consumed either way.
    - A growth under the level does not consume it.
    - A fast-path growth (U + d ≤ T) never sees it. If the heap was over the level at the proof, it can reach the fast path again only after frees lowered gc_low.

## 6. The residual

**In one sentence.** When live data, not garbage, crosses the level within one checkpoint of a handler's exit, the cycle that judges it runs at that handler's last checkpoint, and its verdict refuses the first growth after the handler. Measured outside landings:
- 11 of 4 096 caps on the W16 program, all at the stage string, with 324 B too little room under the contract top at the site;
- 0 of 16 384 on probe2 with the JIT off;
- 43 of 16 384 with the JIT on, 30 of them not covered and 13 that the JIT-on site pass cannot judge.

The JIT-on figure includes verdicts delivered to the trace recorder or to the kernel's window, where trace metadata (the assembler's 568-668 B trace copies) is live.

**By how much it is later than stock (R1's clause).** The refusal is deferred, never earlier:
- It lands after at most one checkpoint interval beyond the point where the live set passes level − pinned.
- The extra bytes are bounded by X = G/8 (the ceiling).
- Stock with its cap at the contract top would have refused the crossing itself.

It is not harmless: the deferred refusal is what lands outside in the 11/43.

**Still not fixed (unchanged residuals).**
- A single request that alone passes the ceiling, retried with no checkpoint between the tries (W9, printed): 20 tries on both objects.
- Pinned garbage larger than PIN: a dead multi-KB object in a returned frame's slot, judged by a cycle that ran in that frame. Not constructed or tested.
- `held`-style table doublings past the ceiling (one 16 KB request at count 2048): refused at once, as at stage C and as stock refuses them, always inside the handler here.

## 7. Measured results

### 7.1 Instruments, and what checked them

- **Builds.**
  - `mk.sh obj` is build-native.sh's line (`-O2 -Wall -Wextra -DLJ52_ADDITIVE`). It reproduces the stage-C object 0259f0d1 byte for byte from the repo source (`orig/`).
  - The prototype compiles warning-clean.
  - `mk.sh mem` is run-mem.sh's link line.
  - The collector gate's own grep (two files, comment filter) finds 0 matches in the prototype and 1 in a copy with a planted `lua_gc(... LUA_GCCOLLECT ...)` (`gatecheck/`).
- **The base depends on where the binary lives.** LuaJIT's `setprogdir` writes the executable's directory into package.path and cpath (lib_package.c:95-108, 553-568). The survey's binary gave a 16 B larger base when run from this directory.
  - Every sweep here runs with `LUA_PATH="?.lua" LUA_CPATH="?.dll"`, so binaries in different directories are comparable.
  - With that, stage C reproduces the survey's classification: 423 outside, against the survey's 431 under its own path; per-shape counts within a few runs.
- **Instrumented = plain.** Each sweep runs on an instrumented copy (`mkinstr_v.py`: recording only). The plain object reruns the W16 sweep and must agree on every shared column. "plain == instrumented" was printed for every variant.
- **"Covered" is a site pass** (`sitepass_v.py`, the survey's method). It re-runs deterministically with two full collections immediately before the refused site, frames as they are there, and tests live_site + whole object ≤ cap + G/2.
  - W16's own measure (live after the run) undercounts live by up to 3 892 B after a stall: the dead coroutine's stack has shrunk.
  - On the 11 residual landings that measure says "covered" and the site pass says "not covered by 324 B". §8.2 fixes W16 accordingly.
- **The JIT-on site pass is weak** (the survey said so). The hook changes which traces compile, and each new trace's assembler copy is 568-668 B of live metadata (ring with vmstate: `~LJ_VMST_ASM`). The 13 JIT-on "covered" downs are therefore unestablished either way.
- **A harness error, found and voided.** My first sabotage script changed only `norefuse++` and left `norefuse--`. The counter went negative, `!M->norefuse` switched refusals off, and M6b "passed".
  - Bisected (`out-bisect-1`, `out-norefuse-2/dbg*`), corrected to change both lines as negative-control.sh does, and re-run: it dies after M5.
  - Recorded in `out-sab-1/NOTES.txt`.
- **Timing.** Stage C and the design alternate rep by rep in one session (`timeit.py`). The ratio is to that same-run reference.

### 7.2 mem_test

mem_test is the repo's suite plus W16 (`wall2/repro/mem_test_w16.c`), 69 checks, plain objects (`out-stageC-3`, `out-final2-1`).

| object | result |
|---|---|
| stage C | 68/69. FAIL W16: 7 covered stalls among 96 caps ("first at cap = base + 384 KB + 0: stall, used 457471 at the refusal, live 454568, top 457499") |
| this design | **69/69** |

**No existing check fails, so there is nothing to re-scope.** Figures that move, stage C → this design:

| check | stage C | this design | why |
|---|---|---|---|
| W12, cycles in the worst W1 round | 21 | 14 | the cadence is silent past the cap |
| W7 od_peak | 32 710 | 28 750 | the reserve level is G − X; one object is lent past it |
| W7 used (cap 304 510) | 337 220 | 333 260 | as above |
| W7 collects | 3 976 | 3 967 | |
| W1 od_peak (od_limit 68 177) | 50 963 | 53 163 | the kernel's BURST level is +PIN and its ceiling +X |
| W8, bytes after 1 129 tables (cap 1 090 690) | 84 646 | 91 814 | repaid at the first crossing, not on halving; still ≤ cap |
| M5 / C3a used (credit 49 152) | 272 304 | 273 360 | refused one verdict later, within T + G + K |
| W9 (INFO) | 20 tries | 20 tries | unchanged residual |

Unchanged: W2b/W2c/W2d (armed after 1, retry 0, lent then repaid), W3 (lent), W4 (near 39 collects, bound 61; its time ratio reads 1.0-2.0 between identical runs at clock() granularity, bound 3.0), W10 `true|true|2|true`, W11 (64 B lent, 32 KB refused), W13-W15, M6/C6, P1-P2.

`mem_test_d2.c` adds W17, 70 checks (`out-seeds-2`, 30 runs each, random string-hash seed):

| object | runs passing all 70 | failing checks | W16 covered | W17 od_peak |
|---|---|---|---|---|
| stage C | 0 of 30 | W16 ×30, W17 ×30 | 6 (×4) / 7 (×26) | 16 377 ×30 |
| this design | **30 of 30** | none | 0 ×30 | 17 433 ×30 |

W17 sits at the contract top G/2 = 16 384, level 17 408, ceiling 21 504. The design's 17 433 is the level plus one table: refused on the verdict.

### 7.3 Sweeps

Driver `lj_repro_v.c` (the survey's lj_repro.c plus the reason, ceiling and live_end columns), fixed seed, arm on, capk 384, junk 24, batch 100. Cells are **inside / stall / down / garbage-covered (site pass)**.

**probe2, JIT off, 4 × 4 096 caps** (`out-stageC-3`, `out-final2-1`):

| shape | stage C | this design |
|---|---|---|
| record | 4053 / 12 / 31 / 43 | 4096 / 0 / 0 / 0 |
| array | 4047 / 30 / 19 / 49 | 4096 / 0 / 0 / 0 |
| string | 3843 / 132 / 121 / 253 | 4096 / 0 / 0 / 0 |
| closure | 4018 / 45 / 33 / 78 | 4096 / 0 / 0 / 0 |
| **outside** | **423 (2.58%), 423 covered** | **0** |

**The W16 program, 4 096 caps.** Uses `w16site.lua`: the survey's w16probe.lua plus inert site hooks.
- Stage C: 3939 / 146 / 11 / **157 covered of 157**.
- This design: 4085 / 11 / 0 / **0 covered of 11**. All 11 are stage-string stalls at one phase per batch period: verdict gc_low = level + 4, live at the site 324 B past room.

**JIT on** (`out-sw-C-jit-1`, `out-sw-F2-jit-1`):

| shape | stage C | this design |
|---|---|---|
| record | 4039 / 18 / 39 / 55 | 4092 / 4 / 0 / 0 |
| array | 4042 / 26 / 28 / 50 | 4096 / 0 / 0 / 0 |
| string | 3617 / 280 / 199 / 238 (17 unmeasured) | 4057 / 26 / 13 / 13* |
| closure | 4044 / 30 / 22 / 52 | 4096 / 0 / 0 / 0 |
| **outside** | **642** | **43** |

\* These 13 are weak JIT-on site-pass readings (§7.1).

Event classes, stage C → this design: survey M4 `1,2,20` 17 → 0; `3,4,20` 12 → 0.

**Other configurations, outside the handler, stage C → this design:**

| configuration | stage C | this design |
|---|---|---|
| legacy path (`OCLJ_LEGACY=1`) | 423 | 0, byte-identical to C mode |
| heartbeat every 3rd resume | 440, all covered | 0 |
| no `pcall(paint)` | 224, all covered | 0 |
| capk 1536 (G ≈ 99 KB; 4 × 1 024 caps at 64 B steps) | 135, all covered | 0 |

### 7.4 Capacity and cost (probe2, JIT off)

| | stage C | this design |
|---|---|---|
| median held: record / array / string / closure | 1376 / 2048 / 5246 / 2024 | 1380 / 2048 / 5265 / 2031 |
| median cycles per run | 32 / 28 / 80 / 32 | 28 / 25 / 71 / 29 |
| total cycles | 696 261 | 619 661 (−11.0%) |
| total cycles, JIT on | 644 989 | 522 963 |
| max sandbox od_peak | 32 768 | 28 876 |
| bailouts | 0 | 0 |
| wall time, 4 × 1 024 caps, four alternated reps | 16.82 / 17.34 / 17.34 / 17.07 s | 15.81 / 16.38 / 15.94 / 16.37 s |

The time ratio is 0.941 overall, 0.92-0.96 per rep. No java process was running.

**Held fewer than stage C: 83 runs, all of one kind.** In each, stage C's first refusal was swallowed by `pcall(paint)` (events 3,1,6) and stage C's fill went on into the reserve. That extra room comes from the swallowed refusal, not from stock's contract.

The design itself has 136 paint-absorbed runs. Each is a verdict, from a cycle run in paint's own frame, delivered to paint. Every one is followed by an inside refusal at the reserve level: 120 verdicts and 16 ceiling refusals at the 16 KB doubling.

### 7.5 The variants measured on the way

Same suite each time; mem_test is out of 69.

| variant | mem_test | W16 program outside (covered) | probe2 outside | note |
|---|---|---|---|---|
| v1: verdict, PIN 0, halving cadence | 68 (W16: 1 covered down) | 10 (10) | 0 | false verdicts from pinned garbage |
| PIN 256 / 512 / 1024, halving | 69 | 10 / 11 / 11 (0) | 0 | W12 23 at every PIN; total cycles +0.3% at PIN 1024 |
| confirmation (two consecutive over-proofs) | 69 | 30 | 0 | worse; dropped |
| PIN G/32 with halving (`out-final-1`) | 69 | 11 (0) | 0 | 793 171 cycles; time ratio 1.10 vs stage C |
| PIN G/32, no halving | 69 | 11 (0) | 0 | 619 661 cycles |
| **PIN G/32, silent past the cap (proposed)** | 69 | 11 (0) | 0 | identical to no-halving in every run |

The confirmation variant's refusals were not instrumented (the instrument targets the non-confirm line), so its site pass measured nothing.

## 8. Test plan

### 8.1 New cases

- **W16** (the survey's case; text in u2-repro §7). It fails on stage C in 30 of 30 random-seed runs (6-7 covered) and passes on this design in 30 of 30. Fix its measure before landing it (§8.2).
- **W17** (`mkw17.py`; in `mem_test_d2.c`): **"a live fill is refused on the verdict, past the top, before the ceiling"**.
  - Setup: as the sandbox (a coroutine under an outermost arm), a pre-sized 8192-slot holder, cap = used + 256 KB. Fill live 64 B tables inside a pcall until refused (bounded at 200 000).
  - Assert: status 0, caught, refusals +1, and G/2 < od_peak ≤ G/2 + G/32 + 512.
  - Stage C: od_peak 16 377 → FAIL (fail-first: it refuses before the contract top, with garbage uncollected).
  - This design: 17 433 → PASS.
  - Sabotage `noverdict` (refusal at the ceiling only): FAIL.
- **Proposed, not built: W18, "a verdict never outlives the heap it judged".**
  - Sequence: a proof past the level, frees while re-armed taking the heap under it, then a crossing that must be lent.
  - It would pin §5.11, which `armedlowstale` shows no case pins today. A hermetic sequence with frees outside a cycle (hash-part shrink on rehash) was judged too intricate for this round.

### 8.2 Changed cases

No existing case needs to change to pass. Recommended edits:

- **W16's covered measure.** On a stall, have the sandbox coroutine record and then `coroutine.yield()` instead of returning, and stop the kernel loop on a flag. The measure then counts the coroutine's stack. Measured gap otherwise: up to 3 892 B, which turns the residual's deferred-live stalls into false "covered" failures.
- **W12's comment:** 21 cycles → 14, so the bound 32 is now 2.3× the measure. Consider tightening it to 24.
- **W1's od_peak check:** compare with od_limit + KSLICE, the kernel's bound, since W1 runs on C frames at depth 0. Today it passes by margin (§4).
- **THE CREDIT comments** in mem_test that cite "G/2" as the burst top: say "level G/2 + G/32, ceiling + G/8".

### 8.3 Sabotages

Run against the final source with `sabotage.py`, which makes negative-control.sh's one-line edits as exact replacements. Each variant is built with build-native.sh's line, linked with `mem_test_d2.c` (70 checks), and run with stdout to a file (`out-sab-final2/`, `out-sab-final2.txt`). The failing sets below are measured.

| # | name | target in the new source | failing set (measured) | vs negative-control.sh today |
|---|---|---|---|---|
| 4.1 | stopgap | `M->accounting = ud != NULL;` | today's set + **W16 W17** | add W16 W17 |
| 4.2 | nopending | `M->pending += delta;` | C0b M3c M4b M5 | same |
| 4.3 | norefuse | both norefuse lines | **dies after M5** (exit 0xE24C4A02, no summary) | same |
| 4.4 | nopark | park-reset `if` | W5a W5b | same |
| 4.5 | freescount | the valve `if` | W5c | same |
| 4.6 | nocredit | **new edit:** `  c = lj52_gc_odmax(total);` → `  *level = total; return total;` (no loan, no slice) | W1 W1L W1j W2d W3 W8 W10 W11 **W16 W17** | the old `return 0;` would leave `*level` unset; add W16 W17 |
| 4.7 | norefusedarm | `  else lj52_gc_arm(M, g, LJ52_ARM_WALL);` (refused's) | W2b W2c **W1 W1L W1j** | W1 now fails on its peak check (76 091 > 68 177): with the cadence silent past the cap only a refusal's arm repays a drop before the reserve level |
| 4.8 | nohyst | `  if (!M->gc_hyst) {` | W4 W12 | same |
| 4.9 | unbounded | `  c = lj52_gc_odmax(total);` → `  c = total;` | C3a C6 M5 M6b M7 W1 W11 W17 W1L W1j W2b W7 W8 | changed: +C6 M6b M7 W17 W8, −W12 |
| 4.10 | nokslice | `  if (lj52_gc_kernel(M, g)) c += LJ52_GC_KSLICE;` (now in levels) | W10 | same |
| 4.11 | nofresh | the fresh-record `if` | W11 | same |
| 4.12 | closereserve | `  if (used <= total) M->gc_odstate = LJ52_OD_BURST;   /* repaid */` (**2-space indent now**) | W8 W11 | sed text changes |
| 4.13 | flushwhole | `#define LJ52_GC_FLUSHSHIFT 1 ` | W15 | same |
| new | **nolend** | `  if (used + delta > ceiling) return 0;  /* THE BOUND */` → `return 0;` (refused at the level: stage C's rule) | **W16** W8 | the fail-first property; 10/10 seeds |
| new | **noverdict** | the VERDICT line → `(void)verdict;` (refused at the ceiling only) | **W17** W12 | 10/10 seeds |
| new | **nopin** | PIN removed from the BURST level | **W16** | 10/10 seeds |
| new | **latelatch** | `if (M->gc_armed) lj52_gc_prove(...)` removed from the grant (proof read after the decision) | **W16** | 10/10 seeds |
| new | **noreserve** | `  M->gc_odstate = LJ52_OD_RESERVE;` in refused | **W8** | shows the room after a refusal is load-bearing |
| new | armedlowstale | gc_low lowered only while unarmed | **none** | untested line; W18 proposed (§8.1) |

### 8.4 In-machine gate (R10, R12): not run here (no JVM in this task)

- **The capacity matrix**, as for stages B and C (`bench/runs/2026-10-04-wall`). Pass condition:
  - capacity ≥ stock in every cell;
  - last-five-batches time within stage C's ratios.
- **An amplified probe** that multiplies out-of-handler exposure: the capacity probe with `BATCH = 10` and junk 8, which puts about 10× the bytes outside the handler.
  - Compare the stall/down rate with stock over ≥ 40 runs per arm.
  - Stage C should show stalls. This design should show none that a site-instrumented probe calls covered.
- **The idle check on a 192 KB stick:** arms and flushes per 10 s. Expected unchanged, since below the cap the cadence is untouched.

## 9. Scores against R1-R12

| R | score | why |
|---|---|---|
| R1 | **PARTLY** (MET for garbage) | No garbage-covered refusal under the ceiling remains in any sweep where the site pass can measure (probe2 0/16 384, W16 program 0, every configuration). A refusal now needs a cycle's verdict. Refusals are never earlier than stock's at the contract top while pinned garbage ≤ PIN, but they are *later*, by at most one checkpoint interval and X bytes. That deferral is the residual and is not harmless: 11/4 096 and 43/16 384 (JIT) outside landings. |
| R1b | MET | W1/W1L/W1j/W8/W2b-c/W10 pass. RESERVE is the room after a refusal; `noreserve` fails W8. The kernel slice is unchanged (W10; `nokslice`). |
| R5 | MET | U + d ≤ ceiling ≤ T + G + K (§4). Charged. W7: od_peak 28 750 ≤ G, used ≤ cap + G + 2048. `unbounded` fails W7. |
| R6 | MET | No collection in the allocator; scalar writes only (stepmul, threshold, the latch), as before. On-trace, GCSTOP and HOOK_GC are defined in §5. Zero LuaJIT lines. |
| R7 | MET | +159/−61 in one file, mostly comment. One field, two constants, one function replaced, one added, one extracted, and one cadence branch deleted. The collector gate passes (0 matches; a planted call is caught). |
| R8 | MET | The verdict and tier live in the record. A loaded state is a fresh record (no verdict; fresh-record rule unchanged; W11). The Int.MaxValue cap never reaches the slow path. GCSTOP refuses past T without touching the record. |
| R9 | MET (hermetic) | Far from the wall: unchanged code paths (W4 far 0 collects). Near it: probe cycles −11%, time ×0.94, W12 21 → 14, W4 near 39 = 39. Idle below the cap is unchanged by construction. In-machine not measured. |
| R10 | PARTLY | Hermetic: W16 fails stage C 30/30 and passes 30/30; W17 likewise; sabotages make each fail (§8.3). W16's measure needs the §8.2 fix. The in-machine gate is designed but not run. |
| R11 | MET | No knob. X and PIN are compile-time shifts of G, which still derives from the cap, and the cap from OC's scale. |
| R12 | PARTLY | Hermetic capacity ≥ stage C's in every shape (medians +0..+19 objects), lower only where stage C's first refusal was swallowed by paint. Time ×0.94. The in-machine matrix was not run. |

## 10. Not checked

- **In-machine:** the real OpenOS dispatcher and `event.timer`, the real kernel loop, the capacity matrix, the idle stick, stock comparisons beyond the survey's hermetic PUC runs. The survey has PUC at 0 outside on probe2 and on the W16 program (out6, out9).
- **Pinned garbage larger than PIN** (G/32): a dead multi-KB object in a returned frame's slot. Not constructed.
- **The JIT-on covered status** of 13 downs, where the site pass is unreliable (§7.1).
- **Routing verdicts away from the trace recorder.** Not attempted: vmstate cannot tell the recorder from the program it is recording.
- **§5.11** (gc_low lowered while armed) is untested.
- **Other configurations:** caps other than 384 KB and 1 536 KB, batch sizes other than 100, junk lengths other than 24.
- **negative-control.sh itself** was not run (the repo is read-only for this task). Its edits were replicated exactly in `sabotage.py`, with the measured sets in §8.3.

## 11. Files

All in `C:/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/d2-verdict/`. Nothing was ever cleared; each pass wrote a fresh `out-*` directory.

**Sources**

| file | what |
|---|---|
| `lj52shim.c` | the proposed source; md5 cff2651d; object `bin-final2/lj52shim.o` e387460a |
| `lj52shim.diff` | the diff against the repo |
| `lj52shim.final1.c` | the version with PIN and the halving |
| `lj52shim.exp.c` | the experiment knobs (PIN, confirmation) |
| `lj52shim.v1.c` | the first prototype |
| `orig/lj52shim.c` | the repo source, which rebuilds to 0259f0d1 |
| `mem_test_d2.c` | W16 + W17; generated by `mkw17.py` |

**Tools**

| file | what |
|---|---|
| `mk.sh` | build and link lines |
| `variant.sh` | full suite per variant |
| `sweep.sh` | configuration sweeps |
| `sitepass_v.py` | site pass |
| `count.py`, `compare.py`, `covered.py` | tabulation |
| `timeit.py` | alternated timing |
| `sabotage.py` | negative controls |
| `bisect_norefuse.py`, `mkdbg.py` | the harness-error diagnosis |
| `lj_repro_v.c` | the driver, generated by `mkdriver.py` and `mkdriver2.py` |
| `mkinstr_v.py` | the instrument |
| `w16site.lua` | the W16 program with site hooks |

**Results**

| directory | contents |
|---|---|
| `out-stageC-3`, `out-final2-1` | the main comparison |
| `out-sw-*` | configurations: jit, legacy, hb3, nopaint, cap1536 |
| `out-seeds-2` | 30-seed runs |
| `out-sab-final2` | sabotages; `out-sab-1` is void for norefuse only (see its NOTES.txt) |
| `out-time-3` | timing; `out-time-1`'s timings are void (no `bc`) |
| `out-pin*`, `out-confirm-*`, `out-final-1`, `out-nohalving-1`, `out-silent-1` | the variants |
| `out-stageC-1/2`, `out-pin*-1/2` | earlier runs before the path fix and the site pass; superseded, kept |
