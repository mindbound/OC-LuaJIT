/*
 * coclone.c — M3 RESTORE-path probe.
 *
 * Builds a suspended coroutine FROM SCRATCH (lua_newthread + grow + slot
 * writes + open-upvalue creation + base/top/status) and resumes it, checking
 * it produces the same results as the original.  Values are copied raw
 * (same process) so that only the *mechanism* is under test, not M1/M2.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <inttypes.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lj_obj.h"
#include "lj_frame.h"
#include "lj_gc.h"
#include "lj_state.h"
#include "lj_func.h"
#include "lj_vm.h"

static int fails = 0;
#define CHECK(c, ...) do { if(!(c)){ fails++; printf("  FAIL: " __VA_ARGS__); \
                                     printf("\n"); } } while (0)

/* ------------------------------------------------------------------ */
/* Exact replica of func_finduv (lj_func.c:37-69), minus the resurrect
 * branch (a freshly built thread has no dead upvalues), and allocating
 * on `L` (catchable) rather than on `co` (cframe == NULL -> panic). */
static GCupval *elj_finduv(lua_State *L, lua_State *co, TValue *slot,
                           uint32_t dhash, int immutable)
{
  global_State *g = G(L);
  GCRef *pp = &co->openupval;
  GCupval *p, *uv;
  while (gcref(*pp) != NULL && uvval((p = gco2uv(gcref(*pp)))) >= slot) {
    if (uvval(p) == slot) return p;          /* already open for this slot */
    pp = &p->nextgc;
  }
  uv = (GCupval *)lj_mem_realloc(L, NULL, 0, sizeof(GCupval));
  newwhite(g, uv);
  uv->gct = ~LJ_TUPVAL;
  uv->closed = 0;
  uv->immutable = (uint8_t)immutable;
  uv->dhash = dhash;
  setmref(uv->v, slot);
  /* NOBARRIER: new (white) and open. */
  setgcrefr(uv->nextgc, *pp);               /* sorted per-thread open list */
  setgcref(*pp, obj2gco(uv));
  setgcref(uv->prev, obj2gco(&g->uvhead));  /* global doubly-linked ring */
  setgcrefr(uv->next, g->uvhead.next);
  setgcref(uvnext(uv)->prev, obj2gco(uv));
  setgcref(g->uvhead.next, obj2gco(uv));
  return uv;
}

/* ------------------------------------------------------------------ */
static const char *SCEN =
  "local co = coroutine.create(function(a)\n"
  "  local counter = 0\n"
  "  local r = 0\n"
  "  local function bump(d) counter = counter + d; return counter end\n"
  "  local function leaf(...)\n"
  "    local got = coroutine.yield(bump, select('#', ...), a)\n"
  "    return got + bump(10)\n"
  "  end\n"
  "  local function mid(...) return leaf(...) end\n"
  "  pcall(function() r = mid(1,2,3) end)\n"
  "  return counter, r\n"
  "end)\n"
  "coroutine.resume(co, 'X')\n"
  "return co\n";

static lua_State *make_co(lua_State *L)
{
  if (luaL_loadstring(L, SCEN) || lua_pcall(L, 0, 1, 0)) {
    printf("scenario error: %s\n", lua_tostring(L, -1));
    fails++;
    return NULL;
  }
  return lua_tothread(L, -1);   /* left on L's stack (anchors it) */
}

/* Resume `co` with the integer 5 and print/collect the two results. */
static void drive(lua_State *L, lua_State *co, const char *what,
                  lua_Number *o1, lua_Number *o2, int *ok)
{
  int st;
  lua_pushinteger(co, 5);
  st = lua_resume(co, 1);
  *ok = (st == LUA_OK);
  *o1 = *o2 = -1;
  if (st == LUA_OK && lua_gettop(co) >= 2) {
    *o1 = lua_tonumber(co, 1);
    *o2 = lua_tonumber(co, 2);
  } else if (st != LUA_OK) {
    printf("  %s: resume error status=%d msg=%s\n", what, st,
           lua_tostring(co, -1));
  }
  printf("  %s: status=%d nres=%d -> %g, %g\n", what, st, lua_gettop(co),
         (double)*o1, (double)*o2);
  (void)L;
}

