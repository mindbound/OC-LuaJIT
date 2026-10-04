# Collecting at the wall from a shim-owned safe point: design

All of this comes from reading the code at HEAD bd302f2; nothing was built or run. "S" means `native/lj52shim.c`. "LJ" means `build/native/luajit-windows-x86_64/src`.

## 0. Summary

The allocator still never collects. At the cap it does one of two things, and in both cases it asks for a collection:
- it **grants** the request against a small overdraft fixed at compile time, or
- it **refuses** it, as today.

Each request is carried two ways, and the first carrier able to decide it settles it:
- **The checkpoint carrier** is today's arm (`stepmul=0`, `threshold=gc.total`), kept unchanged. It is the only way to reach the checkpoints inside C calls, such as jnlua pushes and `lj_gc_check` in the library functions.
- **The hook carrier** is a count=1 hook, installed with the watchdog's own injection sequence (S:1117-1123). At the next instruction boundary, `lj52_wd_hook` runs `lua_gc(L, LUA_GCCOLLECT, 0)`.

`_OCLJ_WATCHDOG.arm` and `disarm` serve as backstop safe points.

**A full collection, not the stepper run to completion.** `lj_gc_fullgc` throws away a partial propagation (LJ lj_gc.c:786-793), so its mark always starts after the request. The stepper carries on with a mark that may have started before the program dropped its data. Data marked before the drop then survives that cycle as floating garbage, which is exactly the P1 recovery shape. `lua_gc` is also the public API, so `lj_gc.h` and `lj_gc_step` stay out of the shim.

**Running finalizers inside the hook is safe.**
- `hook_entergc` sets `HOOK_ACTIVE|HOOK_GC` (lj_obj.h:683-684). A finalizer therefore cannot re-enter any hook (lj_dispatch.c:370).
- `threshold=LJ_MAX_MEM` blocks nested steps (lj_gc.c:516), and errors are swallowed (:522-534).
- The sandbox's `__gc` is stripped by default (machine.lua:816-838). When it is allowed, it runs without hooks on stock too (OC's own comment, :818-820).
- The nested arm/disarm that sgc makes hits the `HOOK_GC` guards described below.
- Compared with PUC's emergency collection, which skips finalizers, the only difference is when they run.

## 1. Mechanism

**Constants.**
- `LJ52_GC_SAND` = 16 KiB, the sandbox band. It must cover one window's fixed-size allocations:
  - a `BC_TNEW` at the parser's 2047-slot array cap (about 16 KiB);
  - an 8 KiB modem or internet payload;
  - restoring a snapshot of sunk tables;
  - the probe's recovery allocation (under 100 B) after a fill window of small objects.
- `LJ52_GC_OVER` = 32 KiB = 2 × SAND, the bound on any excursion. The top 16 KiB is reserved for the kernel thread: per-resume `table.pack` (machine.lua:1625-1630) and signal arguments of 8 KiB or less.
- The existing `norefuse` window adds at most 1.5 KiB. The hard bound is therefore **used ≤ total + 33.5 KiB**.
- `LJ52_GC_WMIN` stays at 128 KiB. `LJ52_GC_ARMCAP` is deleted.

**P1, recovery.** A *crossing* is a call with `acct && delta>0 && !norefuse && used+delta > total`.
- **When a crossing is granted.** Only if the collector is running (`threshold != LJ_MAX_MEM`), `HOOK_GC` is clear, and the hook is ours or free (`hookf` is NULL or `lj52_wd_hook`). In addition, one of these must hold:
  - *Sandbox band:* `gc_credit` is set and `used+delta ≤ total+SAND`. The grant sets `gc_granted`.
  - *Kernel band:* the running thread is the kernel's (`gco2th(g->cur_L) == wd_kernel`, or `wd_depth == 0`) and `used+delta ≤ total+OVER`. `cur_L` is restored to the resumer after `vm_resume` (vm_x64.dasc:1625).
