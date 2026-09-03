/* lj52shim.h -- the Lua 5.2 C API surface that OpenComputers' OWN repackaged
 * JNLua (li.cil.repack.com.naef.jnlua, JNLUA_APIVERSION 4, "eris" branch)
 * requires and that LuaJIT 2.1 (Lua 5.1 ABI) does not provide.
 *
 * HOW IT IS USED
 *   gcc -include lj52shim.h ... OC-JNLua/native/src/jnlua.c
 * jnlua.c is compiled BYTE-IDENTICAL to upstream. Force-including this header
 * ahead of its first line rebinds the 5.2 calls it makes onto LuaJIT. Every
 * entry below corresponds to a compile error or a semantic difference measured
 * against the real OC-JNLua source, not against upstream naef/jnlua.
 *
 * WHAT IS DELIBERATELY *NOT* HERE
 *   lua_copy, lua_tonumberx, lua_tointegerx. jnlua.c calls all three, but
 *   LuaJIT 2.1 exports all three natively (lua.h:352-354); shimming them would
 *   shadow the real implementations with worse ones.
 *
 * PROVENANCE
 *   This is the canonical merge of the divergent shim variants produced during
 *   the JNLua-on-LuaJIT spike. The base is the lineage that booted real OpenOS
 *   1.8.9 with the JIT on through OC's real PersistenceAPI -- the only lineage
 *   that turns the JIT on at all, and the only one that emits the _OCLJ_NATIVE
 *   fingerprint the LuaJ guard depends on. Three defects in that lineage are
 *   fixed here and are called out at their sites:
 *     - lua_load half-enforced its `mode` and had an env-var bypass
 *     - lua_compare's LUA_OPLE used the 5.1 `not (b < a)` fallback
 *     - bit32 normalised operands by truncation instead of modulo 2^32
 *   See CANON/README.md for the full accept/reject list.
 */
#ifndef LJ52SHIM_H
#define LJ52SHIM_H

#include <stddef.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

/* jnlua.c selects its JNI class name and its exported symbol suffix off
 * LUA_VERSION_NUM: 502 gives li.cil...jnlua.LuaState with no suffix, which is
 * the class ocelot-brain and OC actually load. We present the 5.2 shape, so we
 * must answer 502 even though the engine underneath is a 5.1 ABI. */
#undef LUA_VERSION_NUM
#define LUA_VERSION_NUM 502

#ifndef LUA_OK
#define LUA_OK 0
#endif

/* 5.2 adds LUA_ERRGCMM (an error raised inside a __gc metamethod). LuaJIT has
 * no such status, but jnlua.c switches on the constant, so it must exist AND
 * must not alias a status LuaJIT can actually return. LuaJIT returns 0..5 and
 * lauxlib defines LUA_ERRFILE as LUA_ERRERR+1 == 6, so 7 is the first free
 * value. (Several sibling variants used 6 and silently aliased LUA_ERRFILE,
 * which would report a file-open failure as a GC-metamethod error.) */
#ifndef LUA_ERRGCMM
#define LUA_ERRGCMM 7
#endif

/* 5.2 arithmetic and comparison opcodes (lua.h, 5.2.4). */
#ifndef LUA_OPADD
#define LUA_OPADD 0
#define LUA_OPSUB 1
#define LUA_OPMUL 2
#define LUA_OPDIV 3
#define LUA_OPMOD 4
#define LUA_OPPOW 5
#define LUA_OPUNM 6
#endif
#ifndef LUA_OPEQ
#define LUA_OPEQ 0
#define LUA_OPLT 1
#define LUA_OPLE 2
#endif

/* OC asks for Library.BIT32 by the 5.2 name; LuaJIT's lualib.h already defines
 * LUA_BITLIBNAME as "bit" for its own SIGNED BitOp library. Renaming the
 * constant is not enough on its own -- see luaopen_bit32 in the .c, which is a
 * real 5.2 bit32 and NOT an alias for luaopen_bit. */
#undef LUA_BITLIBNAME
#define LUA_BITLIBNAME "bit32"
#ifndef LUA_COLIBNAME
#define LUA_COLIBNAME "coroutine"
#endif
#define LUA_ERISLIBNAME "eris"

/* 5.2's lua_Unsigned is a 32-bit unsigned type (unsigned LUAI_UINT32). */
typedef unsigned int lua_Unsigned;

/* ------------------------------------------------------------------ *
 * arity / signature changes
 * ------------------------------------------------------------------ */

