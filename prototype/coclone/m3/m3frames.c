/*
 * m3frames.c — M3 CROSS-PROCESS (symbolic) frame codec round trip.
 *
 * coclone.c proved the restore *mechanism* by copying stack slots raw in one
 * process, so every proto/cont pointer in the frame words was still valid.
 * This probe removes exactly that crutch:
 *
 *   src   : suspended coroutine built from a chunk compiled in-process.
 *   twin  : the SAME chunk round-tripped through lua_dump()/lua_load(), so
 *           every GCproto is a different object at a different address, then
 *           resumed to the same suspension point.  Supplies the VALUES.
 *   nc    : a fresh thread.  Slot values come from `twin`; every frame word
 *           is recomputed from `src`'s SYMBOLIC encoding
 *             FRAME_LUA  -> (link, bcofs)      pc = proto_bc(pt) + bcofs
 *             delta      -> (link, type)
 *             FRAME_CONT -> (link, contsym, contbcofs)
 *           against `twin`'s protos.  Not one frame word is copied.
 *
 * Then nc and src are resumed with identical input and their results compared.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <inttypes.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lj_obj.h"
#include "lj_frame.h"
#include "lj_bc.h"
#include "lj_gc.h"
#include "lj_state.h"
#include "lj_func.h"
#include "lj_vm.h"

static int fails = 0;
#define CHECK(c, ...) do { if(!(c)){ fails++; printf("  FAIL: " __VA_ARGS__); \
                                     printf("\n"); } } while (0)

/* ------------------------------------------------------------- cont table */
/* lj_vm.h:108-114 — the complete, closed set. Order defines the wire id. */
enum { CS_CAT, CS_RA, CS_NOP, CS_CONDT, CS_CONDF, CS_HOOK, CS_STITCH, CS_MAX };
static const char *const cs_name[CS_MAX] =
  { "cat", "ra", "nop", "condt", "condf", "hook", "stitch" };
static uint64_t cs_addr[CS_MAX];

static void cs_init(void)
{
  cs_addr[CS_CAT]    = (uint64_t)(uintptr_t)(void *)lj_cont_cat;
  cs_addr[CS_RA]     = (uint64_t)(uintptr_t)(void *)lj_cont_ra;
  cs_addr[CS_NOP]    = (uint64_t)(uintptr_t)(void *)lj_cont_nop;
  cs_addr[CS_CONDT]  = (uint64_t)(uintptr_t)(void *)lj_cont_condt;
  cs_addr[CS_CONDF]  = (uint64_t)(uintptr_t)(void *)lj_cont_condf;
  cs_addr[CS_HOOK]   = (uint64_t)(uintptr_t)(void *)lj_cont_hook;
  cs_addr[CS_STITCH] = (uint64_t)(uintptr_t)(void *)lj_cont_stitch;
}

static int cs_find(uint64_t v)
{
  int i;
  for (i = 0; i < CS_MAX; i++) if (cs_addr[i] == v) return i;
  return -1;
}

/* --------------------------------------------------------------- records */

#define MAXFR 64

typedef struct {
  uint8_t  kind;        /* FRAME_LUA/_C/_CONT/_VARG/_CP/_PCALL/_PCALLH */
  uint64_t link;        /* bytes from this frame word down to the outer one */
  uint32_t bcofs;       /* FRAME_LUA: return pc offset in the caller proto  */
  uint8_t  cs;          /* FRAME_CONT: continuation symbol id              */
  uint32_t cbcofs;      /* FRAME_CONT: contpc offset in the caller proto   */
  /* not on the wire — for printing / cross-checks only */
  ptrdiff_t slot;
  const void *rawftsz;
} FrameRec;

static const char *const bcnames[] = {
#define BCNAME(name, ma, mb, mc, mt) #name,
BCDEF(BCNAME)
#undef BCNAME
  NULL
};
static const char *bcname(BCOp op)
{ return (unsigned)op < BC__MAX ? bcnames[op] : "?"; }

static const char *kindname(int k)
{
  switch (k) {
    case FRAME_LUA: return "LUA"; case FRAME_C: return "C";
    case FRAME_CONT: return "CONT"; case FRAME_VARG: return "VARG";
    case FRAME_CP: return "CP"; case FRAME_PCALL: return "PCALL";
    case FRAME_PCALLH: return "PCALLH"; default: return "??";
  }
}