- Every grant files a request (WALL) and records `odpeak`.
- **Otherwise the call is refused.** It does `refusals++`, sets `gc_credit=1` and `gc_granted=0`, and files a request (REFUSE). After a refusal the program may drop its data, so credit has to be open for its next allocation.
- **Settling.** Only a *fresh* collection settles a request: the hook's fullgc, or a proven checkpoint cycle whose arm found `GCSpause`. A WALL request that finds an arm already in place clears `gc_fresh`, so only a cycle begun after the request can settle it. The outcomes:
  - `used ≤ total`: credit stays open.
  - `used > total` and `gc_granted` set: credit closes. The next sandbox crossing refuses, because the live set really does not fit.
  - A free that brings `used ≤ total` reopens credit.
- **How the measured failure becomes a pass.** The fill crosses and is granted. The collection at the next instruction finds the heap still over, so credit closes. The fill's next crossing is refused and caught, and credit reopens. The program sets `held = nil`. `"done/"..n` crosses and is granted. Then either the armed fresh cycle at `lj_meta_cat`'s check after allocating (lj_meta.c:382-385) or the hook frees `held`.
- **Second shape (one large request).** Granted if it fits in the band. Beyond that it is refused once, and the refusal's collection runs at the next instruction, so an immediate retry succeeds.
- **Third shape (trace exit at the cap).** The snapshot restore's allocations (lj_snap.c:846, :894) are crossings like any other and are granted.
- **"Down" (an uncaught refusal stops the machine).** Kernel allocations draw on a band the sandbox can never reach, and that band never closes.

**P2, the last quarter.** Hysteresis applies only to the discretionary request, the pre-emptive one.
- A pre-emptive request is filed when `total-used < w` (w unchanged) **and** `used ≥ gc_next`.
- At every settlement: `gc_next = after + max((total-after)/2, SAND)`.
- If a pre-emptive collection freed less than half of what was allocated since the previous one, `gc_next = LLONG_MAX` until the next WALL, REFUSE or FLUSH settlement.
- WALL and REFUSE requests are never throttled. They play the role of stock's emergency collection, about one per (cap−live) bytes, and filing one is deduplicated: at most one is pending at a time.
- Bound, by derivation only: under churn, at most 2 collections per (cap−live) bytes; in a fill, at most one wasted collection per approach.

**P3, the parked collector.**
1. **Park reset.** In the armed branch, if `state==GCSpause`, the white still equals the latched value, and `gc.threshold > gc.total`, then set `threshold = gc.total`. This branch is never reached under GCSTOP or HOOK_GC, which return earlier. The next checkpoint then starts a fresh cycle at stepmul 0.
2. **The hook ends every arm.** After its fullgc, `lj52_gc_atsafe` disarms explicitly: it restores stepmul and does `collects++`. An arm therefore lasts at most until the next instruction boundary or the next arm/disarm. This also removes the two-flip alias that `settle_gc` works around (mem_test.c:342-349).
3. **The valve goes.** Nothing counts sweep frees any more. `bailouts` now means "an outermost arm found the same request unserviceable twice running", and must read 0.

**P4, the kernelMemory windfall.**
1. **Kernel patch site 13.** Add `if jit then jit.off() end` as the kernel's first statement, and `if jit then jit.on() end` right after the baseline yield (machine.lua:1603). Java has collected and read kernelMemory by then (NativeLuaArchitecture.scala:220-221). This is the mod's version of the harness's E arm (OcljArch.scala:85-97). No trace is recorded and no recorder buffer grows, so the figure is E's 164 393 B on every host, where D read 335–413 KB. `jit.flush()` was rejected because it leaves `irbuf`, `snapbuf` and the rest grown (lj_trace.c:276-303 against :370-373).
2. **The idle thrash this would expose is handled.** `flush_wanted` is set only when a settlement leaves headroom below `LJ52_GC_OVER`, not below w (128 KiB, which on a 192 KB stick is true all the time).

## 2. Code sketch

