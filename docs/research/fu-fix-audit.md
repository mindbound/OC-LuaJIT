# M3 fix audit — `serializer/eris_lj.c` (md5 `e75f0f0ceb08494231bde179b1cfa580`, unchanged by me)

**Suites, from a forced clean rebuild (`gcc -O2 -Wall -Wextra`, zero warnings):
M1 82/82, M2 55/55, M3 39/39 — all pass.** (The stale `erislj_test.exe` I found was already current; I rebuilt anyway to be sure the binary matched the source.)

Verdict summary: **9 of the 12 real defects are genuinely fixed at the cause. 1 is partially fixed and the partial fix introduces a new failure mode. 1 is confirmed still outstanding and fails cleanly. 1 non-bug is correctly left alone.** The 13 reports collapse to **10 distinct defects** — see the duplicate note below.

---

## Duplicate reports (asked for)

- **#1 is one bug reported 3×** (the two extra reports are the `gc-and-memory` and `semantics-at-scale` lens copies at m3-verification.md:814 and :1177).
- **#3 and #6 are the SAME underlying bug, reported 3× in total** (#6 itself was reported 2×). The single root cause is that `u_function`'s `TAG_UPVALOPEN` slot bound read the thread's *in-flight write cursor* instead of its *declared final top*. #6's symptom was "a container at a lower register than the captured local"; #3's symptom was "a recursive `local function`"; both are the same bound. One fix (the `RThread`/`elj_live_top` mechanism) closes both, and it did.

So: 13 reports → 10 defects + 1 not-a-bug.

---

## Per-defect findings

### 1. [critical] GC shrinks the thread stack mid-restore — **FIXED, correct, at the cause**
`eris_lj.c:1305-1331`. `co->top = tvref(co->stack) + need` (:1317) is parked for the whole restore, re-asserted after every slot write (:1329), and lowered to the real top only in pass 5 (:1543). The trailing nil-fill — the *second* overflow site the reviewer found, which the report did not claim — is deleted outright.

This is **stronger than the reviewer's own recommendation** (park at `top_ofs`), and the reasoning holds: with `co->base` still at the bottom, `gc_traverse_frames` returns `used = co->top - stack = need`; after the one-shot `lj_state_cpgrowstack`, `stacksize` is at most `need + 1 + LJ_STACK_EXTRA`, so `4*used < stacksize` can never hold. For a thread small enough that no grow happens, LuaJIT's *second* guard (`2*(LJ_STACK_START+LJ_STACK_EXTRA) < stacksize`) blocks the shrink instead. Both branches are closed.

Reproduced the original failures, now passing: the review's shape (~40 frames + N-string payload, **no** `collectgarbage`, **no** `__persist`) at N=2000/8000/30000 → all round-trip, `nresults=2`/correct values (was SIGSEGV, or 4480 garbage results); the "narrow" shape (large `need`, `top_ofs`=7, the trailing-fill site) → round-trips; an explicit `collectgarbage("collect")` from inside a `__persist` hook fired mid-slot-pass → round-trips.

### 2. [critical] FR_CONT symbol not checked against its site — **FIXED, correct, at the cause**
`eris_lj.c:1465-1482`. Symbol/site consistency via `bcmode_mm(bc_op(pc[-1]))`, exactly as recommended; `pc[0]`/`pc[-1]` are both in range given the existing `1 <= bcofs < pt->sizebc` check.

Reproduced on a genuine `__index` blob: all five wrong symbols (0,2,3,4,6) now rejected with *"frame 1 continuation symbol N does not match the opcode at its continuation site"*; CS_HOOK and out-of-range rejected earlier by the record decoder. **No false rejections**: a 21-case positive sweep over every continuation-attaching metamethod (`__index` via TGETS/TGETV/TGETB/GGET, `__newindex` ×2, `__concat`, `__len`, `__unm`, `__add/sub/mul/div/mod/pow`, `__lt/__le/__eq` including negated branches, `__call`) round-trips and resumes to the correct value, 21/21.

Documented residual is real and unchanged: `CS_CONDT`↔`CS_CONDF` are still interchangeable over one comparison site. Measured — flipping `cs` 4→3 on an `__lt` blob is accepted and resumes to `"GE"` instead of `"L"`. Semantic corruption only, no memory unsafety; the suggested `(bc_op(pc[-1]) & 1)` refinement was not adopted.

### 3. [critical] recursive `local function` unloadable — **FIXED** (same fix as #6)
Verified directly: recursive `local function` (→120), forward-declared local captured before assignment (→42), and mutual recursion (→true) all round-trip and resume. Regression tests exist at `tests/m3.lua:208/220/234`.

