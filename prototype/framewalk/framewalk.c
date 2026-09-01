/*
 * framewalk.c — M0 validation spike for OC-LuaJIT Track P (persistence).
 *
 * Read-only: creates suspended LuaJIT coroutines in every frame shape the OC
 * yield protocol can produce, then walks their stacks and frame chains using
 * the real internal headers (lj_obj.h / lj_frame.h) and validates the
 * serialization schema from docs/persistence-study.md:
 *
 *   H1  cframe == NULL and status == LUA_YIELD for every suspended thread
 *   H2  every frame link decodes into one of: LUA(proto,pcofs) /
 *       DELTA(type,bytes) / CONT(sym,contpc,delta) — nothing else
 *   H3  FRAME_C/FRAME_CP never appear except as the bottom resume frame
 *   H4  every FRAME_CONT continuation address resolves in the closed
 *       9-entry symbol table
 *   H5  FRAME_LUA return PCs fall inside the caller proto's bytecode
 *   H6  open upvalues: each uv->v points into [stack, top), list sorted by
 *       descending slot
 *   H7  cont_stitch aux slots are observable (LJ_TTRACE-tagged) where the
 *       yield happened under a compiled trace — the slot M3 must zero
 *
 * Exit 0 iff all hard assertions hold on all scenarios.
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
#include "lj_vm.h"

static int g_failures = 0;
static int g_stitch_seen = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { g_failures++; printf("    FAIL: " __VA_ARGS__); printf("\n"); } \
  } while (0)

/* H4: the closed continuation set (lj_vm.h:108-114 + integer specials). */
static const struct { const void *addr; const char *name; } k_conts[] = {
  { (const void *)lj_cont_cat,   "cat"   },
  { (const void *)lj_cont_ra,    "ra"    },
  { (const void *)lj_cont_nop,   "nop"   },
  { (const void *)lj_cont_condt, "condt" },
  { (const void *)lj_cont_condf, "condf" },
  { (const void *)lj_cont_hook,  "hook"  },
  { (const void *)lj_cont_stitch,"stitch"},
};

static const char *cont_name(uint64_t contv)
{
  size_t i;
  if (contv == 0) return "int:tailcall";
  if (contv == 1) return "int:ffi_callback";
  for (i = 0; i < sizeof(k_conts)/sizeof(k_conts[0]); i++)
    if ((uint64_t)(uintptr_t)k_conts[i].addr == contv) return k_conts[i].name;
  return NULL;
}

/* Two-step, exactly as the VM's own unwind loops do it:
 *  - a Lua frame's ftsz is a BCIns* (4-byte aligned), so only the low 2 bits
 *    are type bits; bit 2 is address data. Test frame_islua() first, or
 *    FRAME_LUAP appears at random depending on PC alignment.
 *  - delta frames carry a real 3-bit type, so frame_typep() is valid there
 *    (frame_type() alone would conflate CONT(2)/PCALL(6)/PCALLH(7)). */
static const char *frame_type_name(TValue *f)
{
  if (frame_islua(f)) return "LUA";
  switch (frame_typep(f)) {
    case FRAME_C:      return "C";
    case FRAME_CONT:   return "CONT";
    case FRAME_VARG:   return "VARG";
    case FRAME_CP:     return "CP";
    case FRAME_PCALL:  return "PCALL";
    case FRAME_PCALLH: return "PCALLH";
    default:           return "??";
  }
}

/* Confirmed empirically (and by vm_x64.dasc:2380 "mov TRACE:ITYPE, [RB-40]"):
 * a cont_stitch frame's saved GCtrace lives 5 slots below the frame base,
 * i.e. one slot below the continuation pair. This is the slot M3 must write
 * as a zero-payload trace ref so resumption degrades to cont_nop. */
#define STITCH_TRACE_SLOT(framebase) ((framebase) - 5)

/* H7: locate LJ_TTRACE-tagged slots empirically rather than trusting a
 * hardcoded offset — cont_stitch reads its saved trace from [mbase-40]
 * (vm_x64.dasc:2380) and M3 must zero exactly that slot. */
static int scan_trace_slots(lua_State *co, const char *what)
{
  TValue *stack = tvref(co->stack);
  ptrdiff_t n = (ptrdiff_t)co->stacksize;
  ptrdiff_t i;
  int found = 0;
  for (i = 0; i < n; i++) {
    if (itype(stack + i) == LJ_TTRACE) {
      printf("    TRACE-TAGGED slot=%td raw=0x%" PRIx64 " (%s)\n",
             i, stack[i].u64, what);
      found++;
    }
  }
  return found;
}

static void describe_func_slot(TValue *frame)
{
  GCobj *o;
  if (!tvisfunc(frame - 1)) { printf(" func=<non-func slot!>"); return; }
  o = gcval(frame - 1);
  if (isluafunc(&o->fn)) {
    GCproto *pt = funcproto(&o->fn);
    GCstr *name = proto_chunkname(pt);
    printf(" func=Lua:%.40s:%d", name ? strdata(name) : "?", pt->firstline);
  } else {
    printf(" func=C:ffid=%d", o->fn.c.ffid);
  }
}

