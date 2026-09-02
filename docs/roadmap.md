# OC-LuaJIT roadmap

*Living document — extend as steps complete or plans change. Rationale for the decisions baked in here lives in [feasibility.md](feasibility.md).*

## v0 — Skeleton *(done, 2026-09-01)*

- [x] Feasibility study with source-verified findings ([feasibility.md](feasibility.md))
- [x] GTNH ExampleMod1.7.10-based project skeleton, fresh git history
- [x] Architecture stub registered via `Machine.add`, visible in shift+right-click CPU cycling. (Its original LuaJ-style non-persistence premise was disproved by Track P and the class comment has been corrected; the stub is still a stub.)
- [x] Watchdog research + standalone prototype **built, run, and validated** (0.025 ms interrupt of compiled loops with CHECKHOOK; stock build provably can't; ~0% tax on real work — see [watchdog.md](watchdog.md))
- [x] Native performance comparison on real hardware ([../bench/results-2026-09-01.md](../bench/results-2026-09-01.md)): SHA-256 **41×**, matmul 17×, mandelbrot 14×, trampoline 16×, geomean 4.6× (≈6.7× with the strings fix) vs Lua 5.3; interpreter-only floor 2.5×
- [x] First `./gradlew build` verified green (JDK 17 daemon; OC `1.12.58-GTNH:dev` resolves; stub compiles against the real OC API)

## v0.5 — ocelot-brain harness *(the development environment)*

Adopted 2026-09-01 after evaluation ([research/ocelot-brain.md](research/ocelot-brain.md)).
**This inverts the previous plan.** v1 assumed the JNI bridge would be validated
in-game; it is validated here instead, and Minecraft is touched only at v1's
final line. The reason is epistemic rather than convenience: this project's
standing weakness is that every verification claim was one step removed from
reality, and this closes that gap for the machine layer — where all the
remaining risk lives. Minecraft was never going to give us a differential
oracle against real Eris. ocelot-brain does.

- [ ] **The false-green guard, before anything else runs.** ocelot-brain sets
  `includeLuaJ = !isAvailable`, so a failed native load silently substitutes
  LuaJ — which has no Eris, so every persistence test then passes **vacuously**.
  This is the single failure mode that manufactures false confidence. A shared
  harness base class asserts the architecture is what we think it is and dies
  loudly otherwise. A base class, not a convention.
- [ ] Vendor ocelot-brain at a pinned commit. No published artifact; consumed as
  a git submodule + sbt composite build, with three dependency jars fetched by
  URL from asie.pl — vendor those too. MIT, compatible with ours.
- [ ] Split `LuaJITArchitecture` into a host-agnostic core plus two thin shells
  (~60 lines each). Exactly four things diverge: `recomputeMemory`'s body
  (`Iterable[Entity]` versus stack → `Driver.driverFor`), the two extra memory
  getters, the NBT blob write (direct `setByteArray` versus `SaveHandler`), and
  the imports. Compile the shared core with `--release 8` — ocelot-brain's
  Scala is already Java 8; only its 19 Java sources are 61, and our javac
  output is ours to control.
- [ ] Pin `NativeLua52Architecture` for every comparison. **Three languages are
  in play**: ocelot defaults to 5.3, GTNH ships 5.2, we are LuaJIT 5.1 +
  `LUA52COMPAT`. Any 5.3/5.4 result is inadmissible.
- [ ] **The differential oracle.** Same host, same workload, same save point:
  persist with real Eris on PUC 5.2 and with `eris_lj` on LuaJIT, then compare
  accept/refuse decisions and post-restore observables. This is the strongest
  test available to this project, and nothing else can produce it.
- [ ] Tests are "run until a condition, with a timeout" — never "step N ticks".
  Lua runs on a thread pool against a wall clock, so tick-counting tests flake,
  and a flaky persistence test is worse than none. Saves cannot tear:
  `Machine.save` and `Machine.run` share a lock.
- [ ] **Two one-run measurements, both left open by the MineOS census** ([research/mineos-census.md](research/mineos-census.md)): (a) boot MineOS on ocelot-brain with the machine's RAM set to its own declared floor (2048 KB) and try to save -- this either promotes "the save may not fit" to a ranked defect or retires it, and it is the only census row whose fix would be in OUR C code (the write buffer doubles through the host allocator and `lua_pushlstring` then copies it again, so peak is live + buffer + blob); (b) capture a save point with an application WINDOW open -- the stock baseline covers only an idle desktop, and three of MineOS's four interesting shapes exist only once a window is open.
- [ ] **Mirrored host state is an atomicity obligation.** MineOS keeps a full Lua-side framebuffer mirror and renders only the diff, so its `currentFrame*` is a cached belief about the screen used to SUPPRESS work. Not a defect today -- stock OC and ocelot-brain satisfy it by construction (one lock, both halves in the same NBT) -- but our architecture must never break it: one lock, one instant, never restore one half without the other, never pair a stale component NBT with a fresh blob after a failed or retried save. Measured consequence of breaking it: ~64% of the desktop missing permanently, `isRunning=true`, `crashes=0`, `lastError=null`, and it re-saves cleanly.
- [ ] Record the three ocelot-brain defects that will otherwise be misread as
  ours: `Integer` signal loss (`Machine.scala:800-814` has no
  `java.lang.Integer` case and falls through to `setByte(-1)`),
  `new Memory(ExtendedTier.Creative)` throwing on insert, and `brain.conf`
  replacing rather than overriding config.

**What a green harness run does NOT prove**, and this matters more than what it
does: it is not Minecraft (no energy, no `SaveHandler` deferral or world-save
ordering, no tile-entity lifecycle, no inventory/driver resolution — which is
precisely the one method whose body differs between the two `Architecture`
interfaces, so `recomputeMemory` is structurally unexercisable here), and it is
not GTNH. Deeper still: it cannot prove the two things the shape census says
actually kill real machines — PatchGuard-style `tostring(f)` fingerprinting and
unrebased `computer.uptime()` deadlines. Both are true of real Eris too, so the
harness will show us passing exactly where stock OpenComputers also fails,
which is comforting and irrelevant.

## v1 — Working architecture, interpreter-only

The goal: OpenOS boots and runs on the LuaJIT architecture, with the JIT compiler deliberately left off (CCLuaJIT parity: ~1.5–3× vs PUC 5.3, zero trace-safety risk while the plumbing matures).

- [x] **JNI bridge — ANSWERED BY BUILDING IT** ([research/jnlua-binding.md](research/jnlua-binding.md)). We do NOT write one. OpenComputers' own repackaged JNLua drives LuaJIT behind a **~500-line C shim** (measured three times independently: 491 / 538 / 469), with **zero changes to jnlua.c, to the OC-JNLua Java layer, or to ocelot-brain**. Real OpenOS 1.8.9 boots to a shell, `component.invoke` round-trips, and `eris.persist` produces a ~150 KB blob through OC's real `PersistenceAPI` that restores and resumes mid-execution — with the JIT ON. The hand-written-bridge branch (1,200–1,600 C + 400–600 Java) is dead by measurement.
- [ ] **Memory accounting — the one genuinely open integration item.** JNLua caps RAM via `lua_setallocf`, which on LuaJIT is heap corruption (a heterogeneous allocator: LuaJIT arena blocks later handed to msvcrt `free()`), and its `l_alloc_checked` re-enters the Lua API from inside `lua_Alloc`. Neutralised for now by one shim line (`#define lua_setallocf(L,f,ud) ((void)0)`), which stops the process kill — `java exit=127`, no hs_err, no Java exception — but leaves the cap **reported and not enforced**: `used` never increments, so a machine cannot run out of RAM. The real fix is ~45 lines: cache the jobject in a C-side map keyed by `lua_State*` at newstate, then have the checked allocator do JNI field access only, with no allocator swaps and no `getjavastate`.
- [ ] **MEMORY ACCOUNTING AND PUSHCFUNCTION WARM-UP MUST LAND TOGETHER.** This is the single most important scheduling fact from the consolidation, and splitting them introduces a JVM-killer. jnlua.c has **37** `lua_pushcfunction(L, *_protected)` sites, each running in a bare JNI frame *before* its pcall. The shipped memo is LAZY, so the first push of each still allocates and can raise `LUA_ERRMEM` with no protected frame above it -- which on Win x64 (`LJ_UNWIND_EXT=1`) kills the JVM. That is invisible **only because the RAM cap is currently not enforced**. Land accounting alone and the hole re-arms. The warm-up is ~10 lines on top of the memo that already exists: in `lj52_newstate`, after the memo table is seeded, push each protected function once while memory is plentiful. Acceptance test, now concrete: a `disableMemoryLimit:false` run showing `kernelMemory` well above 1 and `freeMemory` actually FALLING as OpenOS boots, plus an OOM raised at the cap -- today both are pinned, so "reported but not enforced" is what the machine says about itself on every run.
- [ ] **`lua_pushcfunction` memoisation — the lazy half is DONE and landed** (`native/lj52shim.c`); what remains is the eager warm-up above. On 5.2 it stores a *light* C function — no allocation, cannot fail — which is what makes JNLua's `*_protected` discipline airtight. LuaJIT has no light C function type, so the push allocates a `GCfunc` and can raise `LUA_ERRMEM` **in the bare JNI frame, before any protected frame exists** — i.e. the error is thrown by the act of installing the error handler. Memoise each protected function's `GCfunc` at state creation and make the shim's push a registry lookup. Side benefit: it restores 5.2's "the same C function pointer pushes an equal value", which is what a perms table wants.
- [x] **`lua_load` mode escape hatches DELETED, with a regression test that has teeth** (`test/native/security_test.c`, 37 checks; `test/native/negative-control.sh` rebuilds the shim from sabotaged copies and asserts the exact failing-id set, so the suite is *observed* to fail rather than merely observed to pass). The consolidation also found two defects in the byte-sniffer variant nobody had recorded: mode `"b"` against a TEXT chunk was silently accepted, and the reject path leaked a stack slot per refused chunk.
- [ ] **Make the mode gate's BUILD assertion behavioural.** `native/build-native.sh` greps for the macro's *shape* and runs no test; the behavioural coverage exists but is opt-in. Link `security_test.c`'s load probe into a postflight stage.
- [ ] ~~Delete both `lua_load` mode escape hatches~~ — done above. OC reads `computer.lua.allowBytecode` and passes `"t"` to refuse precompiled chunks, so mode is **security-relevant**. LuaJIT 2.1 exports `lua_loadx` with the same whitelist semantics, so the gate is fully implementable — but one shim carries a build-conditional fallback that silently discards mode and another honours an `OCLJ_NOMODECHECK` env var. Either shipped by accident turns `allowBytecode=false` into a lie with no error, no log line and no failing test. Test: `load(string.dump(f))` must be refused under `allowBytecode=false`. Note the serializer legitimately loads LuaJIT bytecode via `lj_bcwrite`/`lua_loadx`, so the `"b"` path stays open internally while shut to sandbox code.
- [ ] **A C-recursion ceiling.** LuaJIT has no `nCcalls`/`LUAI_MAXCCALLS`; `lua_resume` takes no `from` and does no C-call accounting, so 5.2's protection against C-stack exhaustion by nested resume does not exist. Sandbox-reachable process kill. Not fixable in the shim — an explicit depth counter above jnlua, naturally in the CHECKHOOK watchdog.
- [ ] **Unify on the differentially-tested `lua_compare`.** The shim that booted OpenOS implements `LUA_OPLE` as `!lua_lessthan(idx2,idx1)` — 5.1 semantics, wrong for a metatable defining only `__le`. A different shim implements it via a Lua helper and measured `__le`-only tables exact. So the build that has booted a machine is the one whose comparison semantics were *not* tested.
- [x] `bit32` differentially covered for VALUES — 45/47 exact against real 5.2 across shifts >= 32, negative displacements, `arshift` sign extension and saturation, rotate masking, operand wrap and string coercion. The 2 divergences are the error-message *function-name* field only (`'?'` vs `'extract'`), which stock LuaJIT does for `string.rep` and `math.floor` too. Fix the claim in the docs, not the code.
- [ ] **Decide `luaL_requiref` deliberately, and move `_VERSION` out of `luaopen_eris`.** The shim implements 5.3 semantics (short-circuit when `_LOADED[modname]` is truthy); real 5.2 always calls `openf`. Benign today only because the skipped `luaopen_coroutine` is a no-op — but `luaopen_eris` is the ONLY site setting `_VERSION = "Lua+Eris 5.2"`, which is the string the anti-vacuity LuaJ guard reads. A single point of failure that can now be bypassed with no error.
- [ ] **Cross-build blob compatibility.** Restoring the `jit` table adds 9 permanents reachable from `_G` (163 vs 154), so a blob written by a pre-merge native and one written by the canonical native have different perms key sets. Untested: what a restore across that boundary actually does. Decide whether a build stamp is warranted so a mid-world upgrade fails loudly rather than strangely.
- [ ] Counting allocator wired to `recomputeMemory` (state created via `lua_newstate` on GC64 — never `luaL_newstate` + `setallocf` swap)
- [ ] Kernel: run GTNH machine.lua with a `bit32` shim over LuaJIT's `bit`; sandbox reports `_VERSION = "Lua 5.2"`; `persistKey` nil path (LuaJ semantics)
- [ ] **Value disposal (`__gc`)**: LuaJIT finalizes userdata and cdata, never tables, so OC's only route to `Value.dispose()` -- a `__gc` on machine.lua's TABLE proxy -- is severed. Fix in OUR native push path, not the serializer or the machine.lua fork: give the Value userdata (which already exists, behind the proxy) a Value-specific metatable whose C `__gc` calls `dispose` before releasing the global ref. ~15 lines; serializer cost zero. Intern Values at the push site (JNLua does not, so stock OC can double-dispose today). Note this bug does not exist until we ship: on stock OC table `__gc` fires and disposal works, so it is one we would INTRODUCE -- which is why it belongs on v1, the first build that could manifest it. Mechanism (g) subsumes the AE2 `NetworkControl` case by restoring the general route; a belt-and-braces dispose on the machine-stopped hook would be deliberately redundant, and lives in **OpenComputers' own `NetworkControl.scala`, not ours** -- an upstream patch or a fork edit, not a task on this list. It is called out only because it is the single leak whose consequences are permanent and compounding rather than bounded by a power cycle. See [../docs/research/gc-dispose-leak.md](research/gc-dispose-leak.md).
- [ ] Component-call protocol: direct calls + `LimitReachedException` → zero results → machine.lua's synchronized-call fallback; `runSynchronized` closure resume
- [ ] Simple wall-clock watchdog (soft error → hard state-kill after resume returns) — sufficient while interpreter-only, since hooks always fire in the interpreter
- [ ] Native build pipeline: pinned LuaJIT v2.1 commit, `LUA52COMPAT` + **`CHECKHOOK`**, static single-lib shim; win-x64 + linux-x64 first, extraction/probe loader cloned from `LuaStateFactory`. **CHECKHOOK is not optional once the JIT is on, and the reason is stronger than timeout enforcement: OC's kernel does not BOOT without it.** `machine.lua`'s first executable statement is `calcHookInterval()`, which spins `while bogomipsBusy do ... end` until a count hook clears the flag; on a stock build that loop compiles to a trace, the hook never fires, and the machine hangs in mcode during sandbox construction. Measured: hang with stock, every milestone green with CHECKHOOK, nothing else changed. Unplanned bonus — that loop is a live, in-kernel, end-to-end regression test for the watchdog's central mechanism.
- [ ] **Sandbox constraints** — cheaper than serializer features, and several are one-liners. Do not expose `ffi` or `string.buffer` ([ffi-decision.md](ffi-decision.md)); do not expose `newproxy`; make `component.list` return `next, list, nil` and restructure `componentProxy.__pairs` so neither keeps a hash-order cursor in a closure upvalue (measured: 11/12 pads diverge before, 12/12 exact after — see [forin-iterator-gap.md](forin-iterator-gap.md)); put the pure-Lua `gmatch` on the sandbox unconditionally, or set `SHORT_STRING` to 0. Full ranked list in [research/os-shape-census.md](research/os-shape-census.md).
- [ ] **Perms flattener** (Java): sorted DFS with dotted names, matching `PersistenceAPI.scala`, **plus** a sweep of function-valued upvalues of every named builtin. Real OC does the sort but not the sweep, so `for _,v in ipairs(t)` with a yield in the body fails to save on stock — measured on a live machine: `perms[ipairs aux] = nil` while `perms[ipairs]` is present, and the aux is a stable per-call object that simply is not permed. Two objects on our build.
- [ ] Validate the whole of the above **in the harness** (v0.5) before touching Minecraft
- [ ] In-game validation, LAST: OpenOS boot, editor, network, a compute benchmark vs the Lua 5.3 CPU

## v2 — JIT on

The headline release: enable the JIT (`luaopen_jit`, then hide `jit`/`debug` from the sandbox) and make the watchdog trace-proof.

- [ ] **JIT x persist interaction (unmeasured risk):** `persist()` calls `lj_trace_flushall` whenever it reaches a thread containing a generic-for loop — and an OS whose event dispatcher is a `pairs` loop is parked inside one essentially always. A server autosaving on a timer would then flush the whole VM's traces on every save, and the JIT may never warm up in exactly the scenario the performance case is about. Candidate fix: narrow to `lj_trace_flushproto` for the affected prototypes; needs checking against the JLOOP/JITERL hazard the flush exists to prevent. **Measure before committing to v2.**
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

- [x] Feasibility study with adversarial verification (no structural blocker; suspended coroutines are pure Lua-stack state; continuation set closed at 9 entries; cont_stitch aux slot handled)
- [x] **M0 — validation spike** *(done 2026-09-01)*: read-only frame-chain walker, [../prototype/framewalk](../prototype/framewalk/). All 7 invariants hold across 8 suspended threads in 7 frame shapes (plain yield, pcall/xpcall, `__index`/`__concat` metamethods, vararg chains with open upvalues, nested coroutines, JIT-hot loop). Two schema corrections found: the `cont_stitch` saved trace is at **framebase − 5** (not the provisionally assumed slot), and frame-type decoding must test `frame_islua()` before `frame_typep()` or pcall frames are silently mislabeled.
- [ ] M0b — rerun the walker against real OC kernel states once the JNI bridge exists (v1), to confirm machine.lua's actual suspend shapes match the catalog
- [x] **M1 — data serializer** *(done 2026-09-01)*: [../serializer](../serializer/) — tables/strings/numbers with shared-ref map, cycles, metatables, perms-at-every-node, spkey literal semantics; fingerprinted header + CRC32; 84 tests pass. Survived a four-lens adversarial review that found and fixed **two crash bugs** (a SIGSEGV from an unvalidated permanent type byte, and an uncatchable C-stack overflow from an unclamped `maxrec`) plus a silent write-only-save-data defect; all ten findings have regression tests. See [../serializer/README.md](../serializer/README.md).
- [x] **M2 — code** *(done 2026-09-01)*: Lua closures via `lj_bcwrite`/`lua_loadx`, upvalue identity through `lua_upvalueid`/`lua_upvaluejoin`, function environments, and the full spkey function protocol; 55 tests (M1 still 83). `debug.upvalueid` equality preserved across a restore. A second four-lens review found a **critical** ordering defect — the reader published an upvalue's owner after reading its value, so the ordinary module pattern produced write-only blobs — plus deterministic dumps, an inert `debug` setting, and a stack-budget correction; all fixed with regression tests. Prototype dedup deferred (documented). See [../serializer/README.md](../serializer/README.md).
- [x] **M3 — suspended coroutines** *(done 2026-09-01)*: [../serializer](../serializer/) — suspended threads round-trip and resume exactly where they left off, including open upvalues aliasing live frames, continuation frames, nested coroutines and the OC kernel shape. 71 tests (M1 82, M2 55), plus a 15-case cross-process suite for for-in replay. A verification+review workflow re-checked the ten design claims M3 was built on (one refuted, one materially corrected) and found **16 defects, 4 critical** — including a heap overflow reachable from an ordinary deep coroutine with no tampering. All fixed; see [../serializer/README.md](../serializer/README.md). A follow-up audit verified every fix against the code and caught one regression (the error-dead-thread fix had turned a loud refusal into write-only save data — a coroutine that dies by error does not close its open upvalues); fixed. `ipairs` is solved host-side by sweeping builtins' function-valued upvalues into perms. **`pairs` is closed** by the replay iterator (M3.1): the loop's position is never persisted, its remaining keys are, and the loop is despecialised on restore so a replacement iterator can drive it. Measured at 17 shapes × 64 hash-layout rotations = 1088 fresh-process restores, all exact (8 shapes through a third process, so the last restore resumes a loop already in replay form), against a negative control that diverges 59/64. A five-dimension adversarial review found 12 defects, 10 confirmed — including a critical one that only appears on the SECOND save through a perms prototype, which the single-round-trip suite structurally could not see. Stock OpenComputers still has this defect and fails silently (0/20).
- [ ] **M4 — protocol + integration**: spkey with pre-reserved ref slots, `settings("spkey"/"path")`, perms/uperms; bridge-side ERIS-library analog; OpenOS boot → persist mid-`pullSignal` → restore → continue. Contract already verified against a real host's call sequence by [../serializer/tests/contract.lua](../serializer/tests/contract.lua) — note `configure()` runs at the top of **every** persist *and* unpersist, so `settings` must be re-settable. **Measured on a live machine and not obtainable by reading:** `machine.lua` overwrites `string.find/match/gmatch/gsub` with its own Lua closures *after* `PersistenceAPI` builds perms, so those four are serialized as **code** in essentially every real blob rather than resolved as permanents — and `gmatch` splits on `#s < SHORT_STRING` (500), tail-returning the unpersistable native C iterator below it and a persistable pure-Lua closure above. The gmatch refusal is therefore **data-length-dependent, not categorical**.
- [ ] **M4.4 — function environments diverge from stock Eris.** Every LuaJIT function carries an fenv and `getfenv(f) == _G` holds even for a closure referencing no global; 5.2 gives such a closure no `_ENV` upvalue at all. Measured on the differential rig: `eris.persist(f)` with an EMPTY perms table **succeeds on stock Eris and is refused by us** ("cannot persist a C function by value"); with `perms={[_G]='_G'}` both succeed and round-trip. So our blobs drag `_G` into closures real Eris does not, and perms becomes load-bearing where stock needs none. Ours to decide, in the serializer.
- [ ] **M4.5 — close the for-in iterator gap**: a Lua closure wrapping `next` is invisible to the replay scan and keeps the old layout dependence. Three layered tiers (prevent / declare / enumerate) plus a sound refuse-fallback, in [../docs/forin-iterator-gap.md](forin-iterator-gap.md). Gated on what OC's `componentProxy.__pairs` actually does. Interacts with the `LUA52COMPAT` build flag v1 already mandates.
- [ ] **M5 — hardening**: persist→unpersist→persist oracle in CI, randomized state fuzzing, corrupted-blob rejection, canary self-test on every load, GC-stress soak with LuaJIT assertions

## Open questions

- OC version pin: currently `1.12.58-GTNH` (2026-08-30); revisit at v1 start.
- Whether to shim JNLua's Java API (reuse OC's `LuaState` abstractions) or keep a minimal purpose-built JNI surface like CCLuaJIT. Current lean: minimal purpose-built.
- `bit32` shim semantics: LuaJIT `bit.*` returns signed 32-bit; bit32 is unsigned — normalize with `% 2^32`; needs a conformance test against PUC `bit32`.
- CHECKHOOK's measured overhead on hot loops (prototype task) — if it's large, consider offering both native builds (safe vs fast) as a server config.
- Microcontrollers/robots/drones: verify `@Architecture.NoMemoryRequirements` interaction and tier gating for the new CPU option.