### 4. [high] T4: `base_ofs` not pinned when the thread has no frames — **FIXED, correct**
`eris_lj.c:1347-1349`, placed exactly where recommended: after the status/nframes cross-check and **before** `co->base` is moved, so a rejected blob leaves the half-built thread inert. Reproduced: the review's resealed one-byte edit (`base_ofs` 2→3 on a never-started coroutine) is now rejected with *"thread has no frames but base is at 3, not the stack bottom (2)"*; the unmutated control still loads. (The *optional* persist-side tautology assert was not added — it was explicitly optional.)

### 5. [high] FRAME_CONT link only bounded by `>= 16` — **FIXED, correct**
`eris_lj.c:1388-1391`, verbatim the recommended bound, placed after `cs` is read and range-checked. Reproduced: link 16 and 24 both rejected with *"continuation frame link N overlaps its own continuation words"*; link 32 caught by the chain-termination check; the genuine link (40 on my specimen) accepted.

### 6. [high] `TAG_UPVALOPEN` validated against a moving `co->top` — **FIXED, correct, at the cause**
`RThread` at `:178-182`, `Info.rthreads` at `:193`, `elj_live_top` at `:1066-1072`, the bound at `:1184`, publish/unpublish at `:1276/:1318-1321/:1546`. C-stack chaining means it nests for coroutines-in-coroutines and is discarded by a longjmp, as designed.

All of the review's failing shapes now pass (container below the captured local →41; array container →42; container 3 registers below →13; the control →41). The restored upvalue genuinely **aliases**: a write through the restored closure is seen by the suspended frame (107/107), and survives a 400-deep `resizestack` plus a full GC.

Note the bound stays tight — `elj_live_top` returns the *declared* `top_ofs` (already validated `base_ofs <= top_ofs <= need`), not `need`, even though `co->top` is now parked at `need`. That interaction between the #1 and #6 fixes is handled correctly.

### 7. [high] `for ... in pairs()` cannot be persisted — **STILL OUTSTANDING, fails cleanly** (as expected)
Confirmed refused at *persist* time with a catchable Lua error, for `pairs(t)`, `next, t`, `pairs` with the yield in a callee, and nested `pairs`. In every case the coroutine is **still resumable afterwards** and a subsequent full GC is clean — so the failure mode is exactly the "loud save-time failure, state stays usable" the design asks for. Numeric `for` and `while` round-trip. Documented under README "Known gaps".

**One gap the review asked for and did not get**: the "strict minimum" honest diagnosis. The message is still *"cannot persist light userdata by value (process-local pointer); put it in the perms table"* — which for `pairs`/`next` sends an operator after a perms entry that cannot exist. Cheap to fix and worth doing even if `TAG_KEYINDEX` waits for a format bump.

### 8. [medium] F18 / `FRAME_PCALLH` — **FIXED on both sides, correct**
Persist side `eris_lj.c:829-831`, restore side `:1377-1378`. Reproduced on the restore side: mutating a genuine `FR_PCALL(6)` frame kind to `FR_PCALLH(7)` is rejected with *"FRAME_PCALLH frame with no active hook"*; the unmutated control still loads. The persist side is verified by reading only — a suspended thread carrying a PCALLH frame is not constructible from pure Lua on this build.

### 9. [medium] `elj_finduv` drops the resurrect branch — **FIXED, correct**
`eris_lj.c:676-686`; a faithful replica of `func_finduv`'s `isdead → flipwhite`, and the stale rationale comment was replaced with the correct one. Verified empirically against the review's own shape (thread first in the array, so pass 4 creates the upvalue with no referrer): **500 round-trips with heap churn, 0 wrong values** (the pristine build failed 7 of 8 runs of this), plus 200 rounds with a full `collectgarbage("collect")` between restore and use — reading the `GCupval` directly each time shows `dead=false`, `closed=false`, and a non-empty `co->openupval`, 0 bad.

### 10. [medium] `p_thread` holds `bot` across the slot loop — **FIXED** (first half only)
`eris_lj.c:772-773` re-derives both `stack` and `bot` immediately before the frame walks, as recommended. The frame walks then use `co->base`, whose *offset* `resizestack` preserves, so this is consistent.

**Not done — the same finding's second half**: `need` is still written at `:753` from the pre-loop `co->stacksize`, so a GC inside the slot loop makes it over-claim. That is now harmless for *live* threads (the restore only uses `need` to size the allocation, and `co->top = stack + need` stays inside it). It is **not** harmless for dead threads — see #11.

