# LuaJIT execution-timeout watchdog — standalone prototype

A pure-C harness (no JNI, no Minecraft) that measures and validates the
**async one-shot count-hook watchdog** intended for the LuaJIT-based CPU
architecture addon for OpenComputers (GTNH fork, MC 1.7.10).

The one question this prototype exists to answer:

> With the JIT **on** and a runaway loop compiled to a self-contained
> trace, can a Java-style watchdog thread that asynchronously injects
> `lua_sethook(..., LUA_MASKCOUNT, count=1)` actually interrupt it — and
> what does that cost?

OC's stock watchdog cannot be used with the JIT on (a standing count hook
aborts trace recording and forces slow interpreter dispatch). CCLuaJIT
shipped this exact async-hook pattern but ran with the `jit` library never
opened, so it was never tested against compiled traces. This harness closes
that gap on a normal desktop before any of it is ported into the addon.

---

## 1. What it does

1. Creates a LuaJIT state with a **counting allocator** (`lua_newstate`,
   GC64), opens `base/math/string/table/bit` **and `jit`**, then deletes the
   `jit` and `debug` globals from the sandbox `_G` — mimicking the real
   sandbox while the JIT **engine stays on** (`JIT_F_ON` lives in
   `jit_State`, set by `jit_init()` during `luaopen_jit`; removing the global
   table does not touch it).
2. Loads the target `.lua` onto a coroutine (`lua_newthread`) and runs it on
   a dedicated **worker OS thread** via `lua_resume`.
3. The main thread is the **watchdog**. After `SOFT_MS` of wall-clock it
   asynchronously injects
   `lua_sethook(co, hook, LUA_MASKCOUNT|LUA_MASKCALL|LUA_MASKRET|LUA_MASKLINE, 1)`.
   The hook raises a **catchable error object** (`{watchdog=true,…}`).
4. If the resume has not returned `HARD_MS` after the hook was armed, it
   records **HARD-ABORT-NEEDED** and demonstrates the only two safe options
   from another thread: **abandon the worker thread** or **exit the process**
   (you must never `lua_close` a state whose thread is still executing).
5. Between the soft and hard deadlines it **re-arms** the hook every
   `REARM_MS` (escalation path).

Threads/sync: Win32 `CreateThread` + `CRITICAL_SECTION` / `CONDITION_VARIABLE`
on Windows, pthreads elsewhere. Timing uses `QueryPerformanceCounter` /
`clock_gettime(CLOCK_MONOTONIC)`.

Per run it prints: `jit.status()` at start, **time-to-interrupt latency**
(deadline → first hook fire), total soft-abort time (deadline → resume
return), hook fire count, the classified outcome, allocator peak/cap-hits,
and PASS/FAIL against `--expect`.

---

## 2. Prerequisites

- **git** on `PATH`.
- **Windows:** a *x64 Native Tools Command Prompt for VS* (so `cl`, `lib`,
  `link` are on `PATH`). Nothing else.
- **Linux:** `gcc`/`clang`, `make`. LuaJIT needs no extra deps.
- **Windows via mingw-w64/MSYS2:** `gcc`, GNU `make`, `git` in the MSYS2
  shell — use the `Makefile`, not `build.bat`.

