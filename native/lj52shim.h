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

/* =====================================================================
 * STOPGAP -- READ BEFORE SHIPPING. This is a known, deliberate defect.
 * ---------------------------------------------------------------------
 * WHAT IT DOES
 *   Makes lua_setallocf a no-op, so the libc allocator installed by
 *   lj52_newstate() stays in place for the whole life of the state and every
 *   allocator swap jnlua.c attempts is discarded. jnlua.c calls lua_setallocf
 *   in three places: controlled_newstate (to install l_alloc_checked for a
 *   memory-capped state), TWICE PER ALLOCATION inside l_alloc_checked itself,
 *   and unconditionally just before lua_close.
 *
 * WHY IT IS HERE
 *   The middle case is fatal on LuaJIT. l_alloc_checked re-enters the Lua API
 *   (getjavastate -> lua_getfield) from inside a lua_Alloc callback, i.e. from
 *   inside the allocator, while the VM is in an inconsistent state. With the
 *   faithful (non-neutralised) build and disableMemoryLimit:false, the machine
 *   dies silently immediately after state creation -- measured: the last log
 *   line is "architecture pinned to NativeLua52Architecture" and nothing
 *   follows. Neutralising the swap is what flipped that run into a full OpenOS
 *   1.8.9 boot plus a persist/restore round trip.
 *
 * WHAT IT COSTS -- and this is the part that must not be forgotten
 *   OC's per-machine RAM cap is REPORTED but never ENFORCED. Measured against
 *   a 1 MB machine with disableMemoryLimit:false: the OpenOS banner correctly
 *   says "1024k RAM", and computer.freeMemory() returns exactly 1048576
 *   forever -- across a full boot, a table-building workload, and a
 *   persist/restore cycle. `used` never increments. A program cannot run out
 *   of RAM; a runaway allocation consumes the SERVER's heap instead of failing
 *   inside the sandbox. That makes this unsuitable for a shared or multiplayer
 *   server as it stands. It is the same class of defect as the dropped
 *   lua_load mode this file just fixed, and it is left in only because
 *   removing it without the real fix below reintroduces a hard crash.
 *
 * THE REAL FIX (~45 lines, in jnlua's own idiom, still no jnlua.c edits)
 *   The re-entrancy exists only because l_alloc_checked needs the JNI jobject
 *   for the state and looks it up THROUGH THE LUA API on every allocation.
 *   Cache it instead:
 *     1. at newstate, cache the state's jobject (a JNI global ref) keyed by
 *        lua_State*, filled in once when jnlua binds the state to its Java
 *        LuaState;
 *     2. make the checked allocator read the cap/used fields off that cached
 *        jobject with plain JNI field access (GetLongField/SetLongField) --
 *        no getjavastate, no lua_getfield, no re-entry into LuaJIT;
 *     3. drop this macro so jnlua's own lua_setallocf calls take effect, and
 *        remove the two per-allocation swaps by holding {real_alloc, ud} in a
 *        per-state struct behind a permanent trampoline, so a "swap" becomes
 *        two field stores.
 *   build/src/ljcompat.c in the spike scratchpad prototypes step 3 (the
 *   trampoline) but was never demonstrated end to end. Landing the real fix
 *   REQUIRES a run with disableMemoryLimit:false showing computer.freeMemory()
 *   actually DECREASING and an out-of-memory error raised at the cap. Until
 *   such a run exists, do not claim the cap is enforced.
 * ===================================================================== */
#define lua_setallocf(L, f, ud) ((void)(L), (void)(f), (void)(ud))

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
 * restores 5.2's push-identity. The LUA_ERRMEM path is unreachable while the
 * allocator stopgap above is in force, but becomes reachable the moment the
 * cap is genuinely enforced, which is exactly why it is fixed now rather than
 * later. There is no build flag to turn this off. */
#define LJ52_CF_RIDX 3
void lj52_pushcfunction(lua_State *L, lua_CFunction f);
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