/* Walk one suspended thread; pattern follows lj_debug/lj_err unwind loops. */
static void walk_thread(lua_State *co, const char *label)
{
  TValue *stack = tvref(co->stack);
  TValue *bot = stack + LJ_FR2;
  TValue *frame = co->base - 1;
  int idx = 0, guard = (int)co->stacksize + 8;

  printf("  thread %p [%s]\n", (void *)co, label);
  printf("    status=%d cframe=%p base_ofs=%td top_ofs=%td stacksize=%d\n",
         (int)co->status, cframe_raw(co->cframe),
         co->base - stack, co->top - stack, (int)co->stacksize);

  CHECK(co->cframe == NULL, "H1: cframe != NULL on suspended thread");
  CHECK(co->status == LUA_YIELD, "H1: status=%d, expected LUA_YIELD", (int)co->status);

  while (frame > bot && guard-- > 0) {
    const char *tn = frame_type_name(frame);
    TValue *prev = NULL;
    printf("    [%2d] slot=%3td type=%-6s", idx++, frame - stack, tn);

    if (frame_islua(frame)) {
      const BCIns *pc = frame_pc(frame);
      prev = frame_prevl(frame);
      describe_func_slot(frame);
      if (prev > bot && tvisfunc(prev - 1) && isluafunc(gcval(prev - 1) ? &gcval(prev - 1)->fn : NULL)) {
        GCproto *cpt = funcproto(&gcval(prev - 1)->fn);
        ptrdiff_t ofs = pc - proto_bc(cpt);
        printf(" ret_pc=(caller+%td of %d)", ofs, (int)cpt->sizebc);
        CHECK(ofs > 0 && ofs <= (ptrdiff_t)cpt->sizebc,
              "H5: pc offset %td outside caller bytecode [1..%d]", ofs, (int)cpt->sizebc);
      } else {
        printf(" ret_pc=%p (caller not Lua/at bottom)", (const void *)pc);
      }
    } else if (frame_iscont(frame)) {
      uint64_t contv = frame_contv(frame);
      const char *cn = cont_name(contv);
      prev = frame_prevd(frame);
      describe_func_slot(frame);
      printf(" delta=%td cont=%s", (ptrdiff_t)frame_sized(frame), cn ? cn : "<UNKNOWN>");
      CHECK(cn != NULL, "H4: unknown continuation 0x%" PRIx64, contv);
      if (cn && strcmp(cn, "stitch") == 0) {
        TValue *framebase = frame + 1;
        TValue *tr = STITCH_TRACE_SLOT(framebase);
        g_stitch_seen++;
        printf("\n      stitch: saved-trace slot=%td itype=%#x raw=0x%016" PRIx64,
               tr - stack, (unsigned)itype(tr), tr->u64);
        CHECK(tr >= stack && itype(tr) == LJ_TTRACE,
              "H7: expected LJ_TTRACE at framebase-5 (slot %td), got itype %#x",
              tr - stack, (unsigned)itype(tr));
      }
    } else {
      /* Delta-typed frame: VARG/PCALL/PCALLH or C/CP. */
      prev = frame_prevd(frame);
      printf(" delta=%td", (ptrdiff_t)frame_sized(frame));
      if (frame_typep(frame) == FRAME_C || frame_typep(frame) == FRAME_CP) {
        int at_bottom = (prev <= bot);
        printf(" %s", at_bottom ? "(bottom resume frame)" : "(INTERIOR C FRAME)");
        CHECK(at_bottom, "H3: interior %s frame above stack bottom", tn);
      }
    }
    printf("\n");
    CHECK(prev != NULL && prev < frame && prev >= stack,
          "H2: frame chain not strictly descending (prev=%p)", (void *)prev);
    if (!(prev != NULL && prev < frame && prev >= stack)) break;
    frame = prev;
  }
  CHECK(guard > 0, "H2: frame walk did not terminate");

  scan_trace_slots(co, "full-stack scan");

  /* H6: open upvalue list. */
  {
    GCobj *o = gcref(co->openupval);
    ptrdiff_t last = (ptrdiff_t)co->stacksize + 1;
    int n = 0;
    while (o != NULL) {
      GCupval *uv = &o->uv;
      ptrdiff_t slot = uvval(uv) - stack;
      printf("    openupval[%d] slot=%td immutable=%d\n", n++, slot, (int)uv->immutable);
      CHECK(!uv->closed, "H6: closed upvalue on openupval list");
      CHECK(slot >= 0 && slot < (ptrdiff_t)co->stacksize, "H6: uv->v outside stack");
      CHECK(slot < last, "H6: openupval list not sorted by descending slot");
      last = slot;
      o = gcref(uv->nextgc);
    }
  }
}

