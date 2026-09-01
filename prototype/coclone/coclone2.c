/* coclone2.c — M3 restore-path probe #2:
 *   A  lua_xmove as the slot-writing primitive (exact indices, nil holes)
 *   B  open upvalue created BEFORE the slot's value is written, plus a
 *      growstack in between (does resizestack fix uv->v?)
 *   C  never-started / suspended / dead thread state encodings
 *   D  lj_state_cpgrowstack overflow behaviour (crafted-blob robustness)
 */
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lj_obj.h"
#include "lj_frame.h"
#include "lj_gc.h"
#include "lj_state.h"

static int fails = 0;
#define CHECK(c, ...) do { if(!(c)){ fails++; printf("  FAIL: " __VA_ARGS__); \
                                     printf("\n"); } } while (0)

static GCupval *elj_finduv(lua_State *L, lua_State *co, TValue *slot)
{
  global_State *g = G(L);
  GCRef *pp = &co->openupval;
  GCupval *p, *uv;
  while (gcref(*pp) != NULL && uvval((p = gco2uv(gcref(*pp)))) >= slot) {
    if (uvval(p) == slot) return p;
    pp = &p->nextgc;
  }
  uv = (GCupval *)lj_mem_realloc(L, NULL, 0, sizeof(GCupval));
  newwhite(g, uv);
  uv->gct = ~LJ_TUPVAL; uv->closed = 0; uv->immutable = 0; uv->dhash = 0;
  setmref(uv->v, slot);
  setgcrefr(uv->nextgc, *pp);  setgcref(*pp, obj2gco(uv));
  setgcref(uv->prev, obj2gco(&g->uvhead));
  setgcrefr(uv->next, g->uvhead.next);
  setgcref(uvnext(uv)->prev, obj2gco(uv));
  setgcref(g->uvhead.next, obj2gco(uv));
  return uv;
}

static void show(const char *what, lua_State *L, lua_State *co)
{
  lua_getglobal(L, "coroutine");
  lua_getfield(L, -1, "status");
  lua_pushthread(co); lua_xmove(co, L, 1);
  lua_call(L, 1, 1);
  printf("  %-16s status=%d cframe=%p base_ofs=%td top_ofs=%td -> \"%s\"\n",
         what, (int)co->status, co->cframe, co->base - tvref(co->stack),
         co->top - tvref(co->stack), lua_tostring(L, -1));
  lua_pop(L, 2);
}