### 11. [medium] a thread that died by error can never be persisted — **PARTIALLY FIXED, and the partial fix is a regression in failure mode**
Present: the refusal is gone (`:715-721`), the normalization `if (co->status > LUA_YIELD) base_ofs = top_ofs = 1 + LJ_FR2;` is at `:746-748`, and both frame walks are gated on the derived base (`:777`, `:783`).

**Three of the five recommended hunks are missing**, and two of them were flagged as load-bearing:

- **Hunk 2's `need` clamp** (`dead ? 2 + LJ_FR2 : ...`) — absent at `:753`.
- **Hunk 4** (emit no open-upvalue records for a dead thread) — absent; `:841-851` walks `co->openupval` unconditionally.
- **Hunk 5** (`p_function` must not select a dead thread as an open-upvalue owner) — absent; the owner selection at `:624-635` filters on `mainthread`/`L`/`cframe` but not on `status > LUA_YIELD`.

Measured consequences on the current build:

| shape | persist | unpersist |
|---|---|---|
| error-dead holding an open upvalue | OK, 86 B | **FAILS**: `open upvalue slot 4 outside the live stack` |
| …same, reached through the escaped closure | OK, 304 B | **FAILS**, same |
| …closure alone (owner found by `elj_find_owner_any`) | OK, 298 B | **FAILS**, same |
| stack-overflow-dead | OK, 86 B | **FAILS**: `thread stack size 65541 out of range` |
| error-dead at recursion depth 5000 | OK, 86 B | loads — into a permanently inert thread with a **29184-slot (228 KB) stack** |

Before the fix these first four were refused *at persist time*. They now produce blobs that save and cannot load — the "silent write-only save data" class this project rated **high** in the M1 review. The last row is a ~2700× size amplification from an 86-byte blob, caused directly by the missing `need` clamp interacting with #10's unfixed second half. I verified with a C inspector that an error-dead thread really does still hold an open upvalue (`status=2 base_ofs=7 top_ofs=8 openuv=1 slot=4`), while a return-dead thread holds none — which is why plain error-dead threads (string/table/nil error, nil-index, error-after-yield, inside a table with a live sibling) *do* round-trip to 84 bytes and come back `dead`.

### 12. [low] `immutable` lost on a restored open upvalue — **FIXED, correct**
`eris_lj.c:1519-1528`, in pass 4, with the recommendation's warning respected (the assignment is *not* inside `elj_finduv`'s early return, so `u_function`'s hardcoded `0` cannot clobber it). Verified by reading `GCupval.immutable` directly: original `slot=5 imm=false | slot=4 imm=true` is reproduced exactly in all three orderings — closures living inside the thread's own stack, closures reachable only from outside, and the thread restored *after* the closure.

### 13. [not-a-bug] `ipairs` aux not reachable for perms — **correctly left alone**
No `eris_lj.c` change, which is right. Verified the host-side workaround end to end: adding `ipairs({})` to perms makes an `ipairs`-suspended coroutine round-trip and resume. The suggested test-side generalization (walk closure upvalues in `build_perms`) was **not** added to `tests/m3.lua`, so the suite still cannot cover `ipairs` loops.

---

## New defects introduced by the fixes

**One**: the #11 partial fix, above — the only place where the current code is worse than what the review found.

**None found elsewhere.** I ran an exhaustive hostile sweep over exactly the bytes `u_thread` validates (status, need/base/top, every frame record, every open-upvalue record), every value 0–255, across five thread shapes: **13,160 loads, zero crashes**, 1,120 accepted. Every accepted mutation is benign — `need` over-claim, the `immutable` byte, the status byte of a frameless thread, and kind swaps between structurally equivalent frames (semantic corruption, resumes without faulting).

One clarification on a crash I did hit: a *full-body* single-byte sweep does segfault, but the offending byte is the **last byte of the FUNC bytecode dump** (dump spans body offsets 78–318 of a 379-byte body; the crash is at 318). That is inside the module's own conceded boundary — "blobs contain LuaJIT bytecode, which the VM does NOT verify". It is pre-existing and not attributable to these fixes, but it does contradict the header's *other*, unconditional sentence ("every wire byte that indexes anything is range-checked … so a malformed blob raises a catchable Lua error rather than crashing"). That sentence should be qualified to exclude the dump payload; the review already noticed the same tension in defect #2's scope note.

## Fixes that address symptom rather than cause

None. Every fix I checked attacks the mechanism: #1 removes the shrink precondition rather than re-checking bounds; #2 validates symbol-vs-site rather than widening the enum; #3/#6 replace the wrong bound with the right one; #9 restores the exact upstream branch. #11 is not a symptom fix — it is an *incomplete* cause fix.

