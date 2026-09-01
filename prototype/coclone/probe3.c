/* probe3: can a half-built thread be resumed by Lua code that gets hold of it?
 * and does status=LUA_ERRRUN during construction block that? */
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lj_obj.h"
#include "lj_state.h"
static const char *T =
 "local co = ...\n"
 "local ok, err = pcall(coroutine.resume, co)\n"
 "return tostring(ok)..' / '..tostring(err)..' / '..coroutine.status(co)\n";
static void try(lua_State *L, lua_State *co, const char *label){
  luaL_loadstring(L, T); lua_pushthread(co); lua_xmove(co, L, 1);
  if (lua_pcall(L,1,1,0)) printf("  %-22s pcall-error: %s\n", label, lua_tostring(L,-1));
  else printf("  %-22s %s\n", label, lua_tostring(L,-1));
  lua_pop(L,1);
}
int main(void){
  lua_State *L = luaL_newstate(); luaL_openlibs(L);
  { lua_State *co = lua_newthread(L);
    lj_state_cpgrowstack(co, 40);
    /* simulate mid-build: junk in slots, top bumped, base still at bottom */
    lua_pushinteger(L, 1234); lua_xmove(L, co, 1);
    lua_pushinteger(L, 5678); lua_xmove(L, co, 1);
    printf("half-built, status=LUA_OK:\n");
    try(L, co, "resume half-built");
    co->status = LUA_ERRRUN;
    printf("half-built, status=LUA_ERRRUN (guard):\n");
    try(L, co, "resume guarded");
    co->status = LUA_OK; co->top = co->base;
    lua_pop(L,1); }
  lua_close(L); return 0;
}