/* ---------------------------------------------------------------- ENCODE */
/* Walk top-down exactly as the VM does. Returns 0 on success. */
static int encode(lua_State *co, FrameRec *fr, int *nout, char *err, size_t errsz)
{
  TValue *stack = tvref(co->stack);
  TValue *bot = stack + LJ_FR2;
  TValue *f = co->base - 1;
  int n = 0;

  if (co->cframe != NULL)
    { snprintf(err, errsz, "thread has a live C frame"); return -1; }
  if (co->status != LUA_YIELD)
    { snprintf(err, errsz, "thread not suspended"); return -1; }

  while (f > bot) {
    TValue *prev;
    FrameRec *r;
    if (n >= MAXFR) { snprintf(err, errsz, "too many frames"); return -1; }
    r = &fr[n];
    memset(r, 0, sizeof(*r));
    r->slot = f - stack;
    r->rawftsz = (const void *)(uintptr_t)f->u64;

    if (frame_islua(f)) {                            /* --------- FRAME_LUA */
      GCfunc *ofn;
      GCproto *pt;
      prev = frame_prevl(f);
      if (prev <= bot - 1 || prev >= f)
        { snprintf(err, errsz, "bad prevl at slot %d", (int)r->slot); return -1; }
      if (!tvisfunc(prev - 1) || !isluafunc(funcV(prev - 1)))
        { snprintf(err, errsz, "caller of frame %d is not a Lua function", n);
          return -1; }
      ofn = funcV(prev - 1);
      pt = funcproto(ofn);
      r->kind = FRAME_LUA;
      r->bcofs = (uint32_t)(frame_pc(f) - proto_bc(pt));
      r->link = (uint64_t)((char *)f - (char *)prev);
    } else {                                         /* -------- delta frame */
      int t = (int)frame_typep(f);
      prev = frame_prevd(f);
      r->kind = (uint8_t)t;
      r->link = (uint64_t)frame_sized(f);
      if (t == FRAME_CONT) {
        uint64_t cv = frame_contv(f);
        int cs;
        GCproto *pt;
        if (cv == LJ_CONT_TAILCALL || cv == LJ_CONT_FFI_CALLBACK)
          { snprintf(err, errsz, "FFI/tailcall continuation (%d) unsupported",
                     (int)cv); return -1; }
        cs = cs_find(cv);
        if (cs < 0)
          { snprintf(err, errsz, "unknown continuation %#" PRIx64, cv); return -1; }
        if (cs == CS_HOOK)
          { snprintf(err, errsz, "lj_cont_hook frame: aux slot is a raw "
                     "MULTRES int, refusing"); return -1; }
        if (!tvisfunc(prev - 1) || !isluafunc(funcV(prev - 1)))
          { snprintf(err, errsz, "cont frame %d: caller not a Lua function", n);
            return -1; }
        pt = funcproto(funcV(prev - 1));
        r->cs = (uint8_t)cs;
        r->cbcofs = (uint32_t)(frame_contpc(f) - proto_bc(pt));
      } else if ((t == FRAME_C || t == FRAME_CP) && prev > bot) {
        snprintf(err, errsz, "interior C frame at slot %d", (int)r->slot);
        return -1;
      }
    }
    n++;
    f = prev;
  }
  if (f != bot)
    { snprintf(err, errsz, "chain did not terminate at stack+LJ_FR2"); return -1; }
  *nout = n;
  return 0;
}

/* --------------------------------------------------- DECODE, pass 1 */
/* Derive frame-word positions from the stored links alone (no protos yet)
 * and validate the structure. Fills pos[] and marks non-value slots. */
