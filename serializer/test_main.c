/* test_main.c — standalone harness for the eris-lj test suite.
 * Opens a LuaJIT state with the standard libraries plus eris, then runs
 * the Lua script named on the command line (default tests/m1.lua).
 * Exit status is the number of failing tests (0 = all pass). */

#include <stdio.h>
#include <stdlib.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "eris_lj.h"

int main(int argc, char **argv)
{
  const char *script = argc > 1 ? argv[1] : "tests/m1.lua";
  lua_State *L = luaL_newstate();
  int rc;

  if (!L) { fprintf(stderr, "cannot create state\n"); return 2; }
  luaL_openlibs(L);
  luaopen_eris_lj(L);
  lua_pop(L, 1);  /* luaL_register left the table on the stack */

  printf("eris-lj test harness\n");
  lua_getglobal(L, "eris");
  lua_getfield(L, -1, "version");
  if (lua_pcall(L, 0, 3, 0) == 0) {
    printf("  %s\n  fingerprint: %s\n  format: %d\n\n",
           lua_tostring(L, -3), lua_tostring(L, -2), (int)lua_tointeger(L, -1));
    lua_pop(L, 3);
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
