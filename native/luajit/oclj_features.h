/* native/luajit/oclj_features.h -- THE LuaJIT feature set of OC-LuaJIT,
 * written down once.
 *
 * HOW IT REACHES EVERYTHING.  native/build-native.sh copies this file into
 * the LuaJIT BUILD COPY's src/ and native/luajit/patch-features-include.sh
 * makes that copy's lj_arch.h include it straight after "lua.h".  So every
 * LuaJIT object, buildvm, and the Makefile's TESTARCH probe (which picks
 * DynASM's JIT/FFI flags) read these bytes -- and so does every translation
 * unit of ours that includes a LuaJIT internal header with
 * -I<build>/luajit-<platform>/src: native/lj52shim.c, serializer/eris_lj.c,
 * test/native/penalty_test.c, race_test.c, wd_test.c and build-native.sh's
 * stage-1b probe.  No feature macro travels on a command line any more:
 * build-native.sh refuses a LuaJIT build log that carries one.  The pinned
 * checkout (prototype/watchdog/luajit) stays pristine.
 *
 * WHY "1".  An old script that still passes -DLUAJIT_ENABLE_LUA52COMPAT
 * defines the same macro as 1, and an identical redefinition is silent; a
 * different value warns.
 *
 * THE THREE FLAGS (all mandatory, none of them tuning):
 *   LUAJIT_ENABLE_LUA52COMPAT -- OC's platform (machine.lua, OpenOS, the
 *       sandbox) is Lua 5.2 source: table.unpack, __pairs, 5.2 coroutine
 *       semantics.
 *   LUAJIT_ENABLE_CHECKHOOK -- REQUIRED TO BOOT with the JIT on:
 *       machine.lua's first statement spins waiting for a count hook, and a
 *       trace delivers one only when the recorder emits hook checks
 *       (lj_record.c:691, :2953).
 *   LUAJIT_DISABLE_FFI -- with FFI compiled in, the LEXER mints cdata:
 *       `1LL`, `2ULL`, `0x10ULL` and `3i` load as int64/uint64/complex
 *       constants (lj_lex.c:116, :127) and register package.loaded.ffi on
 *       the way.  Cdata cannot be persisted, so one such value alive at
 *       save time would cost the machine its state (by reading the save
 *       path; a function that merely holds the constant persists).  Without
 *       FFI they are a syntax error, "malformed number".
 *       docs/ffi-decision.md.
 *
 * THEY CHANGE LAYOUT.  LUAJIT_DISABLE_FFI drops global_State's
 * GCROOT_FFI_FIN slot (lj_obj.h:583-585): GG_State is 6376 bytes instead of
 * 6384 and jit_State sits 8 bytes lower (GG_OFS(J) 832, not 840); without
 * LUA52COMPAT as well it is 6360.  A translation unit that reads J through
 * G2J/L2J (lj_dispatch.h:117-118) with a different set reads the wrong
 * words.  build-native.sh's stage 1b and lj52_newstate refuse a mismatch.
 *
 * EVERY OTHER OPTION THE PINNED LuaJIT TESTS (a census of its LUAJIT_*
 * conditionals, 2026-10-16) THAT CHANGES A STRUCTURE, THE BYTECODE THE
 * PARSER EMITS, THE UNWINDER, OR WHAT A BUILD GATE MEASURES IS REFUSED
 * BELOW, in the archive and in our translation units alike.  A GG_State size check cannot
 * see most of them.  To take one, change this file deliberately.  Debug aids
 * that change none of those (LUA_USE_ASSERT, LUA_USE_APICHECK,
 * LUAJIT_USE_VALGRIND, LUAJIT_USE_PERFTOOLS) are not refused.
 */
#ifndef OCLJ_FEATURES_H
#define OCLJ_FEATURES_H

/* The marker our translation units check: each one that includes a LuaJIT
 * internal header refuses to compile without it (#error). */
#define OCLJ_LUAJIT_FEATURES 1

#define LUAJIT_ENABLE_LUA52COMPAT 1
#define LUAJIT_ENABLE_CHECKHOOK 1
#define LUAJIT_DISABLE_FFI 1