static int decode_pass1(const FrameRec *fr, int n, MSize base_ofs,
                        MSize top_ofs, MSize usable,
                        ptrdiff_t *pos, unsigned char *isfw,
                        char *err, size_t errsz)
{
  ptrdiff_t f, bot = LJ_FR2;
  int i;
  if (n < 1) { snprintf(err, errsz, "no frames"); return -1; }
  if (base_ofs < (MSize)(1 + LJ_FR2) || base_ofs > top_ofs || top_ofs > usable)
    { snprintf(err, errsz, "base/top out of range"); return -1; }
  f = (ptrdiff_t)base_ofs - 1;
  for (i = 0; i < n; i++) {
    const FrameRec *r = &fr[i];
    ptrdiff_t prev;
    if (f <= bot) { snprintf(err, errsz, "frame %d at/below bottom", i); return -1; }
    if (f >= (ptrdiff_t)top_ofs)
      { snprintf(err, errsz, "frame %d word at/above top", i); return -1; }
    if ((r->link & 7) != 0)
      { snprintf(err, errsz, "frame %d link not 8-aligned", i); return -1; }
    if (r->link < 16)
      { snprintf(err, errsz, "frame %d link < 2 slots", i); return -1; }
    if (r->link > (uint64_t)(f - bot) * 8)
      { snprintf(err, errsz, "frame %d link runs off the bottom", i); return -1; }
    switch (r->kind) {
      case FRAME_LUA: case FRAME_CONT: case FRAME_VARG:
      case FRAME_PCALL: case FRAME_PCALLH:
        if (i == n - 1)
          { snprintf(err, errsz, "bottom frame must be C/CP"); return -1; }
        break;
      case FRAME_C: case FRAME_CP:
        if (i != n - 1)
          { snprintf(err, errsz, "interior C/CP frame %d", i); return -1; }
        break;
      default:
        snprintf(err, errsz, "frame %d: illegal kind %d", i, r->kind); return -1;
    }
    prev = f - (ptrdiff_t)(r->link / 8);
    pos[i] = f;
    isfw[f] = 1;                          /* the ftsz word */
    if (r->kind == FRAME_CONT) {
      if (f - 3 <= bot)
        { snprintf(err, errsz, "cont frame %d aux below bottom", i); return -1; }
      isfw[f - 2] = 1;                    /* contpc  */
      isfw[f - 3] = 1;                    /* cont    */
      if (r->cs >= CS_MAX)
        { snprintf(err, errsz, "cont frame %d: symbol %d out of range",
                   i, r->cs); return -1; }
      if (r->cs == CS_HOOK)
        { snprintf(err, errsz, "cont frame %d: lj_cont_hook refused", i); return -1; }
      if (r->cs == CS_STITCH) {
        if (f - 4 <= bot)
          { snprintf(err, errsz, "stitch frame %d: aux slot below bottom", i);
            return -1; }
        isfw[f - 4] = 1;                  /* saved-trace aux */
      }
    }
    f = prev;
  }
  if (f != bot)
    { snprintf(err, errsz, "chain ends at %d, not %d", (int)f, (int)bot); return -1; }
  return 0;
}

/* --------------------------------------------------- DECODE, pass 3 */
/* Slots are already in place; write the frame words, resolving protos out of
 * the restored func slots. Every FRAME_LUA link is re-derived and checked. */
static int decode_pass3(lua_State *co, const FrameRec *fr, int n,
                        const ptrdiff_t *pos, char *err, size_t errsz)
{
  TValue *stack = tvref(co->stack);
  int i;
  for (i = 0; i < n; i++) {
    const FrameRec *r = &fr[i];
    TValue *f = stack + pos[i];
    ptrdiff_t prevofs = pos[i] - (ptrdiff_t)(r->link / 8);
    TValue *prev = stack + prevofs;

    /* Every frame's own func slot must hold a function; the VM dereferences
     * it (gc_traverse_frames, lj_debug, BC_RET's KBASE reload). */
    if (!tvisfunc(f - 1))
      { snprintf(err, errsz, "frame %d: func slot %d is not a function",
                 i, (int)(pos[i] - 1)); return -1; }

    if (r->kind == FRAME_LUA || r->kind == FRAME_CONT) {
      GCproto *pt;
      const BCIns *pc;
      uint32_t ofs = (r->kind == FRAME_LUA) ? r->bcofs : r->cbcofs;
      if (!tvisfunc(prev - 1) || !isluafunc(funcV(prev - 1)))
        { snprintf(err, errsz, "frame %d: caller slot %d is not a Lua function",
                   i, (int)(prevofs - 1)); return -1; }
      pt = funcproto(funcV(prev - 1));
      if (ofs < 1 || ofs >= pt->sizebc)
        { snprintf(err, errsz, "frame %d: bc offset %u outside [1,%u)",
                   i, ofs, (unsigned)pt->sizebc); return -1; }
      pc = proto_bc(pt) + ofs;
      if (r->kind == FRAME_LUA) {
        setframe_pc(f, pc);                       /* lj_frame.h:51 (FR2) */
        if (frame_prevl(f) != prev) {
          setframe_ftsz(f, 0);
          snprintf(err, errsz, "frame %d: bc_a(%u)=%d disagrees with link "
                   "(%d slots)", i, ofs - 1, (int)bc_a(pc[-1]),
                   (int)(pos[i] - prevofs));
          return -1;
        }
        {  /* the instruction we return into must actually be a call */
          BCOp op = bc_op(pc[-1]);
          if (!(op == BC_CALL || op == BC_CALLM ||
                op == BC_ITERC || op == BC_ITERN)) {
            setframe_ftsz(f, 0);
            snprintf(err, errsz, "frame %d: return pc follows %s, not a call",
                     i, bcname(op));
            return -1;
          }
        }
      } else {
        (f - 3)->u64 = cs_addr[r->cs];            /* [base-4] = cont       */
        setframe_pc(f - 2, pc);                   /* [base-3] = contpc     */
        setframe_ftsz(f, (int64_t)(r->link | FRAME_CONT));
        if (r->cs == CS_STITCH) {
          /* vm_x64.dasc:2380-2404: the saved trace is read from [mbase-40],
           * cleartp'd and tested for zero -> cont_nop. Raw 0 is +0.0: itype 0,
           * NOT a GC value, so gc_marktv leaves it alone. LJ_TTRACE with a
           * NULL payload would also test zero but is a GC value -> crash. */
          (f - 4)->u64 = 0;
        }
      }
    } else {
      setframe_ftsz(f, (int64_t)(r->link | r->kind));
      if (r->kind == FRAME_VARG) {
        if (!isluafunc(funcV(f - 1)) ||
            !(funcproto(funcV(f - 1))->flags & PROTO_VARARG))
          { snprintf(err, errsz, "frame %d: VARG frame func is not vararg", i);
            return -1; }
      }
    }
  }
  return 0;
}

