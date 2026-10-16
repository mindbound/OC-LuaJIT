/* test_main.c — standalone harness for the eris-lj test suite.
 * Opens a LuaJIT state with the standard libraries plus eris, then runs
 * the Lua script named on the command line (default tests/m1.lua).
 * Exit status is the number of failing tests (0 = all pass); 2 = the
 * script did not run; 3 with a LAYOUT MISMATCH line on stderr and no banner
 * = eris_lj.c and libluajit.a disagree on LuaJIT's layout, so nothing this
 * binary reports would mean anything (a bare 2 or 3 can also be a failure
 * count). */

#include <stdio.h>
#include <stdlib.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "eris_lj.h"

/* THE LAYOUT GATE, the serializer's half (the shim's is in lj52_newstate).
 * lua_newstate's first allocator call is the GG_State, sized by
 * libluajit.a's own compile (lj_state.c:269); eris_lj_ggsize() is the same
 * struct as eris_lj.c was compiled to see it.  eris reads jit_State through
 * L2J, whose offset moves 8 bytes with LUAJIT_DISABLE_FFI. */
static unsigned long gg_calls = 0;
static size_t gg_first = 0;
static void *gg_alloc(void *ud, void *p, size_t o, size_t n)
{
  (void)ud; (void)o;
  if (gg_calls++ == 0 && p == NULL) gg_first = n;
  if (n == 0) { free(p); return NULL; }
  return realloc(p, n);
}

int main(int argc, char **argv)
{
  const char *script = argc > 1 ? argv[1] : "tests/m1.lua";
  lua_State *L = lua_newstate(gg_alloc, NULL);
  int rc;

  if (!L) { fprintf(stderr, "cannot create the layout probe state\n"); return 2; }
  lua_close(L);
  if (gg_first != eris_lj_ggsize()) {
    fprintf(stderr, "LAYOUT MISMATCH: libluajit.a's GG_State is %lu bytes, eris_lj.c was "
            "compiled for %lu -- compile it against native/build-native.sh's LuaJIT build "
            "copy, whose lj_arch.h includes native/luajit/oclj_features.h\n",
            (unsigned long)gg_first, (unsigned long)eris_lj_ggsize());
    return 3;
  }

  L = luaL_newstate();
  if (!L) { fprintf(stderr, "cannot create state\n"); return 2; }
  luaL_openlibs(L);
  luaopen_eris_lj(L);
  lua_pop(L, 1);  /* luaL_register left the table on the stack */

  printf("eris-lj test harness\n");
  lua_getglobal(L, "eris");
  lua_getfield(L, -1, "version");
  if (lua_pcall(L, 0, 4, 0) == 0) {
    printf("  %s\n  fingerprint: %s\n  format: %d\n  VM features: %s\n  GG_State: %lu bytes (libluajit.a and eris_lj.c agree)\n\n",
           lua_tostring(L, -4), lua_tostring(L, -3), (int)lua_tointeger(L, -2),
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "(none)", (unsigned long)gg_first);
    lua_pop(L, 4);
  } else {
    printf("  (version call failed: %s)\n\n", lua_tostring(L, -1));
    lua_pop(L, 1);
  }
  lua_pop(L, 1);

  if (luaL_dofile(L, script) != 0) {
    fprintf(stderr, "error: %s\n", lua_tostring(L, -1));
    lua_close(L);
    return 2;
  }
  rc = (int)lua_tointeger(L, -1);
  lua_close(L);
  return rc;
}