## Test coverage gaps

`tests/m3.lua` has **no hostile-blob section at all** (`m1.lua` and `m2.lua` both do; grep for `seal`/`crc32`/`patch` in m3 returns 0). The six added regressions all cover the #3/#6 class and the #1 deep-coroutine class. **Defects 2, 4, 5, 8, 11 and 12 got no regression test**, despite the review supplying a ready-made reproducer for each. There is also no error-dead round-trip case and no `pairs()`-refusal case, which is how #11 and #7 slipped through in the first place.

## Minor observation, low confidence

In the 21-case positive sweep (one process, JIT on), the `__call` case at position 21 showed a live `FR_CONT` frame with `cs = 6` (`CS_STITCH`), which the new `mm == MM_call` rule accepted and which round-tripped correctly to `"CALLED"`. A cold single-case run of the same shape has no CONT frame at all (verified against the VM's own frame chain, and all seven `lj_cont_*` addresses are distinct). The likely explanation is JIT trace stitching after ~20 warm cases — which would mean `CS_STITCH` is reachable in practice, contrary to the review's "derived from `recff_stitch` rather than exercised". Worth one confirming probe before anyone relies on it either way.

## Housekeeping

Working tree left exactly as found: `serializer/eris_lj.c` md5 `e75f0f0ceb08494231bde179b1cfa580` (identical to session start), `git status` identical to session start. No repo file was written. `erislj_test.exe` was rebuilt from the unmodified source. All probe binaries deleted. Probe sources remain at `C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\aud\` — notably `a_errdead.lua` (defect 11), `b_pairs.lua` (7, 13), `c_upv.lua` (1, 3, 6), `d_hostile.lua` (2, 4, 5, 8), `e_uvbits.lua` (9, 12), `h_fields.lua` (the 13k-load field sweep), `m_positive.lua` (the 21-case positive sweep), `walk.lua` (a Lua reader for the v1 wire format, cross-validated against the VM's frame chain on six shapes), and `uvlens.c` (the C inspector harness).


# KEY CLAIMS
- [high] 9 of the 12 real defects are fixed at the cause and verified by reproducing the original failure: #1 (GC/shrinkstack), #2 (FR_CONT symbol), #3+#6 (open-upvalue slot bound, one bug), #4 (base_ofs pinning), #5 (CONT link overlap), #8 (F18/PCALLH), #9 (finduv resurrect), #10 first half (bot re-derived), #12 (immutable bit).
- [high] Defect 11 (error-dead threads) is only partially fixed, and the partial fix is a regression in failure mode: three of five recommended hunks are missing (the `need` clamp at eris_lj.c:753, suppressing open-upvalue records for a dead thread at :841-851, and the dead-owner filter in p_function at :624-635). An error-dead thread holding an open upvalue, and a stack-overflow-dead thread, now persist into blobs that cannot be loaded — where before they were refused loudly at persist time.
- [high] Defect 7 (pairs/for-in) is confirmed still outstanding and fails cleanly at persist time, leaving the coroutine resumable and the heap sound — but the review's fallback ask was not done: the error text still says 'put it in the perms table', which for pairs/next points an operator at a perms entry that cannot exist.
- [high] No new defect was introduced by the #1/#2/#3/#5/#6 fixes: an exhaustive sweep of every byte u_thread validates, all 256 values, across five thread shapes (13,160 hostile loads) produced zero crashes, and a 21-case positive sweep over every continuation-attaching metamethod produced zero false rejections.
- [high] tests/m3.lua has no hostile-blob section at all, and defects 2, 4, 5, 8, 11 and 12 received no regression test despite the review supplying a reproducer for each; the six tests added cover only the #3/#6 and #1 classes.

## VERIFICATION
CLAIM: 9 of the 12 real defects are fixed at the cause and verified by reproducing the original failure: #1 (GC/shrinkstack), #2 (FR_CONT symbol), #3+#6 (open-upvalue slot bound, one bug), #4 (base_ofs pinning), #5 (CONT link overlap), #8 (F18/PCALLH), #9 (finduv resurrect), #10 first half (bot re-derived), #12 (immutable bit).
VERDICT: confirmed
EVIDENCE: METHOD: I never edited C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c. I copied it to a scratchpad and generated one-defect-at-a-time "pre-fix" variants (rev1/rev2/rev4/rev5/rev9/rev10/rev12/rev36/rev136), built each against the pinned libluajit_stock.a, and A/B'd against the shipped erislj_test.exe on identical input. Baseline first: m1=82, m2=55, m3=39 all pass.

TRAP FOUND FIRST: a naive 3500-mutation byte fuzz rejected 3500/3500 -- every mutation was eaten by the CRC32 at eris_lj.c:1835 and never reached a validator. All tamper results below re-seal the crc32 (nibble table at eris_lj.c:203, verified by reimplementing it in Lua and asserting equality with the C output).

REPRODUCED THE ORIGINAL FAILURE (5 of 9, counting #3+#6 as one bug):

#1 GC/shrinkstack -- reverted (co->top tracks the write cursor instead of parked at stack+need): SIGSEGV on trial 1 at DEPTH=120 and DEPTH=200. Stock survives 40 trials at every depth. Mechanism confirmed in the pinned LuaJIT: prototype/watchdog/luajit/src/lj_gc.c:320 calls lj_state_shrinkstack(th, gc_traverse_frames(g,th)), and gc_traverse_frames (lj_gc.c:292-306) returns top-bot with top seeded from th->top, so parking top at stack+need makes 4*used < stacksize impossible.

#2 FR_CONT symbol -- reverted (opcode cross-check removed): SIGSEGV on my tampered blob. Stock rejects every wrong-but-in-range symbol with "frame 1 continuation symbol N does not match the opcode at its continuation site" (cs 0,2,3,4,6), CS_HOOK separately, and 7/200 as out of range.

#3+#6 open-upvalue slot bound -- a faithful revert requires reverting #1 too (with top parked, the old co->top bound is merely looser, not tighter). rev136 fails tests/m3.lua:206 with exactly the original error: "eris-lj: open upvalue slot 4 outside the thread's live stack". Stock passes. Fix is elj_live_top()/RThread at eris_lj.c:1066-1072 and 1184.

#4 base_ofs pin -- reverted (persist-side normalisation + restore-side pin both removed): SIGSEGV during forced GC after loading an unstarted coroutine with base_ofs=3. Stock rejects with "thread has no frames but base is at 3, not the stack bottom (2)". Mechanism confirmed: gc_traverse_frames walks th->base-1 downward unconditionally.

#12 immutable bit -- not observable from Lua, so I added an eris.uvbits(co) C accessor to both a fixed and a rev12 build. Fixed: ORIGINAL slot4=1 slot5=0 -> RESTORED slot4=1 slot5=0. rev12: RESTORED slot4=0 -- bit lost. Real semantics, not cosmetic: lj_func.c:148/174 sets it from PROTO_UV_IMMUTABLE and lj_record.c:1762 constifies on it.

GUARD OBSERVED FIRING, BUT ABSENCE DID NOT CRASH (2):
#5 CONT link overlap -- with a compensating outer link so the chain still descends and terminates, stock rejects links 16 and 24 with "continuation frame link N overlaps its own continuation words" (it is the first check to fire). rev5 rejects the same blobs later via "frame names a non-Lua caller". I could not build a shape where removing the bound produces a crash.
#8 F18/PCALLH -- restore-side guard observed firing ("FRAME_PCALLH frame with no active hook") when a frame kind byte is flipped to 7. Both sides present (eris_lj.c:829 persist, :1377 restore). I did not construct a real PCALLH frame (needs a native C hook).

SOURCE-VERIFIED ONLY (2): #9 elj_finduv resurrect (eris_lj.c:684, isdead/flipwhite, faithful to func_finduv) -- rev9 survived NUV=40/TRIALS=40 under an eager collector. #10 first half, bot re-derived from the live co->stack after the slot pass (eris_lj.c:772-773) -- rev10 survived DEEP=300 and DEEP=800.

Zero of the 9 turned out to be unfixed, mis-fixed, or band-aided.
CORRECTION: The claim's first half ("fixed at the cause") is fully supported -- all 9 fixes sit at the causal site and I proved 5 of them load-bearing by reverting them and reproducing the exact original crash/failure. But the second half, "verified by reproducing the original failure", is not durably true of the repo: the committed suite does not reproduce 8 of the 9. All 39 tests in serializer/tests/m3.lua still pass with each of #1, #2, #4, #5, #9, #10 and #12 individually reverted; only #3/#6 is genuinely caught (m3.lua:206). Most concretely, the "40-frame coroutine with a payload" test added specifically to reach the stack-shrink guard for #1 is about 3x too shallow -- the #1-reverted build survives depth 40, 50, 60, 80 and 100, and only segfaults at 120 and 200. Recommend either deepening that test past ~120 frames or dropping the README's claim that it reaches the guard, and adding re-sealed-blob tamper tests for #2/#4/#5 (the format's CRC32 means naive corruption tests are inert -- a tamper test that does not recompute the checksum verifies nothing). Separately: my sweep did find a real SIGSEGV from a single byte at offset 320, but that lands in the dumped bytecode region, i.e. the project's already-conceded unverified-bytecode boundary, not one of the 12 defects.

## VERIFICATION
CLAIM: Defect 11 (error-dead threads) is only partially fixed, and the partial fix is a regression in failure mode: three of five recommended hunks are missing (the `need` clamp at eris_lj.c:753, suppressing open-upvalue records for a dead thread at :841-851, and the dead-owner filter in p_function at :624-635). An error-dead thread holding an open upvalue, and a stack-overflow-dead thread, now persist into blobs that cannot be loaded — where before they were refused loudly at persist time.
VERDICT: confirmed
EVIDENCE: CONFIRMED on both halves — the three named hunks are absent, and both named shapes now save-then-fail-to-load where the pre-fix predicate would have refused them at persist time.

== 1. Source: exactly 2 of the 5 recommended hunks are applied ==
(C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c, built binary fresh: eris_lj.c mtime 18:57:21, erislj_test.exe 18:57:22; `make CC=gcc` = "Nothing to be done")

APPLIED
- Hunk 1 (drop the `base == top` refusal): check_persistable_thread at :705-721 has no status check at all, only a comment ("its stack is normalised to empty on the wire (see p_thread), so there is nothing further to refuse here").
- Hunk 3 (frame walks must not start from the live base): applied in equivalent form via `co->status <= LUA_YIELD` at :777 (count loop) and :783 (`for (f = (co->status <= LUA_YIELD ? co->base - 1 : bot); f > bot; )`). Since the derived base_ofs is 1+LJ_FR2, `stack + base_ofs - 1 == bot`, so this is the recommendation, differently spelled. Not a defect.

MISSING (line numbers as claimed)
- :746-748 sets `base_ofs = top_ofs = 1 + LJ_FR2` for `co->status > LUA_YIELD`, but :753 writes `w_uleb(I, (uint64_t)(co->stacksize - 1 - LJ_STACK_EXTRA));` unconditionally — the `dead ? 2 + LJ_FR2 : ...` clamp is not there.
- :843-846 counts and writes open upvalues unconditionally: `uint32_t nuv = 0; for (o = gcref(co->openupval); o; o = gcref(o->uv.nextgc)) nuv++; w_uleb(I, (uint64_t)nuv); for (o = gcref(co->openupval); ...)` — no `if (!dead)` suppression.
- :624-636 in p_function selects the owner (`uv->closed ? NULL : elj_owner_of_open_uv`, then the elj_find_owner_any fallback filtered only on `any != mainthread && any != L && any->cframe == NULL`) and goes straight to `if (owner != NULL) { w_byte(I, TAG_UPVALOPEN); ... }`. No `if (owner != NULL && owner->status > LUA_YIELD) owner = NULL;` anywhere in the file (grep for `status > LUA_YIELD` returns exactly one hit, :746).

== 2. Probe: the blobs are written and cannot be read back ==
Lua probe run against the current build (scratchpad/d11.lua, ./erislj_test.exe):

  === A. error-dead thread holding an OPEN upvalue ===   (yield, then error("boom-with-live-upvalue"); getter() still returns 99)
  A1 dead thread alone                        save OK (86 bytes),  LOAD FAILED: eris-lj: open upvalue slot 4 outside the live stack
  A2 dead thread in a table                   save OK (93 bytes),  LOAD FAILED: (same)
  A3 closure over the dead thread's upvalue   save OK (262 bytes), LOAD FAILED: (same)
  A4 both closures (shared upvalue)           save OK (452 bytes), LOAD FAILED: (same)
  A5 OC-shaped { processes = { crashed } }    save OK (112 bytes), LOAD FAILED: (same)
  === B. control: error-dead, NO open upvalue ===
  B1 error(string)-dead   save OK (84 bytes), LOAD OK
  B2 error(table)-dead    save OK (84 bytes), LOAD OK
  === C. stack-overflow-dead ===
  C1 no GC                save OK (86 bytes), LOAD FAILED: eris-lj: thread stack size 65541 out of range
  C2 after full GC        save OK (86 bytes), LOAD FAILED: (same)
  === D. control ===
  D1 return-dead          save OK (84 bytes), LOAD OK

A3 is the sharpest form of the reachability point: no thread reference is needed in the save set at all — persisting only the escaped closure is enough, because p_function still picks the dead thread as the open upvalue's owner (TAG_UPVALOPEN, slot 4) and u_function's `slot >= elj_live_top(I, owner)` check at :1184 rejects it against the restored top_ofs of 2. A1/A2/A5 die in u_thread pass 4 (`slot >= top_ofs`, :1512-1514). C dies in the header check at :1281-1283 (`need >= LUAI_MAXSTACK`), need = 65550-1-8 = 65541 — the exact figure the review predicted for the missing clamp.

== 3. The "regression in failure mode" half ==
C probe (scratchpad/d11probe.c, linked against prototype/watchdog/libluajit_stock.a, now deleted) measuring the raw lua_State for each shape, i.e. evaluating the pre-fix predicate `status > LUA_YIELD && !(base == top)`:

  A  error+open-upvalue  status=2 base_ofs=7 top_ofs=8   base==top? NO  -> PRE-FIX: REFUSE
  A' same, after GC      status=2 base_ofs=7 top_ofs=8   base==top? NO  -> PRE-FIX: REFUSE
  C  stack-overflow      status=2 base_ofs=65494 top_ofs=65498 stacksize=65550 need=65541 -> PRE-FIX: REFUSE
  C' same, after GC      identical                                        -> PRE-FIX: REFUSE
  B  error(string)       status=2 base_ofs=6 top_ofs=7   NO   -> PRE-FIX: REFUSE  (now loads fine — genuine improvement)
  B  error(table)        status=2 base_ofs=6 top_ofs=6   YES  -> PRE-FIX: ALLOW   (was the old save-then-fail hole; now loads fine)
  D  return-dead         status=0 base_ofs=2 top_ofs=2   YES  -> PRE-FIX: ALLOW

So both shapes the claim names (A and C) sat on the refusing side of the old guard and are on the accepting side now, with the load failing instead. That is the regression in failure mode, exactly as stated. Note the fix is a net improvement for the shapes with no open upvalue and a normal stack (B, the common case) — it is only A and C that moved from loud-at-save to broken-at-load.

== 4. Why it slipped through ==
tests/m1.lua 82/82, tests/m2.lua 55/55, tests/m3.lua 39/39 all still pass. serializer/tests/m3.lua's only dead-thread case is at :292-300 and is return-dead (`function() return "done" end`); there is no error-dead round trip in the suite, which is the coverage gap the review's own follow-up note asked for.

Working tree left exactly as found (git status identical to the session-start snapshot); probe binary deleted; eris_lj.c untouched.
CORRECTION: No correction to the substance. Two refinements of wording. (a) The claim calls the three hunks "missing" and says two are present; hunk 3 (the frame walks) is present in an equivalent but textually different form — `co->status <= LUA_YIELD` guards at :777/:783 rather than a derived `stack + base_ofs - 1` — so a reader diffing against the review's patch text should not flag it as a fourth gap. (b) "silent write-only save data" is accurate about the outcome but the failure is not silent at load time: it raises a specific, well-worded error ("open upvalue slot 4 outside the live stack" / "thread stack size 65541 out of range"). The harm is that it is raised at restore, after the save already succeeded, rather than at save. Also worth recording alongside the claim: the same change is a genuine net win for error-dead threads with no open upvalues and a normal-sized stack, which previously were either refused (error(string), base != top) or written-and-unloadable (error(table), base == top) and now round-trip correctly to 84 bytes — so the correct framing is "the fix regressed two shapes while fixing the rest", not "the fix made things worse overall".

## VERIFICATION
CLAIM: Defect 7 (pairs/for-in) is confirmed still outstanding and fails cleanly at persist time, leaving the coroutine resumable and the heap sound — but the review's fallback ask was not done: the error text still says 'put it in the perms table', which for pairs/next points an operator at a perms entry that cannot exist.
VERDICT: confirmed
EVIDENCE: CONFIRMED, and the second half is stronger than claimed: the misleading advice is unactionable not just from Lua but through any public C API too.

== 1. The fallback ask was not done (source) ==
C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c, grep for KEYINDEX/lj_tab_keyindex/TAG_KEYINDEX/"for-in"/lightud: the ONLY hits are line 911 (the generic light-userdata refusal) and line 1450 (BC_ITERN in the return-opcode whitelist). No TAG_KEYINDEX, no lj_tab.h include, no LJ_KEYINDEX discrimination anywhere. The arm is verbatim as the review found it (eris_lj.c:909-913):
    case LUA_TLIGHTUSERDATA:
      luaL_error(I->L, "eris-lj: cannot persist light userdata by value "
                       "(process-local pointer); put it in the perms table");
File sha256 263265f5...8fc001, unchanged from session start; all three suites still green (m1 82, m2 55, m3 39).

== 2. Defect 7 still outstanding, and it is exactly the ITERN control slot (my C probe) ==
Probe: scratchpad/adv/keyprobe.c, compiled against serializer/eris_lj.c + prototype/watchdog/libluajit_stock.a (binary deleted after the run). Coroutine suspended in `for k,v in pairs(t)`:
  LJ_FR2=1 LJ_GC64=1 status=1 base_ofs=12 top_ofs=12
  slot  7  raw=0xfffe7fff00000001  itype=0xfffffffc(LJ_TLIGHTUD)  u32.hi=0xfffe7fff == LJ_KEYINDEX  lightudV=NULL
p_thread pushes slots [1+LJ_FR2, top) through the generic persist(), so slot 7 lands in persist_typed's LUA_TLIGHTUSERDATA arm.

== 3. The named perms entry genuinely cannot exist — even for a C host ==
Same probe, three attempts:
  [1] stock (pairs and next both already in the flattened-_G perms)  -> FAIL "put it in the perms table"
  [2] the advice taken literally through the public C API: the slot's lightud pointer is NULL (GC64 lightud segment = 255 -> lightudV returns NULL), so `lua_pushlightuserdata(L, NULL)` is the only key the API can produce for it. P[lightud NULL] reads back as "KEYIDX", i.e. the entry is really there -> persist STILL FAILS with the same message. The canonical NULL lightud is 0xFFFE000000000000, never 0xfffe7fff|idx.
  [3] hand-injecting the raw TValue into the perms table's node with lj_tab_set (reachable from no public API, Lua or C) -> persist OK, 880 bytes, unpersist OK, restored coroutine resumes "kb kc kd 10" and survives a full GC.
So the only key that works is one nothing but a raw-node poke can create. Lua-side confirmation (scratchpad/adv/d7.lua): the only userdata reachable from _G are io.stdin/stdout/stderr (full userdata), newproxy returns full userdata, ffi.cast gives cdata — no lightuserdata constructor exists.

Contrast, measured, showing the message is wrong specifically for pairs/next: the adjacent `ipairs` failure ("cannot persist a C function by value; put it in the perms table") IS actionable — `local aux = ipairs({}); P[aux]="ipairs_aux"` makes the same coroutine persist (446 bytes) and resume correctly (2, 3, 6).

== 4. The failure is clean and the heap is sound (probe) ==
scratchpad/adv/d7.lua: pairs / next / pairs-with-callee-yield / nested-pairs all fail with the identical light-userdata message; manually split `local f,s,c = pairs(t)` (502 B) and numeric for (395 B) persist fine. After 200 consecutive failed persists interleaved with collectgarbage("collect") and allocation churn, the coroutine drained to completion: 11 further yields, 0 duplicate keys, returned total 78 (expected 78), GC clean afterwards, and an unrelated persist/unpersist still worked.
scratchpad/adv/d7b.lua adds the JIT case (jit.status()==true, 350 resumes of a 400-key pairs loop, plus a hot pairs loop yielding in a callee): both still fail cleanly with the same message — no silent success with a bogus control slot — and the original drained to the correct 80200 over all 400 keys.

== 5. Known-gap status is honest, as the claim says ==
serializer/README.md:187-197 documents the gap under "Known gaps", including "Both fail with a clean error and leave the state usable", and the review table at :233 lists it. tests/m3.lua has no pairs-in-a-coroutine case at all (every `pairs`/`ipairs` in it is in build_perms/roundtrip/the failure printer), which is why 39/39 hides it.
CORRECTION: No correction to the claim — but two additions worth carrying forward. (a) The claim understates the problem: the perms entry is unconstructible through the public C API as well, not merely from Lua. Under GC64 the control slot's lightud pointer decodes to NULL (segment 255), so a host following the message can only ever insert `lua_pushlightuserdata(L, NULL)`, which does not match the raw 0xfffe7fff|idx TValue — I inserted it and persist still failed. Only a raw lj_tab_set poke works. So the suggested fallback text ("no perms entry can help") is accurate and should be worded to cover hosts, not just script authors. (b) Separately, the README's own wording for the sibling case is wrong: serializer/README.md:191-192 says `ipairs` "leaves a hidden aux C function that no perms table can name", but `ipairs({})` names it and adding it to perms makes the same coroutine persist (446 B) and restore correctly. That half of the known-gap bullet is host-fixable today and should be corrected — the diagnostic for the ipairs path is fine; only the pairs/next one misleads.