/* -------------------------------------------------------------- upvalues */
/* Replica of func_finduv (lj_func.c) minus the resurrect branch, allocating
 * on L (the coroutine's cframe is NULL, so an error there would panic). */
static GCupval *elj_finduv(lua_State *L, lua_State *co, TValue *slot,
                           uint32_t dhash, int immutable)
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
  uv->gct = ~LJ_TUPVAL;
  uv->closed = 0;
  uv->immutable = (uint8_t)immutable;
  uv->dhash = dhash;
  setmref(uv->v, slot);
  setgcrefr(uv->nextgc, *pp);
  setgcref(*pp, obj2gco(uv));
  setgcref(uv->prev, obj2gco(&g->uvhead));
  setgcrefr(uv->next, g->uvhead.next);
  setgcref(uvnext(uv)->prev, obj2gco(uv));
  setgcref(g->uvhead.next, obj2gco(uv));
  return uv;
}

/* ------------------------------------------------------------- scenarios */

static const char *SCEN_VARARG =
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

static const char *SCEN_CONT =
  "local t = setmetatable({}, { __index = function(_, k)\n"
  "  local got = coroutine.yield('in-index')\n"
  "  return k .. got\n"
  "end })\n"
  "local co = coroutine.create(function()\n"
  "  local v = t.missing\n"
  "  return v, #v\n"
  "end)\n"
  "coroutine.resume(co)\n"
  "return co\n";

static const char *SCEN_CAT =
  "local t = setmetatable({}, { __concat = function(a, b)\n"
  "  local got = coroutine.yield('in-concat')\n"
  "  return 'x' .. got\n"
  "end })\n"
  "local co = coroutine.create(function()\n"
  "  local s = 'a' .. t .. 'b'\n"
  "  return s, #s\n"
  "end)\n"
  "coroutine.resume(co)\n"
  "return co\n";

static const char *SCEN_NOP =
  "local t = setmetatable({}, { __newindex = function(tt, k, v)\n"
  "  local got = coroutine.yield('in-newindex')\n"
  "  rawset(tt, k, v .. got)\n"
  "end })\n"
  "local co = coroutine.create(function()\n"
  "  t.k = 'v'\n"
  "  return t.k\n"
  "end)\n"
  "coroutine.resume(co)\n"
  "return co\n";

static const char *SCEN_COND =
  "local mt = { __lt = function(a, b)\n"
  "  local got = coroutine.yield('in-lt')\n"
  "  return got > 3\n"
  "end }\n"
  "local a, b = setmetatable({}, mt), setmetatable({}, mt)\n"
  "local co = coroutine.create(function()\n"
  "  if a < b then return 'lt' else return 'ge' end\n"
  "end)\n"
  "coroutine.resume(co)\n"
  "return co\n";

