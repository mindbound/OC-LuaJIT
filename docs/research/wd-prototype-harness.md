# Watchdog prototype — delivered

Complete standalone (no JNI, no Minecraft) prototype written to
`C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\watchdog-prototype\`.

## File manifest (all absolute paths under the directory above)
- `harness.c` — single-file C11 harness (560 lines). Win32 path verified to compile clean under `gcc -std=c11 -Wall -Wextra -fsyntax-only` (exit 0, no warnings) using API-accurate stub headers.
- `build.bat` — MSVC build (74 lines): clones+pins LuaJIT, builds it twice as a static lib (CHECKHOOK and stock), compiles the harness against each.
- `Makefile` — gcc/mingw-w64/Linux build (102 lines): same two-variant flow via `XCFLAGS`, plus `make test` (attack matrix) and `make bench` (overhead matrix).
- `README.md` — build+run commands, pinned commit + citation, measurement plan, expected outcomes, uncertainties (261 lines).
- `scripts/attack_tight_loop.lua` (a), `attack_nested_coro.lua` (b), `attack_pcall_swallow.lua` (c), `attack_string_bomb.lua` (d), `attack_alloc_bomb.lua` (e), `bench_mandelbrot.lua` + `bench_numeric.lua` (f).

## Pinned LuaJIT commit
`1ee778a4e37122d8ca7d5733c590a47dafd6b15c` — tip of branch `v2.1`, dated 2026-08-19, "Add FOLD rule for ALEN of TNEW/TDUP." (from `api.github.com/repos/LuaJIT/LuaJIT/branches/v2.1`). Set as `LJ_COMMIT` in both build scripts.

## Key design decisions (each grounded in the local sources)
1. **Custom counting allocator via `lua_newstate` is legal only because GC64 stays on.** Under x64 GC64 (LuaJIT default, `LJ_GC64=1` — lj_arch.h:216) `lua_newstate(lua_Alloc, ud)` is the real entry (lj_state.c:249) and honours a custom allocf (lj_state.c:262-267). On a *non*-GC64 x64 build `lua_newstate` is replaced by a stub that prints "Must use luaL_newstate() for 64 bit target" and returns NULL (lib_aux.c:391-398). So the prototype uses `lua_newstate(counting_alloc, &mem)` and the README/Makefile/build.bat all forbid `-DLUAJIT_DISABLE_GC64`. LuaJIT passes the true old size in `osize` (0 for fresh allocs), so byte accounting is exact.
2. **Sandbox opens base/math/string/table/bit + jit, then deletes the `jit`/`debug` globals; the JIT engine stays on.** `JIT_F_ON` is set in `jit_State` by `jit_init()` during `luaopen_jit` (lib_jit.c:737) and is independent of the `jit` global table; `jit.status()` reports `J->flags & JIT_F_ON` (lib_jit.c:101-106). The harness stashes a registry ref to `jit.status` before nil-ing the global so C can still query engine state.
3. **Async hook injection is the documented mechanism.** `lua_sethook` carries the comment "This function can be called asynchronously (e.g. during a signal)." (lj_dispatch.c:336); it writes only `global_State` fields, calls `lj_trace_abort(g)` and `lj_dispatch_update(g,0)`, and never touches the running thread's stack (lj_dispatch.c:337-348). The watchdog arms `LUA_MASKCOUNT|LUA_MASKCALL|LUA_MASKRET|LUA_MASKLINE, count=1`.
4. **Mask choice is what makes CHECKHOOK bite.** With CHECKHOOK the compiler emits, at the top of every loop, a volatile `XLOAD` of `g->hookmask` band-ed with `(LUA_MASKLINE|LUA_MASKCOUNT)` and a guard `== 0` (lj_record.c:2953-2972); a live trace therefore exits to the interpreter the moment the watchdog sets either mask bit. `count=1` then makes `lj_dispatch_ins` fire the hook on the very next bytecode instruction (lj_dispatch.c:437-439, hookcount resets to hookcstart so it stays armed) — which is why pcall-swallowing (script c) cannot make forward progress.
5. **Two-stage abort with re-arm.** Soft = raise a catchable error *object* (`{watchdog=true,kind="soft-timeout"}`) from the hook via `lua_error`. Between soft and hard deadlines the watchdog re-arms every `--rearm-ms`. Hard = if `lua_resume` hasn't returned `--hard-ms` after arming, record HARD-ABORT-NEEDED and demonstrate the only safe options (abandon the worker OS thread, or `ExitProcess`/`_exit`), never `lua_close` on a state whose thread is still executing.
6. **Two binaries** (`harness_checkhook`, `harness_stock`) so the canonical A/B (same `attack_tight_loop.lua`, both builds) proves CHECKHOOK is *required*, and the `bench_*` scripts quantify its tax (stock vs checkhook vs `--jitoff`). MSVC has no `XCFLAGS` hook, so build.bat appends the defines to msvcbuild.bat's `LJCOMPILE` line (the same thing its own `lua52compat` arg does); the Makefile uses the documented `make XCFLAGS='…' BUILDMODE=static`.

## Honesty about what a build must still resolve (kept explicit in code + README)
- Whether a *compiled trace* actually takes the CHECKHOOK exit at runtime, the interrupt-latency magnitude, and the CHECKHOOK tax are all **TBD until both binaries are built and run** — the harness supplies the clock and the two binaries but pre-computes none of these numbers.
- Cross-thread `lua_sethook` is documented async-safe for *signals* (same thread); calling it from a different OS thread is the established CCLuaJIT/OC pattern but should be checked under ThreadSanitizer / on ARM.
- The `string.rep` bomb (d) ends as either HARD (wedged in C, no hook can fire) or memcap depending on `--mem-mb` vs requested size — this is the honest hard-abort demonstrator because C builtins poll no hooks.
- The msvcbuild `LJCOMPILE`-line PowerShell patch assumes that line's exact prefix at the pinned commit; repinning may require updating it.

## Verification performed here
- `lua_sethook` / `lua_resume(L,nargs)` / `lua_newstate` signatures, GC64 gating, `jit.status`, `luaopen_*` names + libname macros, and the CHECKHOOK IR emission all checked against the local sources and the pinned-commit `lualib.h`.
- `harness.c` passed `gcc 15.2 -std=c11 -Wall -Wextra -fsyntax-only` on the Win32 path (the path MSVC and MinGW both take) with zero diagnostics. The POSIX branch could not be exercised on this MinGW host (its headers reject a forced non-Win32 target), but review shows only standard pthread/`clock_gettime`/`nanosleep` idioms.

# KEY CLAIMS
- [high] Under x64 GC64 (LuaJIT's default), lua_newstate accepts a custom lua_Alloc (lj_state.c:249,262-267); only the non-GC64 x64 build disables it (lib_aux.c:391-398). The prototype's counting allocator is therefore valid precisely because GC64 is kept on.
- [high] LUAJIT_ENABLE_CHECKHOOK makes compiled loops emit a volatile XLOAD of g->hookmask band (LUA_MASKLINE|LUA_MASKCOUNT) with a guard, so a live trace exits to the interpreter as soon as the watchdog sets those mask bits (lj_record.c:2953-2972).
- [high] lua_sethook is documented callable asynchronously and only mutates global_State fields plus the dispatch table without touching the running thread's stack (lj_dispatch.c:336-348), so the cross-thread injection pattern is sound for the interpreter path.
- [high] Removing the 'jit' global does not disable the JIT engine: JIT_F_ON lives in jit_State set by jit_init() during luaopen_jit (lib_jit.c:737) and jit.status() reports J->flags&JIT_F_ON (lib_jit.c:101-106).
- [high] harness.c compiles cleanly (exit 0, no warnings) under gcc 15.2 -std=c11 -Wall -Wextra -fsyntax-only on the Win32 path using API-accurate stub headers; APIs were cross-checked against the pinned-commit lualib.h and local lj_*.c.