/* Each scenario chunk returns a coroutine already advanced to the
 * interesting suspension point (self-resumed from Lua). */
static const struct { const char *label; const char *src; } k_scen[] = {
  { "plain yield in loop",
    "local co = coroutine.create(function()\n"
    "  local s = 0\n"
    "  while true do s = s + 1; coroutine.yield(s) end\n"
    "end)\n"
    "coroutine.resume(co)\n"
    "return co" },
  { "yield under pcall + xpcall",
    "local co = coroutine.create(function()\n"
    "  pcall(function()\n"
    "    xpcall(function() coroutine.yield('deep') end, function(e) return e end)\n"
    "  end)\n"
    "end)\n"
    "coroutine.resume(co)\n"
    "return co" },
  { "yield inside __index metamethod (CONT frame)",
    "local t = setmetatable({}, { __index = function(_, k)\n"
    "  coroutine.yield('in-index'); return k\n"
    "end })\n"
    "local co = coroutine.create(function() return t.missing end)\n"
    "coroutine.resume(co)\n"
    "return co" },
  { "yield inside __concat metamethod (cont_cat)",
    "local t = setmetatable({}, { __concat = function(a, b)\n"
    "  coroutine.yield('in-concat'); return 'x'\n"
    "end })\n"
    "local co = coroutine.create(function() return 'a' .. t end)\n"
    "coroutine.resume(co)\n"
    "return co" },
  { "yield in vararg function, deep call chain, open upvalues",
    "local co = coroutine.create(function()\n"
    "  local counter = 0\n"
    "  local function leaf(...)\n"
    "    local bump = function() counter = counter + 1 end\n"
    "    bump(); coroutine.yield(bump, ...)\n"
    "  end\n"
    "  local function mid(...) leaf(...) end\n"
    "  local function outer() mid(1, 2, 3) end\n"
    "  outer()\n"
    "end)\n"
    "coroutine.resume(co)\n"
    "return co" },
  /* The inner thread is kept alive in a global: coroutine.resume clears the
   * yielded values off the coroutine stack, so returning it via yield would
   * leave nothing to walk. */
  { "nested coroutine suspended inside another",
    "local co = coroutine.create(function()\n"
    "  INNER = coroutine.create(function()\n"
    "    local keep = 1\n"
    "    coroutine.yield(function() return keep end)\n"
    "  end)\n"
    "  coroutine.resume(INNER)\n"
    "  coroutine.yield('outer-suspended')\n"
    "end)\n"
    "coroutine.resume(co)\n"
    "return co" },
  { "yield from JIT-hot loop (stitch expected)",
    "local co = coroutine.create(function()\n"
    "  local s = 0\n"
    "  for i = 1, 1e9 do s = s + i; coroutine.yield(s) end\n"
    "end)\n"
    "for _ = 1, 400 do coroutine.resume(co) end\n"
    "return co" },
};

int main(void)
{
  size_t i;
  lua_State *L = luaL_newstate();
  if (!L) { fprintf(stderr, "no state\n"); return 2; }
  luaL_openlibs(L);  /* includes jit -> JIT_F_ON */

  printf("framewalk: LuaJIT frame-shape validation (M0)\n");
  printf("build: GC64=%d FR2=%d\n\n", LJ_GC64, LJ_FR2);

  for (i = 0; i < sizeof(k_scen)/sizeof(k_scen[0]); i++) {
    printf("== scenario %zu: %s\n", i + 1, k_scen[i].label);
    if (luaL_loadbuffer(L, k_scen[i].src, strlen(k_scen[i].src), k_scen[i].label)
        || lua_pcall(L, 0, 1, 0)) {
      printf("    FAIL: scenario error: %s\n", lua_tostring(L, -1));
      g_failures++;
      lua_pop(L, 1);
      continue;
    }
    if (!lua_isthread(L, -1)) {
      printf("    FAIL: scenario did not return a thread\n");
      g_failures++;
      lua_pop(L, 1);
      continue;
    }
    walk_thread(lua_tothread(L, -1), k_scen[i].label);
    /* Nested scenario: also walk the inner coroutine, kept alive in _G.INNER. */
    if (strstr(k_scen[i].label, "nested")) {
      lua_getglobal(L, "INNER");
      if (lua_isthread(L, -1)) {
        printf("    -- inner thread:\n");
        walk_thread(lua_tothread(L, -1), "inner coroutine");
      } else {
        printf("    FAIL: inner coroutine not reachable\n");
        g_failures++;
      }
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
    printf("\n");
  }

  if (!g_stitch_seen)
    printf("NOTE: no stitch aux slot observed — hot-loop scenario may not have "
           "compiled; check jit.status or raise iteration count.\n");
  printf("\n%s (%d failure%s)\n", g_failures ? "RESULT: FAIL" : "RESULT: ALL INVARIANTS HOLD",
         g_failures, g_failures == 1 ? "" : "s");
  lua_close(L);
  return g_failures ? 1 : 0;
}
