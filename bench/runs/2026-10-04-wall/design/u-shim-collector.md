## Report: native/lj52shim.c memory paths (HEAD bd302f2, read-only)

Abbreviations: **S** = native/lj52shim.c, **LJ** = build/native/luajit-windows-x86_64/src. LJ lj_gc.c:720-760 is byte-identical to the pristine checkout.

### 1. lj52_alloc, both modes

**Delta and counters.** The delta is `-osize` for a free, `nsize` for a new block, and `nsize-osize` for a resize (S:354-356). With no record, the call goes straight to libc (S:358). `mem_calls++` counts every call (S:359).

**C mode** (`csync`, S:369-389). It works only when `acct = accounting && total>0` (S:370).
- **Free** (S:371-377): `lj52_gc_pressure(M,total,used+delta)` runs *before* the free, so the disarm check sees the heap after the free. It is followed by `lj52_back` and then `used += delta`.
- **Cap test** (S:378): `acct && delta>0 && !norefuse && total-used < delta`. On a refusal it does `gc_refusals++`, calls `lj52_gc_pressure(M,total,used)` and returns **NULL** (S:379-381). Shrinks are never refused.
- **Grow/shrink success** (S:383-387): `used += delta`, then `gc_pressure(M,total,used)`. A backing failure (`lj52_back` NULL) returns NULL without counting it and without calling `gc_pressure`.

**Legacy mode** (S:400-455).
- **Unbound or close** (no javaref or env): the call goes to `lj52_back`. Bytes are banked in `pending` and `used`. Nothing is refused and `gc_pressure` is not called (S:402-419).
- **Bound:** `mem_jni++` and `getmem` read Java's total and used (S:421-424). A first bound call settles `pending` (S:425-429).
- **Free:** `gc_pressure(total, used+delta)`, then the free, then `setmem` (S:430-439).
- **Refusal predicate:** `!(total<=0 || delta<=0 || total-used>=delta || norefuse)` (S:440). On a refusal: `gc_refusals++`, `gc_pressure(total,used)`, return NULL (S:445-447).
- **Success:** `setmem`, `used += delta`, `gc_pressure(total, used+delta)` (S:449-454).

**What LuaJIT does with NULL.** `lj_mem_realloc` calls `lj_err_mem` when `p==NULL && nsz>0`, before it updates `gc.total` (LJ lj_gc.c:873-879). `lj_mem_newgco` does the same (:887-889). `lj_err_mem` pushes the preallocated ERRMEM string (lj_state.c:202) and calls `lj_err_throw(L, LUA_ERRMEM)` (lj_err.c:813-832). There is no collection and no retry. PUC by contrast runs `luaC_fullgc(L,1)` and retries the allocation (lmem.c:84-93).

**New finding: a refusal can happen without an arm.** `gc_pressure` arms only when `total-used < w` (S:930-933). One request larger than the headroom, while the headroom is still at least w, is refused with no arm and no collection. Example: a 1.2 MB array when 1 MB is free on a 3 MB cap, with the rest garbage. PUC would collect and succeed. This contradicts the comment at S:441-444 ("a refusal with gc_arms == 0 ... is a bug here"). It is a second shape of problem (1).

**norefuse window.** `lj52_pushcfunction` wraps `norefuse++/--` around the raw push (S:1723-1728). That suppresses the refusal (S:378, S:440) and makes `gc_pressure` inert (S:889). See Q5.

### 2. lj52_gc_pressure (S:880-943)

**Early return** (S:889) when any of these holds: `gc_busy`, `norefuse>0`, `M->L==NULL` (during `lua_newstate`, because `M->L` is set only at S:1786), or `total<=0`.

**VM-owned states** (S:897): it returns, with no counting, under `HOOK_GC` (a finalizer) or when `threshold==LJ_MAX_MEM` (host GCSTOP). An armed record stays armed through both.

**When armed** (S:902-928):
- **Proof:** `currentwhite != gc_white && state==GCSpause` (S:903). On proof it restores stepmul *only if it is still 0* (S:904), sets `gc_armed=0` and does `collects++`. It then recomputes w and sets `gc_flush_wanted` if `total-used<w` (S:913-915).
- **Otherwise:** `++gc_armedcalls > 65536` (`LJ52_GC_ARMCAP`, S:865) triggers the bailout: restore stepmul if it is 0, disarm, `bailouts++` (S:916-924).
- **It always returns at S:927.** The call that proves a cycle never re-arms; the next call does.

**When unarmed** (S:930-941):
- **Watermark:** `w = max(total/4, 128 KB)` (S:864, S:930-931).
- **Arm:** if `total-used < w`: save stepmul, latch `currentwhite`, set `stepmul=0` and `threshold=gc.total`, then `armed=1`, `armedcalls=0`, `arms++`.