**New fields in `lj52_mem`** (after S:274; `gc_armedcalls` is removed):
```c
int gc_req, gc_hookown;   /* hook carrier installed / installed by us alone          */
int gc_kind;              /* RQ_PRE 1|RQ_WALL 2|RQ_REFUSE 4|RQ_FLUSH 8: pending work */
int gc_fresh, gc_stuck;   /* arm found GCSpause; outermost arms that found work stuck */
int gc_credit, gc_granted;/* sandbox band open; sandbox grant since last refusal      */
long long gc_low, gc_requsd, gc_next, gc_seentotal, gc_odpeak;
lua_State *wd_kernel;     /* caller of the last outermost arm                          */
volatile long gc_grants, gc_hookcollects;
```
At newstate: zeroed, with `gc_credit=1`.

**C mode, S:378-381**, which becomes:
```c
if (acct && delta>0 && !M->norefuse && M->total-M->used < delta
    && !lj52_gc_wall(M, M->total, M->used, delta)) return NULL;
```
S:373 and S:386 pass `delta` to `lj52_gc_pressure`.

**Legacy mode.**
- After `getmem` (S:424): `M->gc_seentotal = total;`.
- S:440-447: `if (!(total<=0||delta<=0||total-used>=delta||M->norefuse) && !lj52_gc_wall(M,total,used,delta)) return NULL;`.
- S:434 and S:453 pass `delta`.
- The dropin gets the same fix through the same function.

**`lj52_gc_wall(M,total,used,delta)`** (new):
- Applies the grant rule in §1.
- On a grant: `gc_grants++`, updates `odpeak`, and sets `gc_granted` if the grant came from the sandbox band. Returns 1.
- On a refusal: `refusals++`, `credit=1`, `granted=0`. Unless HOOK_GC or GCSTOP is set, it also calls `lj52_gc_request(...,RQ_REFUSE)`. Returns 0.

**`lj52_gc_request(M,total,used,kind)`** (new). It writes scalars and the timer's injection, nothing else:
```c
M->gc_kind |= kind; M->gc_seentotal = total; if (kind==RQ_PRE) M->gc_requsd = used;
if (!M->gc_armed) { /* today's S:934-939, plus: */ M->gc_fresh = g->gc.state==LJ52_GCS_PAUSE; }
else if (kind & (RQ_WALL|RQ_REFUSE)) M->gc_fresh = 0;
if (!M->gc_req) {
  if (g->hookf && g->hookf != lj52_wd_hook) return 0;      /* a foreign hook: not ours */
  M->gc_req = 1;
  if (!(g->hookmask & LUA_MASKCOUNT)) { lj52_wd_inject(M); M->gc_hookown = 1; }
  else g->hookcount = 1;                                    /* fired deadline / fallback */
}
return 1;
```
The timer thread already runs `lj52_wd_inject` at arbitrary instants, recording and on-trace included. Running it on the Lua thread is a subset of the interleavings that already happen in production.

**`lj52_gc_pressure`** (rewrite of S:880-943):
- Keep the early returns.
- On the way in: `if (used<gc_low) gc_low=used; if (!gc_credit && used<=total) gc_credit=1;`.
- Keep the HOOK_GC and LJ_MAX_MEM returns.
- Armed branch: either the proof (restore stepmul, `collects++`, `lj52_gc_settle(M,total,used,gc_fresh)`) or the park reset.
- Unarmed branch: `if (delta>0 && !gc_kind && total-used<w && used>=gc_next) request(RQ_PRE)`.

**`lj52_gc_settle(M,total,after,decisive)`** (new):
- Sets `gc_next` (the hysteresis and back-off from §1) and `gc_low = after`.
- `after ≤ total`: credit 1, kind 0.
- Otherwise, if `decisive`: close credit if `gc_granted` was set; clear `gc_granted` and kind.
- Otherwise WALL/REFUSE wait for the hook, and only PRE/FLUSH are cleared.
- In every case: `if (total-after < LJ52_GC_OVER) gc_flush_wanted = 1`.

