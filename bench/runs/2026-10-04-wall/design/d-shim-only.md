# The collector at the wall: a shim-only design (credit, hysteresis, park reset)

Everything below comes from reading the code at bd302f2. Nothing was built or run. Citations: **S** = `native/lj52shim.c`, **LJ** = `build/native/luajit-windows-x86_64/src`.

## 1. The mechanism

**P1: recovery at the wall. The allocator lends bounded credit and collects at the next checkpoint.**

The core rule is in four parts:

- **When to lend.** A positive request that would pass the cap is granted if `used + delta <= total + credit`. The credit comes from a two-tier record:
  - **BURST** is the default (0, from calloc). Credit is G/2.
  - **RESERVE** applies after a refusal. Credit is G.
  - Credit is **0** when the VM cannot collect: under `HOOK_GC`, under `threshold == LJ_MAX_MEM` (host GCSTOP), or when `M->L == NULL`. Inside finalizers the cap stays hard, as on PUC, where `gcrunning == 0`.
- **When to arm.** Every grant over the cap arms the collector unless it is already armed or the BURST band gate below holds it back. Every refusal arms too, from any headroom, which fixes shape 2 (a refusal with no arm). Arming is unchanged: `stepmul = 0` and `threshold = gc.total`. The VM runs a full cycle at its next checkpoint; the allocator never collects.
- **How the record changes.**
  - A refusal moves it to RESERVE.
  - A proof (the existing white latch, S:903) that finds `used <= total` moves it back to BURST: the debt is repaid.
  - A proof that finds `used > total` changes nothing. RESERVE survives proofs, so the cycle armed by a refusal can run *before* the program drops its data and recovery still works.
- **Why recovery works.**
  1. Before any refusal, grants stop at `total + G/2`.
  2. So when the refusal comes, at least G/2 of credit is left in reserve.
  3. The program's allocate-first constructs then succeed on credit. Examples are `lj_meta_cat` (LJ lj_meta.c:382-385) and `string.rep` (LJ lib_string.c:100-101).
  4. In RESERVE, each such grant arms. The construct's own check right after the allocation then collects the dropped data.

How G is sized:
- `G = clamp(total >> 4, 32 KB, 512 KB)`, so G/2 is always below `w = max(total/4, 128 KB)`. Credit is a fallback, not the routine buffer.
- The 32 KB floor binds on the 192 KB stick (cap ≈ 509 KB). There the reserve of ≥ 16 KB covers result strings, sunk-object restores, and the kernel's per-resume `table.pack`.
- The 512 KB ceiling bounds the host-side excursion per machine at any cap, including `Int.MaxValue`.

**The absolute bound.** Outside the `norefuse` window, every positive delta passes `used + delta <= total + credit <= total + G`. So:

    used <= total + G + W_nr,  where W_nr <= ~1.5 KB (S:1723-1728)

The bound is absolute, not incremental, so repeated refusals cannot ratchet it.

**What still fails.**
- One request larger than `headroom + credit`, made before any checkpoint has run, is still refused. It now arms, so a retry after any checkpoint succeeds. This is the residual (§5).
- A trace exit that restores sunk objects (LJ lj_snap.c:846/894) now draws on credit and does not raise ERRMEM unless the credit is exhausted.

**P2: the re-arm cadence. Hysteresis on headroom.**

New fields: `gc_hyst` (set at the first proof) and `gc_low` (`used` at the last proof, lowered by later frees). Arming while unarmed works like this:

