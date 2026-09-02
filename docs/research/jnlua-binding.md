# The binding: OC's JNLua drives LuaJIT, and a real machine boots on it

The question that swung the largest work item by 4x: can OpenComputers' own
repackaged JNLua drive LuaJIT, or must we hand-write a bridge?

**Answered by building and running it: REUSE.** Real OpenOS 1.8.9 boots to a
shell on LuaJIT through unmodified OC-JNLua, with our serializer substituted for
Eris, persists through OC's real PersistenceAPI, and resumes mid-execution --
with the JIT ON and OC's memory limiting at its default. 2026-09-01.

Changes to OpenComputers' own code: **zero**. jnlua.c (2420 lines) compiles with
a force-included shim header, 0 errors and 0 warnings, `git status --porcelain`
empty. The Java layer is the untouched OC-JNLua jar; ocelot-brain's
`NativeLua52Architecture` and `LuaStateFactory` are untouched.

## How far it got

ALL SIX MILESTONES (a)-(f), and — new this session — with the JIT ON and with OC's memory limiting left at its DEFAULT.

Three arms each built a LuaJIT-backed libjnlua52-windows-x86_64.dll and drove it through ocelot-brain. I re-derived and then extended the boot arm's result rather than inheriting it, because its own `final_luajit*.log` files show FAIL at (b) — the passing LuaJIT runs live in `scratchpad/work_r1/`, and the `final_*` files are the JIT-on failures. Verified evidence, all paths under .../b355bc57-.../scratchpad/:

Prior arm, JIT OFF, memory limiting OFF (work_r1/jitoff.log, rep1-3.log, openos_jitoff.log; 3/3 repeats):
(a) LuaState opens; (b) machine.lua sandbox builds; (c) BIOS runs (boot nonce 380613); (d) real OpenOS 1.8.9 to a `/home #` shell; (e) component.invoke/gpu.set round-trips; (f) eris.persist -> 150,576-byte blob through OC's real PersistenceAPI, restore resumes (nonce identical, counter 107->189, suspended for-in coroutine intact). Banner read "(0k RAM)" vs the control's "(1024k RAM)".