**`lj52_gc_atsafe(L,M)`** (new). This is the only collection in the shim:
```c
if (!M->gc_kind && !M->gc_armed) return;
if (!M->accounting || (g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) return;
M->gc_busy = 1; lua_gc(L, LUA_GCCOLLECT, 0); M->gc_busy = 0;   /* gc_busy: no proof inside */
M->gc_hookcollects++;
if (M->gc_armed) { if (!g->gc.stepmul) g->gc.stepmul = M->gc_savedmul; M->gc_armed = 0; M->gc_collects++; }
lj52_gc_settle(M, M->csync ? M->total : M->gc_seentotal, M->used, 1);  M->gc_kind = 0;
```
The check `!M->accounting` is what reads `accounting` as false once close has run.

**`lj52_wd_hook`, prefix at S:1048, before the thread filter:**
```c
if (M && M->gc_req) { M->gc_req = 0; lj52_gc_atsafe(L, M);
  if (M->gc_hookown) { M->gc_hookown = 0; if (!M->wd_fired) { lj52_gc_unhook(M); return; } } }
```
`lj52_gc_unhook` does `__atomic_fetch_and(&g->hookmask,~LUA_MASKCOUNT)` and then `lj_dispatch_update(g,0)`. It leaves `hookf` alone, and disarm clears it.

**Other changes:**
- `lj52_wd_program`: clear `gc_hookown` at the three synchronous installs (S:1252, 1266, 1292), so a deadline's hook that is past due, or the degraded fallback hook, is never removed.
- `lj52_wd_arm` (S:1406): keep the flush, then call `lj52_gc_atsafe(L,M)`. In the outermost block (S:1419-1431): set `wd_kernel=L`, run the `gc_stuck`/`bailouts` check, and after the hook is cleared set `gc_req=gc_hookown=0`.
- `lj52_wd_disarm` (S:1448): call `lj52_gc_atsafe` first, and set `gc_req=gc_hookown=0` after its `lua_sethook`.
- `lj52_gc_flushtraces`: replace the re-arm block (S:993-1001) with `M->gc_kind |= RQ_FLUSH`. The arm that follows sweeps the unlinked GCtrace objects immediately.
- `lj52_mem_settotal` (S:478): add `gc_credit=1`.
- `_OCLJ_GCSTATS`: still 20 values. Only the meaning of position 3 (bailouts) changes.
- New raw global `_OCLJ_GCWALL()`, registered next to S:1639, returning 6 values: grants, odpeak, hookcollects, kind, credit, gc_next.
- Zero LuaJIT lines change.

**The collector gate** (build-native.sh:335-347), moved into `native/gate-collector.sh <dir>`:
- `lj_gc_fullgc|lj_gc_step|luaC_|LUA_GCSTEP` stay forbidden everywhere.
- `lua_gc *\(|LUA_GCCOLLECT` must match exactly one line of code, inside `lj52_gc_atsafe`'s body, after lines testing `HOOK_GC` and `LJ_MAX_MEM`.
- Every call to `lj52_gc_atsafe(` must sit in `lj52_wd_hook`, `lj52_wd_arm` or `lj52_wd_disarm` (awk tracks the enclosing column-0 function).
- Fail-first, against sed-sabotaged copies:
  - g1: `lua_gc(M->L,LUA_GCCOLLECT,0);` inserted into `lj52_alloc`;
  - g2: an `lj52_gc_atsafe` call inserted into `lj52_gc_wall`;
  - g3: the HOOK_GC guard deleted.
  
  Each must fail with its own message, and the canonical copy must pass. They join negative-control.sh, which has no collector sabotage today.

## 3. Edge cases