/* 5.2: lua_resume(L, from, nargs). LuaJIT: lua_resume(L, nargs). 5.2 uses
 * `from` only to maintain a resume chain for error reporting and for the
 * nCcalls budget; dropping it changes nothing observable through jnlua. */
#define lua_resume(L, from, n) lj52_resume((L), (from), (n))

/* lua_load: THE MODE GATE. ------------------------------------------------
 * 5.2's lua_load takes a `mode` string ("t", "b", "bt", or NULL) and refuses a
 * chunk whose actual form is not listed. OC reads computer.lua.allowBytecode
 * (Settings.scala) and passes "t" to forbid precompiled chunks.
 *
 * LuaJIT 2.1 exports lua_loadx() with EXACTLY 5.2's contract and enforces it
 * with the same whitelist (lj_load.c:37-49: for each character of mode, clear
 * the reject flag if it matches 'b' for a bytecode stream or 't' for source;
 * otherwise throw LUA_ERRSYNTAX "attempt to load chunk with wrong mode").
 * A mode of NULL disables the check, which is also 5.2's behaviour. So the
 * gate is a one-line delegation and needs no reader wrapper at all.
 *
 * This replaces a hand-rolled `lj52_load` that sniffed the stream's first byte
 * for 0x1B. That sniffer had three defects, all measured:
 *   1. getenv("OCLJ_NOMODECHECK") disabled it entirely at run time;
 *   2. it enforced only ONE direction -- mode "b" against a TEXT chunk was
 *      silently accepted, where 5.2 and lua_loadx both refuse;
 *   3. its reject path leaked a stack slot. The wrapping reader returns NULL
 *      on its first call, so lua_load compiles an EMPTY chunk and pushes a
 *      function; the sniffer then pushed its error string ON TOP, leaving +2
 *      where 5.2 leaves +1. jnlua's load_protected assumes exactly one value,
 *      so every refused chunk leaked a slot into the state shared with OC's
 *      kernel, which died later as Error.InternalError pointing nowhere.
 * There is deliberately NO build flag and NO environment variable that can
 * reintroduce any of that: this is a plain unconditional macro. build-native.sh
 * greps the tree for OCLJ_NOMODECHECK and LJ52_DROP_LOAD_MODE and refuses to
 * build if either reappears.
 *
 * The "b" direction stays open to OUR OWN serializer: serializer/eris_lj.c
 * calls lua_loadx(..., "b") directly (eris_lj.c:1675) to load the LuaJIT
 * bytecode it wrote with lj_bcwrite, and it is compiled WITHOUT this header
 * force-included, so no macro here can reach it. Do not "fix" the bytecode
 * question by refusing bytecode globally -- that breaks unpersist. */
#define lua_load(L, r, d, cn, mode) lua_loadx((L), (r), (d), (cn), (mode))

/* ------------------------------------------------------------------ *
 * allocator ownership
 * ------------------------------------------------------------------ */

/* PUC Lua's luaL_newstate() installs a plain realloc/free allocator, so
 * jnlua.c can swap its own realloc/free-based allocator in and out at will --
 * including the swap it performs immediately before lua_close(). LuaJIT's
 * luaL_newstate() instead installs its OWN internal allocator (lj_alloc,
 * VirtualAlloc/mmap-backed). Handing those blocks to libc free() at close time
 * corrupts the heap and takes the JVM down with no Java-visible error.
 * lj52_newstate() therefore creates the state with a libc allocator from
 * birth; only a GC64 build tolerates a foreign allocator on x64, which
 * build-native.sh asserts at stage 1b rather than letting it surface as a heap
 * corruption at close time. */
#define luaL_newstate() lj52_newstate()

/* ------------------------------------------------------------------ *
 * memory accounting -- OC's per-machine RAM cap, actually enforced
 * ------------------------------------------------------------------ */

