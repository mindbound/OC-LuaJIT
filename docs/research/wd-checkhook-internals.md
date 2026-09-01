## How `LUAJIT_ENABLE_CHECKHOOK` works and what an async-injected hook does (LuaJIT v2.1, source-level)

All local file paths below are under `C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\`.

---

### (1) Where `#ifdef LUAJIT_ENABLE_CHECKHOOK` is and what it emits

There are exactly **two** `#ifdef LUAJIT_ENABLE_CHECKHOOK` regions in the code, both in `lj_record.c`, and only **one of them emits code**:

**A. The emission site — `lj_record_setup()`, `lj_record.c:2953-2973`.** This runs once at the **start of recording every root and side trace** (it is the last thing `lj_record_setup` does, after `rec_setup_root`/`lj_snap_replay`). It emits three IR instructions:

```c
TRef tr = emitir(IRT(IR_XLOAD, IRT_U8),
                 lj_ir_kptr(J, &J2G(J)->hookmask), IRXLOAD_VOLATILE);   // load g->hookmask (1 byte)
tr = emitir(IRTI(IR_BAND), tr, lj_ir_kint(J, (LUA_MASKLINE|LUA_MASKCOUNT))); // & 0x0C
emitir(IRTGI(IR_EQ), tr, lj_ir_kint(J, 0));                            // GUARD: must == 0
```

The author's own comment (lj_record.c:2954-2966) states the intent verbatim: *"Regularly check for instruction/line hooks from compiled code and exit to the interpreter if the hooks are set... disabled by default, since the hook checks may be quite expensive in tight loops... Use this only if you want to asynchronously interrupt the execution. You can set the instruction hook via lua_sethook() with a count of 1 from a signal handler or another native thread."*

- **What it tests:** `g->hookmask` (the `global_State.hookmask` byte, `lj_obj.h:641`), masked with `LUA_MASKLINE|LUA_MASKCOUNT` (= `4|8` = `0x0C`). It does **not** read `hookcount`; a count of 1 matters only after the exit, in the interpreter. `HOOK_ACTIVE`/`HOOK_VMEVENT`/`HOOK_GC`/`HOOK_PROFILE` (the high bits, `lj_obj.h:676-680`) are deliberately masked out, so only real instruction/line hooks trigger the exit.
- **Where in the IR it lands / where the check ends up in machine code:** it is emitted at the very top of the trace (the first 3 IR refs after `REF_FIRST`). Because the `XLOAD` is flagged `IRXLOAD_VOLATILE`, the load/store-forwarding optimizer **refuses to CSE or hoist it** — `lj_opt_mem.c:856-857` sends any `IRXLOAD_VOLATILE` straight to `doemit` instead of forwarding. Consequently the loop optimizer's copy-substitution pass (`lj_opt_loop.c:34-77`, "copy-substitution... re-emitted to the compiler pipeline") re-emits the check into the **loop body**, so the guard is re-evaluated at the loop back-edge on **every iteration**, not just at trace entry. This is confirmed empirically by the FreeLists disassembly in (2). It is emitted at function-head/trace-head level (per trace), and by virtue of being loop-variant it survives into each iteration.
- **The `IR_EQ` is a guard (`IRTGI` = typed guarded int).** When the tested value is non-zero (a hook has been armed), the guard **fails**, which triggers a normal **trace exit**: the guard branches to the trace's exit stub → `vm_exit_handler` (`vm_x64.dasc:2449`) → `lj_trace_exit` (`lj_trace.c:~900`) reconstructs interpreter state from the snapshot → `vm_exit_interp` (`vm_x64.dasc:2499`) resumes the interpreter. The interpreter then re-dispatches the next bytecode through the **dynamic** dispatch table (`vm_x64.dasc:2554`, `jmp aword [DISPATCH+OP*8]`), which `lua_sethook`→`lj_dispatch_update` has already repointed to `lj_vm_inshook`/`lj_dispatch_ins`, so the count hook fires.

**B. The non-emitting site — `rec_itern()`, `lj_record.c:691-693`.** This only bumps a reference-count threshold: `IRRef ref = REF_FIRST + LJ_HASPROFILE; #ifdef LUAJIT_ENABLE_CHECKHOOK ref += 3; #endif`. It accounts for the 3 extra IR instructions when deciding whether a `pairs()`/`ITERN` loop body is "empty" (`J->cur.nins > ref`). No code is emitted here.