int main(void)
{
  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  printf("coclone2\n\n");

  /* ---- A: lua_xmove writes at exact slots when we drive co->top ---- */
  printf("== A: lua_xmove at exact slot indices (with nil holes)\n");
  {
    lua_State *co = lua_newthread(L);
    int i, ok = 1;
    static const int want[8] = { 0, 0, 11, -1, -1, 44, -1, 77 };  /* -1 = nil */
    lj_state_cpgrowstack(co, 64);
    for (i = 1 + LJ_FR2; i < 8; i++) {
      co->top = tvref(co->stack) + i;      /* aim at the exact slot */
      if (want[i] < 0) lua_pushnil(L); else lua_pushinteger(L, want[i]);
      lua_xmove(L, co, 1);                 /* writes slot i, top -> i+1 */
      CHECK(co->top == tvref(co->stack) + i + 1, "xmove top drift at %d", i);
    }
    for (i = 1 + LJ_FR2; i < 8; i++) {
      TValue *o = tvref(co->stack) + i;
      int got = tvisnil(o) ? -1 : (int)numberVnum(o);
      if (got != want[i]) { ok = 0; printf("  slot %d: got %d want %d\n",
                                           i, got, want[i]); }
    }
    CHECK(ok, "xmove slot placement wrong");
    printf("  xmove placement OK, final top_ofs=%td\n",
           co->top - tvref(co->stack));
    lua_pop(L, 1);
  }

  /* ---- B: upvalue opened before the value, growstack in between ---- */
  printf("\n== B: open upvalue on a nil slot, value written later,\n"
         "      with a stack reallocation in between\n");
  {
    lua_State *co = lua_newthread(L);
    TValue *slot0;
    GCupval *uv;
    ptrdiff_t idx = 5;
    lj_state_cpgrowstack(co, 20);
    co->top = tvref(co->stack) + idx + 1;
    uv = elj_finduv(L, co, tvref(co->stack) + idx);   /* slot still nil */
    slot0 = uvval(uv);
    CHECK(tvisnil(uvval(uv)), "slot not nil at open time");
    CHECK(!uv->closed && gcref(co->openupval) == obj2gco(uv), "list wrong");
    lj_state_cpgrowstack(co, 4000);                   /* forces realloc */
    printf("  after regrow: stack moved %d, uv->v tracked = %d\n",
           tvref(co->stack) + idx != slot0,
           uvval(uv) == tvref(co->stack) + idx);
    CHECK(uvval(uv) == tvref(co->stack) + idx,
          "resizestack did NOT relocate uv->v");
    /* now write the value through the stack; the upvalue must see it */
    co->top = tvref(co->stack) + idx;
    lua_pushinteger(L, 4242);
    lua_xmove(L, co, 1);
    CHECK(numberVnum(uvval(uv)) == 4242, "upvalue does not see the slot value");
    lua_gc(L, LUA_GCCOLLECT, 0);
    printf("  after full GC: uv->v in stack = %d, value = %g\n",
           uvval(uv) >= tvref(co->stack) &&
           uvval(uv) < tvref(co->stack) + co->stacksize,
           (double)numberVnum(uvval(uv)));
    CHECK(numberVnum(uvval(uv)) == 4242, "value lost across GC");
    lua_pop(L, 1);
  }

  /* ---- C: thread state encodings ---- */
  printf("\n== C: thread states\n");
  {
    lua_State *co;
    luaL_dostring(L, "return coroutine.create(function(a) "
                     "coroutine.yield(a) return 'done' end)");
    co = lua_tothread(L, -1);
    show("never-started", L, co);
    printf("     never-started: top-base = %td, slot[base] is a func = %d\n",
           co->top - co->base, tvisfunc(co->base));
    lua_pushinteger(co, 1); lua_resume(co, 1);
    show("suspended", L, co);
    lua_resume(co, 0);
    show("dead(normal)", L, co);
    printf("     dead: top==base? %d\n", co->top == co->base);
    lua_pop(L, 1);

    luaL_dostring(L, "return coroutine.create(function() error('boom') end)");
    co = lua_tothread(L, -1);
    lua_resume(co, 0);
    show("dead(error)", L, co);
    lua_pop(L, 1);

    /* hand-built never-started thread */
    {
      lua_State *nc = lua_newthread(L);
      luaL_dostring(L, "return function(a) return a*2 end");
      lua_xmove(L, nc, 1);              /* function at slot 2, top = 3 */
      show("built-fresh", L, nc);
      lua_pushinteger(nc, 21);
      { int st = lua_resume(nc, 1);
        printf("     resume -> st=%d res=%g\n", st, lua_tonumber(nc, -1));
        CHECK(st == LUA_OK && lua_tonumber(nc, -1) == 42, "fresh thread call"); }
      lua_pop(L, 1);
    }
  }

  /* ---- D: overflow behaviour of the protected grow ---- */
  printf("\n== D: cpgrowstack overflow\n");
  {
    lua_State *co = lua_newthread(L);
    int rc = lj_state_cpgrowstack(co, LUAI_MAXSTACK + 1000);
    printf("  cpgrowstack(MAXSTACK+1000) -> %d (LUA_OK=%d ERRRUN=%d ERRMEM=%d)"
           "  stacksize=%d cframe=%p top_ofs=%td\n",
           rc, LUA_OK, LUA_ERRRUN, LUA_ERRMEM, (int)co->stacksize, co->cframe,
           co->top - tvref(co->stack));
    if (rc != LUA_OK && co->top > tvref(co->stack) + 1 + LJ_FR2)
      printf("  error object on co: %s\n",
             tvisstr(co->top - 1) ? strdata(strV(co->top - 1)) : "<not a str>");
    CHECK(rc != LUA_OK, "overflow was not reported");
    CHECK(co->cframe == NULL, "cframe left dangling after overflow");
    lua_pop(L, 1);
  }

  printf("\n%s (%d failure%s)\n", fails ? "RESULT: FAIL" : "RESULT: OK",
         fails, fails == 1 ? "" : "s");
  lua_close(L);
  return fails ? 1 : 0;
}