The pinned LuaJIT commit is **`1ee778a4e37122d8ca7d5733c590a47dafd6b15c`**
(tip of branch `v2.1`, dated 2026-08-19, *"Add FOLD rule for ALEN of
TNEW/TDUP."*). Both build scripts clone `https://github.com/LuaJIT/LuaJIT.git`
and `git checkout` that commit. Repin by editing `LJ_COMMIT` in `build.bat`
and `Makefile`.

Both scripts build LuaJIT **twice**, as a **static** lib, with
`XCFLAGS='-DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_CHECKHOOK'` for the
design build and `-DLUAJIT_ENABLE_LUA52COMPAT` alone for a **stock** build,
producing two harness binaries:

| binary | LuaJIT flags | role |
|---|---|---|
| `harness_checkhook` | `+LUA52COMPAT +CHECKHOOK` | the design under test |
| `harness_stock`     | `+LUA52COMPAT`            | evasion baseline / CHECKHOOK-tax reference |

**GC64 stays ON** (the x64 default). Do **not** add `-DLUAJIT_DISABLE_GC64`:
the counting allocator is installed via `lua_newstate`, and on a *non-GC64*
x64 build `lua_newstate` is disabled and a custom allocator is impossible
(`lib_aux.c`). GC64 is what makes the metered allocator legal here.

---

## 3. Build

### Windows (MSVC)

```bat
cd watchdog-prototype
build.bat
```

Produces `harness_checkhook.exe`, `harness_stock.exe`, `lua51_checkhook.lib`,
`lua51_stock.lib`. Under the hood `build.bat`:
1. clones + checks out the pinned commit into `luajit\`;
2. writes two patched copies of `luajit\src\msvcbuild.bat` that append the
   defines to its `LJCOMPILE` line (the same mechanism msvcbuild's own
   `lua52compat` argument uses — msvcbuild has no `XCFLAGS` hook);
3. runs each patched `msvcbuild … static` and copies out the `.lib`;
4. compiles `harness.c` against each lib (no explicit `/MD`/`/MT`, to match
   msvcbuild's static-default CRT exactly).

### Linux / mingw-w64 (gcc)

```sh
cd watchdog-prototype
make            # -> harness_checkhook(.exe), harness_stock(.exe)
make test       # run the attack matrix
make bench      # run the overhead matrix
```

The `Makefile` clones + checks out the pinned commit, then for each variant
does `make -C luajit clean && make -C luajit BUILDMODE=static XCFLAGS='…'`
(a full clean is required whenever `XCFLAGS` changes), copies
`luajit/src/libluajit.a` to `libluajit_checkhook.a` / `libluajit_stock.a`,
and links `harness.c` against each. Link libs: `-lpthread -lm -ldl` on Linux;
on mingw the harness compiles its `_WIN32` (Win32-threads) branch and needs
only `-lm`.

### Manual (either platform), for reference

```sh
git clone https://github.com/LuaJIT/LuaJIT.git luajit
cd luajit && git checkout 1ee778a4e37122d8ca7d5733c590a47dafd6b15c && cd ..
# Linux static lib, CHECKHOOK build:
make -C luajit clean
make -C luajit BUILDMODE=static XCFLAGS='-DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_CHECKHOOK'
cc -std=c11 -O2 -I luajit/src harness.c luajit/src/libluajit.a -lpthread -lm -ldl -o harness_checkhook
```

---

## 4. Run

```
harness [options] <script.lua>
  --soft-ms N     inject hook after N ms wall-clock          (default 200)
  --hard-ms N     escalate to hard abort N ms after arming   (default 500)
  --rearm-ms N    re-arm hook every N ms in soft..hard       (default 50)
  --mem-mb N      counting allocator cap, MB                 (default 64)
  --jitoff        force the JIT engine OFF (A/B benchmarking)
  --hard-exit     on hard abort, exit the process (default: abandon thread)
  --expect K      complete|interrupt|memcap|hard  -> prints PASS/FAIL
```

Exit code is `0` when `--expect` matches (or when no `--expect` is given and
the run ended normally), `1` on an `--expect` mismatch, `40` on an abandoned
hard-abort with no expectation, `42` from `--hard-exit`.

The canonical experiment:

```sh
./harness_checkhook --expect interrupt scripts/attack_tight_loop.lua   # must interrupt
./harness_stock     --expect hard      scripts/attack_tight_loop.lua   # expected to evade
```

---

## 5. Test scripts and expected outcomes

| script | what it attacks | expected (CHECKHOOK) | expected (stock) |
|---|---|---|---|
| `attack_tight_loop.lua` | `while true do x=x+1 end` — compiles to a self-contained loop trace that polls nothing. **The canonical evasion case.** | **interrupt** (trace exits via the CHECKHOOK guard) | **hard** (trace never sees the hook) |
| `attack_nested_coro.lua` | runaway loop 4 `coroutine.wrap` levels deep — verifies the hook (global per `global_State`) hits the *running* coroutine and the error propagates all the way out | interrupt | hard |
| `attack_pcall_swallow.lua` | `while true do pcall(function() while true do end end) end` — swallows the soft error; tests re-arm/escalation | interrupt (count=1 fires every instruction; the *outer* unprotected loop can't advance) | hard |
| `attack_string_bomb.lua` | `string.rep` / concat bomb — runs in **C**, no bytecode, so **no hook fires** while it executes; CHECKHOOK does not help here | **hard** (stuck in C) *or* **memcap** if the cap bites first | hard/memcap |
| `attack_alloc_bomb.lua` | unbounded table growth — exercises the counting allocator and, at a large cap, the soft hook | **memcap** at `--mem-mb 32`; **interrupt** at a huge cap | memcap / hard |
| `bench_mandelbrot.lua` | FP-heavy escape-time loop, runs to completion | **complete** | complete |
| `bench_numeric.lua` | `bit`-heavy ARX mixing loop, runs to completion — most sensitive to the per-loop CHECKHOOK guard | complete | complete |

Give the benchmarks a large `--soft-ms` (e.g. `--soft-ms 600000`) so the
watchdog never fires mid-measurement.

---

## 6. Measurement plan

**A. Does the design work? (correctness)**
Run every `attack_*` script on `harness_checkhook`. Expect the two infinite
*Lua* loops (a, b, c) to report `interrupt` with a small **interrupt
latency** (deadline → first hook fire). Run the same three on
`harness_stock`: (a) and (b) should report **hard** — direct evidence that
CHECKHOOK is *required*, and that without it a compiled `while true do end`
is an un-interruptible griefing vector.

**B. What does it cost? (the CHECKHOOK tax)**
For each `bench_*` script, compare wall-clock across three configurations:

| config | command |
|---|---|
| JIT on, stock LuaJIT | `harness_stock --soft-ms 600000 scripts/bench_numeric.lua` |
| JIT on, CHECKHOOK LuaJIT | `harness_checkhook --soft-ms 600000 scripts/bench_numeric.lua` |
| JIT off (interpreter floor) | `harness_stock --jitoff --soft-ms 600000 scripts/bench_numeric.lua` |

`(checkhook / stock) − 1` is the tax on a tight loop; `bench_numeric` (many
bit-ops per iteration, pure inner loop) is the near-worst case, `bench_mandelbrot`
a milder one. This is the number that decides whether shipping a CHECKHOOK
build is acceptable. **The actual figure is TBD until both binaries are
built and run on the target hardware** — the harness supplies the clock and
the two binaries; it does not and cannot pre-compute the tax.

**C. Interrupt latency distribution**
Vary `--soft-ms` and re-run (a)/(b) many times; the harness prints the
deadline→hook latency per run. Expect it dominated by the OS scheduler
waking the watchdog plus one dispatch-table rewrite, not by loop size.

**D. Hard-abort path**
`attack_string_bomb.lua --mem-mb 4096 --soft-ms 50 --hard-ms 300` should
reach **HARD-ABORT-NEEDED** (execution wedged inside a C builtin where no
hook can fire). Confirm both demonstrations: default (abandon thread, harness
returns) and `--hard-exit` (process exits 42).

---

## 7. Uncertainties a real build must resolve

- **CHECKHOOK actually taking the trace exit.** Verified in source
  (`lj_record.c:2953` emits a volatile `XLOAD` of `g->hookmask` + guard on
  every loop; `lj_dispatch.c:2970`-style guard tests `LUA_MASKLINE|LUA_MASKCOUNT`),
  but not verified at runtime here. Run (a) on both builds; this is the
  load-bearing result.
- **Cross-thread `lua_sethook` memory ordering.** `lua_sethook` is documented
  async-safe *for signals* (same thread). We call it from a *different* OS
  thread — the established CCLuaJIT/OC pattern, but worth a run under
  ThreadSanitizer / on weakly-ordered hardware (ARM) to confirm the dispatch
  update and `hookmask` write are observed by the VM thread promptly and
  safely.
- **Interrupt latency magnitude** and the **CHECKHOOK tax** — both TBD,
  produced only by running the binaries (§6).
- **Does the `--jitoff` A/B under-report the tax?** `--jitoff` disables the
  engine globally; it is the interpreter floor, not "CHECKHOOK with tracing
  suppressed". The stock-vs-checkhook comparison (both JIT on) is the honest
  tax; `--jitoff` is only the floor reference.
- **string.rep bomb ending.** Whether it wedges in C (hard) or trips the
  allocator (memcap) depends on `--mem-mb` vs the requested size; tune to
  demonstrate the intended one.
- **msvcbuild `LJCOMPILE`-line patch** assumes that line's exact prefix
  (`@set LJCOMPILE=cl …`) at the pinned commit; if you repin and the line
  changes, the PowerShell `-replace` in `build.bat` must be updated.

---

## 8. File manifest

```
watchdog-prototype/
  harness.c                       single-file C11 harness (all logic + comments)
  build.bat                       MSVC build: pinned LuaJIT x2 + harness x2
  Makefile                        gcc/mingw/Linux build: pinned LuaJIT x2 + harness x2
  README.md                       this file
  scripts/
    attack_tight_loop.lua         (a) compiled tight numeric infinite loop
    attack_nested_coro.lua        (b) nested-coroutine infinite loop
    attack_pcall_swallow.lua      (c) pcall-swallowing loop (re-arm test)
    attack_string_bomb.lua        (d) string.rep / concat builtin bomb
    attack_alloc_bomb.lua         (e) table-growth alloc bomb (counting allocator)
    bench_mandelbrot.lua          (f) FP benchmark, run to completion
    bench_numeric.lua             (f) bit-ops benchmark, run to completion
```
