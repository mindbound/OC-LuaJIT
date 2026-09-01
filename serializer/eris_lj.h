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
#define ERIS_LJ_FORMAT 2

/* Build fingerprint: refuse blobs from a different natives build.
 * ERIS_LJ_COMMIT is injected by the build (-DERIS_LJ_COMMIT=...). */
#ifndef ERIS_LJ_COMMIT
#define ERIS_LJ_COMMIT "unpinned"
#endif

LUALIB_API int luaopen_eris_lj(lua_State *L);

#endif