| Situation | Arms when |
|---|---|
| No proof yet | `total - used < w` (today's behaviour) |
| Normal: `gc_low < total` | `total - used < min(w, (total - gc_low) >> 1)` |
| Band, BURST: `gc_low >= total` | `top - used < (top - gc_low) >> 1`, with `top = total + G/2` |
| Band, RESERVE | `used > total`: every grant arms (the stock cost per attempt) |

Cost:
- **Steady churn:** one full cycle per (cap − live)/2 bytes, against stock's one per (cap − live). That is 2× stock's cycle count, instead of one cycle per checkpoint.
- **Live fill:** the arms come at h, h/2, h/4, …, about log₂(w/size of one allocation) ≈ 10 cycles across the last quarter, plus about 7 in the BURST band. Today's count is 143–389 per batch.

A frees-only path cannot newly cross the gate: headroom rises by d while the gate rises by d/2.

The flush follows the same cadence. A cycle armed by the flush (S:993-1001) never raises `gc_flush_wanted` at its own proof. That bounds flushes to proofs of gate- or wall-armed cycles, which breaks the flush → re-arm → flush loop.

**P3: the parked collector.**
- **(a) Park reset.** In the armed branch, when the state is `GCSpause`, the white is unchanged and `threshold > gc.total`, write `threshold = gc.total` and count `gc_parkresets++`.
  - It is benign whenever it fires: it only restores the arm's own intent. It also fixes the "two collections hide the proof" case that mem_test's `settle_gc` works around.
  - It never fires inside a step. The only allocator calls inside `lj_gc_step` happen in sweep, atomic or finalize: `lj_str_resize` runs before `state = GCSpause` (LJ lj_gc.c:696-701), and finalizers are excluded by the `HOOK_GC` check.
- **(b) The bailout counts only allocation attempts** (grants and refusals), never frees or shrinks. An armed sweep that frees more than 65 536 blocks no longer trips it.

**P4: the kernelMemory windfall.** Kernel patch site 13 calls `jit.flush()` immediately before the baseline `coroutine.yield()` (machine.lua:1603-1605). OC's collect (NLA:220) then sweeps the unlinked GCtrace objects before it reads the figure.
- **Order:** this lands in a separate commit, only after the P2 gate passes on arm E, which already has a trace-free kernelMemory.
- **Known remainder:** the recorder buffers and the `J->trace` vector survive `lj_trace_flushall` (LJ lj_trace.c:276-303).

## 2. The code change

**Constants:**

```c
#define LJ52_GC_ODSHIFT   4            /* G = total/16: excursion <= 6.25% of the cap, G/2 < w   */
#define LJ52_GC_ODMIN     (32*1024)    /* reserve >= 16 KB on a 509 KB cap                       */
#define LJ52_GC_ODMAX     (512*1024)   /* host bound per machine at any cap                      */
#define LJ52_GC_HYSTSHIFT 1            /* re-arm after half the post-cycle headroom; 2x stock     */
#define LJ52_OD_BURST 0 / LJ52_OD_RESERVE 1
#define LJ52_ARM_GATE 0 / LJ52_ARM_WALL 1 / LJ52_ARM_FLUSH 2
#define LJ52_GP_FREE 0 / LJ52_GP_GROW 1 / LJ52_GP_TRY 2   /* kinds of gc_pressure call */
```

`LJ52_GC_ARMCAP` and `LJ52_GC_WMIN` stay as they are; ARMCAP now counts attempts only.

**New fields in `lj52_mem`** (after S:275; calloc makes every default correct):

```c
int gc_odstate; int gc_hyst; long long gc_low; int gc_armby;
volatile long gc_overdrafts; long long gc_odpeak; volatile long gc_parkresets;
```

**New functions** (defined below the LuaJIT includes; `credit` is forward-declared beside S:280):

```c
static long long lj52_gc_odmax(long long t){ t >>= LJ52_GC_ODSHIFT;
  return t < LJ52_GC_ODMIN ? LJ52_GC_ODMIN : t > LJ52_GC_ODMAX ? LJ52_GC_ODMAX : t; }
static long long lj52_gc_credit(lj52_mem *M, long long total){ global_State *g;
  if (M->L == NULL) return 0; g = G(M->L);
  if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) return 0;
  return M->gc_odstate == LJ52_OD_RESERVE ? lj52_gc_odmax(total) : lj52_gc_odmax(total) >> 1; }
static void lj52_gc_arm(lj52_mem *M, global_State *g, int why){ /* body of S:933-940 */
  M->gc_savedmul = g->gc.stepmul; M->gc_white = g->gc.currentwhite;
  g->gc.stepmul = 0; g->gc.threshold = g->gc.total;
  M->gc_armed = 1; M->gc_armedcalls = 0; M->gc_armby = why; M->gc_arms++; }
static void lj52_gc_refused(lj52_mem *M, long long total, long long used){ global_State *g;
  M->gc_refusals++;
  lj52_gc_pressure(M, total, used, LJ52_GP_TRY);          /* proof/park/valve first */
  if (M->gc_busy || M->L == NULL || total <= 0) return;
  g = G(M->L); if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) return;
  M->gc_odstate = LJ52_OD_RESERVE;
  if (!M->gc_armed) lj52_gc_arm(M, g, LJ52_ARM_WALL); }
```

**`lj52_gc_pressure(M, total, used, kind)`, a rewrite of S:880-943.** The early returns at S:889/897 stay. Then:

```c
if (kind == LJ52_GP_GROW && used > total) {            /* a grant on credit */
  M->gc_overdrafts++; if (used - total > M->gc_odpeak) M->gc_odpeak = used - total; }
if (M->gc_armed) {
  if (white changed && state == PAUSE) {               /* proof, S:903-915 */
    restore stepmul if 0; disarm; collects++;
    M->gc_hyst = 1; M->gc_low = used;
    if (used <= total) M->gc_odstate = LJ52_OD_BURST;
    if (M->gc_armby != LJ52_ARM_FLUSH && total - used < w) M->gc_flush_wanted = 1;
  } else if (state == PAUSE && g->gc.threshold > g->gc.total) {
    g->gc.threshold = g->gc.total; M->gc_parkresets++;  /* P3a */
  } else if (kind != LJ52_GP_FREE && ++M->gc_armedcalls > LJ52_GC_ARMCAP) { /* P3b */
    ...S:922-924 unchanged... }
  return; }
if (M->gc_hyst && used < M->gc_low) M->gc_low = used;
arm = !M->gc_hyst ? total - used < w
    : M->gc_low < total ? total - used < min(w, (total - M->gc_low) >> LJ52_GC_HYSTSHIFT)
    : M->gc_odstate == LJ52_OD_RESERVE ? used > total
    : (top = total + (lj52_gc_odmax(total) >> 1), top - used < (top - M->gc_low) >> 1);
if (arm) lj52_gc_arm(M, g, used > total ? LJ52_ARM_WALL : LJ52_ARM_GATE);
```

`gc_busy` set and clear are unchanged.

**C mode (S:371-388):**
- S:373 passes `LJ52_GP_FREE`.
- S:378 gains `&& M->total - M->used + lj52_gc_credit(M, M->total) < delta`. The credit is computed only on this slow path.
- S:379-381 becomes `lj52_gc_refused(M, M->total, M->used); return NULL;`.
- S:386 passes `delta > 0 ? GROW : FREE`.

**Legacy mode (S:430-454):** the same three edits.
- S:440: `!(… || M->norefuse) && total - used + lj52_gc_credit(M, total) < delta`.
- S:445-447 calls `lj52_gc_refused`.
- S:453 passes the kind.
- `setmem` may now write `used > total`. Java clamps free memory with `max(0, total - used)`: `gen-luastate-subclass.py:221` on the additive build, and jnlua's `LuaState.java:503-508` on the dropin.

**Other shim edits:**
- **Flush:** S:993-1001 becomes `if (!M->gc_armed && g->gc.threshold != LJ_MAX_MEM) lj52_gc_arm(M, g, LJ52_ARM_FLUSH);`.
- **Stats:** a new raw global, `_OCLJ_ODSTATS()`, returns 5 values: overdrafts, od_peak, od_state, park_resets and od_limit (= `odmax(total)`). It is installed beside S:1639. `_OCLJ_GCSTATS` keeps exactly 20 values, so no pinned site changes.

**Kernel** (`native/kernel/patch-machine-lua.lua`, new site 13 through `replace_once`):

```lua
src = replace_once(src, "baseline flush",
[==[  -- Yield once to get a memory baseline.
  coroutine.yield()
]==], [==[  -- Yield once to get a memory baseline.
  -- OC-LuaJIT: unlink kernel-init traces so OC's collect after this yield sweeps them.
  if type(jit) == "table" and jit.flush then jit.flush() end
  coroutine.yield()
]==])
```

`jit` is a raw global (S:1852). The sandbox never sees it, and `jit.flush` is a C function the interpreter calls, so it is safe here. The `build-native.sh` collector gate (:340) is untouched: nothing new calls the collector.

## 3. Edge cases

- **On-trace allocation at the cap.** The credit and the arm only read and write scalars, as today's arm does.
  - A trace with counted allocations reaches `asm_gc_check` at the head or LOOP (LJ lj_asm.c:2587-2591, :1691). `lj_gc_step_jit` exits at `GCSatomic`, and `lj_trace_exit` finishes the cycle off-trace (LJ lj_trace.c:942-944).
  - A trace whose only allocations are uncounted (NEWREF, i.e. table inserts) has no check. It uses credit up to the ceiling and is then refused on trace, through the existing unwind.
- **Trace exits.** Sunk-object restores draw on credit and arm. Only an exhausted credit reproduces today's ERRMEM from an exit.
- **The norefuse window.** It is unchanged: charged, never refused, `gc_pressure` inert (S:889). It is the only path past `total + G`, by about 1.5 KB at most. The M6/C6 tests have to exhaust both tiers now (§4).
- **Finalizers (`HOOK_GC`).** Credit is 0 and a refusal makes no RESERVE and no arm. A refusal inside `__gc` is swallowed (LJ lj_gc.c:522-534), as on PUC.
- **Host GCSTOP / GCRESTART.** Under GCSTOP, credit is 0 and nothing arms; the cap is hard because nothing could repay the debt. GCRESTART sets `threshold = total` (LJ lj_api.c:1252), so an armed record runs at the next checkpoint. A host `SETSTEPMUL` while armed is a pre-existing hazard and is not touched.
- **OC lifting the cap to Int.MaxValue.**
  - While the cap is lifted, headroom is huge and no gate fires.
  - When it is restored, `gc_low` is the lowest `used` since the last proof, so the gate becomes `min(w, …)`. If the cap is restored under `used` (C4b), the next growth arms. Growth past `total + G/2` is refused and arms, and the next collection clears it.
  - `odmax` caps G at 512 KB even at `Int.MaxValue`.
- **eris.** Every new field lives in `lj52_mem`. Nothing is in `global_State` and nothing is persisted. A loaded state starts in BURST with no hysteresis, so it behaves as today until its first proof, and the over-cap balance does not cross a save. OC also collects after unpersist with the cap lifted.
- **The dropin's legacy path.** It gets the same predicate and the same calls with Java's `total` and `used`. The credit is charged into Java's field.
- **Sandbox code trying to drive it without bound.**
  - *Bytes:* the ceiling is absolute, at `total + G + W_nr`. Repeated caught refusals can at most fill it with live data.
  - *CPU:* full cycles are bounded by refusals, gate crossings, RESERVE grants and gate-armed flushes. Refusal- and RESERVE-driven cycles cost one per attempt, which is stock's emergency cycle per refusal. Gate cycles cost one per (cap − live)/2 bytes. `pcall(string.rep, "x", 2^31)` is refused in 64-bit arithmetic and costs at most one armed cycle per attempt, like stock.
  - *Trust:* `_OCLJ_ODSTATS` is read-only and never reaches the sandbox.

## 4. Fail-first tests

These are in `mem_test.c`. Each runs in C mode on the C state and in legacy mode on the P state. "FAILS today" is by reading of S:378-447 and S:880-943; each test has to be seen failing against today's object through `OCLJ_SHIMOBJ` before its pass counts.

- **W1, recovery (P1).**
  - Setup: holder pre-sized from C (`lua_createtable(1<<16, 0)`); cap = used + 512 KB.
  - Chunk, with `jit.off()`: `ok, err = pcall(fill {} into holder)`, then `holder = nil`, then `string.rep("x", 256)`, then one table.
  - Assert: `err` is "not enough memory" (the wall was reached); the rep succeeded (**FAILS today**: refused, because rep allocates before its check); afterwards collects went up, `used <= total`, `od_peak <= od_limit`, bailouts 0. Run 3 rounds.
  - W1j: the same with JIT on and the wd_test 10 s alarm.
- **W2, shape 2 (P1).**
  - Setup: cap = base + 1 MB. Make 0.6·H of garbage (`lua_createtable` then pop), so headroom stays at or above w and nothing arms.
  - Request `headroom + G/2 + 64 KB`. It is refused (the residual, which has to stay).
  - **W2b:** `armed == 1` after the refusal (**FAILS today**).
  - **W2c:** the retry, which checks before allocating (LJ lj_api.c:710), succeeds (**FAILS today**).
  - **W2d:** a request of `headroom + G/4` is granted, `used > total`, and after the next checkpoint plus one allocation `used <= total` (**FAILS today**).
- **W3, trace exit (P1).** A compiled loop `local t = {i, i+1} if i == n then return t end` gets warm under a large cap. Then set the cap to exactly `used` and call. Assert that `t` is returned and `overdrafts >= 1` (**FAILS today**: ERRMEM from the restore).
- **W4, cadence (P2).**
  - Setup: 256 KB live parked in the registry; cap = used + 64 KB (inside w); `churn(0, ∞, 2000)`.
  - Assert `1 <= Δcollects <= ceil(2000·64 / (h/2)) + 2`, which is 6 (**FAILS today** at about 1000), and no refusal.
  - Far control: cap = used + 4w gives `Δcollects <= 2`.
  - Same-process time ratio near/far ≤ 3.
  - P1a, P2b and C5b must stay green.
- **W5, park (P3).**
  - **W5a:** follow u-tests §5(3): `LUA_GCSTEP` until `state == 4`, arm, one table, then `state == 0`. After the next allocation assert `threshold <= gc.total` and `park_resets >= 1` (**FAILS today**: threshold stays at 2·estimate).
  - **W5b:** 64 B churn. Assert no refusal, collects move within 100 steps, bailouts 0 (**FAILS today**: refused after about 3k steps).
  - **W5c:** GCSTOP; make 10⁵ garbage tables; set the cap so headroom is below w; GCRESTART; one chunk. Assert `Δbailouts == 0` and `Δcollects >= 1` (**FAILS today**: the sweep's frees trip ARMCAP).
- **W7, creep (R5).** A pcall per live insert, 10⁵ times. Check `used <= total + od_limit + 2 KB` every 1000 steps; `refusals >= 1`; `Δcollects <= 2·Δrefusals + 24`.
- **W6, P4.**
  - **(a)** The patcher's output contains the flush immediately before the baseline yield. This **FAILS** on today's `build/native/kernel/machine.lua`.
  - **(b)** Three twin states each run `TRACE_CHUNK`, then `jit.flush()`, then COLLECT. Assert `JIT_LIVE == 0`, identical `used` across the three, and `used <= ref + 16 KB`, where ref is the same chunk run under `jit.off`. The arm without the flush must exceed `ref + 16 KB`, which shows the bound can fail.

**Existing checks re-scoped on purpose.** Each gets its own fail-first against a sabotaged shim with unbounded credit.
- M5, C3a and e4 change "used ≤ cap" to "≤ cap + od_limit", and must read ≤ cap after one COLLECT.
- M6 and C6 set `cap = used − odmax(used)`, which exhausts both tiers.

**negative-control.sh sabotages, with the checks each must fail.**

| Sabotage | Must fail |
|---|---|
| credit = 0 | W1, W2d, W3 |
| no arm in `gc_refused` | W2b, W2c |
| hysteresis off | W4 |
| no park reset | W5a, W5b |
| frees counted toward the bailout | W5c |
| credit = total | W7 |

**The in-machine gate (capacity matrix).**
- **Instrument first:** `CAP-*` prints `_OCLJ_GCSTATS` positions 2, 3, 5, 7, 8, 9 and 15, plus `_OCLJ_ODSTATS`. It must be seen reading "absent" on today's DLL. `cap.sh` also gets a `dropin` mode.
- **(a) Recovery:**
  - D/E/O 60-run matrix: 0 "recovery refused" and 0 "down" (today 19/60).
  - Every clean run shows refusals ≥ +1 and `od_peak <= od_limit`.
  - Overdrafts ≥ 1 in each shape.
  - Held O/S ≥ 0.95 in the 1024 KB closure cell.
  - Dropin subset (192 KB and 1024 KB × 4 shapes): 0 refused, 0 down.
- **(b) Throughput:** median `t_last5 <= 3×` stock's in the same pinned chain, and fill arms ≤ 3 per batch on average (today ≥ 143).
- **(c) Parking:** bailouts == 0 and collects ≥ arms − 1 everywhere; the park fingerprint is never read.
- **(d) P4, measured after it lands:**
  - kernelMemory identical across ≥ 3 replicates per stick, and ≤ 164 393 + 16 KB.
  - The same on an unpinned host.
  - 192 KB idle: arms ≤ 63 per 400 ticks and 0 flushes (today E reads 1390–2964 and 16–29).
  - Boot failures 0/12.
- **(e) Regression suites:** additive 65/63/59, dropin 62, stock 47, the sieve acceptance test, wd_test W6b.

## 5. What it does not fix

- A single request larger than `headroom + credit`, made before any checkpoint has run, is refused where stock would collect and succeed. Retries succeed.
- Bursts at the wall that pass the credit with no checkpoint are refused without a proven cycle: table inserts (NEWREF), stack growth, and buffer growth inside one C call.
- A program that creeps live data into the reserve through caught refusals loses the recovery guarantee. It gets one extra refusal after it drops its data.
- Finalizer-time allocation keeps a hard cap.
- Also unchanged:
  - the `lj_tab_resize` array/hash order (PUC has the same);
  - a host SETSTEPMUL while armed;
  - mcode outside the cap;
  - the recorder buffers left in kernelMemory after P4.

**The remaining divergence from stock, in one sentence:** where stock collects at the refused allocation, we lend up to G/2 bytes past the cap (G after a refusal), charged and reported as 0 free, and collect at the next checkpoint, so a request that would fit only after that collection is refused when it exceeds the remaining credit before the checkpoint runs, and a program can hold at most G bytes more than its cap.

## 6. Self-assessment

| | Verdict | Why |
|---|---|---|
| R1 | PARTLY | Catch, drop, continue works whenever the post-drop allocations fit in the reserve (≥ G/2). Refusals can still precede a full collection: shape-2 requests and checkpoint-free bursts. Shrinks, frees and raising are unchanged. |
| R2 | PARTLY (by reading) | Steady churn costs 2× stock's cycle count. A live fill costs about 17 cycles in its last quarter. The estimate is 1–3× stock's `t_last5`, unmeasured. If the matrix disagrees, `HYSTSHIFT` = 2. |
| R3 | MET by construction | The park reset, attempt-only bailouts, and every arm proven at a checkpoint. Gated by W5 and matrix (c). |
| R4 | PARTLY | Trace-free except for the recorder buffers, whose determinism is unproven. Sequenced after the P2 gate on E. |
| R5 | MET | `used <= total + G + 1.5 KB`, cap-relative and absolute. Charged. Java clamps free at 0. The sandbox cannot ratchet it (W7). No new refusal sites; the overdraft only removes refusals. |
| R6 | MET | No collection in the allocator. C1–C7 untouched, since only the existing two scalars are written. On-trace behaviour as §3. |
| R7 | MET | Zero LuaJIT lines. About 80 shim lines and 1 kernel site. The collector gate is unchanged. `_OCLJ_GCSTATS` stays at 20 values. |
| R8 | MET | All state in `lj52_mem`. GCSTOP means credit 0. The cap lift is handled through `gc_low` and the 512 KB ceiling on G. |
| R9 | MET | The hot path adds one compare and the kind argument. Credit is computed only on the refusal path. Gate = w before the first proof, so P1a is unchanged. |
| R10 | PARTLY | W1–W7 fail on today's shim by reading, not yet observed. P4 is hermetic only at the patch-text and mechanism level. The dropin needs a new `cap.sh` mode. |
| R11 | MET | No knob. ramScale is inherited. All constants are compile-time. |

The least-supported claim is R2's ≤ 3×. Cycle costs of 0.06–0.24 ms come from dividing today's `t_last5` by today's arms. The 17-cycle count is arithmetic, not a measurement. The matrix decides.

**Files:** `C:/Users/astro/Downloads/OC-LuaJIT/native/lj52shim.c`, `C:/Users/astro/Downloads/OC-LuaJIT/native/kernel/patch-machine-lua.lua`, `C:/Users/astro/Downloads/OC-LuaJIT/test/native/mem_test.c`, `C:/Users/astro/Downloads/OC-LuaJIT/test/native/OcljSmoke.scala`, `C:/Users/astro/Downloads/OC-LuaJIT/bench/runs/2026-10-03-ramscale/scripts/cap.sh`