**_OCLJ_GCSTATS fields** (S:1592-1621, 20 values): arms, collects, bailouts, refusals, armed, gc.total, gc.threshold, gc.stepmul, gc.state, trace_flushes, flush_wanted, flush_refusals, flush_bytes, heap, c_total, c_used, csync, used_reads, alloc_calls, alloc_jni.

**Re-arm cadence: confirmed, with one refinement.**
1. The armed step reaches GCSpause and sets `threshold = estimate/100*pause` (LJ lj_gc.c:741-744). Pause is 200 by default (luaconf.h:93, lj_state.c:308). Stepmul is still 0 at this point.
2. The next allocator call proves the cycle and disarms (S:903-906).
3. The call after that re-arms if `used > total-w` (S:933-937).
4. The next checkpoint then runs an unbounded full cycle. The interpreter's TNEW check runs *before* the allocation (vm_x64.dasc:3800-3813). Library functions use `lj_gc_check`, and traces use `asm_gc_check`.

So for single-allocation constructs it is **one full cycle per two allocator calls** in the last quarter.

**New finding: the bailout counts the sweep's own frees.** While armed, every call goes through S:916, including the frees from the armed cycle's sweep (free path S:373/S:434). Proof needs `state==GCSpause`, which is false during the sweep. A single armed cycle that frees more than about 65,536 blocks (for example around 2.5 MB of 40-byte garbage at the top tiers) trips the valve mid-cycle. The step still finishes, because `lim` was fixed at entry (lj_gc.c:734-736). The result is a false `bailouts++`, no `collects++`, and no flush predicate for that cycle. Not observed: the ramscale logs contain 27 `bailouts=0` lines and no nonzero ones. Which runs those lines come from was not checked.

### 3. Trace flush under pressure

- **Predicate:** set only at the proof, when `total-used < w` (S:913-915), with `used` as passed by the caller (S:373/380/386/434/446/453).
- **Consumed in `lj52_wd_arm`** (S:1406) before the depth-cap check, so nested arms consume it too (S:1400-1406). The kernel calls `collectgarbage("collect")` every 10th resume (machine.lua:1617-1622) *before* `watchdog.arm` (:1625). That collect's proof only lands at the next allocator call, so it does not raise the flag for that same arm.
- **`lj52_gc_flushtraces`** (S:952-1002) does, in order:
  1. Clears the flag (S:959).
  2. Sums trace metadata by the `lj_trace_free` formula (S:965-972) and returns if that is 0 (S:973).
  3. Refuses if `HOOK_GC` is set or `luaJIT_setmode(L,0,FLUSH)!=1`, counting `flush_refusals` (S:979-981).
  4. Counts `traceflushes` and `flushbytes` (S:983-984).
  5. Re-arms with `stepmul=0` and `threshold=total`, but only if not already armed and not under GCSTOP (S:993-1001).
- **Guards it lacks:** the re-arm checks neither headroom nor `gc.state`, so it can also land mid-sweep (see Q4). It flushes all traces, kernel-init ones included. That is the mechanism behind problem (4)'s windfall. Why the windfall is bimodal is not determinable by reading.

### 4. The mid-sweep gap: the reading is right, with three corrections

**Arm while `state ∈ {GCSsweepstring, GCSsweep, GCSfinalize}`.** That cycle's `atomic()` has already flipped the white (lj_gc.c:654), so the latched white is the post-flip value. The next checkpoint runs `lj_gc_step` with `lim=LJ_MAX_MEM` (:734-736) and finishes the sweep, reaching GCSpause at :700-701 or via finalize at :718-719. The loop returns **at the first GCSpause** (:741-744) with no `gc_mark_start` and no atomic, and writes `threshold = estimate/100*pause`. That write is what resets the arm's `threshold=total`. The white is unchanged, so the record stays armed with stepmul 0.

**On trace.** In GCSfinalize, `return LJ_MAX_MEM` (:710) empties lim. The step exits at :747-753 with `threshold=total+1024` (or `=total`), and `lj_gc_step_jit` forces a trace exit (:776). The interpreter then finishes the step as above.

**Arm from inside a running step.** A sweep free (S:373), `lj_str_resize` (:697) or `lj_buf_shrink` (:649) can all reach `gc_pressure`. The arm's threshold is then overwritten by that step's tail (:742/:748/:753). `stepmul=0` survives, so it converges on the same state. An arm at :649 latches the *pre*-flip white, and the flip at :654 makes that cycle provable. That case is harmless.