- **On-trace allocation at the cap.**
  - The grant works the same way. The inject trips CHECKHOOK's guard (lj_record.c:2953-2972), whose volatile XLOAD is re-emitted on every loop iteration, so the trace exits within one iteration. The armed `asm_gc_check` may make it exit earlier, at atomic.
  - Anything past the band raises ERRMEM on trace through the existing unwind (lj_err.c:347-383).
  - A trace exit's snapshot restore draws from the band.
- **The `norefuse` window.** Unchanged: always granted, always charged, `gc_pressure` inert, no request. It adds at most 1.5 KiB to the bound.
- **Finalizers (HOOK_GC).**
  - No grant and no request inside one; that matches PUC, which does no emergency collection while `gcrunning` is 0. A refusal there is swallowed by `gc_call_finalizer`.
  - `atsafe` returns immediately, including from sgc's nested arm/disarm. That is C4: never collect inside `__gc`.
- **Host GCSTOP and GCRESTART.**
  - Under GCSTOP: no credit, no request, `atsafe` defers, and the park reset never overwrites `LJ_MAX_MEM`.
  - After GCRESTART (`threshold=total`), the armed checkpoint runs, and the next arm/disarm serves any pending work.
- **OC raising the cap to Int.MaxValue around persist.** Headroom is far above w, so there is no crossing and no request. `settotal(cap)` reopens credit. C4b still refuses, because used is far above cap + 32 KiB.
- **eris.** Nothing has to cross a save: every new field lives in `lj52_mem`, and stepmul is 0 only while armed (one boundary). After unpersist the record is new (credit 1, `gc_next` 0). The hook bits are runtime state, and the next outermost arm resets them.
- **Dropin's legacy path.**
  - The same rules apply at S:440 with Java's total.
  - The hook reads `gc_seentotal`.
  - The hook collection's frees take the legacy JNI free path, as every collection's frees do.
- **Sandbox code trying to drive it.**
  - The sandbox's excursion stays within 16 KiB: credit closes after a proven over-cap collection and reopens only after a refusal or once used ≤ total.
  - Sandbox code that runs on the kernel thread (an error object's `__tostring` at machine.lua:1630) stays within 32 KiB.
  - Requests are deduplicated, so there is at most one collection per instruction boundary. A refusal loop costs one full collection per refused allocation, which is PUC's own rate (lmem.c:84-93).
- **Sharing the hook with the watchdog.**
  - The GC part runs before the thread filter, because collection is global.
  - `HOOK_ACTIVE` is never touched: only `LUA_MASKCOUNT` is changed, by atomic OR/AND.
  - A timer fire that lands between our read of `wd_fired` and our AND is lost and fires again within 50 ms. That is the existing accepted residual.
  - **W6b:** accounting is off, so no request is ever filed. Its cost is one branch in arm/disarm, and the 20 ms bound is untouched.

## 4. Fail-first tests

Every X check must FAIL against today's object (OCLJ_SHIMOBJ = cb29485d's `lj52shim.o`) and PASS after the change. On today's shim `_OCLJ_GCWALL` is missing and reads −1; every check is written so that −1 fails.

Sandbox-class bodies run as `co` under an outermost `ARM` and a `coroutine.resume`, the same way the kernel runs them. They use C mode; the e-variants repeat on the legacy `FS` state.

