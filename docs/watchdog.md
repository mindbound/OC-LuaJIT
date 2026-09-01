# Timeout watchdog design

*Synthesized 2026-09-01 from source-level research on LuaJIT v2.1 (pinned commit `1ee778a4`), GTNH OC's machine.lua, CCLuaJIT, and production precedents. Background: [feasibility.md §3](feasibility.md). Validation harness: [../prototype/watchdog](../prototype/watchdog/).*

## Decision

No standing debug hook during normal execution. A Java watchdog thread **injects** `lua_sethook(L, hook, LUA_MASKCALL|LUA_MASKRET|LUA_MASKCOUNT, 1)` asynchronously when the deadline expires, on a LuaJIT built with `-DLUAJIT_ENABLE_CHECKHOOK`. Two-stage abort (soft error → hard state destruction), plus a last-resort thread abandonment that fixes CCLuaJIT's use-after-free.

This is the author-documented pattern: the `LUAJIT_ENABLE_CHECKHOOK` comment in `lj_record.c` says verbatim to "set the instruction hook via lua_sethook() with a count of 1 from a signal handler or another native thread," pointing at LuaJIT's own CLI Ctrl-C handler (`luajit.c`: `laction` → `lua_sethook(globalL, lstop, LUA_MASKCALL|LUA_MASKRET|LUA_MASKCOUNT, 1)`).

## Why the mechanism is sound (source-verified)