/* WHAT THIS REPLACES.  Until this landed, lua_setallocf was a no-op macro and
 * OC's RAM cap was REPORTED but never ENFORCED: computer.freeMemory() returned
 * the full module size forever and NativeLuaArchitecture's
 *     kernelMemory = math.max(getTotalMemory - getFreeMemory, 1)
 * bottomed out at its literal floor of 1 on every run.  A program could not
 * run out of RAM; a runaway allocation ate the SERVER's heap instead of
 * failing inside the sandbox.
 *
 * WHY THE OBVIOUS FIX KILLS THE JVM.  Simply letting jnlua's own
 * lua_setallocf calls through -- so that l_alloc_checked becomes the state's
 * allocator -- dies immediately after state creation with `java exit=127`, no
 * hs_err file and no Java exception.  Measured, twice, on ocelot-brain: the
 * last line of the run is "architecture pinned to NativeLua52Architecture".
 * The cause is NOT the allocator swapping (see below); it is that
 * l_alloc_checked calls getjavastate(L), which calls lua_getfield on the
 * registry -- RE-ENTERING THE VM from inside a lua_Alloc callback, with
 * g->gc.total not yet updated for the allocation in flight and possibly a
 * GCtab mid-resize.  PUC Lua tolerates that; LuaJIT does not.
 *
 * WHAT IS *NOT* THE PROBLEM, contrary to this file's earlier comment.  jnlua
 * swaps the allocator twice per allocation, and that reads alarming, but on
 * LuaJIT lua_setallocf is literally two stores into global_State
 * (lj_api.c:1297) -- it cannot fail, allocate, or re-enter.  The swap is free.
 *
 * HOW IT WORKS NOW.  lj52_newstate installs ONE allocator, lj52_alloc, with a
 * per-state record as its ud, and that pairing is never changed again for the
 * life of the state.  Two consequences, both load-bearing:
 *   - lua_getallocf(L, &ud) hands the record back from ANY thread of the
 *     state, because allocf/allocd live in the shared global_State.  That is
 *     the whole reason this needs no lookup table and no locking, which a
 *     server running many machines on many threads would otherwise need.
 *   - jnlua's lua_setallocf calls no longer install anything.  They are
 *     intercepted below and only flip flags on the record.
 * lj52_alloc then performs EXACTLY jnlua's accounting arithmetic, using
 * jnlua's OWN JNI accessors, handed to us at the call site by the macro below.
 * It never touches the Lua API.  That is the entire fix.
 *
 * WHY THE MACRO PASSES jnlua'S STATIC FUNCTIONS.  getluamemory, setluamemory
 * and getthreadenv are file-static in jnlua.c, so lj52shim.c cannot name them
 * -- but this macro EXPANDS INSIDE jnlua.c, where they are all in scope (they
 * are forward-declared at jnlua.c:84-88, far above every lua_setallocf call
 * site).  Borrowing them rather than reimplementing them means we reuse
 * jnlua's cached jfieldIDs and its JNIVERSION handling, and we never need a
 * JavaVM, a jclass or a GetFieldID of our own.  JNLUA_JAVASTATE comes along
 * the same way, so the registry key this file matches on is jnlua's own
 * spelling rather than a copy that could silently drift.
 * If OC-JNLua ever renames or retypes any of the four, this fails to COMPILE,
 * which is the failure mode we want.
 *
 * WHAT SANDBOX LUA SEES.  Identical to real PUC-Lua OpenComputers: a refused
 * allocation makes LuaJIT raise LUA_ERRMEM, jnlua turns that into
 * LuaMemoryAllocationException, and NativeLuaArchitecture.runThreaded maps it
 * to ExecutionResult.Error("not enough memory").
 *
 * MIGRATION HAZARD, deliberately recorded here.  OC persists kernelMemory into
 * the save (NativeLuaArchitecture.save/load).  A world written by a build with
 * accounting DEAD carries kernelMemory == 1; loading it under this build
 * recomputes totalMemory as 1 + ram, charging the real ~200 KB kernel against
 * the player's RAM and starving the machine.  Nothing has run in Minecraft
 * yet, so no such save exists -- but do not ship this to an existing world
 * without a migration that discards a kernelMemory of 1. */

#include <jni.h>

/* Signatures pinned to jnlua.c's, so a mismatch is a compile error rather than
 * a call through an incompatible function pointer. */
typedef void (*lj52_getmemfn)(JNIEnv *env, jobject obj, jint *total, jint *used);
typedef void (*lj52_setmemfn)(JNIEnv *env, jobject obj, jint used);
typedef JNIEnv *(*lj52_envfn)(void);

void lj52_setallocf(lua_State *L, lua_Alloc f, void *ud,
                    lj52_envfn envfn, lj52_getmemfn getmem,
                    lj52_setmemfn setmem, const char *jskey);

/* jnlua encodes its own intent in `ud`: l_alloc_checked is always installed
 * with ud == L, l_alloc_unchecked always with ud == NULL.  That is the signal
 * we honour -- accounting on iff ud != NULL -- so the close path
 * (lua_setallocf(L, l_alloc_unchecked, NULL) immediately before lua_close)
 * correctly stops us writing to a weak global ref the JVM is about to drop. */