| id | setup | today | pass |
|---|---|---|---|
| X1a | JIT off. Cap = used + 512 KB. Holder pre-sized from C (`lua_createtable(L,1<<16,0)`). Three rounds of `pcall(fill)`, then drop the holder, then `"done/"..n` | the concat is refused (ERRMEM) | status 0, all rounds ok, err=="not enough memory", refusals ≥ +3, grants ≥ 3, odpeak ≤ 16 KiB, at rest kind==0, collects==arms |
| X1b–d | X1a with a JIT-hot fill (10 s alarm), with a `string.rep(256)` recovery, and with a record fill (contents asserted intact before the drop) | refused | same |
| X1f | Recovery is `for i=1,6000 do R2[i]=i end` (array growth, no checkpoint in the window) | refused | pass. Also fails with the hook carrier sabotaged |
| X2a/b | Cap = base + 3 MB. 2 MB of garbage made under GCSTOP, then RESTART; precondition: garbage ≥ 1.5 MB. Request = headroom + 12 KiB / headroom + 256 KiB | refused / both attempts refused | granted / second attempt succeeds |
| X3 | Loop with a sunk `{i,i}`, compiled. Cap = used. `f(500)` takes the guard exit | ERRMEM | status 0, correct value, grants ≥ 1 |
| X4 | 256 KB live. Lua churn of 2000 × 64 B, headroom 4w against headroom w/2 | about 1000 arms | collections ≤ ceil(bytes/(h/2)) + 2; time ratio near/far ≤ 3, best of 3 |
| X5a/b | u-tests §5(3): arm mid-sweep (precondition: state 4 when it arms), then C-driven churn (a) and Lua churn (b) | parked, refused | no refusal, collects advance, stepmul (stat 8) ≠ 0 at rest, bailouts 0 |
| X6a/b | 510 KB total. Live leaves post-collection headroom at w+8 KB / w−16 KB, with 40 resident traces. 400 ticks of (1 KB garbage, `ARM_DISARM`) | re-arm per checkpoint; (b) flushes | collections ≤ ceil(400 KB/(h/2)) + 2, trace_flushes 0, traces_live unchanged |
| X7a | One request, then a W6b-style loop | none | after service the hook bit is clear; loop time ≤ 3× its same-run reference |
| X7b/c | `ARM(0.05)` plus a loop that crosses every iteration / a foreign `debug.sethook` | none | the deadline still fires / the crossing is refused, not granted |
| X8 | GCSTOP crossing / `newproxy` `__gc` allocating past the cap / a 1000-round ratchet | none | refused, threshold still LJ_MAX_MEM / refused, arms unchanged / used ≤ total + 33.5 KiB every round |
| X9 | Sandbox fills until refused, catches, yields; the "kernel" then does `table.pack` of 64 values | refused (down) | ok; the sandbox's next crossing is refused |

**Negative controls.** Each sabotage must fail exactly the checks listed:

| sabotage | must fail |
|---|---|
| OVER=SAND=0 | X1, X2a, X3, X9 |
| no inject | X1f |
| no park reset | X5a |
| `gc_next=0` | X4, X6 |
| flush predicate back to w | X6b |
| never unhook | X7a |
| no kernel band | X9 |

**Deliberate re-scopes:**
- M5, C3a and harness e4: "≤ total" becomes "≤ total + 33.5 KiB, refusals ≥ 1".
- M6b and C6: the control cap becomes used − 32 KiB.
- P2a–h and C5b: live is set to leave headroom under 32 KiB; P2g/h read straight after `arm()`.

**Harness gate.** The capacity matrix (bench/runs/2026-10-03-ramscale/scripts, about 87 min) runs from the main session under nohup plus Monitor.
- **Pass criteria:**
  - 0 "recovery refused" and 0 "down" across D/E/O (today 19 of 60).
  - Every run shows refusals ≥ +1.
  - odpeak ≤ 34 304 B.
  - Held medians O/S ≥ 0.95 at the 1024 KB closure cell.
  - Median `t_last5` ≤ 3× stock per cell, in the same pinned chain (today 21–121×).
  - Collections ≤ 3 per batch over the last five batches.
  - At rest: collects==arms, bailouts==0, armed false, kind 0, stat 8 == 200. The CAP-\* lines must add positions 2, 3, 5, 7, 8, 9, 15 and 16 plus `_OCLJ_GCWALL`, and must first be seen to print stepmul 0 mid-fill on today's DLL.
  - kernelMemory for D is identical across at least 3 replicates per stick and equal to E's figure, with `traces_live` 0 at the measurement. It must also hold unpinned under load.
  - CAP-IDLE at 192 KB: ≤ 63 collections over 400 ticks and 0 flushes. Boots: 12 of 12.
