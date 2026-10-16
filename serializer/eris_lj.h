/*
 * eris_lj.h — Eris-API-compatible serializer for the pinned LuaJIT build.
 * Track P, milestone M2: data graphs (nil/bool/number/string/table with
 * metatables, cycles, shared references), permanents substitution, the full
 * spkey protocol, and Lua closures — prototypes, upvalue identity (sharing
 * survives a round trip) and function environments. Threads and userdata
 * arrive in M3.
 *
 * NOTE: from M2 a blob carries LuaJIT bytecode and the spkey protocol calls
 * restored closures, so blobs must come from trusted storage. See the
 * trust-boundary comment in eris_lj.c.
 *
 * Lua-visible API (mirrors fnuecke/eris):
 *   eris.persist([perms,] value)  -> binary string
 *   eris.unpersist([uperms,] str) -> value
 *   eris.settings(name[, value])  -> current value; set with 2 args
 *     settings: "spkey" (string), "path" (bool), "maxrec" (number),
 *               "debug"/"spio" (accepted, unused in M1)
 */

#ifndef ERIS_LJ_H
#define ERIS_LJ_H

#include "lua.h"

#define ERIS_LJ_VERSION "eris-lj 0.3 (M3)"

/* Format version written into every blob header. Bump on ANY change.
 * 2: threads, and generic for-in loops rewritten into replay form. */
#define ERIS_LJ_FORMAT 3

/* Build fingerprint: refuse blobs from a different natives build.  It is
 * ERIS_LJ_COMMIT|LUAJIT_VERSION|ERIS_LJ_SERHASH|VM-features word (eris_lj.c).
 * ERIS_LJ_COMMIT is injected by the build (-DERIS_LJ_COMMIT=...). */
#ifndef ERIS_LJ_COMMIT
#define ERIS_LJ_COMMIT "unpinned"
#endif

LUALIB_API int luaopen_eris_lj(lua_State *L);

/* sizeof(GG_State) as eris_lj.o was compiled to see it.  lj52_newstate and
 * test_main.c compare it with lua_newstate's first allocation -- the GG_State
 * as libluajit.a lays it out -- and refuse a mismatch (THE FEATURE CHANNEL in
 * eris_lj.c). */
size_t eris_lj_ggsize(void);

#endif