static const char *SCEN_ITER =
  "local function iter(s, c)\n"
  "  if c >= 3 then return nil end\n"
  "  local got = coroutine.yield('iter' .. c)\n"
  "  return c + 1, got\n"
  "end\n"
  "local co = coroutine.create(function()\n"
  "  local acc = ''\n"
  "  for i, v in iter, nil, 0 do acc = acc .. i .. ':' .. v .. ' ' end\n"
  "  return acc\n"
  "end)\n"
  "coroutine.resume(co)\n"
  "return co\n";

static const char *SCEN_XPCALL =
  "local co = coroutine.create(function()\n"
  "  local ok, v = xpcall(function()\n"
  "    local g = coroutine.yield('deep')\n"
  "    return g * 2\n"
  "  end, function(e) return 'H' .. tostring(e) end)\n"
  "  return ok, v\n"
  "end)\n"
  "coroutine.resume(co)\n"
  "return co\n";

static const char *SCEN_STITCH =
  "local co = coroutine.create(function()\n"
  "  local s = 0\n"
  "  for i = 1, 1e9 do s = s + i; coroutine.yield(s) end\n"
  "end)\n"
  "for _ = 1, 400 do coroutine.resume(co) end\n"
  "return co\n";

/* ------------------------------------------------------ dump / load twin */

typedef struct { char *p; size_t n, cap; } Buf;

static int bwriter(lua_State *L, const void *p, size_t sz, void *ud)
{
  Buf *b = (Buf *)ud;
  (void)L;
  if (b->n + sz > b->cap) {
    size_t nc = (b->cap ? b->cap * 2 : 4096);
    while (nc < b->n + sz) nc *= 2;
    b->p = (char *)realloc(b->p, nc);
    if (!b->p) return 1;
    b->cap = nc;
  }
  memcpy(b->p + b->n, p, sz);
  b->n += sz;
  return 0;
}

typedef struct { const char *s; size_t sz; int done; } SReader;
static const char *sreader(lua_State *L, void *ud, size_t *size)
{
  SReader *r = (SReader *)ud;
  (void)L;
  if (r->done) { *size = 0; return NULL; }
  r->done = 1;
  *size = r->sz;
  return r->s;
}

/* Build the scenario coroutine. If `viadump`, the chunk is compiled, dumped
 * to bytecode and re-loaded first, so every GCproto is a fresh object. */
static lua_State *make_co(lua_State *L, const char *src, int viadump)
{
  if (luaL_loadstring(L, src)) {
    printf("  load error: %s\n", lua_tostring(L, -1)); fails++; return NULL;
  }
  if (viadump) {
    Buf b; SReader r;
    b.p = NULL; b.n = b.cap = 0;
    if (lua_dump(L, bwriter, &b) != 0) {
      printf("  dump failed\n"); fails++; free(b.p); return NULL;
    }
    lua_pop(L, 1);
    r.s = b.p; r.sz = b.n; r.done = 0;
    if (lua_load(L, sreader, &r, "=twin") != 0) {
      printf("  reload error: %s\n", lua_tostring(L, -1)); fails++;
      free(b.p); return NULL;
    }
    free(b.p);
  }
  if (lua_pcall(L, 0, 1, 0)) {
    printf("  scenario error: %s\n", lua_tostring(L, -1)); fails++; return NULL;
  }
  if (!lua_isthread(L, -1)) { printf("  no thread\n"); fails++; return NULL; }
  return lua_tothread(L, -1);   /* left on L's stack */
}

/* Resume a thread with one argument and stringify all results. */
static void drive(lua_State *co, int arg, char *out, size_t osz)
{
  int st, i, top;
  size_t k = 0;
  lua_pushinteger(co, arg);
  st = lua_resume(co, 1);
  top = lua_gettop(co);
  k += (size_t)snprintf(out + k, osz - k, "st=%d [", st);
  for (i = 1; i <= top && k < osz; i++) {
    const char *s = lua_tostring(co, i);
    k += (size_t)snprintf(out + k, osz - k, "%s%s", i > 1 ? "," : "",
                          s ? s : luaL_typename(co, i));
  }
  snprintf(out + k, osz - k, "]");
}

/* --------------------------------------------------------------- the test */