**Parked when `estimate*pause/100` exceeds the largest reachable `gc.total`.** That is roughly live > cap/2, since `gc.total` tracks `used` (M3b) and `used` is capped. Nothing then crosses the threshold. The park ends only by one of:
- the 65,536-call bailout (S:916-924), shown as `bailouts>0`;
- a full collect: the kernel's every-10th-resume collect (machine.lua:1620) or a host `lua_gc(COLLECT)`, both through `lj_gc_fullgc` (:781-803);
- a host GCRESTART or GCSTEP (lj_api.c:1252, :1263-1271);
- the live set shrinking until `gc.total` can reach the threshold again.

**Correction to the results note "until a refusal"** (bench/results-ramscale-2026-10-03.md:171). A refusal does **not** unpark the collector. The refusal path only calls `gc_pressure`, which in the armed branch only counts (S:378-381 → S:916). While parked, no collection runs, the flush predicate is never evaluated, and refusals can occur with collectable garbage on the heap.

**Why sieve did not show it.** Its live set is about 52 KB, so twice the estimate is quickly reachable. The next unbounded step from GCSpause then includes atomic, which explains `collects==arms` in §8f.

### 5. Other GC touches

- **No `lua_gc` call in the shim.** It appears only in comments (S:895). build-native.sh:335-341 fails the build on `lj_gc_fullgc|lj_gc_step|luaC_|lua_gc(|LUA_GCCOLLECT|LUA_GCSTEP`. build-native.sh:311-322 asserts that the enum begins with `GCSpause` (S:878).
- **jnlua's host `lua_gc`** (jnlua.c:384-399) reaches LuaJIT directly (lj_api.c:1243-1288).
  - GCSTOP (:1249): `gc_pressure` returns early (S:897) while staying armed.
  - **GCSETSTEPMUL while armed** (:1277-1279) returns 0 as the old value and overwrites it. The disarm restores only if stepmul is still 0 (S:904/922). A host save/restore pair that straddles a disarm would write back 0, and every later step would be unbounded with nothing to restore it.
  - machine.lua calls only `collect` (its single `collectgarbage` site is :1620, so the sandbox has none). Whether OC's Java side calls setstepmul is not determinable in this tree.
- **setallocf flag.** `lj52_setallocf` installs nothing and sets only `accounting = ud!=NULL` plus the callbacks (S:525-536). jnlua's sites are at jnlua.c:295 (on), :327 and :362 (off). `lj52_close` forces `accounting=0` (S:1656). The `l_alloc_checked` swaps (jnlua.c:255-257) never run on this native.
- **pushcfunction window** (S:1723-1728). The bound is 38 GCfuncs, about 1.5 KB, with a pre-sized memo (S:1691-1694, S:1809-1814). `lua_pushcclosure` starts with `lj_gc_check` (lj_api.c:681), so an armed full cycle can run inside the window. Its frees bypass `armedcalls` and the proof (S:889), and the proof is deferred to the next call.
- **Read-only:** `lj52_gcstats` (S:1600-1603).

### 6. Claimed invariants and what pins them

| Invariant (claim site) | Pinned by |
|---|---|
| Allocator never collects; GCSpause==0 (S:745, S:867-878) | build-native.sh:311-341 (not mem_test) |
| Charges exactly; used == LuaJIT count (S:324-326) | M3, M3b, M3c, M4, M4c, C0b, C2a, C2c |
| used never negative; pending banked (S:403-417) | M2b, M4b; negative-control.sh:352 |
| Cap refuses | M5 (legacy), C3a, C4b; C3b/C4c re-admit |
| Pushcfunction window: never refused, still charged | M6a (M6b control), M7, C6; negative-control.sh:383 expects death |
| Accounting flag off: nothing refused or charged to Java | M8, C7; negative-control.sh:326 |
| Arm → proven cycle | P1a (also asserts bailouts and refusals unchanged), P2a, P2b, C5a (no bailout check) |
| Flush only at proof with headroom short; never in the allocator | P1b, P2c, C5b; P2d |
| Flush at the safe point, once; flag consumed; re-armed; used drops | P2e, P2f, P2g, P2h; P1c/P1d (no flush when unwanted) |
| C mode: no JNI after handover | C0a, C0c, C0d, C1, C2b, C8, M9 |
| Own arena | M0, M0b, M0c |
| `collects==arms`, `bailouts==0`, `armed=false` at rest (S:1554-1568) | Harness only (§8f sieve, OcljSmoke mem-2); mem_test's `settle_gc` (mem_test.c:342-349) exists because `armed` persists at rest |

**Unpinned:**
- `threshold=total` rather than 0 (the debt trap)
- the HOOK_GC and GCSTOP early returns
- `flush_refusals`
- the conditional stepmul restore
- the mid-sweep park
- the bailout counting sweep frees
- refusal without an arm
- the re-arm cadence

negative-control.sh has **no sabotage of the collector or the flush**: zero matches for `gc_pressure`, `gc_armed`, `stepmul`, `gc_flush` or `currentwhite`.