/*
 * eris_lj.h — Eris-API-compatible serializer for the pinned LuaJIT build.
 * Track P, milestone M1: data graphs (nil/bool/number/string/table with
 * metatables, cycles, shared references), permanents substitution, spkey
 * literal semantics. Functions/threads/userdata arrive in M2/M3.
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

#define ERIS_LJ_VERSION "eris-lj 0.1 (M1)"

/* Format version written into every blob header. Bump on ANY change. */
#define ERIS_LJ_FORMAT 1

/* Build fingerprint: refuse blobs from a different natives build.
 * ERIS_LJ_COMMIT is injected by the build (-DERIS_LJ_COMMIT=...). */
#ifndef ERIS_LJ_COMMIT
#define ERIS_LJ_COMMIT "unpinned"
#endif

LUALIB_API int luaopen_eris_lj(lua_State *L);

#endif
