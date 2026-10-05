# The unwinder crash: root cause (investigator, 2026-10-05)

The harness blocks writing report `.md` files; the parent reads my text output. Here is the complete finding (the `report.md` content, since the file write is disallowed), followed by the ≤300-word summary.

---

## Root cause of the exit-139 unwinder crash

**Verdict: the synthesis's lead is THE cause** (not a contributor, not wrong), proven by reading `L` at the fault.

**Fault.** `EXCEPTION_ACCESS_VIOLATION` (read, reported target `0xffffffffffffffff` = a non-canonical `#GP`, not a literal −1). Faulting instruction `err_unwind+0x110`: `movzbl -0x3(%rdx),%edx` — i.e. `bc_a(frame_pc(f)[-1])` in the `FRAME_LUA` case (`lj_err.c:129`, `lj_frame.h:108`). Stack: `err_unwind ← lj_err_unwind_win+0x9f (lj_err.c:279) ← RaiseException ← lj_err_throw+0x3a (lj_err.c:774/389) ← lj_err_mem+0x88 (lj_err.c:831) ← lj_mem_realloc (shim returned NULL) ← lj_str_new ← lj_strfmt_num ← lj_ff_tostring (vm_x64.dasc:1370/1385) ← lj_ff_coroutine_resume ← lua_pcall ← main`.

**Mechanism (confirmed by the VEH's `L` dump).** At the fault `L->top == L->base`, so before `setstrV(L, L->top++, ERRMEM)` the stale top was `base-1`; the frame slot being walked `rax == base-8 == top-1`; `*frame == 0xfffd8…3470 == GCstr_ptr | (LJ_TSTR<<47)` (`LJ_TSTR=~4u`, `lj_obj.h:264`) — exactly the ERRMEM string. `ff_tostring`'s inline number path sets only `L->base` ("Add frame since C call can throw", `vm_x64.dasc:1385`) and **omits `L->top`**, unlike `fff_fallback` (`:2198`) and `fff_gcstep` (`:2248`) which do set it. On the refusal, `lj_err_mem` skips its top-refresh because `curr_funcisL` is false for a fast function (`lj_err.c:823-830`), so the message is pushed onto the frame-info slot `L->base-1`; `err_unwind` reads its low 3 bits as `FRAME_LUA` and dereferences the NaN-boxed value as a PC → `#GP`.

**Why stage C is rare (1/4096) and verdict frequent (17–43%):** common to all crashing refusals is a refusal of the small result string inside the *interpreted* `tostring(number)` fast function while `L->top == L->base-1`. Verdict refuses right at `tostring`; stage C reaches that site rarely. **JIT-on is required to reach it** (control census: JIT-off 0/256, JIT-on 43/128) — and OC always runs JIT-on.

**Reproduction.** Layout-probabilistic (ASLR flips it; gdb masks it; shipped binary now 0/40 at off 9488). Captured in-process with a vectored exception handler + a symbol-matched single-TU `lj_err.o` override, using the verdict shim (`j2s/obj/verdict.o`) over the stage-C `libluajit.a` — identical code path/backtrace to stage C. Control: 59 crashes/256 caps; 20/20 at a fixed offset.

**Fix (smallest).** One `else if` in `lj_err_mem`, after the `curr_funcisL` block — clamp a stale sub-base top up to base so the message never lands on `L->base-1`:
```c
} else if (LJ_UNLIKELY(L->top < L->base)) {
    L->top = L->base;   /* fast function left top stale below the frame */
}
```
`err_unwind` never reads slots ≥ base, and `unwindstack` still delivers `L->top-1`, so the error becomes a clean `LUA_ERRMEM`. A shim-only fix is impossible (it can't know the VM is in `tostring`; "never refuse" defeats the cap). Patch as a review artifact in `native/luajit` style: `scratchpad/wall2/crash/patch-fastfunc-errmem-top.sh` (anchored, idempotent, reproduces the edit exactly). **Tests:** control 59/256 → fix **0/256 + 0/1536** more; patch-produced object 0/256; fixed stdout `status=0 term=1`.

**Reachability.** Reachable by ordinary sandbox code: `tostring`/`print`/`string.format` of a *number* near the RAM cap, JIT on. A SIGSEGV is the whole JVM (machine.lua's `coroutine.resume` is unprotected, `patch-machine-lua.lua:278-282`). Probability per refusal is low but nonzero and design-dependent (stage C ~1/4096 caps; verdict ~1 in 2–6). The patch makes it 0 regardless of refusal placement.

Artifacts in `scratchpad/wall2/crash/`: `veh.c`, `ljr_verdict_{ctrl,fix,patched,veh}.exe`, `crash_capture.txt`, `ljfix/lj_err*.c|.o`, `patch-fastfunc-errmem-top.sh`, `census_cmp.txt`, `stageC_result.txt`.

---

### Summary (≤300 words)

Root cause confirmed: the lead is THE cause. The exit-139 segfault is a latent LuaJIT bug, not a shim bug. In `ff_tostring`'s interpreted number path (`vm_x64.dasc:1385`) LuaJIT sets `L->base` but not `L->top` before calling `lj_strfmt_num`; `fff_fallback`/`fff_gcstep` (`:2198`/`:2248`) set both. When the shim refuses the result-string allocation (`lj_mem_realloc`→NULL→`lj_err_mem`), `curr_funcisL` is false for the fast function so `lj_err_mem` skips its top-refresh (`lj_err.c:823-830`) and pushes the ERRMEM string at the stale `L->top` (`:831`). On the crashing trajectory that top is `L->base-1`, so the NaN-boxed GCstr lands on the frame-info slot; `err_unwind` (`lj_err.c:109`) reads its low 3 bits as `FRAME_LUA` (`:129`) and dereferences it as a PC (`bc_a(frame_pc(f)[-1])`, `lj_frame.h:108`) → non-canonical `#GP`. Proven by reading `L` at the fault: `top==base`, frame slot `== base-1 == top-1`, `*slot == GCstr|(LJ_TSTR<<47)`.

The crash is ASLR-probabilistic (gdb masks it; the shipped binary now gives 0/40). I captured it in-process via a vectored exception handler plus a symbol-matched `lj_err.o` override, using the verdict shim (identical backtrace to stage C): control 59/256 caps crash. JIT-on is required (JIT-off 0/256, JIT-on 43/128); OC runs JIT-on.

Fix (smallest): one `else if` in `lj_err_mem` clamping a stale sub-base `L->top` up to `L->base`. Result: control 59/256 → fixed 0/256 and 0/1536 more; clean `LUA_ERRMEM` delivered. Patch (review artifact, not applied): `scratchpad/wall2/crash/patch-fastfunc-errmem-top.sh`.

Reachability: ordinary sandbox code doing `tostring`/`print`/`format` of a number near the cap, JIT on, kills the whole JVM (unprotected `coroutine.resume`). Probability per refusal low but nonzero on stage C (~1/4096 caps), design-amplifiable; the patch makes it zero.