MY RUNS (work_r1/checkhook_*.log, noswap_*.log; arm7/ build):
- CHECKHOOK build, JIT ON, disableMemoryLimit:true — rigbios 2/2 runs FAILURES: 0, all of a,b,c,e,f1,f2; OpenOS FAILURES: 0, shell + 150,574-byte blob + restore.
- CHECKHOOK build + one-line allocator fix, JIT ON, disableMemoryLimit:FALSE (OC's default) — rigbios FAILURES: 0 with `computer.freeMemory()` = 1048576 (was 0); OpenOS boots to `/home #` printing "OpenOS 1.8.9 (1024k RAM)", persists 150,611 bytes, restores. FAILURES: 0.
- Negative control, same CHECKHOOK build WITHOUT the allocator fix, memory limit on: `java exit=127`, dead before milestone (a), no Java exception, no hs_err — Blocker 2 reproduced and shown orthogonal to the JIT.

LuaJ GUARD: honoured on every reported result, mine included. Each log carries `includeLuaJ = false`, `architecture pinned to NativeLua52Architecture`, and an in-VM fingerprint read out of the live sandbox: `native=luajit/LuaJIT 2.1.ROLLING | _VERSION=Lua+Eris 5.2 | eris.version=eris-lj 0.3 (M3) / 1ee778a4|LuaJIT 2.1.ROLLING / fmt=2`. A LuaJ fallback cannot produce that string. Not yet closed: (e) component.invoke was only exercised on the synthetic BIOS workload, not inside OpenOS; and nothing has run in Minecraft.

## The shim, measured

MEASURED, three independent implementations, replacing the prior spike's unverified 350-450:
- arm6/nat (the one that boots): lj52shim.c 399 + lj52shim.h 92 = 491 lines
- armDROPIN/shim: lj52compat.c 419 + .h 119 = 538 total / 357 code
- rt (differential arm): lj52shim.c 327 + .h 142 = 469 lines
Converged answer: ~500 lines of C, wc -l, three times, independently. Call it 450-550. The prior figure is re-established, slightly low.

Changes to OC's own code: ZERO. jnlua.c (2420 lines, OC-JNLua master @ da3d4d4, `git status --porcelain` empty) compiles with `-include lj52shim.h` and no edits — 0 errors, 0 warnings. The Java layer is the untouched OC-JNLua-20230530.0.jar. ocelot-brain's NativeLua52Architecture/LuaStateFactory untouched. Adding my one-line allocator fix keeps that property: it is a `#define lua_setallocf(L,f,ud) ((void)0)` in the shim header, not a jnlua.c patch, so the "rewrite the marshalling layer" branch (1,200-1,600 C + 400-600 Java) is dead by measurement, not by argument.

Composition of the ~500: ~110 is a from-scratch bit32 (LuaJIT ships signed `bit`; 5.2 wants unsigned `bit32`; `LUA_BITLIBNAME` must be #undef'd first) that ANY strategy needs. The rest is 18 mechanical divergences (12 trivial, 6 real implementations, 0 impossible) plus one hard `#error` on LUA_VERSION_NUM which also fixes the exported JNI symbol suffix. The two most expensive items are invisible to a compiler — both allocator defects, ~60 lines — which is why a compile-only spike underprices this.

RESIDUAL WORK TO A CORRECT BOOTING MACHINE, in units I can defend:
1. Memory accounting — the only genuinely open item. ~45 lines inside jnlua.c: cache the jobject in a C-side map keyed by lua_State* at newstate, then have `l_alloc_checked` do JNI GetIntField/SetIntField only, with no `lua_setallocf` swaps and no `getjavastate` (i.e. no Lua API re-entry). Today my one-liner makes the cap REPORTED but not ENFORCED: totalMemory/freeMemory read 1048576 and `used` never increments (kernelMemory 1 vs the control's 174,605). A machine cannot currently run out of RAM.
2. pushcfunction warm-up: ~45 lines, memoize a GCfunc per C function pointer at state creation (see item 5).
3. C-recursion ceiling: LuaJIT has no nCcalls/LUAI_MAXCCALLS; an explicit depth counter above jnlua, naturally in the CHECKHOOK watchdog. Tens of lines.
4. Do arith/compare/len in C rather than via a Lua helper chunk if error-string fidelity matters (~60 lines).
5. Then the v1 items that were always ours: perms flattener sweep, Value `__gc` dispose, sandbox constraints.
That is days, not months, and none of it is research.

## Semantic residue -- what is papered over

PAPERED OVER, ranked by how quietly it can bite.

1. lua_load "mode" — SECURITY, and the answer is better than feared, but it is a live footgun. OC reads `computer.lua.allowBytecode` (Settings.scala:85) and passes "t" to refuse precompiled chunks, so the mode IS security-relevant. LuaJIT 2.1 exports `lua_loadx(L, reader, dt, chunkname, mode)` and lj_load.c:37-45 enforces it with the same whitelist semantics as 5.2's checkmode, so the gate is fully implementable. Two of the three shims map `lua_load`->`lua_loadx` exactly; the boot shim implements it with its own reader wrapper. BUT the rt shim carries a build-conditional fallback (`#define lua_load(L,r,d,cn,mode) lua_load((L),(r),(d),(cn))`) that silently DISCARDS the mode, and the boot shim honours an `OCLJ_NOMODECHECK` env var. Either shipped by accident turns `allowBytecode=false` into a lie with no error, no log line, and no test that fails. Ship the lua_loadx mapping, delete both escape hatches, and add a regression test that `load(string.dump(f))` is refused under allowBytecode=false. Second-order note: LuaJIT bytecode is a different, equally unsafe format, and the serializer legitimately loads it via lj_bcwrite/lua_loadx, so the "b" path must stay open internally while staying shut to sandbox code.

2. Memory accounting (see shimSize item 1) — currently reported but unenforced. Silent by construction: nothing errors, machines simply become immortal against OOM. Highest-priority residue.

3. No nCcalls / LUAI_MAXCCALLS anywhere in LuaJIT. lua_resume takes no `from` and does no C-call accounting, so 5.2's protection against C-stack exhaustion by nested resume does not exist. Dropping `from` in the shim is a non-issue; the missing ceiling is sandbox-reachable and kills the process.

4. Function environments. Every LuaJIT function carries an fenv, and `getfenv(f) == _G` holds even for a closure referencing no global; 5.2 gives such a closure no _ENV upvalue at all. Measured on the differential rig: `eris.persist(f)` with an EMPTY perms table succeeds on stock Eris and is REFUSED by eris_lj ("cannot persist a C function by value"); with `perms={[_G]='_G'}` both succeed and round-trip. Our blobs drag _G into closures real Eris does not, and perms becomes load-bearing where stock needs none. Belongs to the serializer, not the shim — an M2/M4 decision, plus a census row.

5. lua_compare LE. The boot shim (the one that booted OpenOS) implements LUA_OPLE as `!lua_lessthan(idx2,idx1)` — 5.1 semantics, wrong for a metatable defining only __le. The rt shim implements it via a Lua helper and measured __le-only tables EXACT. So the build that has booted a machine is the one whose comparison semantics were NOT differentially tested. Unify on the tested implementation.

6. bit32 is ~110 lines of new code that no differential run has exercised against 5.2's edge semantics (shifts >= 32, negative shifts, argument coercion, unsigned wrap). Silent wrong answers, not crashes.

7. Sandbox-visible identity. `unpack` exists and `unpack == table.unpack` is TRUE (FALSE on stock) — this independently reproduces census row N2 on a live machine. `_VERSION` differs by shim: the booting build reports "Lua+Eris 5.2" (verified in the fingerprint), the drop-in build reports "Lua 5.1"; one build also had LuaState.LUA_VERSION="Lua 5.1" while lua_versionnum()=502, an inconsistent pair the Java layer can see. Pick "Lua+Eris 5.2" everywhere and audit version checks.

8. Error text. Implementing arith/compare/len via a Lua helper chunk leaks its chunk name into messages ("[lj52shim]:5: attempt to perform arithmetic on local 'a'" vs "attempt to perform arithmetic on a table value"). Cosmetic until a program matches on it.

9. Registry layout: LuaJIT defines neither LUA_RIDX_MAINTHREAD nor LUA_RIDX_GLOBALS, and LuaState.register(name, fns, global=true) does a rawGet(REGISTRYINDEX, 2). Four lines to seed at newstate; omit them and the failure is a wrong-table write, not an error.

MEASURED AND NOT A PROBLEM, so nobody should spend time on it: numbers. The premise that 5.2 has an integer subtype is false — lua_Number is double on both, lua_pushinteger stores a double on both. 33 differential cases (Long round-trips, 2^53±1, Long.MAX/MIN, tostring of -0.0/inf/nan, string.format('%d'), toInteger/toNumberX coercions) are byte-for-byte identical, including out-of-range saturation. The 5.2 API translations (absindex, compare, arith incl. metamethods and string coercion, len honouring __len, rawlen, tolstring, getsubtable, requiref) are exact. Resume status codes, yield/return values, error propagation, dead-coroutine resume and yields across a Java boundary are identical; exception classes, messages, LuaError cause chaining and 4-frame stack traces match. One caution paid for in a crash: lua_absindex's pseudo-index floor must be LUA_REGISTRYINDEX, not LUA_GLOBALSINDEX — getting it wrong is an instant access violation inside lua_getsubtable.

## The JVM-killer question

JNLua's C is SAFE TO REUSE, and reuse does NOT inherit unprotected entry points — but it inherits one latent hole that must be closed with a wrapper we add.

The model is real: LuaJIT on Win x64 uses external SEH unwinding (LJ_UNWIND_EXT=1), and a luaL_error raised in an unprotected JNI entry frame kills the JVM outright (Internal Error 0xe24c4a02 = LJ_EXCODE). But jnlua.c is already written to the discipline that makes this safe: 74 occurrences of the `*_protected` pattern — every entry point pushes a static C function and runs its Lua work under lua_pcall, so a Lua error always finds a catch frame before it reaches the JNI boundary. 50,000 error unwinds through JNI-touching C frames left a real HotSpot healthy under -Xcheck:jni. We inherit the safety, not the hazard.

THE HOLE, and it is a genuine one: that discipline is airtight on 5.2 only because `lua_pushcfunction` there stores a LIGHT C function — no allocation, cannot fail. LuaJIT has no light C function type; the push goes through lua_pushcclosure, allocates a GCfunc and runs lj_gc_check. Under OC's RAM cap, that push can raise LUA_ERRMEM in the bare JNI frame BEFORE any protected frame exists. All ~40 protected entry points open this way, so all of them are exposed — the error is thrown by the very act of installing the error handler.

THE FIX IS A WRAPPER WE ADD, NOT A WEAKNESS IN THE REUSE CASE: memoize the GCfunc. At state creation, push each of jnlua's static protected functions once (while memory is plentiful) and cache them in the registry keyed by C function pointer; make the shim's `lua_pushcfunction` a registry rawget on that key. Entry then allocates nothing and cannot fail. ~45 lines, shim-only, no jnlua.c edit, and it has the side benefit of restoring 5.2's "the same C function pointer pushes an equal value" — which is what a perms table wants. One caveat the arm that wrote it flagged honestly: that identity change is untested because nothing depends on it yet.

Two related notes. First, the JVM-killer people actually hit in practice was not SEH at all — it was the allocator (below), which produces exit 127 with no hs_err and no Java exception, the hardest failure mode to diagnose in a shipped mod. Second, our own additions must keep the discipline: eris_lj's entry points are called from Lua and are therefore already inside a protected frame, so they are fine as they stand, but any future direct-from-JNI helper must be wrapped the same way.

## What this changes

FOUR THINGS CHANGE, and two of them retire "blockers" that were about to be written into the roadmap.

1. BLOCKER 1 (the JIT hang) IS DISSOLVED, and it was never a LuaJIT defect. The boot arm built LuaJIT with `XCFLAGS="-DLUAJIT_ENABLE_LUA52COMPAT"` and no CHECKHOOK (arm6/build_luajit.sh:13). The mechanism is machine.lua's own opening lines: `calcHookInterval()` runs `while bogomipsBusy do ... end`, and `bogomipsBusy` is set false ONLY inside the count hook installed by `debug.sethook(calcBogoMips, "", hookInterval)`. On a stock (non-CHECKHOOK) LuaJIT the loop compiles to a trace, the count hook never fires, the exit condition never becomes true — an infinite loop in mcode, in the first executable statement of machine.lua. That matches every symptom the arm reported: hang during sandbox construction, thread RUNNABLE forever in lua_resume, top frame unsymbolized mcode, LUA_MASKCOUNT hook never firing, everything fine with the JIT off. This project already researched, prototyped and MEASURED the fix — docs/watchdog.md:19 states verbatim that without CHECKHOOK a hook is "never [delivered] inside a self-contained compiled loop", and its results table records the stock build failing exactly this test. I rebuilt LuaJIT with `-DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_CHECKHOOK`, changed nothing else, and every milestone passes with the JIT ON (work_r1/checkhook_jiton.log, checkhook_rep2.log, checkhook_openos.log; FAILURES: 0). So the statement "the project's entire performance rationale currently does not survive its own boot test" is retracted: the rationale survives, on the build flag the roadmap already mandates for v2. It also promotes CHECKHOOK from a v2 watchdog nicety to a v1 hard requirement — OC's kernel does not boot without it — and it hands us an unplanned bonus: the bogomips loop is a live, in-kernel, end-to-end regression test for the watchdog's central mechanism.

2. BLOCKER 2 (the allocator) IS REAL, ORTHOGONAL, AND MOSTLY CHEAP. Reproduced on the CHECKHOOK build: OC default config -> `java exit=127`, dead before milestone (a). Cause confirmed by reading jnlua.c:240-296 — `controlled_newstate` calls luaL_newstate then swaps (heterogeneous allocator: LuaJIT arena blocks later handed to msvcrt free()), and `l_alloc_checked` calls `lua_setallocf` twice and `getjavastate` (a lua_getfield on the registry) from inside lua_Alloc. I removed the process kill with ONE line in the shim — `#define lua_setallocf(L,f,ud) ((void)0)`, ignoring all three swaps and keeping the libc allocator lj52_newstate installs — and with OC's DEFAULT `disableMemoryLimit:false` plus the JIT on, real OpenOS 1.8.9 boots to `/home #` printing "(1024k RAM)", persists 150,611 bytes and restores, FAILURES: 0 (work_r1/noswap_openos.log, noswap_mem.log). What remains is accounting, not crashing: `used` never increments, so freeMemory sits at the cap and a machine cannot run out of RAM. That is the ~45-line jnlua.c patch described above, and it is the ONE integration item I would still call unknown-ish rather than mechanical. NOTE THE HARD DEPENDENCY: this only works because the pinned LuaJIT is GC64 — lj_state.c guards lua_newstate with `#if LJ_64 && !LJ_GC64`, so a non-GC64 x64 build has no public custom-allocator entry point and this whole approach is blocked. That belongs in the build pipeline as an assertion, not a comment.

3. "PLUMBING, NOT RESEARCH" — upheld with one amendment. Every layer transliterates; the reuse verdict is decisive; but the three allocator/OOM items are process-kill-grade with no hs_err and no Java exception, so they should be called PLUMBING WITH TWO SHARP EDGES: the allocator, and the pushcfunction-under-cap hole. Neither is research; both are the kind of bug that ships.

4. OCELOT-BRAIN'S ADOPTION IS VINDICATED BEYOND ITS BRIEF. It did not merely provide a boot test — it produced the differential oracle (the genuine OC 5.2 + real Eris native loading the same OC-JNLua classes, ~90 measured cases in nine areas) that killed several inherited assumptions, and it caught the two allocator defects that were structurally invisible to the compile-only spike. Keep the rig: the four DLL variants, the fingerprint guard, and the same-session stock control are the cheapest asset this project has.

ROADMAP EDITS I would make: move CHECKHOOK from v2 to v1 (kernel-critical, not watchdog-optional); add an explicit "allocator strategy" line to v1 next to the existing "counting allocator wired to recomputeMemory" bullet, which is now MEASURED as the critical path rather than assumed; add "assert LJ_GC64 at build time"; add the lua_loadx mode-enforcement test to the v1 sandbox-constraints bullet; and add the fenv/perms divergence as an M2 decision on Track P plus a row in the shape census. Nothing in the serializer's own contract changes — eris_lj drove a real OpenOS persist/restore through OC's unmodified PersistenceAPI, which is the strongest evidence it has had.

Two smaller corrections to inherited facts: the incompatibility list is 18 divergences against OC-JNLua MASTER (meson, libjnlua52/53/54), not the "eris" branch — LUA_ERISLIVE appears nowhere in the jnlua.c ocelot-brain consumes, and LuaJIT 2.1 already ships lua_copy/lua_tointegerx/lua_tonumberx/lua_loadx/lua_upvalueid/LUA_OK. And the eris substitution is one line: jnlua's entire eris surface is `luaL_requiref(L, LUA_ERISLIBNAME, luaopen_eris, 1)`, which our `luaopen_eris_lj` already satisfies.

I wrote nothing under C:/Users/astro/Downloads/OC-LuaJIT; `git status --porcelain` is byte-identical to the session-start snapshot. My artifacts: scratchpad/arm7/ (CHECKHOOK LuaJIT + two DLL variants, checkhook_only.dll preserved) and scratchpad/work_r1/checkhook_*.log, noswap_*.log, ch.conf, chmem.conf.


---

# Corrections after consolidation

This note was written from the pre-consolidation state, when the result existed
only as seven divergent scratchpad variants. Consolidating them into
`native/lj52shim.{c,h}` proved nine things wrong or stale here. Recorded rather
than silently edited, because two of the corrections are about claims this
document made without the evidence it implied.

**C1 - shim size.** The headline "~500 lines, measured three times
independently, call it 450-550" no longer describes what ships: the canonical
shim is **868 lines** (615 + 253). The ~500 figure survives as a rough CODE
estimate; the growth is comments and rationale blocks. Stop quoting 450-550 as
the size of the deliverable.

**C2 - a measurement this document credited but never had.** It said "the rt
shim implements [`lua_compare` LE] via a Lua helper and measured `__le`-only
tables EXACT", and recommended unifying on it. `rt/runs/` contains four JVM
crash dumps and two pairs of zero-byte files. The recommendation was *right*
and the merge followed it -- but on grounds this document did not actually
possess. The measurement now genuinely exists: `security_test` LE1-LE8, 8/8,
including "LUA_OPLE fired `__le` once and `__lt` never".

**C3 - the boot shim's byte-sniffer was worse than recorded.** This note flagged
only rt's dropped mode and the env-var bypass, treating the sniffer as an
acceptable third option. The negative control proved two further defects in it:
mode `"b"` against a TEXT chunk was silently **accepted** (the gate was
one-way), and the reject path left **+2 on the stack** where 5.2 promises +1 --
one leaked slot per refused chunk, in the state OC's kernel shares. The variant
that actually booted OpenOS was itself defective here.

**C4 - the pushcfunction fix does not satisfy this document's own security
argument, and this is the consequential one.** The "JVM-killer" section
prescribes an EAGER memo: *"at state creation, push each of jnlua's static
protected functions once (while memory is plentiful) ... entry then allocates
nothing and cannot fail."* The shipped memo is **lazy** -- the cold path still
calls `lua_pushcclosure`, which allocates and runs `lj_gc_check`. jnlua.c has
**37** `lua_pushcfunction(L, *_protected)` sites, each executing in a bare JNI
frame *before* its pcall, so the FIRST push of each can still raise
`LUA_ERRMEM` with no protected frame above it. **It is invisible today only
because the RAM cap is not enforced** -- see the sequencing trap in
[../roadmap.md](../roadmap.md). The warm-path benefit and the restored 5.2
push-identity are real and tested (0 bytes over 20000 warm pushes); the
*cannot-fail* property is not delivered.

**C5 - the JIT was on, but the `jit` table was a string.** Nothing here noticed
that in every pre-merge build `luaopen_jit`'s leftover scratch value overwrote
the registered table, making `jit.on`/`jit.off`/`jit.status` unreachable from
Lua. Confirmed as a real pre-merge regression: runs against the arm7 DLL fail
`jit.status() = NO-JIT` where the merged DLL passes. The "blocker dissolved"
conclusion stands -- the JIT itself was running -- but the published fingerprint
should carry the `jit=` field it now has.

**C6 - minor.** The stopgap ships as
`((void)(L),(void)(f),(void)(ud))`, not `((void)0)`, for `-Wextra` cleanliness.
And `LUA_ERRGCMM` is now pinned at 7; several siblings used 6 and silently
aliased LuaJIT lauxlib's `LUA_ERRFILE`.

**C7, C8, C9 - three items listed here as open are now CLOSED.**
`component.invoke` is exercised *inside OpenOS* (six probes through OpenOS's own
component library, passing before the persist and again after the restore, with
the post-restore probe proven fresh by a resumed timer closure). `bit32` is
differentially covered for values -- 45/47 exact across shifts >= 32, negative
displacements, `arshift` sign extension and saturation, rotate masking, operand
wrap and string coercion; the only divergence is the error-message *function
name* field, which is LuaJIT-wide rather than ours. And the registry layout is
seeded at newstate (`registry[1]` = main thread, `registry[2]` = `_G`).

**New material this note could not have contained:** restoring the `jit` table
adds **9 permanents** reachable from `_G` (163 vs 154), so blobs are only
guaranteed to round-trip within one build lineage; and `luaL_requiref`
implements Lua 5.3 semantics (short-circuit on `_LOADED`) rather than 5.2's
unconditional call -- benign today only because the skipped `luaopen_coroutine`
is a no-op.
