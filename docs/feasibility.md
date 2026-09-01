# OC-LuaJIT feasibility study

*Completed 2026-09-01. All claims below were verified against primary sources (GTNH OpenComputers `master`, LuaJIT `v2.1` branch sources, the CCLuaJIT repository, Eris/JNLua, and the OpenPython / OC-Wasm addons), including an adversarial verification pass. This document records the findings that shaped the project; the living plan is in [roadmap.md](roadmap.md).*

## Verdict

A LuaJIT architecture addon for GTNH OpenComputers is **feasible** and cleaner to build than its ComputerCraft predecessor was. **JNLua/Eris-compatible persistence is impossible** — confirmed by the authors of every relevant component — so the architecture is **non-persistent by design** (computers reboot on chunk reload), which OC supports as a first-class mode. Performance gains are **bimodal**: roughly 3–15× (more on tight numeric loops) for compute-bound Lua, near zero for component-call-bound programs.

## 1. Architecture integration

Everything CCLuaJIT needed an ASM coremod for, OC provides as public API:

- Registration: a class implementing `li.cil.oc.api.machine.Architecture` with a `(li.cil.oc.api.machine.Machine)` constructor and `@Architecture.Name("LuaJIT")`, registered via `li.cil.oc.api.Machine.add(...)` **during init or later** (not pre-init). It then automatically appears in shift+right-click CPU cycling (`CPULike.scala:28-48`; the choice is stored per-item as `oc:archClass` NBT, `DriverCPU.scala:43-67`).
- Lifecycle contract (`api/machine/Architecture.java`): `initialize`/`close`, `runThreaded(isSynchronizedReturn)` on a worker pool (default 4 threads, `Settings.threads`), `runSynchronized()` on the main server thread, `recomputeMemory`, `onSignal`/`onConnect`, `load`/`save`.
- **No yield-across-C problem**: OC's component-call protocol never yields across a C boundary. Direct calls return normally; when the per-tick budget is exhausted, `Machine.invoke` throws `LimitReachedException`, the architecture's callback wrapper returns zero results, and machine.lua converts that into `coroutine.yield(closure)` → `ExecutionResult.SynchronizedCall` → `runSynchronized()` next tick (`machine.lua:1080-1103`). LuaJIT's lack of `lua_yieldk` is therefore irrelevant here — unlike in ComputerCraft, where it forced CCLuaJIT's ugliest hacks (blocking executor threads in `pullEvent`, bytecode-scanning all classes for event-filter constants).
- Precedents: OpenPython (MC 1.12) and OC-Wasm-GTNH (MC 1.7.10, our exact target stack) both integrate through this API with zero OC patches.

The JNI bridge itself is precedented by CCLuaJIT's single 811-line `LuaJITMachine.cpp`: one `lua_State` per computer, eager deep-copy value marshalling with cycle detection, Java callbacks exposed as C closures. Known CCLuaJIT bridge bugs to avoid: `byte[]`→Lua via `lua_pushstring` on a NUL-terminated copy (truncates binary data — use `lua_pushlstring`), and Lua→Java strings decoded as US-ASCII.

## 2. Persistence: impossible in Eris form; reboot-on-load is sanctioned

How OC's persistence works: the **entire kernel coroutine** is serialized as one Eris object from Lua stack index 1 (plus a pending synchronized-call value at index 2) via `eris.persist` with perms/uperms tables built by flattening everything reachable from `_G` (`NativeLuaArchitecture.scala:396-437`, `PersistenceAPI.scala`). Eris is compiled into OC's patched JNLua natives (`LuaState.Library.ERIS`).

Why it can't be ported:

- Eris README: it "won't work with other Lua implementations, such as LuaJIT, because Eris works directly on some internal structures of vanilla Lua."
- fnuecke (author of both OC and Eris), closing eris issue #4: "there is no LuaJIT support in Eris and there probably never will be."
- Mike Pall (2008, re Pluto): "the internal data formats are not compatible with standard Lua, so you won't be able to use Pluto at all."
- LuaJIT cannot load PUC bytecode at all; its own bytecode is only compatible within one major+minor version and GC mode (luajit.org/extensions.html). Its `string.buffer` serializer explicitly cannot serialize functions, threads, or userdata. Interpreter-only mode does not change the object model. No prior art exists after 18 years.

The sanctioned fallback — verbatim from OC's shipped LuaJ architecture (`LuaJLuaArchitecture.scala:254-261`):