static int roundtrip(lua_State *L, const char *label, const char *src)
{
  FrameRec fr[MAXFR], fr2[MAXFR];
  ptrdiff_t pos[MAXFR];
  unsigned char isfw[4096];
  char err[256];
  lua_State *co, *twin, *nc;
  MSize base_ofs, top_ofs, usable, need, i;
  int n = 0, n2 = 0, j, nuv = 0, protos_differ = 0, raw_shared = 0;
  int uvslot[32]; GCupval *olduv[32];
  char r1[256], r2[256];
  int coidx, twinidx, ncidx;
  int before = fails;

  printf("\n===== %s =====\n", label);

  co = make_co(L, src, 0);
  if (!co) return -1;
  coidx = lua_gettop(L);
  twin = make_co(L, src, 1);
  if (!twin) return -1;
  twinidx = lua_gettop(L);

  /* --- encode both, compare the symbolic forms --- */
  if (encode(co, fr, &n, err, sizeof err) != 0)
    { printf("  encode(src) refused: %s\n", err); fails++; return -1; }
  if (encode(twin, fr2, &n2, err, sizeof err) != 0)
    { printf("  encode(twin) refused: %s\n", err); fails++; return -1; }

  printf("  src  stacksize=%d base_ofs=%d top_ofs=%d frames=%d\n",
         (int)co->stacksize, (int)(co->base - tvref(co->stack)),
         (int)(co->top - tvref(co->stack)), n);
  for (j = 0; j < n; j++) {
    printf("   [%d] slot=%3d %-6s link=%-3d", j, (int)fr[j].slot,
           kindname(fr[j].kind), (int)fr[j].link);
    if (fr[j].kind == FRAME_LUA) printf(" bcofs=%u", fr[j].bcofs);
    if (fr[j].kind == FRAME_CONT)
      printf(" cont=%s cbcofs=%u", cs_name[fr[j].cs], fr[j].cbcofs);
    printf("  rawftsz=%p / twin %p\n", fr[j].rawftsz, fr2[j].rawftsz);
  }
  CHECK(n == n2, "src/twin frame count differs (%d vs %d)", n, n2);
  if (n != n2) return -1;
  for (j = 0; j < n; j++) {
    CHECK(fr[j].kind == fr2[j].kind && fr[j].link == fr2[j].link &&
          fr[j].bcofs == fr2[j].bcofs && fr[j].cs == fr2[j].cs &&
          fr[j].cbcofs == fr2[j].cbcofs && fr[j].slot == fr2[j].slot,
          "src/twin symbolic frame %d differs", j);
    if (fr[j].kind == FRAME_LUA && fr[j].rawftsz == fr2[j].rawftsz)
      raw_shared++;
  }
  CHECK(raw_shared == 0, "%d FRAME_LUA pc words are identical pointers — "
        "the twin did not get fresh protos", raw_shared);

  base_ofs = (MSize)(co->base - tvref(co->stack));
  top_ofs  = (MSize)(co->top - tvref(co->stack));
  CHECK((MSize)(twin->base - tvref(twin->stack)) == base_ofs &&
        (MSize)(twin->top - tvref(twin->stack)) == top_ofs,
        "twin layout differs from src");

  /* --- collect the twin's open upvalues --- */
  {
    GCobj *o;
    for (o = gcref(twin->openupval); o; o = gcref(o->uv.nextgc)) {
      if (nuv < 32) {
        uvslot[nuv] = (int)(uvval(&o->uv) - tvref(twin->stack));
        olduv[nuv] = &o->uv;
        nuv++;
      }
    }
  }

  /* --- pass 1: derive positions and validate, protos not needed --- */
  usable = co->stacksize - 1 - LJ_STACK_EXTRA;
  memset(isfw, 0, sizeof isfw);
  if (decode_pass1(fr, n, base_ofs, top_ofs, usable, pos, isfw,
                   err, sizeof err) != 0)
    { printf("  pass1 rejected a GOOD record: %s\n", err); fails++; return -1; }
  for (j = 0; j < n; j++)
    CHECK(pos[j] == fr[j].slot, "derived pos[%d]=%d != encoded slot %d",
          j, (int)pos[j], (int)fr[j].slot);

  /* --- build the thread --- */
  nc = lua_newthread(L);
  ncidx = lua_gettop(L);
  need = usable;
  {
    MSize cur = (MSize)(mref(nc->maxstack, TValue) - tvref(nc->stack));
    if (need > cur) {
      int rc = lj_state_cpgrowstack(nc, need - cur);
      CHECK(rc == LUA_OK, "grow failed rc=%d", rc);
      if (rc != LUA_OK) return -1;
    }
  }

  /* --- pass 2: values (from the twin), skipping every frame word --- */
  for (i = 1 + LJ_FR2; i < top_ofs; i++) {
    if (!isfw[i])
      copyTV(nc, tvref(nc->stack) + i, tvref(twin->stack) + i);
    nc->top = tvref(nc->stack) + i + 1;
  }
  nc->top = tvref(nc->stack) + top_ofs;

  /* prove the protos we are about to decode against are new objects */
  for (j = 0; j < n; j++) {
    TValue *a = tvref(co->stack) + fr[j].slot - 1;
    TValue *b = tvref(nc->stack) + fr[j].slot - 1;
    if (tvisfunc(a) && tvisfunc(b) && isluafunc(funcV(a)) && isluafunc(funcV(b))) {
      if (funcproto(funcV(a)) != funcproto(funcV(b))) protos_differ++;
      else CHECK(0, "frame %d func slot shares a proto with the source", j);
    }
  }
  printf("  %d frame func slots hold Lua closures with FRESH protos\n",
         protos_differ);

  /* --- open upvalues on the new thread + referrer back-patch --- */
  for (j = 0; j < nuv; j++) {
    GCupval *nu = elj_finduv(L, nc, tvref(nc->stack) + uvslot[j],
                             olduv[j]->dhash, olduv[j]->immutable);
    MSize k;
    for (k = 0; k < top_ofs; k++) {
      TValue *o = tvref(nc->stack) + k;
      if (tvisfunc(o) && isluafunc(funcV(o))) {
        GCfunc *fn = funcV(o);
        uint32_t u;
        for (u = 0; u < fn->l.nupvalues; u++)
          if (&gcref(fn->l.uvptr[u])->uv == olduv[j]) {
            setgcref(fn->l.uvptr[u], obj2gco(nu));
            lj_gc_objbarrier(L, fn, obj2gco(nu));
          }
      }
    }
  }
  if (nuv) printf("  reopened %d upvalue(s) at slots", nuv);
  for (j = 0; j < nuv; j++) printf(" %d", uvslot[j]);
  if (nuv) printf("\n");

  /* --- pass 3: the frame words, symbolically --- */
  if (decode_pass3(nc, fr, n, pos, err, sizeof err) != 0)
    { printf("  pass3 rejected a GOOD record: %s\n", err); fails++; return -1; }

  /* nothing raw survived: every FRAME_LUA pc must differ from the source's */
  for (j = 0; j < n; j++) {
    if (fr[j].kind == FRAME_LUA || fr[j].kind == FRAME_CONT) {
      uint64_t a = (tvref(co->stack) + fr[j].slot)->u64;
      uint64_t b = (tvref(nc->stack) + fr[j].slot)->u64;
      if (fr[j].kind == FRAME_LUA)
        CHECK(a != b, "frame %d ftsz identical to the source (%#" PRIx64 ")",
              j, a);
    }
  }

  /* --- finalise --- */
  nc->base   = tvref(nc->stack) + base_ofs;
  nc->top    = tvref(nc->stack) + top_ofs;
  nc->status = LUA_YIELD;
  nc->cframe = NULL;
  setgcrefr(nc->env, twin->env);

  lua_gc(L, LUA_GCCOLLECT, 0);         /* the restored thread must survive GC */
  CHECK((MSize)(nc->base - tvref(nc->stack)) == base_ofs,
        "full GC moved base unexpectedly");

  /* --- resume both and compare --- */
  drive(co, 5, r1, sizeof r1);
  drive(nc, 5, r2, sizeof r2);
  printf("  original : %s\n  restored : %s\n", r1, r2);
  CHECK(strcmp(r1, r2) == 0, "results differ");

  /* --- negative tests on the same records --- */
  {
    FrameRec bad[MAXFR];
    ptrdiff_t p2[MAXFR];
    unsigned char m2[4096];
    int caught = 0, tried = 0;
    /* (a) EXHAUSTIVE: every in-range-but-wrong bc offset for every FRAME_LUA
     *     frame must be refused by the (bc_a agreement + call-op) checks. */
    for (j = 0; j < n; j++) {
      GCproto *pt;
      uint32_t o;
      TValue *cf;
      if (fr[j].kind != FRAME_LUA) continue;
      cf = tvref(twin->stack) + (fr[j].slot - (ptrdiff_t)(fr[j].link / 8)) - 1;
      if (!tvisfunc(cf) || !isluafunc(funcV(cf))) continue;
      pt = funcproto(funcV(cf));
      for (o = 1; o < pt->sizebc; o++) {
        lua_State *t;
        int rc;
        MSize cur;
        if (o == fr[j].bcofs) continue;
        memcpy(bad, fr, sizeof bad);
        bad[j].bcofs = o;
        memset(m2, 0, sizeof m2);
        tried++;
        if (decode_pass1(bad, n, base_ofs, top_ofs, usable, p2, m2,
                         err, sizeof err) != 0) { caught++; continue; }
        t = lua_newthread(L);
        cur = (MSize)(mref(t->maxstack, TValue) - tvref(t->stack));
        if (need > cur) lj_state_cpgrowstack(t, need - cur);
        for (i = 1 + LJ_FR2; i < top_ofs; i++) {
          if (!m2[i]) copyTV(t, tvref(t->stack) + i, tvref(twin->stack) + i);
          t->top = tvref(t->stack) + i + 1;
        }
        rc = decode_pass3(t, bad, n, p2, err, sizeof err);
        if (rc != 0) caught++;
        else printf("    ACCEPTED wrong bcofs %u on frame %d (op %s)\n",
                    o, j, bcname(bc_op(proto_bc(pt)[o - 1])));
        lua_pop(L, 1);
      }
    }
    printf("  negative: %d/%d in-range-but-wrong FRAME_LUA offsets rejected\n",
           caught, tried);
    CHECK(caught == tried, "%d wrong bc offsets slipped through",
          tried - caught);

    /* (b) a link that does not reach the bottom */
    memcpy(bad, fr, sizeof bad);
    bad[n - 1].link += 8;
    memset(m2, 0, sizeof m2);
    CHECK(decode_pass1(bad, n, base_ofs, top_ofs, usable, p2, m2,
                       err, sizeof err) != 0, "off-bottom chain accepted");
    printf("  negative: short bottom link -> %s\n", err);

    /* (c) an out-of-table continuation symbol */
    for (j = 0; j < n; j++) if (fr[j].kind == FRAME_CONT) {
      memcpy(bad, fr, sizeof bad);
      bad[j].cs = CS_MAX + 3;
      memset(m2, 0, sizeof m2);
      CHECK(decode_pass1(bad, n, base_ofs, top_ofs, usable, p2, m2,
                         err, sizeof err) != 0, "bad cont symbol accepted");
      printf("  negative: cont symbol %d -> %s\n", CS_MAX + 3, err);
      break;
    }
  }

  lua_remove(L, ncidx);
  lua_remove(L, twinidx);
  lua_remove(L, coidx);
  return fails - before;
}