- **Full suite:** all arms pass, and wd_test is unchanged at 35/0.

## 5. What it does not fix

- A single C call (Java callback pushes, a library function) that needs more than headroom + 16 KiB, with only garbage to cover it and no `lj_gc_check` inside, is still refused. Neither carrier can reach inside the call.
- Requests larger than the band are refused once; the retry succeeds.
- A program that fills memory within one resume can be refused while trace metadata is still resident. Recorder buffers stay charged after a flush.
- Finalizers run earlier than on PUC, and still run with no deadline, as on stock.
- sgc's nested arm still consumes the flush flag and then refuses it under HOOK_GC.
- Not addressed: the `lj_tab_resize` hidden-keys order (shared with PUC) and mcode sitting outside the cap.
- kernelMemory becomes 164 393 B, deterministic but still below stock's 174 605 B.

**Residual divergence, in one sentence:** PUC collects and then decides, while we grant first against a 32 KiB overdraft and decide at the next instruction boundary or checkpoint, so "not enough memory" lands on the program's next allocation rather than this one, live data can exceed the cap by at most 16 KiB (32 KiB on the kernel thread), and a request needing more than headroom + 16 KiB within one instruction or C call is refused once even when garbage would have covered it.

## 6. Self-assessment

| | verdict | why |
|---|---|---|
| R1 | **PARTLY** | The contract holds within the band, including recovery and the kernel's allocations. Shrinks, immediate credit on free, and an allocation-free raise are unchanged. It is not met beyond the band (§5). |
| R2 | **PARTLY** | By construction: at most 2× stock's collection count under churn, and at most 1 extra per approach in fills. Not measured; the 3× time target needs the matrix. |
| R3 | **MET (reading)** | Every arm is settled by its proof, the park reset, or the hook/backstop within one boundary or one resume. No valve, so no false bailouts. A foreign hook plus a latch alias can keep an arm alive until the next outermost arm. |
| R4 | **PARTLY** | Deterministic and trace-free through site 13, but below stock's figure. The thrash bound is derived, not yet measured. |
| R5 | **MET** | Bound of total + 33.5 KiB, a compile-time constant, charged; Java clamps free memory to 0. Sandbox code cannot ratchet it. No new bare-frame refusal. |
| R6 | **MET (reading)** | The allocator writes scalars plus the timer's injection. Collection happens only at instruction boundaries, where `L->top` is fixed (lj_dispatch.c:420-422), execution is off-trace, recording is aborted (:372) and no finalizer is running, or inside kernel C functions guarded by HOOK_GC. That satisfies C1–C7, since no constructor, grow or sweep is in progress there. On-trace behaviour is defined. |
| R7 | **PARTLY** | Zero LuaJIT lines, and the gate is re-scoped with a fail-first. About 150 shim lines change and there is one new stats global. |
| R8 | **MET** | Nothing has to cross eris. GCSTOP is respected, GCRESTART resumes, and Int.MaxValue causes no crossings. |
| R9 | **MET (reading)** | The checkpoint carrier is unchanged far from the wall, and P1a's C-driven churn still passes. The hook costs two dispatch updates per request. |
| R10 | **MET (planned)** | X1–X9 fail-first on today's object, negative controls for each part, and the dropin covered by the legacy variants. |
| R11 | **MET** | No setting is added; `ramScaleFor64Bit` stays inherited. |

**Least-supported claims, weakest first:**
1. **The safety of collecting at an arbitrary instruction boundary.** It rests on equivalence with a checkpoint in Lua code: LuaJIT's C code anchors its objects across `lua_call`, and the watchdog's own `checkDeadline` already runs there. A Lua callback that never allocates gains a collection point it did not have before.
2. **The 16/32 KiB sizing.** It is a policy choice, not a bound the VM guarantees.
3. **The kernel band identifying the kernel thread.** It relies on `cur_L` and on the kernel being the caller of the outermost arm (machine.lua:1625).
4. **The R2 ratios.** They are derived, not measured.