```scala
override def load(nbt: NBTTagCompound) {
  if (machine.isRunning) { machine.stop(); machine.start() }
}
override def save(nbt: NBTTagCompound) {}
```

OC ships a login warning for this mode ("They will reboot on chunk reloads."), a `disablePersistence` config that applies the same semantics to native Lua, and machine.lua branches on `persistKey == nil` to bypass all Eris machinery. A middle-ground option for later: an explicit **data-only persistence API** (OC-Wasm's model — memory/globals snapshot, no call stack, programs restart as state machines).

For contrast, OpenPython's "fully persistable" claim is real but non-transferable: it interprets MicroPython firmware with a software ARM Cortex-M0 emulator, so its whole VM is a snapshotable memory image + 17 registers — persistence by whole-machine emulation, at a catastrophic performance cost. Full code-level breakdown (and the reusable parts for our v3): [openpython-persistence.md](openpython-persistence.md).

## 3. The watchdog crux (summary — full design in [watchdog.md](watchdog.md))

OC's 5-second "too long without yielding" is enforced by machine.lua keeping a **count debug hook armed around every resume**. Verified in LuaJIT v2.1 source, that design is unusable with the JIT on:

- Any hook call aborts in-progress trace recording (`lj_dispatch.c:372`).
- An armed count/line hook forces the whole VM into the slower `DISPMODE_INS` hook-checking interpreter dispatch.
- **Compiled traces never poll hooks** unless LuaJIT is built with `-DLUAJIT_ENABLE_CHECKHOOK` (off by default). Without it, `while true do end` compiles to a self-contained trace that no in-VM mechanism can interrupt.

Key discovery about the precedent: **CCLuaJIT ran with the JIT compiler off.** `JIT_F_ON` is set in exactly one place — `jit_init()` inside `luaopen_jit()` (`lib_jit.c:733-756`) — and CCLuaJIT opens only `base, math, string, table, bit` (`LuaJITMachine.cpp:692-696`), never the `jit` library, never `luaJIT_setmode`. Its "~10–13× on SHA-256" was the LuaJIT *interpreter* vs ComputerCraft's much slower LuaJ, and its abort mechanism was never tested against compiled traces.

Chosen design: no standing hook during normal execution; a Java watchdog thread injects `lua_sethook(count=1)` asynchronously at deadline expiry (the pattern LuaJIT's own CLI uses for Ctrl-C); LuaJIT built with `LUAJIT_ENABLE_CHECKHOOK` so traces take the exit too; two-stage soft/hard abort mirroring OC semantics.

## 4. Memory limits

- GC64 is the default on all modern 64-bit LuaJIT builds, which makes `lua_newstate` with a **counting allocator** a working exported API again (64-bit non-GC64 refuses it: "Must use luaL_newstate() for 64 bit target", `lib_aux.c`).
- **Trap**: OC's JNLua does `luaL_newstate()` then swaps in the counting allocator via `lua_setallocf`. That swap is unsafe on LuaJIT (no block migration out of the internal arena) — the state must be *created* with the counting allocator.
- JIT machine code bypasses `lua_Alloc` (direct mmap/VirtualAlloc in `lj_mcode.c`) but is bounded per state by `maxmcode` (default 2 MB; lower it via `jit.opt.start` for OC's many-small-computers workload).
- OC's framework only uses `recomputeMemory`'s boolean ("is RAM present"); actual byte-limiting is architecture-internal. `ramScaleFor64Bit` exists for tuning.

## 5. Language compatibility: small, well-bounded

Scanned: machine.lua (1548 lines) and all 129 OpenOS loot files.

- Build with `-DLUAJIT_ENABLE_LUA52COMPAT`: covers the pervasive `table.pack/unpack` and `rawlen` usage.
- Stock LuaJIT extensions cover the rest: `load(..., env)` (OC sandboxes via load's env parameter — **zero** `_ENV` references anywhere), `xpcall(f, h, ...)` with args, `coroutine.isyieldable`, `table.move`, yield-across-pcall/metamethods.
- All 5.3-isms are guarded with `or`-fallbacks and are already nil on OC's supported Lua 5.2 profile (`string.pack`, `utf8`, `math.maxinteger`, ...). `sandbox._VERSION` would report "Lua 5.2". No `//`, no `goto` anywhere in OpenOS.
- The one real porting item: a `bit32` shim (~100 lines over LuaJIT's built-in `bit`), because OpenOS's `lib/bit32.lua` is written in Lua 5.3 operator syntax.
- machine.lua's pure-Lua pattern matcher (lines 86–686, used for strings ≥ 500 chars so timeouts apply during matching) is hot pure-Lua code — exactly what the JIT compiles well, and it keeps long string matching interruptible in our favor.

## 6. Performance expectations

- **Compute-bound** (crypto, compression, rendering pipelines before GPU calls, emulators, pathfinding): ~3–15× vs PUC Lua 5.3 (Klausmeier 2020: 10–13.6× on array/n-queens; 2016: 24.5× on numeric ODE), wider in both directions at the extremes. Interpreter-only floor: ~1.5–3×.
- **Component-bound** (most casual programs): ~zero. Per-tick direct-call budgets (0.5/1.0/1.5 by CPU tier; e.g. hard cap of 384 T3 `gpu.set`/tick) and one synchronized call per 50 ms tick dominate; LuaJIT cannot buy budget. (Budgets are configurable server-side, which shifts but does not remove this ceiling.)
- Traces survive OC's yield-heavy model: the trace cache lives in the per-state `jit_State` and persists across resumes; `coroutine.yield/resume` are never trace-compiled, so each yield briefly exits to the interpreter — irrelevant at OC timeslice granularity.
- Secondary benefit: ~10× less executor-thread CPU per timeslice on busy GTNH servers.

## 7. Build & packaging

- GTNH toolchain: this repo is based on ExampleMod1.7.10 (GTNHGradle/RetroFuturaGradle), Java 8 bytecode via Jabel, OC dependency `com.github.GTNewHorizons:OpenComputers:<ver>:dev` from the GTNH nexus.
- Natives: ship per-platform libs in resources and clone OC's `LuaStateFactory` mechanics (version-stamped tmp-dir extraction → `System.load` → probe-create a state → graceful "unavailable" fallback). OC's own natives jar covers ~10 platform combos as the matrix template; ours: win-x64, linux-x64, linux-aarch64, mac-x64, mac-arm64.
- LuaJIT: pin a v2.1 commit (rolling releases — CCLuaJIT's unpinned clone and dead macOS SDK URL are the cautionary tale); build static into a single JNI shim per platform with `XCFLAGS="-DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_CHECKHOOK"`.
- JNI on GTNH's modern JVMs (lwjgl3ify, Java 17/21+): non-issue; lwjgl3ify's stock launch args already include `--enable-native-access=ALL-UNNAMED` for JDK 24+.

## 8. Sources

- GTNH OpenComputers `master`: `api/machine/Architecture.java`, `server/machine/Machine.scala`, `luac/NativeLuaArchitecture.scala`, `luac/PersistenceAPI.scala`, `luac/LuaStateFactory.scala`, `luaj/LuaJLuaArchitecture.scala`, `assets/opencomputers/lua/machine.lua`, `application.conf`, `EventHandler.scala`, `CPULike.scala`, `DriverCPU.scala`, `GraphicsCard.scala`
- LuaJIT `v2.1` sources: `lib_jit.c`, `lj_dispatch.c/h`, `lj_record.c`, `lj_trace.c`, `lj_asm.c`, `vm_x64.dasc`, `lj_state.c`, `lib_aux.c`, `lj_alloc.c`, `lj_mcode.c`, `lj_jit.h`, `lj_arch.h`; luajit.org/extensions.html, ext_buffer.html, doc/install.html
- fnuecke/eris (README, issue #4), fnuecke/jnlua (`eris` branches, `jnlua.c`), BlueAmulet/JNLua-Natives, MightyPirates/OpenComputers#3287, Mike Pall lua-l 2008-09 ("LuaJIT + Pluto")
- CCLuaJIT (local checkout, branch `1.7.10_CC`): `LuaJITMachine.cpp`, `LuaJITMachine.java`, `TaskScheduler.java`, ASM transformers, `Dockerfile`/`build-natives.sh`; sci4me's CC forum benchmark thread
- OpenPython (`OpenPythonArchitecture.kt`, `OpenPythonVirtualMachineV1.kt`, thumbsf `CPU.kt`), OC-Wasm-GTNH (`CPU.java`, `Compiler.java`, `Postprocessor.java`, `Snapshot.java`, `state/*`)
