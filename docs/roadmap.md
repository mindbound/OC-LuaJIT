# OC-LuaJIT roadmap

*Living document — extend as steps complete or plans change. Rationale for the decisions baked in here lives in [feasibility.md](feasibility.md).*

## v0 — Skeleton *(done, 2026-09-01)*

- [x] Feasibility study with source-verified findings ([feasibility.md](feasibility.md))
- [x] GTNH ExampleMod1.7.10-based project skeleton, fresh git history
- [x] Architecture stub registered via `Machine.add`, visible in shift+right-click CPU cycling; LuaJ-style non-persistence contract in place
- [x] Watchdog research + standalone prototype **built, run, and validated** (0.025 ms interrupt of compiled loops with CHECKHOOK; stock build provably can't; ~0% tax on real work — see [watchdog.md](watchdog.md))
- [x] Native performance comparison on real hardware ([../bench/results-2026-09-01.md](../bench/results-2026-09-01.md)): SHA-256 **41×**, matmul 17×, mandelbrot 14×, trampoline 16×, geomean 4.6× (≈6.7× with the strings fix) vs Lua 5.3; interpreter-only floor 2.5×
- [x] First `./gradlew build` verified green (JDK 17 daemon; OC `1.12.58-GTNH:dev` resolves; stub compiles against the real OC API)

## v1 — Working architecture, interpreter-only

The goal: OpenOS boots and runs on the LuaJIT architecture, with the JIT compiler deliberately left off (CCLuaJIT parity: ~1.5–3× vs PUC 5.3, zero trace-safety risk while the plumbing matures).

- [ ] JNI bridge (`src/main/cpp/`): state-per-computer, machine callbacks as C closures, correct binary-safe string marshalling (`lua_pushlstring`, UTF-8/byte-array round-trip — not CCLuaJIT's ASCII/NUL-truncating version)
- [ ] Counting allocator wired to `recomputeMemory` (state created via `lua_newstate` on GC64 — never `luaL_newstate` + `setallocf` swap)
- [ ] Kernel: run GTNH machine.lua with a `bit32` shim over LuaJIT's `bit`; sandbox reports `_VERSION = "Lua 5.2"`; `persistKey` nil path (LuaJ semantics)
- [ ] Component-call protocol: direct calls + `LimitReachedException` → zero results → machine.lua's synchronized-call fallback; `runSynchronized` closure resume
- [ ] Simple wall-clock watchdog (soft error → hard state-kill after resume returns) — sufficient while interpreter-only, since hooks always fire in the interpreter
- [ ] Native build pipeline: pinned LuaJIT v2.1 commit, `LUA52COMPAT` (+`CHECKHOOK`, harmless while JIT is off), static single-lib shim; win-x64 + linux-x64 first, extraction/probe loader cloned from `LuaStateFactory`
- [ ] In-game validation: OpenOS boot, editor, network, a compute benchmark vs the Lua 5.3 CPU

## v2 — JIT on

The headline release: enable the JIT (`luaopen_jit`, then hide `jit`/`debug` from the sandbox) and make the watchdog trace-proof.

- [ ] Adopt the prototype-validated watchdog: no standing hook; Java watchdog thread injects `lua_sethook(count=1)` at deadline; `LUAJIT_ENABLE_CHECKHOOK` build so compiled traces take the exit; machine.lua's count=1 re-arm escalation for pcall-swallowing code
- [ ] Hard-abort path: state destruction after resume returns; thread-abandonment backstop for the residual native-code case, with server-log diagnostics
- [ ] `jit.opt` tuning for many small computers (`maxmcode`, `maxtrace` scaled to installed RAM)
- [ ] Benchmark suite in-game: compute-bound (SHA-256, deflate, mandelbrot, pathfinding) and component-bound (terminal I/O) vs Lua 5.3 CPU; publish honest numbers
- [ ] Platform matrix completion: linux-aarch64, mac-x64/arm64
- [ ] Player-facing polish: login warning about non-persistence (OC's `WarningLuaFallback` pattern), docs

## v3 — Optional data persistence

*(May be subsumed by Track P below if it succeeds; kept as the fallback.)*

- [ ] Explicit opt-in API (e.g. `computer.setPersistData(blob)` / boot signal carrying the blob back), `string.buffer`-based encoding with a cycle-handling wrapper
- [ ] External-file storage following OC's SaveHandler pattern (large blobs must stay out of chunk NBT — see OpenPython/OC-Wasm precedents)
- [ ] Example OpenOS service showing the "save data, re-run code" pattern for automation controllers

## Track P — full transparent persistence (the moonshot)

Feasibility study complete and positive: [persistence-study.md](persistence-study.md). Goal: an Eris-API-compatible serializer (`eris-lj.c` sidecar compiled into the pinned LuaJIT build) so OC's `PersistenceAPI`/machine.lua machinery works unchanged and LuaJIT computers persist like the stock CPUs. ~3–4k LOC C, months part-time; runs in parallel with v1/v2 (M0–M2 don't depend on the JNI bridge).

- [x] Feasibility study with adversarial verification (no structural blocker; suspended coroutines are pure Lua-stack state; continuation set closed at 9 entries; cont_stitch aux slot → zero-payload trace ref)
- [x] **M0 — validation spike** *(done 2026-09-01)*: read-only frame-chain walker, [../prototype/framewalk](../prototype/framewalk/). All 7 invariants hold across 8 suspended threads in 7 frame shapes (plain yield, pcall/xpcall, `__index`/`__concat` metamethods, vararg chains with open upvalues, nested coroutines, JIT-hot loop). Two schema corrections found: the `cont_stitch` saved trace is at **framebase − 5** (not the provisionally assumed slot), and frame-type decoding must test `frame_islua()` before `frame_typep()` or pcall frames are silently mislabeled.
- [ ] M0b — rerun the walker against real OC kernel states once the JNI bridge exists (v1), to confirm machine.lua's actual suspend shapes match the catalog
- [x] **M1 — data serializer** *(done 2026-09-01)*: [../serializer](../serializer/) — tables/strings/numbers with shared-ref map, cycles, metatables, perms-at-every-node, spkey literal semantics; fingerprinted header + CRC32; 84 tests pass. Survived a four-lens adversarial review that found and fixed **two crash bugs** (a SIGSEGV from an unvalidated permanent type byte, and an uncatchable C-stack overflow from an unclamped `maxrec`) plus a silent write-only-save-data defect; all ten findings have regression tests. See [../serializer/README.md](../serializer/README.md).
- [ ] **M2 — code**: protos via `lj_bcwrite`/`lj_bcread` with dedup, Lua closures, upvalue identity (closed + open); `debug.upvalueid` equality preserved
- [ ] **M3 — suspended coroutines** (the schedule risk): frame decode → three symbolic forms + cont relocation table; PC → (proto, offset); open-upvalue relinking; hard rejects (`cframe != NULL`, interior C frames, unknown cont, hook frames); zero the cont_stitch trace slot
- [ ] **M4 — protocol + integration**: spkey with pre-reserved ref slots, `settings("spkey"/"path")`, perms/uperms; bridge-side ERIS-library analog; OpenOS boot → persist mid-`pullSignal` → restore → continue
- [ ] **M5 — hardening**: persist→unpersist→persist oracle in CI, randomized state fuzzing, corrupted-blob rejection, canary self-test on every load, GC-stress soak with LuaJIT assertions

## Open questions

- OC version pin: currently `1.12.58-GTNH` (2026-08-30); revisit at v1 start.
- Whether to shim JNLua's Java API (reuse OC's `LuaState` abstractions) or keep a minimal purpose-built JNI surface like CCLuaJIT. Current lean: minimal purpose-built.
- `bit32` shim semantics: LuaJIT `bit.*` returns signed 32-bit; bit32 is unsigned — normalize with `% 2^32`; needs a conformance test against PUC `bit32`.
- CHECKHOOK's measured overhead on hot loops (prototype task) — if it's large, consider offering both native builds (safe vs fast) as a server config.
- Microcontrollers/robots/drones: verify `@Architecture.NoMemoryRequirements` interaction and tier gating for the new CPU option.