**CHECKHOOK.** Enables one extra check per compiled-loop iteration: `lj_record_setup` emits a *volatile* `XLOAD` of `global_State.hookmask`, `BAND 0x0C` (`LUA_MASKLINE|LUA_MASKCOUNT`), and a guarded `EQ 0` (`lj_record.c:2953-2973`). The volatile flag prevents hoisting, so the loop optimizer re-emits it at every back-edge. On x86-64 it assembles to a single fused `test byte [hookmask], 0x0C` + predicted-not-taken `jne <exit>` — **~0.15% measured overhead** on a degenerate tight loop (Tarantool #5778), negligible on real work. When the guard fails, the trace takes a *normal* trace exit: snapshot replay reconstructs consistent interpreter state, and only then does the interpreter's hook dispatch run the hook — **no longjmp ever crosses trace machine code**.

**Async `lua_sethook`.** Explicitly commented "can be called asynchronously" (`lj_dispatch.c:337-348`). It writes `hookf`, `hookcount/hookcstart`, then `hookmask` (a single byte — untearable), aborts any in-progress trace recording, and rewrites the interpreter dispatch table. Worst case from a late-observed write is *delayed delivery*, never VM corruption (x86-64 TSO; the trace reader reloads `hookmask` per iteration via the volatile load). Community consensus and Mike Pall's statements agree this is the one thread-safe entry point.

**Delivery and semantics.** The hook fires in whatever coroutine is running — hook state is VM-global in LuaJIT (`debug.sethook` even discards its thread argument), so **nested coroutines cannot evade it** (a strict improvement over PUC's per-thread hooks for our purpose). The error raised by the hook originates from an ordinary interpreter frame, is `pcall`-catchable in the sandbox like stock OC's `tooLongWithoutYielding`, and the `count=1` re-arm re-raises within ~one instruction if malicious code swallows it in a pcall loop (the same escalation machine.lua line 47 already implements, and Redis independently invented for SCRIPT KILL).

**Without CHECKHOOK** an injected hook is delivered on interpreter bytecode, C-function returns, any trace exit, and hot-count dispatch — but **never inside a self-contained compiled loop** (`while true do end`; LuaJIT issues #779, #1488). CHECKHOOK exists precisely to close that hole, and the one historical CHECKHOOK bug (an ITERN loop-detection miscompile, FreeLists 2022) was fixed next-day in commit `d4b6bb80ea3b` — present in our pinned commit; keep a `pairs()`-loop regression test anyway.

## Precedents

| System | Approach | Relevance |
|---|---|---|
| LuaJIT CLI (`luajit.c`) | SIGINT → `lua_sethook(count=1)` → catchable "interrupted!"; 2nd Ctrl-C kills process | The canonical pattern, incl. two-stage escalation |
| Tarantool | Enabled CHECKHOOK **by default** in their builds after measuring negligible overhead (#7762); cooperative "fiber slices" as the user feature | Production validation of CHECKHOOK + async sethook |
| OpenResty | No built-in abort; agentzh recommends exactly "custom OS thread + `lua_sethook` count=1 + CHECKHOOK build" | Independent endorsement of the design |
| Redis (PUC Lua) | On SCRIPT KILL escalates to an every-instruction hook "so the user will not be able to catch the error with pcall" | The re-arm anti-swallow escalation, independently invented |
| Luau (Roblox) | Greenfield sandbox VM: interrupt callbacks at safepoints, emitted in native codegen too; same residual C-function blind spot | A from-scratch design converged on the same architecture |
| CC:Tweaked (Cobalt) | 7000ms soft ("Too long without yielding") → +1500ms hard (destroy runtime) → abandonment | Source of our stage timings; CCLuaJIT cloned it |

## State machine (per machine)

`T0` = entry into the kernel resume inside `runThreaded`; `timeout` = OC's `Settings.timeout` (5.0s).

1. **RUNNING** — watchdog notes `deadline = T0 + timeout`. Resume returns → disarm, done.
2. **SOFT** (at `deadline`) — inject `lua_sethook(L, watchdog_hook, CALL|RET|COUNT, 1)`. The C hook `lua_call`s machine.lua's own `checkDeadline` (registered in the Lua registry at boot), inheriting stock OC behavior byte-for-byte: one +0.5s grace, count=1 re-arm, the identical `tooLongWithoutYielding` error table. Expected outcome: resume returns with "too long without yielding" → `ExecutionResult.Error` → `Machine.crash` — indistinguishable from stock OC. Always clear the hook before the next resume.
3. **HARD** (at `deadline + 1.5s`, resume still in flight) — keep the hook re-armed; when the resume *does* return (however it returns), the machine is condemned: `lua_close` from the Java side **only now, with no resume in flight**, and crash with the standard message. Mirrors CC's "destroy the entire Lua runtime."
4. **ABANDON** (at `deadline + 3s`, resume never returned — wedged in a C builtin or `__gc`) — requires the resume to run on a **dedicated per-machine runner thread** (never abandon an OC pool thread): mark the machine dead, report the crash, leak the runner + state, and leave the hook armed with an `abandoned` flag so that *if* the code ever reaches a safepoint, the hook raises, the runner unwinds, closes the state **on its own thread**, and exits. This deferred close fixes CCLuaJIT's latent cross-thread `lua_close` use-after-free (`TaskScheduler.java:286-290` + `unload()`).

machine.lua changes: delete the standing `debug.sethook` around resumes and the bogomips calibration; keep `deadline`/`checkDeadline`/`tooLongWithoutYielding` and the sandbox pcall/xpcall deadline checks; expose `checkDeadline` to C via the registry.

Never use `TerminateThread`/`pthread_cancel` in a JVM (heap/CRT/JVM-lock corruption; Java's own `Thread.stop` was removed for the same reason). Process isolation (Mike Pall's actual recommendation for hostile code) is the only stronger option — deferred as a future escape hatch.

## Threat model

| # | Hazard | Outcome with the watchdog | Severity / mitigation |
|---|---|---|---|
| 1 | Compiled hot loop (`while true do end`) | CHECKHOOK guard exits the trace; hook fires | Low — mask MUST include `LUA_MASKCOUNT` (the guard tests only COUNT\|LINE; a CALL/RET-only mask never exits traces) |
| 2 | Catastrophic backtracking in the **native** pattern matcher | Hook cannot fire mid-C; `LJ_MAX_XLEVEL=200` bounds depth, not work | **High** → machine.lua already routes strings ≥500 chars through its pure-Lua matcher (interruptible *and* JIT-compiled for us); consider routing **all** pattern ops through it; hard abort backstops <500-char strings |
| 3 | `string.rep`/`table.concat`/`string.format`/huge alloc bombs | Uninterruptible but **memory-cap-bounded**: allocator NULL → catchable `LUA_ERRMEM`, graceful even inside traces on GC64 (`LJ_UNWIND_JIT`) | Low |
| 4 | `table.sort` with malicious comparator | Each comparison is a `lua_call` → hook opportunity | Low |
| 5 | GC atomic phase | Uninterruptible C region, but bounded by the per-computer memory cap (low ms); heavy phases deferred off-trace | Low |
| 6 | mcode/`maxmcode` exhaustion | Trace abort → blacklist → interpreter fallback (*more* interruptible) | Low |
| 7 | Nested coroutines / sandbox disarm | Hook is VM-global; sandbox has no `sethook` | Low |
| 8 | `pcall` swallowing | count=1 re-arm re-raises every instruction | Low |
| 9 | Malicious `__gc` finalizer | Hooks are **suppressed during finalizers** (`hook_entergc`), which may even run on the server main thread | **High if enabled** → keep user `__gc` disabled (machine.lua's `allowGC=false` default exists for exactly this reason) |
| 10 | Deep C↔Lua re-entrant recursion (recursive gsub-callback etc.) | Lua-only recursion → catchable overflow at 65500 slots; C-boundary recursion → **native stack overflow → JVM crash** (LuaJIT has no `LUAI_MAXCCALLS`) | **Medium-High** → generously sized native stack on the runner thread |
| 11 | Cross-thread injection during trace *recording* | `lua_sethook` also touches `jit_State` (trace abort) — the one narrow race CCLuaJIT never exercised (its JIT was off) | Medium → ordered writes + barrier on the Java/JNI side; verify under stress; x86-64 TSO makes it safe in practice |

## Prototype

[`prototype/watchdog/`](../prototype/watchdog/) — standalone C11 harness (no JNI/Minecraft): builds the pinned LuaJIT twice (stock vs CHECKHOOK, static), runs five attack scripts (tight compiled loop, nested coroutines, pcall-swallow, string bomb, alloc bomb with a counting allocator) and two benchmarks (mandelbrot, numeric) under a watchdog thread with soft/hard staging. To measure: (a) proof that the stock build **cannot** interrupt a compiled loop while the CHECKHOOK build can; (b) interrupt latency; (c) the CHECKHOOK tax (stock vs CHECKHOOK vs `-joff`).

## Prototype results (2026-09-01, Ryzen 7 7840U, mingw-w64 gcc 15.2, LuaJIT 2.1 @ `1ee778a4`)

The full attack matrix ran on both builds (`make test`), JIT confirmed ON via `jit.status()`:

| Test | CHECKHOOK build | Stock build |
|---|---|---|
| Compiled `while true do end` | **Interrupted, 0.025 ms** deadline→hook; 0.081 ms to full soft-abort | **Hook never fires** (count=0) — only thread abandonment remains |
| Nested-coroutine loop | Interrupted, 0.024 ms (hook is VM-global) | — |
| `while true do pcall(...) end` swallow | Interrupted; count=2 shows the re-arm re-fired through the pcall | — |
| Alloc bomb (64 MB cap, counting allocator) | Catchable "not enough memory" at the cap (`cap_hits=1`) | — |
| `string.rep` bomb | Interrupted at 6.1 ms — the hook lands between C calls; memory cap bounds single calls (threat-model row 3 confirmed; the pure hard-abort case needs one enormous single C call) | — |

**CHECKHOOK tax**: mandelbrot 58.4 ms (CHECKHOOK) vs 59.0 ms (stock) — indistinguishable; degenerate numeric/bit microloop 29.0 vs 24.0 ms (~20% in a single noisy run; Tarantool's careful measurement of the same check was 0.15%). Same loop interpreted: 1253 ms — the JIT gain (~45×) dwarfs the tax by orders of magnitude.

**Conclusion: the design is validated end-to-end** — async injection interrupts JIT-compiled hostile code in microseconds, the stock build provably cannot, every anti-swallow and memory-cap behavior works as researched, and the safety tax is negligible on real workloads.

## Cross-component invariant: the hook must raise, never yield

Established while verifying M3 (2026-09-01). This watchdog installs a **native
C hook**, and LuaJIT's `lua_yield` has a hook branch that builds a
`cont_hook` continuation frame — a frame whose auxiliary slot is a raw
`MULTRES` count and whose "function" slot holds the thread rather than a
function. Such a frame cannot be serialized, so a coroutine suspended inside
one can never be persisted.

We are safe only because `watchdog_hook` calls `lua_error` and never
`lua_yield`. That is not incidental: it is a constraint on this design and on
any future variant that would rather "yield to the host on deadline" than
raise. The moment such a hook yields, every snapshot taken while a coroutine
is suspended in it becomes unpersistable.

(Stock OC is safe for a different reason: its hook is a *Lua* function, and
`lib_debug.c`'s trampoline runs it through `lua_call`, which pushes a frame
without `CFRAME_RESUME`, so `cframe_canyield` is false and yielding from it
fails outright. That reasoning does **not** transfer to a native hook.)

## Disarming is load-bearing, not hygiene

Measured 2026-09-01. A **still-armed `count=1` hook poisons every subsequent
host-driven Lua call on that state**: the first fire can be caught by a `pcall`,
and the second fire — two instructions later — killed the process outright. The
state machine above already says "always clear the hook before the next resume";
this note is here because that line reads like tidiness and is not. The watchdog
must disarm on *every* exit path from a resume, including the ones where the
resume returned normally and the deadline had not yet expired.

Two related findings from the same investigation, both reassuring:

- **A hook cannot fire inside the serializer's own C code.** It can only fire
  inside the two places persistence calls back into Lua — a `__persist`
  callback on save, and a reconstruction closure on load — and an error raised
  there unwinds cleanly and leaves the state fully usable. So a deadline
  expiring during a save cannot corrupt anything; at worst it fails the persist,
  which OC turns into its sanctioned reboot-on-load.
- **There is no genuine overlap window with OC's save path.** `Machine.run`
  (which calls `runThreaded`) and `Machine.save`/`load` are each
  `Machine.this.synchronized` for their whole bodies, so they are mutually
  exclusive by monitor rather than merely by the `isExecuting` check. The only
  residual risk is a watchdog arming microseconds *after* a resume returned —
  which is precisely what the disarm discipline above prevents.

## `jit.flush` and persist ordering

Also settled: `jit.flush` before a persist is **neither required nor harmful**
for the bytecode path. `lj_bcwrite` un-patches J-variant opcodes from live
traces, and `lj_trace_flushall` un-patches every root trace before nulling the
trace table, so both orders are safe. Earlier project documents gave two
contradictory orders; neither was wrong, and the requirement should be stated as
"either order is safe" rather than as a rule.

## Open items
- Decide `SHORT_STRING` threshold (route all pattern ops through the Lua matcher?).
- Stress-test cross-thread injection on a weak-memory host (ARM) or under TSan before shipping non-x86 natives.
- CHECKHOOK `pairs()`-loop regression test in CI.