int main(void)
{
  lua_State *L = luaL_newstate();
  if (!L) return 2;
  luaL_openlibs(L);
  cs_init();

  printf("m3frames: symbolic cross-process frame codec (GC64=%d FR2=%d)\n",
         LJ_GC64, LJ_FR2);
  printf("cont symbols:");
  { int i; for (i = 0; i < CS_MAX; i++)
      printf(" %s=%p", cs_name[i], (void *)(uintptr_t)cs_addr[i]); }
  printf("\n");

  roundtrip(L, "vararg + pcall + open upvalues", SCEN_VARARG);
  roundtrip(L, "__index metamethod (cont_ra)",   SCEN_CONT);
  roundtrip(L, "__concat metamethod (cont_cat)", SCEN_CAT);
  roundtrip(L, "__newindex metamethod (cont_nop)", SCEN_NOP);
  roundtrip(L, "__lt metamethod (cont_condt/condf)", SCEN_COND);
  roundtrip(L, "for-in iterator (ITERC frame)", SCEN_ITER);
  roundtrip(L, "xpcall (FRAME_PCALL)", SCEN_XPCALL);
  roundtrip(L, "JIT stitch frame (cont_stitch)", SCEN_STITCH);

  printf("\n%s (%d failure%s)\n", fails ? "RESULT: FAIL" : "RESULT: OK",
         fails, fails == 1 ? "" : "s");
  lua_close(L);
  return fails ? 1 : 0;
}
