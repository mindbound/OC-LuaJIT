/*
 * m3trace.c — what value may be written into a cont_stitch frame's saved-trace
 * aux slot (framebase-5)?
 *
 * vm_x64.dasc:2380  mov TRACE:ITYPE, [RB-40]   ; RB = frame base
 *              2381  cleartp TRACE:ITYPE       ; shl 17 / shr 17 -> low 47 bits
 *              2404  test TRACE:ITYPE, TRACE:ITYPE
 *                    jz ->cont_nop
 * so the slot's low 47 bits must be zero for resumption to degrade to cont_nop.
 * nil (0xffff...) is therefore WRONG: cleartp(nil) = 0x7fffffffffff != 0.
 *
 * Two candidates DO satisfy it:
 *   A  u64 = ((uint64_t)LJ_TTRACE << 47)   "zero-payload trace ref"
 *   B  u64 = 0                             (+0.0, a plain double)
 *
 * But the slot is also a live stack slot for the GC:
 *   gc_traverse_thread (lj_gc.c:312) / gc_traverse_tab (lj_gc.c) call
 *   gc_marktv, which is  `if (tviswhite(tv)) gc_mark(g, gcV(tv));`  and
 *   tviswhite(x) = tvisgcv(x) && iswhite(gcV(x))   (lj_gc.h:35)
 *   iswhite(x)   = ((x)->gch.marked & LJ_GC_WHITES) (lj_gc.h:32)
 * so a GC-typed value with a NULL payload dereferences NULL.
 *
 *   m3trace pred    - just print the predicates for both candidates
 *   m3trace tab A|B - put the candidate in a table array slot, then full GC
 *   m3trace co  A|B - put it in a plain numeric local slot of a suspended
 *                     coroutine (the shape the stitch aux slot really has),
 *                     then full GC
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
#include "lj_tab.h"

static uint64_t cleartp(uint64_t v) { return (v << 17) >> 17; }

static void pred(const char *name, uint64_t u)
{
  TValue t;
  t.u64 = u;
  printf("  %-18s raw=%#018" PRIx64 "  itype=%#010x  cleartp=%#" PRIx64
         "  tvisgcv=%d tvisnum=%d gcval=%p\n",
         name, u, (unsigned)itype(&t), cleartp(u),
         tvisgcv(&t) ? 1 : 0, tvisnum(&t) ? 1 : 0, (void *)gcval(&t));
}

int main(int argc, char **argv)
{
  const char *what = argc > 1 ? argv[1] : "pred";
  const char *which = argc > 2 ? argv[2] : "B";
  uint64_t A = ((uint64_t)LJ_TTRACE) << 47;
  uint64_t B = 0;
  uint64_t V = (which[0] == 'A') ? A : B;
  lua_State *L;

  printf("m3trace what=%s cand=%s (LJ_TTRACE=%#x)\n", what, which,
         (unsigned)LJ_TTRACE);
  pred("A: trace|NULL", A);
  pred("B: +0.0", B);
  pred("   nil", (uint64_t)-1);
  if (!strcmp(what, "pred")) return 0;

  L = luaL_newstate();
  luaL_openlibs(L);

  if (!strcmp(what, "tab")) {
    GCtab *t;
    lua_createtable(L, 4, 0);
    lua_pushinteger(L, 7); lua_rawseti(L, -2, 1);
    lua_pushinteger(L, 8); lua_rawseti(L, -2, 2);
    t = tabV(L->top - 1);
    printf("  table asize=%d, overwriting array slot 1\n", (int)t->asize);
    arrayslot(t, 1)->u64 = V;
  } else {
    lua_State *co;
    TValue *stack;
    ptrdiff_t i, victim = -1;
    if (luaL_dostring(L,
          "local co = coroutine.create(function()\n"
          "  local a, b, c, d, e, f = 101, 102, 103, 104, 105, 106\n"
          "  coroutine.yield(a + b + c + d + e + f)\n"
          "  return 'done'\n"
          "end)\n"
          "coroutine.resume(co)\n"
          "return co\n")) {
      printf("scenario error: %s\n", lua_tostring(L, -1));
      return 2;
    }
    co = lua_tothread(L, -1);
    stack = tvref(co->stack);
    /* a plain local, i.e. a slot the GC marks but the frame walk never
     * dereferences — exactly the role framebase-5 plays for cont_stitch. */
    for (i = 1 + LJ_FR2; i < co->top - stack; i++)
      if (tvisnum(stack + i) && numV(stack + i) == 103) { victim = i; break; }
    if (victim < 0) { printf("  could not find the victim slot\n"); return 2; }
    printf("  suspended thread top_ofs=%td, overwriting plain local slot %td\n",
           co->top - stack, victim);
    stack[victim].u64 = V;
  }

  printf("  running full GC ...\n");
  fflush(stdout);
  lua_gc(L, LUA_GCCOLLECT, 0);
  printf("  SURVIVED the full GC\n");
  lua_close(L);
  return 0;
}