int main(void)
{
  lua_State *L = luaL_newstate();
  lua_State *ref, *src, *nc;
  MSize i, need, top_ofs, base_ofs, srcstacksize;
  TValue *st;
  int nuv = 0, uvslot[16];
  GCupval *olduv[16];
  lua_Number r1, r2, c1, c2;
  int rok, cok, cf_ok;

  luaL_openlibs(L);
  printf("coclone: M3 restore-path probe (GC64=%d FR2=%d "
         "LJ_STACK_EXTRA=%d LUAI_MAXSTACK=%d)\n\n",
         LJ_GC64, LJ_FR2, (int)LJ_STACK_EXTRA, (int)LUAI_MAXSTACK);

  /* ---- 0. what a *fresh* thread looks like ---- */
  {
    lua_State *f = lua_newthread(L);
    printf("== fresh thread: stacksize=%d maxstack_ofs=%td base_ofs=%td "
           "top_ofs=%td status=%d cframe=%p openupval=%p\n",
           (int)f->stacksize, mref(f->maxstack, TValue) - tvref(f->stack),
           f->base - tvref(f->stack), f->top - tvref(f->stack),
           (int)f->status, f->cframe, (void *)gcref(f->openupval));
    printf("   slot0 itype=%#x (thread? %d, ==self? %d)  slot1 itype=%#x nil=%d\n",
           (unsigned)itype(tvref(f->stack)), tvisthread(tvref(f->stack)),
           tvisthread(tvref(f->stack)) && threadV(tvref(f->stack)) == f,
           (unsigned)itype(tvref(f->stack) + 1), tvisnil(tvref(f->stack) + 1));
    CHECK(f->stacksize == 2 * LUA_MINSTACK + LJ_STACK_EXTRA,
          "fresh stacksize %d != LJ_STACK_START+EXTRA", (int)f->stacksize);
    CHECK((MSize)(mref(f->maxstack, TValue) - tvref(f->stack))
            == f->stacksize - 1 - LJ_STACK_EXTRA, "maxstack invariant");
    CHECK(f->base == tvref(f->stack) + 1 + LJ_FR2, "fresh base != stack+1+FR2");
    /* ---- 1a. protected grow on a coroutine, then check invariants ---- */
    {
      int rc = lj_state_cpgrowstack(f, 100);
      printf("   cpgrowstack(100) -> %d, stacksize=%d maxstack_ofs=%td "
             "base_ofs=%td top_ofs=%td cframe=%p status=%d\n",
             rc, (int)f->stacksize,
             mref(f->maxstack, TValue) - tvref(f->stack),
             f->base - tvref(f->stack), f->top - tvref(f->stack),
             f->cframe, (int)f->status);
      CHECK(rc == LUA_OK, "cpgrowstack failed");
      CHECK(f->cframe == NULL, "cpgrowstack left cframe != NULL");
      CHECK(f->base == f->top, "cpgrowstack disturbed base/top");
      CHECK(f->base == tvref(f->stack) + 1 + LJ_FR2, "base moved");
      cf_ok = (f->cframe == NULL);
    }
    lua_pop(L, 1);
  }
  printf("\n");

  /* ---- reference run ---- */
  ref = make_co(L);
  if (!ref) goto out;
  printf("== reference coroutine\n");
  drive(L, ref, "original", &r1, &r2, &rok);
  lua_pop(L, 1);

  /* ---- clone source ---- */
  src = make_co(L);
  if (!src) goto out;
  st = tvref(src->stack);
  srcstacksize = src->stacksize;
  base_ofs = (MSize)(src->base - st);
  top_ofs  = (MSize)(src->top - st);
  printf("\n== source: stacksize=%d base_ofs=%d top_ofs=%d status=%d "
         "cframe=%p\n", (int)srcstacksize, (int)base_ofs, (int)top_ofs,
         (int)src->status, src->cframe);
  {
    GCobj *o;
    for (o = gcref(src->openupval); o; o = gcref(o->uv.nextgc)) {
      ptrdiff_t s = uvval(&o->uv) - st;
      printf("   openupval slot=%td immutable=%d dhash=%08x\n",
             s, (int)o->uv.immutable, o->uv.dhash);
      if (nuv < 16) { uvslot[nuv] = (int)s; olduv[nuv] = &o->uv; nuv++; }
    }
  }
  printf("   raw slots 0..%d:", (int)top_ofs - 1);
  for (i = 0; i < top_ofs && i < 6; i++)
    printf(" [%d]=%#x", (int)i, (unsigned)itype(st + i));
  printf("\n");

  /* ---- 2. build the clone ---- */
  nc = lua_newthread(L);            /* anchored on L's stack for the rest */
  /* required slots: everything the source's maxstack covered. */
  need = srcstacksize - 1 - LJ_STACK_EXTRA;
  CHECK(need < LUAI_MAXSTACK, "crafted size out of range");
  {
    MSize cur = (MSize)(mref(nc->maxstack, TValue) - tvref(nc->stack));
    if (need > cur) {
      int rc = lj_state_cpgrowstack(nc, need - cur);
      CHECK(rc == LUA_OK, "grow clone failed rc=%d", rc);
    }
  }
  printf("\n== clone: grown to stacksize=%d (source %d), maxstack_ofs=%td\n",
         (int)nc->stacksize, (int)srcstacksize,
         mref(nc->maxstack, TValue) - tvref(nc->stack));
  CHECK((MSize)(mref(nc->maxstack, TValue) - tvref(nc->stack)) >= need,
        "clone maxstack too small");

  /* Copy slots 2..top-1.  Slots 0 (self thread) and 1 (FR2 nil) are what
   * stack_init already left there and must NOT be overwritten with the
   * source's (which names the *source* thread). */
  st = tvref(src->stack);                        /* re-fetch: grow moved us */
  for (i = 1 + LJ_FR2; i < top_ofs; i++) {
    /* copyTV into a thread stack slot: no barrier (threads are never black) */
    copyTV(nc, tvref(nc->stack) + i, tvref(src->stack) + i);
    nc->top = tvref(nc->stack) + i + 1;          /* keep top >= written */
  }

  /* ---- 3. open upvalues, pointing at slots that already hold values ---- */
  for (i = 0; i < (MSize)nuv; i++) {
    GCupval *nuvp = elj_finduv(L, nc, tvref(nc->stack) + uvslot[i],
                               olduv[i]->dhash, olduv[i]->immutable);
    /* Re-point every Lua closure on the clone's stack that referred to the
     * source's upvalue.  (Stands in for M3's referrer back-patch list.) */
    MSize k;
    for (k = 0; k < top_ofs; k++) {
      TValue *o = tvref(nc->stack) + k;
      if (tvisfunc(o) && isluafunc(funcV(o))) {
        GCfunc *fn = funcV(o);
        uint32_t j;
        for (j = 0; j < fn->l.nupvalues; j++)
          if (&gcref(fn->l.uvptr[j])->uv == olduv[i]) {
            setgcref(fn->l.uvptr[j], obj2gco(nuvp));
            lj_gc_objbarrier(L, fn, obj2gco(nuvp));
          }
      }
    }
  }
  {
    GCobj *o; int n = 0; ptrdiff_t last = 1 << 30;
    for (o = gcref(nc->openupval); o; o = gcref(o->uv.nextgc)) {
      ptrdiff_t s = uvval(&o->uv) - tvref(nc->stack);
      CHECK(!o->uv.closed, "clone upvalue not open");
      CHECK(s < last, "clone openupval not sorted descending");
      last = s; n++;
    }
    printf("   clone open upvalues: %d (source had %d)\n", n, nuv);
    CHECK(n == nuv, "clone upvalue count mismatch");
  }

  /* ---- 4. final state ---- */
  nc->base   = tvref(nc->stack) + base_ofs;
  nc->top    = tvref(nc->stack) + top_ofs;
  nc->status = LUA_YIELD;
  nc->cframe = NULL;
  setgcrefr(nc->env, src->env);        /* thread env; NOBARRIER (lua_State) */

  /* A full GC here must not disturb the half-built-then-finished thread. */
  lua_gc(L, LUA_GCCOLLECT, 0);
  printf("   after full GC: stacksize=%d base_ofs=%td top_ofs=%td\n",
         (int)nc->stacksize, nc->base - tvref(nc->stack),
         nc->top - tvref(nc->stack));

  /* ---- 5. resume the clone ---- */
  printf("\n== resume clone\n");
  {
    lua_getglobal(L, "coroutine");
    lua_getfield(L, -1, "status");
    lua_pushvalue(L, -3);            /* the clone thread */
    lua_call(L, 1, 1);
    printf("   coroutine.status(clone) = %s\n", lua_tostring(L, -1));
    lua_pop(L, 2);
  }
  drive(L, nc, "clone   ", &c1, &c2, &cok);
  CHECK(rok && cok, "one of the resumes failed");
  CHECK(r1 == c1 && r2 == c2, "clone results %g,%g != original %g,%g",
        (double)c1, (double)c2, (double)r1, (double)r2);

out:
  printf("\n%s (%d failure%s)\n", fails ? "RESULT: FAIL" : "RESULT: OK",
         fails, fails == 1 ? "" : "s");
  (void)cf_ok;
  lua_close(L);
  return fails ? 1 : 0;
}