/* OUR ADDITIONS TO LuaJIT'S LIBRARIES.  Since 2026-10-13 our LuaJIT is a
 * fork that may take Lua 5.3 functions (docs/roadmap.md, the 5.2-class
 * row).  Each addition is named here, once: it puts new C functions within
 * reach of _G -- new permanents in every blob -- so serializer/eris_lj.c
 * names it in the blob fingerprint's VM-features word from this macro, and
 * build-native.sh checks the word against what luajit.exe does.
 *   OCLJ_LIB_STRPACK -- string.pack, string.packsize and string.unpack, Lua
 *       5.3.6's whole format language (native/luajit/oclj_strpack.c,
 *       registered in lib_string.c by native/luajit/
 *       patch-strpack-register.sh).  oclj_strpack.c refuses to compile
 *       without it.  Word token "pack1".  Two deliberate deviations from
 *       5.3.6, both because every number is a double: an unpacked integer
 *       beyond 2^53 is rounded to the nearest double, never refused; 'l' and
 *       'L' are 8 bytes on every platform. */
#define OCLJ_LIB_STRPACK 1

#if defined(LUAJIT_USE_SYSMALLOC)
#error "OC-LuaJIT (oclj_features.h): LUAJIT_USE_SYSMALLOC compiles lj_alloc out; lj52shim.c keeps every state in its own lj_alloc arena (lj52_back)"
#endif
#if defined(LUAJIT_DISABLE_JIT) || defined(LUAJIT_DISABLE_GC64)
#error "OC-LuaJIT (oclj_features.h): the JIT and GC64 are part of the feature set (a foreign allocator needs GC64 on x64); both change GG_State"
#endif
#if defined(LUAJIT_NUMMODE)
#error "OC-LuaJIT (oclj_features.h): LUAJIT_NUMMODE changes the number representation (DUALNUM); eris_lj's restore is untested across it"
#endif
#if defined(LUAJIT_ENABLE_TABLE_BUMP) || defined(LUAJIT_DISABLE_PROFILE)
#error "OC-LuaJIT (oclj_features.h): LUAJIT_ENABLE_TABLE_BUMP and LUAJIT_DISABLE_PROFILE change jit_State/GG_State"
#endif
#if defined(LUAJIT_USE_GDBJIT)
#error "OC-LuaJIT (oclj_features.h): LUAJIT_USE_GDBJIT grows GCtrace (lj_jit.h:283), which lj52shim.c's flush accounting multiplies; no size gate sees it"
#endif
#if defined(LUAJIT_DISABLE_BUFFER)
#error "OC-LuaJIT (oclj_features.h): LUAJIT_DISABLE_BUFFER renumbers fast functions and error ids; string.buffer's exposure is undecided"
#endif
#if defined(LUAJIT_DISABLE_JITUTIL) || defined(LUAJIT_DISABLE_VMEVENT)
#error "OC-LuaJIT (oclj_features.h): the build gates and the tests read traces through jit.util and jit.attach"
#endif
#if defined(LUAJIT_DISABLE_DEBUGINFO) || defined(LUAJIT_DISABLE_TAILCALL)
#error "OC-LuaJIT (oclj_features.h): LUAJIT_DISABLE_DEBUGINFO and LUAJIT_DISABLE_TAILCALL change the bytecode the parser emits, and so every blob"
#endif
#if defined(LUAJIT_SECURITY_PRNG) || defined(LUAJIT_SECURITY_STRHASH)
#error "OC-LuaJIT (oclj_features.h): the VM security knobs stay at LuaJIT's defaults (lj_arch.h); lj52shim.c seeds each arena with lj_prng_seed_secure"
#endif
#if defined(LUAJIT_SECURITY_STRID) || defined(LUAJIT_SECURITY_MCODE)
#error "OC-LuaJIT (oclj_features.h): the VM security knobs stay at LuaJIT's defaults (lj_arch.h); lj52shim.c seeds each arena with lj_prng_seed_secure"
#endif
#if defined(LUAJIT_NO_UNWIND) || defined(LUAJIT_UNWIND_INTERNAL)
#error "OC-LuaJIT (oclj_features.h): with internal unwinding an error raised in a helper called from JIT-compiled code (mainly out-of-memory, which the RAM cap raises) goes to the panic handler, not to pcall (lj_err.c:54-56); LJ_NO_UNWIND also changes CFRAME_SIZE (lj_frame.h:173-177)"
#endif

#endif