No other functional `#ifdef LUAJIT_ENABLE_CHECKHOOK` exists in the VM (`vm_x64.dasc`'s `vm_inshook`/`vm_record`/`vm_rethook` hook paths at lines 2266-2314 are the interpreter's normal hook machinery, independent of CHECKHOOK).

---

### (2) Per-iteration overhead in a tight compiled loop

**The emitted x86-64 is a single fused test + branch.** The three IR instructions (`XLOAD`, `BAND` with 0x0C, guarded `EQ 0`) fold into one `test byte [mem], imm8` plus a conditional jump to the exit — the assembler fuses `XLOAD`+`BAND`+`EQ` into a memory-operand `test` (`lj_asm.c` dispatches `IR_BAND`→`asm_band`, `IR_XLOAD`→`asm_xload`, comparison→`asm_comp`; the fold engine collapses the constant AND-vs-zero into `test`).

Two independent sources give the exact code and a measured number:

- **The FreeLists report (Myria, 2022-06-01) shows the disassembly directly:** `test byte ptr [rbx-0EEFh],0Ch` / `jne <exit>` — where `[rbx-0xEEF]` is `global_State::hookmask` and `0x0C` is `LUA_MASKLINE|LUA_MASKCOUNT`. That is **two instructions** (one memory load fused into `test`, one predicted-not-taken branch) per loop back-edge.
- **The Tarantool discussion (#5778)** quotes the same emitted pair (`test byte [r14-0xeaf], 0xc; jnz ->2`) and reports a **measured ~0.15% slowdown** on a tight increment loop (9.903 s → 9.918 s), noting the penalty "scales down considerably" once real workloads do anything else.

**Reasoning about the cost:** the load is from a fixed, DISPATCH-relative address (`g->hookmask`) that is essentially always L1-resident and shared with the interpreter's own hot state; the branch is statically not-taken and near-perfectly predicted (it is taken exactly once, ever — at abort time). So the amortized cost is roughly one fused load-test µop plus a predicted branch — sub-1 cycle to ~1 cycle per iteration, i.e. low single-digit-percent worst case on the very tightest empty loops, and negligible (<<1%) on anything with real work. Mike Pall's own framing (lj_record.c comment) is qualitative — *"may be quite expensive in tight loops"* — and that is why it is off by default; the empirical 0.15% is consistent with "cheap in practice, only visible on degenerate loops." Note it also **defeats some loop optimizations**: the volatile load cannot be hoisted, and its presence can keep an otherwise-empty loop from being eliminated.

---

### (3) Cross-thread injection safety of `lua_sethook`

`lua_sethook` is in `lj_dispatch.c:337-348`, explicitly commented *"This function can be called asynchronously (e.g. during a signal)."* The write path is:

```c
mask &= HOOK_EVENTMASK;
if (func == NULL || mask == 0) { mask = 0; func = NULL; }
g->hookf = func;                                                  // 1. pointer write
g->hookcount = g->hookcstart = (int32_t)count;                    // 2. two int32 writes
g->hookmask = (uint8_t)((g->hookmask & ~HOOK_EVENTMASK) | mask);  // 3. byte write (what CHECKHOOK tests)
lj_trace_abort(g);                                                // 4. abort any in-progress recording
lj_dispatch_update(g, 0);                                         // 5. rewrite dispatch table
```

**Fields written:** `hookf` (`lua_Hook` pointer, `lj_obj.h:655`), `hookcount`+`hookcstart` (`int32_t`, `lj_obj.h:653-654`), `hookmask` (`uint8_t`, `lj_obj.h:641`); then `lj_dispatch_update` may rewrite up to the whole `dispatch[]` array of `ASMFunction` pointers (`lj_dispatch.c:106-219`) and `g->dispatchmode`.

**All plain, non-atomic writes; no memory barriers.** There is no `__atomic`/`volatile`/fence anywhere in this path. Safety rests on hardware guarantees plus the CHECKHOOK reader using a **volatile** load:

- `hookmask` is a **single byte** → its write is inherently atomic on every real CPU; it can never tear. Late visibility only **delays** the exit.
- `hookcount`/`hookcstart`/`hookf` are naturally aligned int32/pointer → aligned word/pointer writes are atomic on x86-64 and ARM64; no torn value is observable.
- The reader in a trace uses `IRXLOAD_VOLATILE` (`lj_record.c:2969`), so it **re-loads `hookmask` from memory every iteration** and the compiler cannot cache it in a register — this is the mechanism that lets a cross-thread write become visible to a running trace at all.
- **Write ordering favors the reader:** `hookf` and `hookcount` are written *before* `hookmask` (the bit the guard tests). On x86-64 (TSO) store order is preserved, so any thread that observes the `hookmask` bit set is guaranteed to also observe the matching `hookf`/`hookcount`. On weakly-ordered ISAs (ARM) these could in principle be reordered, giving a transient window where the guard fires but `hookf` is momentarily stale — but the injected hook doesn't run until *after* the trace exits and the interpreter re-dispatches, many instructions later, so in practice the writes have long since landed.
- The `dispatch[]` rewrite from another thread is a single-writer/aligned-pointer-slot situation: a **running trace never reads the dispatch table** (traces jump to native code, not through `disp[op]`), and the interpreter reads `disp[op]` only *after* the trace has exited — by which time the writes have completed under TSO. Each slot read yields either the old or the new (both-valid) `ASMFunction` pointer; no corruption.

**Worst case = delayed delivery, not corruption.** If the `hookmask` write is observed late, the trace simply runs a few more iterations before taking the exit. There is **no path to VM corruption from the byte/pointer writes themselves.**

**The one genuine race to design around (medium confidence):** `lua_sethook` also calls `lj_trace_abort(g)` and `lj_dispatch_update(g, 0)`, which mutate `jit_State J` and `g->dispatchmode`. `jit_State` is **not** designed for concurrent mutation. If the injection lands at the exact instant the executor thread is itself *recording* a trace (in `lj_record`/`lj_trace_ins`), the two threads touch `J` concurrently. Mike Pall's guarantee is specifically that *"lua_sethook is the only thread-safe call"* (quoted in Tarantool #5778) — i.e. this specific function is the sanctioned async entry point, and on the x86-64 TSO servers that GTNH runs on the aligned-slot writes make it safe in practice. It is "documented-safe / safe-in-practice on x86," not formally data-race-free on weak memory models. For OC: the injection targets a VM that is *executing*, and the recorder is abortable idempotently, so the practical risk is confined to a narrow recording-instant window; treat "kill the trace recorder mid-record from another thread" as the sharp edge, and prefer the state to be executing (not compiling) when the deadline hook is injected.

---

### (4) What the injected hook does when it calls `lua_error`/`lj_err_caller`, and unwind context

**The critical safety property: the hook never runs "inside" a trace, and `longjmp` never crosses trace machine code.** Sequence when the async hook fires inside a compiled loop:

1. CHECKHOOK guard fails → trace exit stub → `vm_exit_handler` (`vm_x64.dasc:2449`) → `lj_trace_exit` (`lj_trace.c`, invoked via `lj_vm_cpcall(L, NULL, &exd, trace_exit_cp)`, line ~921). The snapshot is replayed, so **the interpreter's Lua stack, PC and slots are fully reconstructed to a consistent interpreter state.** The trace's native frame is completely unwound here — cleanly, by design, not by longjmp.
2. `vm_exit_interp` (`vm_x64.dasc:2499`) resumes the interpreter and re-dispatches the next bytecode through the dynamic table (`vm_x64.dasc:2540-2554`), now pointing at `lj_vm_inshook`.
3. `lj_vm_inshook` (`vm_x64.dasc:2288-2306`) decrements `hookcount` (1→0) and calls `lj_dispatch_ins` (`lj_dispatch.c:411-454`), which at line 437-441 sees `(hookmask & LUA_MASKCOUNT) && hookcount==0`, reloads `hookcount`, and calls `callhook(L, LUA_HOOKCOUNT, -1)` (`lj_dispatch.c:366-392`).
4. `callhook` sets `HOOK_ACTIVE` (`hook_enter`, `lj_obj.h:682`), then calls the user hook `hookf(L, &ar)`. The hook calls `lua_error`/`error(obj)`.

So the `lua_error`→`lj_err_run`→`lj_err_throw` unwind (`longjmp`/`lj_vm_unwind_c`) originates **from an ordinary interpreter frame** (the `lj_dispatch_ins` C frame), exactly as a hook error would in a non-JIT build. **There is no longjmp across a trace exit** — the trace exit already happened as a controlled return in step 1. This is the whole reason the mechanism is safe: the JIT converts an async request into a *clean interpreter re-entry*, and only then does normal error propagation run.

**Where the error ends up / coroutine state:** the throw unwinds the coroutine's C stack to its nearest protected frame. `lj_err_unwind` (`lj_err.c:152-190`) handles `FRAME_PCALL` (a sandbox `pcall`) by calling `hook_leave(g)` (clears `HOOK_ACTIVE`, line 185) and stopping there — so **an error raised in the hook IS catchable by a `pcall` inside the sandbox**, identically to a normal error. If nothing catches it, the unwind reaches the `FRAME_CP` resume boundary (`lj_err.c:152-160`), where `hook_leave(G(L))` runs and `L->status` is set to the error code, and `lua_resume` (`lj_api.c:1229-1239`) returns non-`LUA_OK` with the error object on the coroutine's stack. The coroutine is left **suspended-with-error at the resume boundary** (not `"dead"` unless the error propagated out of its main function); `L->cframe` is `NULL`, `L->status` = the error code.

**Comparison with machine.lua's `tooLongWithoutYielding`:** functionally identical propagation, and OC's design is exactly the "escalating" version of this. In `machine.lua`:
- `checkDeadline` (lines 45-53) is the hook. When `computer.realTime() > deadline`, it **re-arms itself with `debug.sethook(coroutine.running(), checkDeadline, "", 1)`** (count=1, line 47) and then `error(tooLongWithoutYielding)` (line 52). The count=1 re-arm is the "hard" stage: even if sandbox code wraps the running region in `pcall`, the *next* instruction re-enters `checkDeadline` and re-errors, so a `pcall` cannot make forward progress — the coroutine is forced to keep erroring until it unwinds out.
- The resume loop `main()` (lines 1518-1543) arms the hook before each resume (`debug.sethook(co, checkDeadline, "", hookInterval)`, line 1532), then `local result = table.pack(coroutine.resume(co, ...))` (1533). On the deadline error, `result[1]` is false and line 1535-1536 does `error(tostring(result[2]), 0)` — propagating the failure to the host (computer crash/reboot).
- `pcallTimeoutCheck` (lines 55-61) + line 1548 (`return pcallTimeoutCheck(pcall(main))`) rewrite the sentinel table into the `"too long without yielding"` string for the host.

**The OC-LuaJIT design maps onto this cleanly:** the Java watchdog's async `lua_sethook(L, hook, LUA_MASKCOUNT, 1)` is the CHECKHOOK-enabled equivalent of machine.lua line 47's count=1 re-arm; the hook raises a catchable error object (soft stage); the count=1 keeps re-firing so a malicious `pcall` can't swallow it; and if the state still won't die, OC's Java side destroys the `lua_State` (hard stage) — the analog of "computer halted." The only difference from stock machine.lua is that the hook is **injected on deadline from Java rather than kept armed**, which is exactly what preserves the JIT (an always-armed count hook forces `DISPMODE_INS` and aborts every trace, `lj_dispatch.c:119-121` + `:372`).

---

### (5) With CHECKHOOK **NOT** defined: where an injected count hook is still delivered vs never

Without CHECKHOOK, the injected `lua_sethook(...MASKCOUNT, count=1)` still updates the dispatch table (`lj_dispatch_update`, `lj_dispatch.c:151-206` sets `DISPMODE_INS` → all instruction slots become `lj_vm_inshook`). Delivery therefore happens **the next time control passes through the interpreter's dynamic dispatch**, which is:

**Delivered (eventually):**
- **Interpreter bytecode execution.** Any instruction executed by the interpreter goes through `disp[op]` → `lj_vm_inshook` → `lj_dispatch_ins` → count hook. Immediate for interpreted code.
- **A trace exit for any *other* reason.** If the running trace exits (a type guard fails, a side exit, loop tripcount ends, an allocation/GC exit), it returns to the interpreter and re-dispatches through the now-hook-pointing table (`vm_x64.dasc:2554`) → hook fires. So a trace that *happens* to exit soon will deliver.
- **Function calls / returns crossing the interpreter.** `FUNCF`/`FUNCV` hot-call dispatch and `BC_RET*` go through `lj_dispatch_call`/`lj_vm_rethook` when the corresponding mode bits are set; and any call out of a trace that returns to the interpreter re-dispatches.
- **Hot-count dispatch / new trace attempts.** When the interpreter hits a hotcount underflow (`vm_hotloop`/`vm_hotcall`) it enters `lj_trace_hot`/`lj_dispatch_call`; those interpreter round-trips will observe the updated dispatch.

**Never delivered (the fatal gap):**
- **A self-contained compiled loop.** A trace whose loop body has no guard that fails and never calls back into the interpreter (the canonical `while true do end`, or a tight numeric loop that stays on-trace) **never reads `hookmask` and never re-dispatches**, so the injected hook is *never* seen. The trace runs forever. This is the exact case reported in LuaJIT issue #1488 ("debug hook not reached with jit.on()": `while true do end` counts to ~11 hook hits then "gets stuck"), issue #779 ("hook callback will be not called if code is in JIT"), and Tarantool #5778.

**What CHECKHOOK buys:** precisely the missing case — it adds the per-iteration `test hookmask; jne exit` at every loop back-edge (and trace head), so **even a self-contained compiled loop polls `hookmask` and takes the exit** when the async write lands. Everything else in the "Delivered" list already works without CHECKHOOK. In other words, CHECKHOOK converts "delivered only if the trace voluntarily returns to the interpreter" into "delivered within one loop iteration, guaranteed" — which is mandatory for an anti-grief timeout watchdog, because the griefing payload (`while true do end`) is exactly the self-contained-loop case.

---

### (6) Does CHECKHOOK exist/work identically in current v2.1 rolling? Open issues?

**Yes — the code is present and unchanged in structure on the v2.1 branch**, verified against the freshly fetched `lj_record.c` (the `lj_record_setup` block at ~2953 and the `rec_itern` `ref += 3` at ~691 are both in the current v2.1 source; GitHub search confirms `LuaJIT/LuaJIT/blob/v2.1/src/lj_record.c` still carries it). It has never been promoted to a runtime flag — it remains a compile-time `-DLUAJIT_ENABLE_CHECKHOOK` option, disabled by default. Community/maintainer confirmations that it is the sanctioned way to interrupt JITed code: issue #779 ("rebuild with `make XCFLAGS=-DLUAJIT_ENABLE_CHECKHOOK`... It may cost some performance, but I have not noticed this yet"), issue #1488, and Tarantool #5778.

**Relevant open/known issue — read carefully, because it validates rather than threatens the OC design:** FreeLists thread *"Infinite loop with LUAJIT_ENABLE_CHECKHOOK in v2.1"* (Myria, 2022-06-01). The reporter enabled CHECKHOOK and observed the VM "spin forever" in this compiled sequence:
```
test byte [rbx-0xEEF], 0Ch   ; hookmask & (MASKLINE|MASKCOUNT)
jne  <exit>                  ; hook set -> leave
test byte [rbx-0xEEF], 0Ch
je   <back to previous test> ; hook clear -> loop
jmp  <exit2>
```
This is **not a CHECKHOOK malfunction** — it is CHECKHOOK working as designed on an infinite Lua loop. The user's Lua code was itself an infinite loop with no other observable work, so after optimization the loop body reduced to *just* the hook check plus its back-edge; with `hookmask == 0` the loop legitimately spins, because an infinite Lua loop is *supposed* to run forever until something interrupts it. The reporter's own closing line confirms the mechanism is sound: **"An asynchronous abort via lua_sethook does in fact abort the loop"** — i.e. when a thread sets `hookmask`, the `jne <exit>` is taken and the trace exits. For the OC watchdog this is the ideal confirmation: a `while true do end` grief payload compiles to a spin that *contains the escape guard*, and the Java watchdog's async `lua_sethook(count=1)` flips `hookmask`, the guard fires, the trace exits to the interpreter, the count hook runs, and the error propagates — exactly stages soft→hard. The only caution the thread surfaces is a build/version-specific one: verify on the exact rolling commit you ship that the guard's exit target is wired to a real interpreter exit (the reporter was momentarily confused by the `je` self-loop, which is the *normal* back-edge, distinct from the `jne` escape). No evidence exists of CHECKHOOK being removed or semantically changed on v2.1; it is stable but perpetually opt-in and unmaintained-as-a-feature (Mike Pall's guidance in these threads is that timeout-via-hook is acceptable but a higher-level DSL / not running untrusted tight loops is "more efficient").

**Net for the OC-LuaJIT watchdog:** CHECKHOOK is real, present in current v2.1, cheap in practice (~0.15% on degenerate loops, negligible otherwise), and is the *only* mechanism that makes a self-contained compiled loop interruptible. The async `lua_sethook(L, hook, LUA_MASKCOUNT, 1)` injection is documented-safe (single-byte `hookmask` write, volatile reload in-trace, x86-64 TSO), delivers via a clean trace-exit → interpreter re-dispatch → count-hook path (no longjmp across trace code), and the resulting error is `pcall`-catchable in the sandbox and forced-terminal via the count=1 re-arm — structurally identical to machine.lua's `tooLongWithoutYielding`, differing only in that the hook is injected on deadline instead of kept armed.

---
**Sources:** local `lj_record.c` (2953-2973, 691-693), `lj_dispatch.c` (106-219, 337-348, 366-392, 411-454), `lj_dispatch.h` (70-129), `lj_obj.h` (641,653-655,674-689), `lj_opt_mem.c` (854-857), `lj_opt_loop.c` (22-77), `lj_err.c` (145-190), `lj_api.c` (1120-1239), `vm_x64.dasc` (2266-2314, 2449-2567), `machine.lua` (44-61, 1518-1548); LuaJIT issues [#1488](https://github.com/LuaJIT/LuaJIT/issues/1488), [#779](https://github.com/LuaJIT/LuaJIT/issues/779), [#723](https://github.com/LuaJIT/LuaJIT/issues/723); [FreeLists "Infinite loop with LUAJIT_ENABLE_CHECKHOOK in v2.1"](https://www.freelists.org/post/luajit/Infinite-loop-with-LUAJIT-ENABLE-CHECKHOOK-in-v21); [Tarantool discussion #5778](https://github.com/orgs/tarantool/discussions/5778).

# KEY CLAIMS
- [high] CHECKHOOK emits exactly 3 IR instructions once per trace in lj_record_setup (lj_record.c:2953-2973): a VOLATILE XLOAD of g->hookmask, BAND with (LUA_MASKLINE|LUA_MASKCOUNT)=0x0C, and a guarded IR_EQ against 0; because the XLOAD is IRXLOAD_VOLATILE it cannot be CSE'd or hoisted (lj_opt_mem.c:856-857), so the loop optimizer's copy-substitution re-emits it into the loop body and the check runs at every back-edge. When the guard fails it triggers a normal trace exit to the interpreter.
- [high] The check compiles to a single fused 'test byte [hookmask], 0x0C; jne <exit>' (two machine instructions), with a measured ~0.15% slowdown on a tight increment loop (9.903s vs 9.918s) and negligible cost on real workloads; the load is L1-hot and the branch is predicted-not-taken.
- [high] lua_sethook (lj_dispatch.c:337-348) writes hookf, hookcount/hookcstart, then hookmask as plain non-atomic writes with no barriers; hookmask is a single byte (untearble) and the others are aligned, so cross-thread injection risks only DELAYED delivery, never VM corruption, on x86-64 TSO. The residual sharp edge is that lua_sethook also calls lj_trace_abort/lj_dispatch_update, which touch jit_State, so injection during active trace RECORDING is the one narrow race to design around.
- [high] When the injected hook fires, the trace has already exited cleanly (guard fail -> vm_exit_handler -> lj_trace_exit reconstructs interpreter state from the snapshot) BEFORE the interpreter re-dispatches through the now-updated dynamic table to lj_vm_inshook->lj_dispatch_ins->callhook->hookf; the subsequent lua_error/longjmp originates from an ordinary interpreter C frame, so longjmp never crosses trace machine code. The resulting error is pcall-catchable in the sandbox (lj_err.c:174-190 FRAME_PCALL) and, with count=1 re-arm, forced-terminal, structurally identical to machine.lua's tooLongWithoutYielding (lines 45-53, 1532-1536).
- [high] CHECKHOOK is present and unchanged on the current v2.1 branch; the only known 'infinite loop with CHECKHOOK' report (FreeLists 2022, Myria) is CHECKHOOK working as designed on an infinite Lua loop, and the reporter confirms 'An asynchronous abort via lua_sethook does in fact abort the loop' -- validating exactly the OC watchdog path. Without CHECKHOOK, an injected count hook is delivered on interpreter bytecode, C-function returns, any trace exit, and hot-count dispatch, but NEVER on a self-contained compiled loop (LuaJIT issues #1488, #779).