#define lua_setallocf(L, f, ud)                                              \
  lj52_setallocf((L), (f), (ud), (lj52_envfn)getthreadenv,                   \
                 getluamemory, setluamemory, JNLUA_JAVASTATE)

/* The record is heap-allocated and outlives lua_close, so free it after. */
void lj52_close(lua_State *L);
#define lua_close(L) lj52_close(L)

/* The one write we have to watch: newstate_protected binds the Java LuaState
 * into registry[JNLUA_JAVASTATE] as a full userdata holding a weak global ref,
 * and close_protected sets that key to nil.  Caching the userdata's address
 * here is what lets the allocator find the jobject without lua_getfield --
 * i.e. without the VM re-entry that kills the JVM. */
void lj52_setfield(lua_State *L, int idx, const char *k);
#define lua_setfield(L, idx, k) lj52_setfield((L), (idx), (k))

/* ------------------------------------------------------------------ *
 * lua_pushcfunction
 * ------------------------------------------------------------------ */

/* On PUC Lua 5.2, lua_pushcfunction(L, f) pushes a *light C function*: a
 * tagged pointer. It allocates nothing, cannot fail, and pushing the same
 * pointer twice yields two EQUAL values. jnlua.c leans on all three: each of
 * its ~38 uses sits in a bare JNI frame, before the lua_pcall that protects
 * the real work.
 *
 * LuaJIT has no light C function type. lua.h's lua_pushcfunction is
 * lua_pushcclosure(L, f, 0), which allocates a GCfunc and runs a GC step;
 * under a real RAM cap that push raises LUA_ERRMEM with no protected frame
 * anywhere below it, and the resulting SEH exception escapes into the JVM.
 *
 * lj52_pushcfunction memoises one GCfunc per (state, C function) in a
 * registry-held table, so a warm push allocates nothing -- and, as a bonus, it
 * restores 5.2's push-identity.
 *
 * The memo alone is NOT enough, and that is why this and the accounting above
 * are one change rather than two. A memo still has to allocate the first time
 * it sees each function, and the cap can refuse that first push just as
 * readily. So lj52_pushcfunction additionally runs its whole body with
 * refusal SUSPENDED -- charged, but never refused -- which is safe only
 * because the set of functions jnlua ever pushes is fixed at compile time:
 * 38 sites, 38 distinct named statics, one apiece. The reasoning, and the two
 * measurements that pin it, are at lj52_pushcfunction in lj52shim.c.
 * There is no build flag to turn any of this off. */
#define LJ52_CF_RIDX 3
void lj52_pushcfunction(lua_State *L, lua_CFunction f);

/* ------------------------------------------------------------------ *
 * the deadline watchdog (implementation and rationale in lj52shim.c)
 * ------------------------------------------------------------------ */

/* Nested arms the watchdog can hold.  PUC Lua allows ~200 nested resumes
 * (LUAI_MAXCCALLS); OC programs that recurse through coroutine.wrap must not
 * hit a limit here first.  Beyond it arm() degrades to "inherit the enclosing
 * deadline" rather than erroring.  Part of the contract, hence here. */
#define LJ52_WD_MAXDEPTH 256
#undef lua_pushcfunction
#define lua_pushcfunction(L, f) lj52_pushcfunction((L), (f))

/* ------------------------------------------------------------------ *
 * declarations
 * ------------------------------------------------------------------ */

lua_State *lj52_newstate(void);
int        lj52_resume(lua_State *L, lua_State *from, int nargs);

int    lua_absindex(lua_State *L, int idx);
size_t lua_rawlen(lua_State *L, int idx);
int    lua_compare(lua_State *L, int idx1, int idx2, int op);
void   lua_arith(lua_State *L, int op);
void   lua_len(lua_State *L, int idx);
void   lua_pushunsigned(lua_State *L, lua_Unsigned n);
lua_Unsigned lua_tounsigned(lua_State *L, int idx);
int    luaL_getsubtable(lua_State *L, int idx, const char *fname);
void   luaL_requiref(lua_State *L, const char *modname, lua_CFunction openf, int glb);
const char *luaL_tolstring(lua_State *L, int idx, size_t *len);

/* Libraries the 5.2 shape names but LuaJIT does not ship under that name. */
int luaopen_coroutine(lua_State *L);
int luaopen_bit32(lua_State *L);
int luaopen_eris(lua_State *L);

#endif /* LJ52SHIM_H */
