/*
 * eris_lj.c — Eris-API-compatible serializer for the pinned LuaJIT build.
 * Milestone M1: data graphs. See eris_lj.h for the surface and
 * docs/persistence-study.md for the design rationale.
 *
 * Architecture follows fnuecke/eris (MIT): a reference table at a fixed
 * stack index dedupes shared/cyclic objects; every non-scalar is first
 * looked up in the caller's perms table; ids are assigned in encounter
 * order, and the persist and unpersist sides MUST register objects in the
 * identical sequence — containers before their contents (so cycles
 * resolve), and a permanent's own id reserved before its key is read back
 * (so the key's ids line up).
 *
 * Wire format v1:
 *   'E' 'L' 'J' <u8 format> <u8 fplen> <fingerprint bytes>
 *   <one value record>
 *   <u32le crc32 of every preceding byte>
 * Value records: see the Tag enum. Multi-byte integers are ULEB128.
 * Numbers are canonical: exact integers in +-2^53 as zigzag ULEB128
 * (identical on DUALNUM and non-DUALNUM builds), everything else
 * (incl. -0, NaN, inf) as 8 little-endian IEEE-754 bytes.
 *
 * Structural robustness: every read is bounds-checked, every wire byte that
 * indexes anything is range-checked, and recursion is bounded on both sides,
 * so a malformed blob raises a catchable Lua error rather than crashing.
 * Depth costs ~160 bytes of C stack per level on the read side at -O2 (one
 * unpersist() frame; u_table and u_function both inline into it), plus about
 * 19 KB of fixed frames, so ERIS_LJ_MAXREC_MAX stays under 40% of a 1 MB
 * thread stack — the JVM per-thread default an OC computer runs on.
 *
 * TRUST BOUNDARY (from M2 on): blobs contain LuaJIT bytecode, which the VM
 * does NOT verify, and the spkey protocol *calls* restored closures on load.
 * A tampered blob is therefore equivalent to arbitrary code execution in the
 * host process — the CRC32 detects corruption, not tampering (it is a
 * checksum, not a MAC, and any blob can be re-sealed). Upstream Eris and
 * Pluto share this property. Persisted blobs must come from storage at least
 * as trusted as the host itself; for OpenComputers that is the server's world
 * save directory, which only an operator can write. If blobs ever cross a
 * weaker boundary, add a keyed MAC over the body and verify it before the
 * first byte is parsed.
 *
 * Longjmp discipline: the write buffer is a __gc-owned userdata whose
 * storage comes from the host's own lua_Alloc (so it is inside the host's
 * memory accounting, and an error frees it via the finalizer). Nothing
 * else is heap-allocated; all working values live on the Lua stack.
 */

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "luajit.h"

/* The public lua_dump() hardcodes its flags, so it can neither drop debug
 * info nor ask for a deterministic dump. We ship a pinned LuaJIT, so calling
 * lj_bcwrite directly is safe (and is what the sidecar design sanctions). */
#include "lj_obj.h"
#include "lj_bcdump.h"
#include "lj_frame.h"
#include "lj_state.h"
#include "lj_gc.h"
#include "lj_vm.h"
#include "lj_bc.h"
#include "lj_tab.h"
#include "lj_trace.h"

#include "eris_lj.h"

/* ---------------------------------------------------------------- limits */

#ifndef ERIS_LJ_MAXREC_DEFAULT
#define ERIS_LJ_MAXREC_DEFAULT 2000
#endif

#ifndef ERIS_LJ_MAXREC_MAX
/* Hard ceiling on the effective recursion limit, whatever a host asks for:
 * enter() must always raise its catchable error before the native stack is
 * exhausted. At the ~160 B/level measured for M2 records, 2000 levels is
 * ~320 KB plus fixed frames — about a third of a 1 MB thread stack. */
#define ERIS_LJ_MAXREC_MAX 2000
#endif

/* Largest reference id we can hand to lua_rawseti/lua_rawgeti. */
#define ERIS_LJ_MAXREF 0x7fffffff

#define ERIS_LJ_FINGERPRINT ERIS_LJ_COMMIT "|" LUAJIT_VERSION

/* Fixed stack slots used by both directions. */
#define PERMIDX 1  /* perms (persist) / uperms (unpersist) table */
#define REFTIDX 2  /* reference table: obj->id persisting, id->obj restoring */
#define BUFIDX  3  /* write buffer userdata (persist) / input string anchor */
#define SPKIDX  4  /* the spkey string, kept alive here */
/* Upvalues live in their own id space: they are not first-class Lua values,
 * so they can never appear in a value slot, and keeping them separate makes
 * it impossible for a crafted blob to resolve a value reference to one.
 * Persisting: UPVIDX maps lightuserdata(upvalue id) -> id. Restoring: an
 * upvalue is identified by an owning closure plus a slot number, so UPVIDX
 * maps id -> owner closure and UPVNIDX maps id -> slot. */
#define UPVIDX  5
#define UPVNIDX 6
/* Restoring only: id -> a flat list {closure, slot, closure, slot, ...} of
 * every closure that referred to that upvalue. An upvalue that turns out to
 * be OPEN is not created until its thread has been restored, and closures
 * encountered in the meantime have already been joined to the placeholder,
 * so they must all be re-pointed at the real one afterwards. */
#define UPVLIST 7

/* ------------------------------------------------------------------ tags */

enum {
  TAG_NIL = 0,
  TAG_FALSE = 1,
  TAG_TRUE = 2,
  TAG_INT = 3,        /* zigzag ULEB128 */
  TAG_NUM = 4,        /* 8 LE bytes */
  TAG_STR = 5,        /* ULEB128 length + bytes */
  TAG_TABLE = 6,      /* u8 flag (0 = literal), pairs, nil, metatable */
  TAG_PERMANENT = 7,  /* u8 original type + the perms key as a value */
  TAG_REF = 8,        /* ULEB128 reference id */
  TAG_FUNC = 9,       /* u32le dump length, dump, ULEB128 nuv, uv records, fenv */
  TAG_UPVAL = 10,     /* upvalue slots only: a fresh upvalue, value follows */
  TAG_UPVALREF = 11,  /* upvalue slots only: ULEB128 upvalue id to join with */
  TAG_THREAD = 12,    /* suspended coroutine: header, slots, frames, upvalues */
  TAG_UPVALOPEN = 13, /* upvalue slots only: an OPEN upvalue of a thread slot */
  /* Reserved: 14 = userdata. */
  TAG_FORIN_ITER = 15 /* the for-in replay iterator; no payload */
};

/* Table record flags (byte after TAG_TABLE). */
#define TABLE_LITERAL 0
#define TABLE_SPECIAL 1  /* spkey function; M2 */

/* ------------------------------------------------------------------ info */

/* Frame kinds on the wire. These are the LuaJIT FRAME_* values, restated so
 * the format does not silently follow an internal enum. FRAME_LUAP (4) is
 * deliberately absent: it is not a real delta type, only an artifact of
 * frame_typep() applied to a Lua frame whose PC happens to have bit 2 set. */
#define FR_LUA    0
#define FR_C      1
#define FR_CONT   2
#define FR_VARG   3
#define FR_CP     5
#define FR_PCALL  6
#define FR_PCALLH 7

/* The closed continuation set (lj_vm.h). A CONT frame's continuation word is
 * jumped to directly by cont_dispatch (vm_x64.dasc: "jmp RA"), so it is the
 * single most dangerous word in the format: it is stored as a small enum with
 * no escape hatch, never a raw address. */
enum {
  CS_CAT = 0, CS_RA, CS_NOP, CS_CONDT, CS_CONDF, CS_HOOK, CS_STITCH, CS_MAX
};

static const void *const cont_addr[CS_MAX] = {
  (const void *)lj_cont_cat,   (const void *)lj_cont_ra,
  (const void *)lj_cont_nop,   (const void *)lj_cont_condt,
  (const void *)lj_cont_condf, (const void *)lj_cont_hook,
  (const void *)lj_cont_stitch
};

/* Ids reserved by a special-persistence record that is still being written.
 * A reference back into one of these means the __persist closure captured the
 * very object it is meant to reconstruct, which can never be loaded — worth
 * naming precisely instead of failing later as a dangling reference. Linked
 * through the C stack, so a longjmp discards it with the frames that own it. */
typedef struct PendingRef {
  lua_Integer id;
  struct PendingRef *prev;
} PendingRef;

/* Threads whose restore is still in flight. u_thread parks co->top at the
 * declared span before writing any slot, so co->top is not the live top while
 * a restore is running: a closure living in one of those slots can hold an
 * open upvalue over a slot the write cursor has not reached yet. Linked
 * through the C stack, like PendingRef, so a longjmp discards it with the
 * frames that own it, and it nests for coroutines inside coroutines. */
typedef struct RThread {
  lua_State *co;
  uint64_t top_ofs;
  struct RThread *prev;
} RThread;

typedef struct {
  lua_State *L;
  size_t len;                 /* bytes written (persist) */
  const unsigned char *in;    /* input (unpersist) */
  size_t inlen, pos;
  lua_Integer refcount;
  lua_Integer upvcount;       /* separate id space, see UPVIDX */
  lua_Integer curid;          /* persist: id persist_keyed just reserved */
  PendingRef *pending;
  RThread *rthreads;          /* unpersist: threads still being restored */
  int level, maxrec;
  int wdebug;                 /* keep debug info in dumps ('debug' setting) */
  int flushed;                /* JIT traces already flushed for this call */
} Info;

/* ----------------------------------------------------------------- crc32 */

/* Nibble table: const, so there is no lazy-init race between the many
 * lua_States a host may run concurrently on different threads. The extra
 * pass per byte is immaterial at save-time scale (a few ms per MB). */
static const uint32_t crc_tab[16] = {
  0x00000000u, 0x1DB71064u, 0x3B6E20C8u, 0x26D930ACu,
  0x76DC4190u, 0x6B6B51F4u, 0x4DB26158u, 0x5005713Cu,
  0xEDB88320u, 0xF00F9344u, 0xD6D6A3E8u, 0xCB61B38Cu,
  0x9B64C2B0u, 0x86D3D2D4u, 0xA00AE278u, 0xBDBDF21Cu
};

static uint32_t eris_crc32(const unsigned char *p, size_t n)
{
  uint32_t c = 0xFFFFFFFFu;
  size_t i;
  for (i = 0; i < n; i++) {
    c ^= p[i];
    c = (c >> 4) ^ crc_tab[c & 0xf];
    c = (c >> 4) ^ crc_tab[c & 0xf];
  }
  return ~c;
}

/* ------------------------------------------------------- write buffer */

/* Grown in place through the host allocator and owned by a __gc userdata
 * parked at BUFIDX: no superseded copies pile up, the memory is inside the
 * host's accounting, and a longjmp still frees it. */
typedef struct { unsigned char *p; size_t cap; } WBuf;

static void *wbuf_realloc(lua_State *L, void *p, size_t osz, size_t nsz)
{
  void *ud;
  lua_Alloc af = lua_getallocf(L, &ud);
  return af(ud, p, osz, nsz);
}

/* Idempotent, so it can be called eagerly on the normal return path and the
 * finalizer then becomes a no-op. Freeing at once keeps peak memory down:
 * otherwise the block lingers until the next GC cycle, and OC stops the GC
 * around persist entirely. */
static void wbuf_free(lua_State *L, WBuf *w)
{
  if (w && w->p) {
    wbuf_realloc(L, w->p, w->cap, 0);
    w->p = NULL;
    w->cap = 0;
  }
}

static int wbuf_gc(lua_State *L)
{
  wbuf_free(L, (WBuf *)lua_touserdata(L, 1));
  return 0;
}

static void wbuf_new(lua_State *L, size_t cap)  /* pushes the userdata */
{
  WBuf *w = (WBuf *)lua_newuserdata(L, sizeof(WBuf));
  w->p = NULL;
  w->cap = 0;
  /* Attach the finalizer before allocating, so a failure below is still
   * cleaned up. */
  lua_newtable(L);
  lua_pushcfunction(L, wbuf_gc);
  lua_setfield(L, -2, "__gc");
  lua_setmetatable(L, -2);
  w->p = (unsigned char *)wbuf_realloc(L, NULL, 0, cap);
  if (!w->p) luaL_error(L, "eris-lj: out of memory");
  w->cap = cap;
}

/* Non-erroring append: returns non-zero instead of raising. lua_dump's
 * writer callback must use this — a longjmp out of lj_bcwrite would abandon
 * its internal buffer state. */
static int w_try(Info *I, const void *p, size_t n)
{
  WBuf *w = (WBuf *)lua_touserdata(I->L, BUFIDX);
  if (I->len + n > w->cap) {
    size_t ncap = w->cap ? w->cap : 256;
    void *np;
    while (ncap < I->len + n) {
      if (ncap > ((size_t)-1) / 2) return 1;
      ncap *= 2;
    }
    np = wbuf_realloc(I->L, w->p, w->cap, ncap);
    if (!np) return 1;
    w->p = (unsigned char *)np;
    w->cap = ncap;
  }
  memcpy(w->p + I->len, p, n);
  I->len += n;
  return 0;
}

static void w_raw(Info *I, const void *p, size_t n)
{
  if (w_try(I, p, n))
    luaL_error(I->L, "eris-lj: out of memory writing %d bytes", (int)n);
}

static void w_byte(Info *I, unsigned char b) { w_raw(I, &b, 1); }

static void w_uleb(Info *I, uint64_t v)
{
  unsigned char b[10];
  int n = 0;
  do {
    unsigned char x = (unsigned char)(v & 0x7f);
    v >>= 7;
    if (v) x |= 0x80;
    b[n++] = x;
  } while (v);
  w_raw(I, b, (size_t)n);
}

static void w_u64le(Info *I, uint64_t v)
{
  unsigned char b[8];
  int i;
  for (i = 0; i < 8; i++) b[i] = (unsigned char)((v >> (8 * i)) & 0xff);
  w_raw(I, b, 8);
}

static void w_u32le(Info *I, uint32_t v)
{
  unsigned char b[4];
  int i;
  for (i = 0; i < 4; i++) b[i] = (unsigned char)((v >> (8 * i)) & 0xff);
  w_raw(I, b, 4);
}

/* Overwrite an already-written u32le (used to backpatch a dump's length,
 * which is only known once lua_dump has finished). */
static void w_patch_u32le(Info *I, size_t ofs, uint32_t v)
{
  WBuf *w = (WBuf *)lua_touserdata(I->L, BUFIDX);
  int i;
  for (i = 0; i < 4; i++) w->p[ofs + i] = (unsigned char)((v >> (8 * i)) & 0xff);
}

/* -------------------------------------------------------------- read side */

static void r_need(Info *I, size_t n)
{
  /* I->pos never exceeds I->inlen (every advance is preceded by a check),
   * so the subtraction below cannot wrap. */
  if (I->pos > I->inlen || n > I->inlen - I->pos)
    luaL_error(I->L, "eris-lj: truncated data (want %d more bytes at %d/%d)",
               (int)n, (int)I->pos, (int)I->inlen);
}

static unsigned char r_byte(Info *I)
{
  r_need(I, 1);
  return I->in[I->pos++];
}

static void r_raw(Info *I, void *p, size_t n)
{
  r_need(I, n);
  memcpy(p, I->in + I->pos, n);
  I->pos += n;
}

static uint64_t r_uleb(Info *I)
{
  uint64_t v = 0;
  int shift = 0;
  for (;;) {
    unsigned char b = r_byte(I);
    if (shift > 63 || (shift == 63 && (b & 0x7f) > 1))
      luaL_error(I->L, "eris-lj: varint overflows 64 bits");
    v |= (uint64_t)(b & 0x7f) << shift;
    if (!(b & 0x80)) break;
    shift += 7;
  }
  return v;
}

static uint32_t r_u32le(Info *I)
{
  unsigned char b[4];
  r_raw(I, b, 4);
  return (uint32_t)b[0] | ((uint32_t)b[1] << 8) |
         ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}

static uint64_t r_u64le(Info *I)
{
  unsigned char b[8];
  uint64_t v = 0;
  int i;
  r_raw(I, b, 8);
  for (i = 7; i >= 0; i--) v = (v << 8) | b[i];
  return v;
}

/* -------------------------------------------------------------- numbers */

/* Exactly-representable integer range for doubles; staying inside it keeps
 * the int fast path free of undefined conversions and of NaN/inf edges. */
#define ERIS_INT_LIMIT 9007199254740992.0  /* 2^53 */

static void p_number(Info *I)
{
  lua_Number n = lua_tonumber(I->L, -1);
  if (n >= -ERIS_INT_LIMIT && n <= ERIS_INT_LIMIT) {  /* false for NaN */
    int64_t i = (int64_t)n;
    /* Reject -0.0: it converts to integer 0 and would lose its sign. */
    if ((lua_Number)i == n && !(i == 0 && signbit(n))) {
      uint64_t zz = ((uint64_t)i << 1) ^ (uint64_t)(i >> 63);
      w_byte(I, TAG_INT);
      w_uleb(I, zz);
      return;
    }
  }
  {
    uint64_t bits;
    double d = (double)n;
    memcpy(&bits, &d, 8);
    w_byte(I, TAG_NUM);
    w_u64le(I, bits);
  }
}

/* --------------------------------------------------------------- helpers */

static lua_Integer newref(Info *I)
{
  if (I->refcount >= ERIS_LJ_MAXREF)
    luaL_error(I->L, "eris-lj: too many distinct objects");
  return ++I->refcount;
}

static void registerobject(Info *I)  /* ... obj */
{
  lua_Integer ref = newref(I);
  luaL_checkstack(I->L, 1, "eris-lj ref");
  lua_pushvalue(I->L, -1);
  lua_rawseti(I->L, REFTIDX, (int)ref);
}

static void enter(Info *I)
{
  if (++I->level > I->maxrec)
    luaL_error(I->L, "eris-lj: too complex (recursion limit %d reached)",
               I->maxrec);
}

static void leave(Info *I) { --I->level; }

/* ------------------------------------------------------------ persisting */

static void persist(Info *I);
static void unpersist(Info *I);

static void p_string(Info *I)  /* ... str */
{
  size_t len;
  const char *s = lua_tolstring(I->L, -1, &len);
  w_byte(I, TAG_STR);
  w_uleb(I, (uint64_t)len);
  w_raw(I, s, len);
}

static void p_metatable(Info *I)  /* ... obj */
{
  luaL_checkstack(I->L, 2, "eris-lj mt");
  if (!lua_getmetatable(I->L, -1)) lua_pushnil(I->L);
  persist(I);
  lua_pop(I->L, 1);
}

static void p_literaltable(Info *I)  /* ... tbl */
{
  lua_State *L = I->L;
  luaL_checkstack(L, 4, "eris-lj table");
  lua_pushnil(L);                       /* tbl nil */
  while (lua_next(L, -2)) {             /* tbl k v */
    lua_pushvalue(L, -2);               /* tbl k v k */
    persist(I);
    lua_pop(L, 1);                      /* tbl k v */
    persist(I);
    lua_pop(L, 1);                      /* tbl k */
  }                                     /* tbl */
  lua_pushnil(L);                       /* tbl nil */
  persist(I);
  lua_pop(L, 1);                        /* tbl */
  p_metatable(I);
}


/* Find the thread whose stack an open upvalue points into, among the threads
 * already registered in the reference table. LuaJIT gives an upvalue no
 * back-pointer to its thread, so there is nothing better to search: a thread
 * encountered LATER cannot be found here, and the caller then falls back to
 * writing the upvalue by value. That is exact for the case that matters --
 * OpenComputers persists the kernel coroutine as the root, so it is always
 * registered before anything that could capture one of its slots. */
static lua_State *elj_owner_of_open_uv(lua_State *L, GCupval *uv)
{
  lua_State *found = NULL;
  luaL_checkstack(L, 3, "eris-lj uvowner");
  lua_pushnil(L);
  while (lua_next(L, REFTIDX)) {        /* key value */
    if (lua_isthread(L, -2)) {
      lua_State *co = lua_tothread(L, -2);
      GCobj *o;
      if (co->status <= LUA_YIELD)      /* dead threads own no live slots */
        for (o = gcref(co->openupval); o; o = gcref(o->uv.nextgc))
          if (&o->uv == uv) { found = co; break; }
    }
    lua_pop(L, 1);
    if (found) { lua_pop(L, 1); break; }
  }
  return found;
}


/* Search every live thread for the one whose stack an open upvalue points
 * into. Threads are chained on the GC root list; the main thread lives in
 * GG_State and is not on it, so it is checked separately. This is only
 * reached for open upvalues, and only when the cheap reference-table lookup
 * missed, so the cost stays off the common path. */
static lua_State *elj_find_owner_any(lua_State *L, GCupval *uv)
{
  global_State *g = G(L);
  GCobj *o;
  lua_State *m = mainthread(g);
  for (o = gcref(m->openupval); o; o = gcref(o->uv.nextgc))
    if (&o->uv == uv) return m;
  for (o = gcref(g->gc.root); o; o = gcref(o->gch.nextgc)) {
    if (o->gch.gct == ~LJ_TTHREAD) {
      lua_State *co = &o->th;
      GCobj *u;
      for (u = gcref(co->openupval); u; u = gcref(u->uv.nextgc))
        if (&u->uv == uv) return co;
    }
  }
  return NULL;
}

/* lua_dump writer: must not raise, so it uses w_try and reports failure
 * through the context instead. */
typedef struct { Info *I; int failed; } DumpCtx;

static int dump_writer(lua_State *L, const void *p, size_t sz, void *ud)
{
  DumpCtx *c = (DumpCtx *)ud;
  (void)L;
  if (c->failed) return 1;
  if (w_try(c->I, p, sz)) { c->failed = 1; return 1; }
  return 0;
}

/* lua_dump() with the two flags it does not expose: DETERMINISTIC (so the
 * same closure always dumps to the same bytes — LuaJIT otherwise emits
 * template-table constants in hash order, which its per-process hash seed
 * randomises) and STRIP (so eris.settings("debug", false) can actually drop
 * debug info, which dominates the size of a typical blob). */
static int elj_dump(lua_State *L, lua_Writer w, void *ud, int keepdebug)
{
  cTValue *o = L->top - 1;
  uint32_t flags = LJ_FR2 * BCDUMP_F_FR2 | BCDUMP_F_DETERMINISTIC;
  if (!keepdebug) flags |= BCDUMP_F_STRIP;
  if (tvisfunc(o) && isluafunc(funcV(o)))
    return lj_bcwrite(L, funcproto(funcV(o)), w, ud, flags);
  return 1;
}

static void p_function(Info *I)  /* ... f */
{
  lua_State *L = I->L;
  DumpCtx ctx;
  size_t lenofs, dumplen;
  int fidx, nuv, i;

  luaL_checkstack(L, 6, "eris-lj func");
  fidx = lua_gettop(L);                 /* f must be on top for lua_dump */

  w_byte(I, TAG_FUNC);
  lenofs = I->len;
  w_u32le(I, 0);                        /* placeholder, backpatched below */

  ctx.I = I;
  ctx.failed = 0;
  if (elj_dump(L, dump_writer, &ctx, I->wdebug) != 0 || ctx.failed)
    luaL_error(L, "eris-lj: cannot dump function%s",
               ctx.failed ? " (out of memory)" : "");
  dumplen = I->len - lenofs - 4;
  if (dumplen > 0xffffffffu)
    luaL_error(L, "eris-lj: function dump too large");
  w_patch_u32le(I, lenofs, (uint32_t)dumplen);

  /* Upvalues. Identity — not just value — has to survive: closures sharing
   * a variable must still share it after a restore, so each distinct
   * upvalue is written once (keyed by lua_upvalueid) and later users write
   * a reference to join with. */
  nuv = 0;
  while (lua_getupvalue(L, fidx, nuv + 1)) { lua_pop(L, 1); nuv++; }
  w_uleb(I, (uint64_t)nuv);
  for (i = 1; i <= nuv; i++) {
    void *uvid = lua_upvalueid(L, fidx, i);
    lua_pushlightuserdata(L, uvid);     /* uvid */
    lua_rawget(L, UPVIDX);              /* id? */
    if (!lua_isnil(L, -1)) {
      w_byte(I, TAG_UPVALREF);
      w_uleb(I, (uint64_t)lua_tointeger(L, -1));
      lua_pop(L, 1);
    } else {
      GCupval *uv = (GCupval *)uvid;
      lua_pop(L, 1);
      if (I->upvcount >= ERIS_LJ_MAXREF)
        luaL_error(L, "eris-lj: too many distinct upvalues");
      ++I->upvcount;
      lua_pushlightuserdata(L, uvid);
      lua_pushinteger(L, I->upvcount);
      lua_rawset(L, UPVIDX);
      /* An OPEN upvalue aliases a live stack slot. If the thread that owns
       * that slot is itself part of the graph, the aliasing has to survive,
       * so the upvalue is identified by (thread, slot). If it is not — the
       * usual case for a closure created inside a still-running function —
       * there is no frame on the other side to alias, and the value is the
       * whole of its observable content, so it is written like a closed one
       * (which is what M2 did for every upvalue). */
      lua_State *owner = uv->closed ? NULL : elj_owner_of_open_uv(L, uv);
      if (owner == NULL && !uv->closed) {
        /* Not reached yet by the graph walk. If a real coroutine owns the
         * slot, that coroutine IS part of this closure's state — aliasing a
         * live frame is not something a value copy can express — so it is
         * pulled in. The main thread is never persistable, so an upvalue
         * open into it is captured by value instead. */
        lua_State *any = elj_find_owner_any(L, uv);
        /* A dead thread is excluded for the same reason it emits no
         * upvalue records: its stack is normalised away, so there is no slot
         * left to alias. Such an upvalue is written by value instead. */
        if (any != NULL && any != mainthread(G(L)) && any != L &&
            any->cframe == NULL && any->status <= LUA_YIELD)
          owner = any;
      }
      if (owner != NULL) {
        w_byte(I, TAG_UPVALOPEN);
        setthreadV(L, L->top, owner);
        L->top++;
        persist(I);                     /* the owning thread */
        lua_pop(L, 1);
        w_uleb(I, (uint64_t)(uvval(uv) - tvref(owner->stack)));
      } else {
        w_byte(I, TAG_UPVAL);
        lua_getupvalue(L, fidx, i);     /* value */
        persist(I);
        lua_pop(L, 1);
      }
    }
  }

  /* LuaJIT is Lua 5.1: closures carry a function environment separate from
   * their upvalues, and OC's sandbox is installed exactly that way (via
   * load()'s env argument), so it has to round-trip too. */
  lua_getfenv(L, fidx);
  persist(I);
  lua_pop(L, 1);
}


/* -------------------------------------------------- for-in replay (pairs) */

/* THE PAIRS GAP.
 *
 * A generic for-in loop over pairs()/next carries its position as an index
 * into the table's CURRENT layout. BC_ITERN keeps that index in the loop's
 * control slot, tagged LJ_KEYINDEX; the despecialised BC_ITERC form keeps the
 * previous key instead, which lj_tab_keyindex turns straight back into such an
 * index. Neither survives a move to another process: LuaJIT places a string
 * key at hashmask(t, s->sid), and sid comes from a per-VM counter reseeded
 * from the PRNG every few hundred strings, so the same table rebuilt in a
 * fresh VM has a different node order and a resumed loop silently skips or
 * repeats keys. (PUC Lua with upstream Eris has the same defect and does not
 * even refuse; it seeds per lua_State, so it diverges between two coroutines
 * in one process. See docs/research/pg-stock-oc-parity.md.)
 *
 * So the position is not persisted at all. Instead the keys the loop has not
 * yet reached are snapshotted in the saving VM's own traversal order, and the
 * loop's hidden (func, state, control) triple is rewritten -- ON THE WIRE
 * ONLY, never in the saving VM -- to replay that list:
 *
 *   func    = elj_forin_replay                 (TAG_FORIN_ITER)
 *   state   = { [1]=t, [2]=keys, [3]=pos }     (an ordinary table)
 *   control = nil, and thereafter the previous key
 *
 * Values are still read live out of t, so a body that assigns t[k] later in
 * the loop sees the new value, and a key deleted mid-loop is skipped -- both
 * exactly as `next` behaves. Keys ADDED during a traversal are not visited,
 * which the language already leaves undefined.
 *
 * BC_ITERN validates nothing: it masks the state slot's type tag rather than
 * testing it (vm_x64.dasc, cleartp == shl 17/shr 17) and never reads the func
 * slot at all. A replay triple installed under a still-specialised ITERN would
 * therefore be read as a raw GCtab layout, so the restore despecialises the
 * loop first -- ITERN -> ITERC and that loop's ISNEXT -> JMP. That is a pure
 * opcode-byte swap, because the parser emits both pairs with identical
 * operands (lj_parse.c:2921,2930), and it is the same edit LuaJIT itself
 * performs on live loops in blacklist_pc (lj_trace.c:380). */

static int elj_forin_replay(lua_State *L)  /* (state, control) -> key, value */
{
  lua_Integer i;
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_settop(L, 2);
  lua_rawgeti(L, 1, 3);                 /* s ctl pos */
  if (lua_isnil(L, 2)) {
    i = 0;                              /* nil control starts the traversal */
  } else {
    if (!lua_istable(L, 3))
      return luaL_error(L, "eris-lj: malformed for-in replay state");
    lua_pushvalue(L, 2);                /* s ctl pos ctl */
    lua_rawget(L, 3);                   /* s ctl pos i? */
    if (lua_type(L, -1) != LUA_TNUMBER)
      return luaL_error(L, "eris-lj: for-in replay resumed from a key that is "
                           "not in its own key list");
    i = lua_tointeger(L, -1);
    lua_pop(L, 1);                      /* s ctl pos */
  }
  lua_rawgeti(L, 1, 2);                 /* s ctl pos keys */
  lua_rawgeti(L, 1, 1);                 /* s ctl pos keys t */
  if (!lua_istable(L, 4) || !lua_istable(L, 5))
    return luaL_error(L, "eris-lj: malformed for-in replay state");
  for (;;) {
    if (i < 0 || i >= ERIS_LJ_MAXREF)
      return luaL_error(L, "eris-lj: for-in replay index out of range");
    lua_rawgeti(L, 4, (int)++i);        /* ... key */
    if (lua_isnil(L, -1)) return 1;     /* exhausted: a nil ends the loop */
    lua_pushvalue(L, -1);
    lua_rawget(L, 5);                   /* ... key t[key] */
    if (!lua_isnil(L, -1)) return 2;    /* the LIVE value, raw, like next() */
    lua_pop(L, 2);                      /* deleted mid-loop: skip it */
  }
}

/* ... t -> ... { [1]=t, [2]=keys, [3]=pos }
 * `keys` are the keys a traversal of t starting at keyindex `idx` would still
 * visit, and `pos` maps each back to its position. The walk mirrors
 * lj_tab_next exactly -- array part, then the node part -- so the list is this
 * VM's own traversal order with the already-visited prefix cut off. Keeping
 * `pos` rather than a cursor in the state keeps the iterator stateless, so
 * calling it twice with the same control value answers the same thing, which
 * is the contract `next` has. */
static void elj_push_replay_state(lua_State *L, uint32_t idx)
{
  GCtab *t;
  uint32_t k, n = 0;
  if (!tvistab(L->top - 1))
    luaL_error(L, "eris-lj: for-in loop state is a %s, expected a table",
               luaL_typename(L, -1));
  t = tabV(L->top - 1);
  luaL_checkstack(L, 8, "eris-lj for-in replay");
  lua_newtable(L);                      /* t keys */
  for (k = idx; k < t->asize; k++) {
    lua_pushinteger(L, (lua_Integer)k);
    lua_rawseti(L, -2, (int)++n);
  }
  k -= t->asize;                        /* exactly as lj_tab_next does */
  for (; k <= t->hmask; k++) {
    Node *nd = &noderef(t->node)[k];
    /* By KEY, not by value. A traversal visits SLOTS and decides at the moment
     * it reaches one, so a key whose value is nil right now is still visited
     * if the program restores it before the cursor gets there -- LuaJIT nils
     * the value and keeps the node. Filtering here instead would drop such a
     * key forever, and the save point is the host's choice, not the
     * program's. elj_forin_replay re-checks t[key] on arrival, so the test
     * belongs there. An empty node has a nil key and is correctly skipped:
     * only a rehash could put a key there, and that is what makes inserting
     * during a traversal undefined in the first place. */
    if (!tvisnil(&nd->key)) {
      copyTV(L, L->top, &nd->key);      /* the key, whatever its type */
      L->top++;
      lua_rawseti(L, -2, (int)++n);
    }
  }
  lua_newtable(L);                      /* t keys pos */
  for (k = 1; k <= n; k++) {
    lua_rawgeti(L, -2, (int)k);         /* t keys pos key */
    lua_pushinteger(L, (lua_Integer)k); /* t keys pos key k */
    lua_rawset(L, -3);                  /* t keys pos */
  }
  lua_createtable(L, 3, 0);             /* t keys pos s */
  lua_pushvalue(L, -4); lua_rawseti(L, -2, 1);
  lua_pushvalue(L, -3); lua_rawseti(L, -2, 2);
  lua_pushvalue(L, -2); lua_rawseti(L, -2, 3);
  lua_replace(L, -4);                   /* s keys pos */
  lua_pop(L, 2);                        /* s */
}

/* ... state control -> ... state'
 * Build a fresh replay state carrying only the keys the loop has not reached
 * yet. Used when a thread that was ALREADY restored once is persisted again:
 * without it every later blob would re-ship the whole original snapshot and
 * keep every already-visited key strongly alive for the life of the loop. */
static void elj_repack_replay_state(lua_State *L)
{
  lua_Integer i = 0, n = 0, j;
  luaL_checkstack(L, 8, "eris-lj for-in replay");
  if (!lua_istable(L, -2))
    luaL_error(L, "eris-lj: for-in replay state is not a table");
  if (!lua_isnil(L, -1)) {
    lua_rawgeti(L, -2, 3);              /* state ctl pos */
    if (!lua_istable(L, -1))
      luaL_error(L, "eris-lj: for-in replay state has no position map");
    lua_pushvalue(L, -2);               /* state ctl pos ctl */
    lua_rawget(L, -2);                  /* state ctl pos i? */
    if (lua_type(L, -1) != LUA_TNUMBER)
      luaL_error(L, "eris-lj: for-in replay control is not in its key list");
    i = lua_tointeger(L, -1);
    if (i < 0 || i >= ERIS_LJ_MAXREF)
      luaL_error(L, "eris-lj: for-in replay position out of range");
    lua_pop(L, 2);                      /* state ctl */
  }
  lua_pop(L, 1);                        /* state */
  lua_rawgeti(L, -1, 2);                /* state keys */
  if (!lua_istable(L, -1))
    luaL_error(L, "eris-lj: for-in replay state has no key list");
  lua_newtable(L);                      /* state keys keys' */
  for (j = i + 1; j < ERIS_LJ_MAXREF; j++) {
    lua_rawgeti(L, -2, (int)j);
    if (lua_isnil(L, -1)) { lua_pop(L, 1); break; }
    lua_rawseti(L, -2, (int)++n);
  }
  lua_newtable(L);                      /* state keys keys' pos' */
  for (j = 1; j <= n; j++) {
    lua_rawgeti(L, -2, (int)j);
    lua_pushinteger(L, j);
    lua_rawset(L, -3);
  }
  lua_createtable(L, 3, 0);             /* state keys keys' pos' s' */
  lua_rawgeti(L, -5, 1);                /* the iterated table, unchanged */
  lua_rawseti(L, -2, 1);
  lua_pushvalue(L, -3); lua_rawseti(L, -2, 2);
  lua_pushvalue(L, -2); lua_rawseti(L, -2, 3);
  lua_replace(L, -5);                   /* s' keys keys' pos' */
  lua_pop(L, 3);                        /* s' */
}

/* One for-in loop that has to be replayed rather than resumed in place.
 * Positions are stack OFFSETS, so a GC that moves the thread's stack while
 * the replay states are being built cannot invalidate them. */
typedef struct {
  ptrdiff_t ctl;      /* stack slot of the control var (register RA-1) */
  uint32_t ra;        /* the loop instruction's A operand */
  uint32_t idx;       /* keyindex the snapshot starts at */
  uint32_t itern;     /* bcofs of the loop head, or 0 for "every loop head in
                       * the prototype whose A operand is `ra`" */
  int replay;         /* the triple is ALREADY in replay form: this thread was
                       * restored once and is being persisted again */
} ForinRec;

/* Current bytecode offset of the frame BELOW `above`, recovered the way
 * lj_debug.c's debug_framepc does it: a Lua or continuation frame stores the
 * pc it will return to, which IS its caller's current position. The third
 * branch debug_framepc has -- walking the C frame chain -- does not exist
 * here, because a suspended thread always has cframe == NULL. Returns 0 when
 * the position cannot be established; 0 is never a real loop position, since
 * instruction 0 is always the prototype's header. */
static uint32_t elj_frame_pc(GCproto *pt, TValue *above)
{
  const BCIns *ins, *bc;
  if (above == NULL) return 0;
  if (frame_islua(above)) ins = frame_pc(above);
  else if (frame_iscont(above)) ins = frame_contpc(above);
  else return 0;
  bc = proto_bc(pt);
  if (ins <= bc || ins > bc + pt->sizebc) return 0;
  return (uint32_t)(ins - bc) - 1;      /* the call, not the return address */
}

/* Extent of the loop body belonging to the loop head at `pos`. The generic-for
 * layout is
 *      ISNEXT/JMP base -> loop        (at body-1)
 *   body: ... the body ...
 *   loop: ITERN/ITERC base, ...
 *         ITERL base -> body
 * so the body is [ITERL target, pos). Returns 0 when the extent cannot be
 * read: BC_JITERL's D field is a trace number rather than a jump offset, so a
 * traced loop must not be guessed at (which is why persist flushes first). */
static int elj_loop_body(GCproto *pt, uint32_t pos, uint32_t *body)
{
  const BCIns *bc = proto_bc(pt);
  ptrdiff_t b;
  if (pos + 1 >= pt->sizebc) return 0;
  if (bc_op(bc[pos + 1]) != BC_ITERL && bc_op(bc[pos + 1]) != BC_IITERL)
    return 0;
  b = (ptrdiff_t)pos + 2 + bc_j(bc[pos + 1]);
  if (b < 1 || b > (ptrdiff_t)pos) return 0;
  *body = (uint32_t)b;
  return 1;
}

/* Walk a suspended thread's frames, innermost first, and find every generic
 * for-in loop over pairs()/next that is still running.
 *
 * Two shapes exist and only one of them announces itself:
 *
 *  - BC_ITERN, the specialised form, whose control slot carries LJ_KEYINDEX.
 *  - BC_ITERC calling the real `next`, which the VM leaves behind whenever
 *    BC_ISNEXT's guard fails once (a __pairs shim, or `next, t, startkey` with
 *    a non-nil start) and whenever blacklist_pc despecialises a hot but
 *    untraceable loop. Its control slot holds a plain key with no marker at
 *    all. That form persists today and corrupts silently.
 *
 * Both are found the same way -- by scanning the frame's prototype for loop
 * heads and testing the triple each one addresses -- because a live loop's
 * (func, state, control) always sits at registers RA-3/RA-2/RA-1 with the real
 * `next` in the func slot: BC_ISNEXT only specialises after checking
 * ffid == FF_next_N, and the despecialised form still calls that same
 * function. Where the frame's position is known it decides liveness outright;
 * where it is not, an unmarked triple is ambiguous and is refused rather than
 * guessed at, because rewriting three ordinary locals that happen to hold
 * (next, a table, one of its keys) would corrupt live data.
 *
 * With recs == NULL this only returns an upper bound on the number of records
 * -- every loop head in every Lua frame -- so the caller can size the array
 * before anything is allocated. That counting walk touches no Lua object and
 * so cannot move the stack under the detection walk that follows. */
static uint32_t elj_forin_scan(Info *I, lua_State *co, uint64_t top_ofs,
                               ForinRec *recs, uint32_t cap)
{
  lua_State *L = I->L;
  TValue *stack = tvref(co->stack);
  TValue *bot = stack + LJ_FR2;
  TValue *f, *above = NULL;
  uint32_t n = 0;
  int above_varg = 0;

  if (co->status > LUA_YIELD) return 0;  /* normalised to an empty stack */

  for (f = co->base - 1; f > bot; ) {
    TValue *nextf = frame_islua(f) ? frame_prevl(f) : frame_prevd(f);
    /* BC_FUNCV leaves a SECOND copy of the function below the varargs, whose
     * "base" would address the vararg region instead of the frame's
     * registers. lj_debug_frame skips it the same way. */
    int pseudo = above_varg;
    above_varg = frame_isvarg(f);
    if (!pseudo && tvisfunc(f - 1) && isluafunc(funcV(f - 1))) {
      GCproto *pt = funcproto(funcV(f - 1));
      const BCIns *bc = proto_bc(pt);
      ptrdiff_t base_ofs = (f + 1) - stack;
      uint32_t pc = elj_frame_pc(pt, above);
      uint32_t pos;
      for (pos = 1; pos + 1 < pt->sizebc; pos++) {
        BCOp op = bc_op(bc[pos]);
        uint32_t ra, body, idx, j;
        ptrdiff_t ctl_ofs;
        TValue *fn, *st, *ctl;
        int inbody, recs_replay = 0;
        if (recs == NULL) {
          /* Capacity bound only -- and this pass runs BEFORE the trace flush,
           * so a compiled loop head still reads as BC_JLOOP. Counting that too
           * is what makes a hot loop force the flush that reveals it. */
          if (op == BC_ITERN || op == BC_ITERC || op == BC_JLOOP) n++;
          continue;
        }
        if (op != BC_ITERN && op != BC_ITERC) continue;
        /* Classified by the CONTROL SLOT below, never by the opcode:
         * blacklist_pc despecialises a RUNNING loop and leaves its
         * LJ_KEYINDEX control value in place (lj_tab_keyindex has a branch
         * for exactly that), so an ITERC head can carry either form. */
        ra = bc_a(bc[pos]);
        if (ra < 3 || (uint32_t)(ra - 1) >= pt->framesize) continue;
        ctl_ofs = base_ofs + (ptrdiff_t)ra - 1;
        if (ctl_ofs < (ptrdiff_t)(3 + LJ_FR2) ||
            ctl_ofs >= (ptrdiff_t)top_ofs) continue;
        /* Where the position is known it is decisive in both directions.
         * The range is INCLUSIVE of the loop head: when a loop's iterator is
         * a Lua function that yields, the frame's position sits exactly on
         * the ITERC while the hidden triple is still live. */
        inbody = -1;
        if (pc != 0 && elj_loop_body(pt, pos, &body))
          inbody = (pc >= body && pc <= pos);
        if (inbody == 0) continue;
        fn = stack + ctl_ofs - 2;
        st = stack + ctl_ofs - 1;
        ctl = stack + ctl_ofs;
        if (!tvistab(st)) continue;
        if (ctl->u32.hi == LJ_KEYINDEX) {
          /* The specialised form, and unambiguous: only BC_ISNEXT ever writes
           * this value. The FUNC SLOT IS NOT PART OF THE TEST. BC_ITERN never
           * reads it, so it need not hold `next` at all -- table.foreach's
           * loop, compiled into every lua_State at LuaJIT build time, leaves
           * it nil, because genlibbc.lua rewrites its PAIRS(t) into
           * `nil, t, 0x4dp80` and then patches the resulting ITERC byte back
           * to ITERN. Gating on the func slot refused that loop outright.
           * Classify by the control slot; never by the func slot or the
           * opcode. (The restore writes the replay iterator into the func
           * slot, which the despecialised ITERC then does read.) */
          idx = ctl->u32.lo;
        } else if (!tvisfunc(fn)) {
          continue;
        } else if (funcV(fn)->c.ffid == FF_C &&
                   funcV(fn)->c.f == elj_forin_replay) {
          /* This thread was restored once already and is being persisted
           * again. The triple is ours, so it is as self-identifying as an
           * LJ_KEYINDEX control value and needs no position test -- but it
           * DOES still need a record. The prototype in the next VM is not
           * necessarily in the state this one is: one that comes from uperms
           * is the host's own, recompiled per process, so it can be BC_ITERN
           * over there even though it is BC_ITERC here. Without a record the
           * next restore despecialises nothing and hands a live BC_ITERN our
           * state table to read as a raw GCtab. */
          recs_replay = 1;
          idx = 0;                      /* repacked from the state, not an idx */
        } else if (funcV(fn)->c.ffid != FF_next_N) {
          continue;
        } else {
          if (inbody != 1)
            luaL_error(L, "eris-lj: cannot tell whether a for-in loop over "
                          "next is still running in a frame whose bytecode "
                          "position could not be recovered");
          idx = lj_tab_keyindex(tabV(st), ctl);
          if (idx == ~(uint32_t)0) continue;   /* not a key of that table */
        }
        /* Sequential loops at one nesting level share a base register, so two
         * loop heads can name the same control slot. Merge them: when the
         * position could not single one out, ask the restore to despecialise
         * every ITERN with that A operand, which is exactly what blacklist_pc
         * does to arbitrary loops and is harmless to the ones we are not in. */
        for (j = 0; j < n; j++) if (recs[j].ctl == ctl_ofs) break;
        if (j < n) {
          if (recs[j].itern != pos) recs[j].itern = 0;
          continue;
        }
        if (n >= cap)
          luaL_error(L, "eris-lj: too many for-in loops in one thread");
        recs[n].ctl = ctl_ofs;
        recs[n].ra = ra;
        recs[n].idx = idx;
        recs[n].itern = pos;
        recs[n].replay = recs_replay;
        n++;
      }
    }
    above = f;
    f = nextf;
  }
  return n;
}

/* Despecialise one generic-for loop head, exactly as blacklist_pc does.
 * Idempotent: a loop already running as ITERC is left alone, which is what two
 * threads suspended in the same loop -- and a host VM that despecialised it on
 * its own -- both produce. Returns 0 if `pos` does not name such a loop. */
static int elj_despecialise(lua_State *L, GCproto *pt, uint32_t pos, uint32_t ra)
{
  BCIns *bc = proto_bc(pt);
  BCOp op;
  ptrdiff_t isn;
  if (pos < 1 || pos + 1 >= pt->sizebc) return 0;
  op = bc_op(bc[pos]);
  if ((op != BC_ITERN && op != BC_ITERC) || bc_a(bc[pos]) != ra) return 0;
  if (op == BC_ITERC) return 1;         /* already despecialised: nothing to do */
  /* An ITERN's ITERL is pure data -- BC_ITERN reads only its D field and never
   * dispatches it, so it never carries a hotcount and never becomes IITERL or
   * JITERL. An already-despecialised head legitimately can be followed by
   * IITERL, which is why this sits BELOW the return above rather than before
   * it. */
  if (bc_op(bc[pos + 1]) != BC_ITERL)
    luaL_error(L, "eris-lj: for-in loop head at %d is not followed by ITERL",
               (int)pos);
  isn = (ptrdiff_t)pos + 1 + bc_j(bc[pos + 1]);
  /* The head is BC_ISNEXT for a loop the parser specialised, but it can also
   * be a plain BC_JMP that never was one: table.foreach is an LJLIB_LUA
   * prototype built at LuaJIT BUILD time, and genlibbc.lua rewrites its
   * PAIRS(t) to `nil, t, 0x4dp80` -- which defeats predict_next, so the parser
   * emits JMP+ITERC -- and then hand-patches the ITERC byte to ITERN. Every
   * lua_State carries that loop, its callback can yield, and it presents the
   * ordinary LJ_KEYINDEX control slot. Requiring ISNEXT here refused it.
   * blacklist_pc writes this slot unconditionally for the same reason, and
   * lj_record.c asserts only that bc[pos+1] is BC_ITERL.
   *
   * The ITERL of a real loop always jumps backwards past its own body, so the
   * head is strictly below `pos`; that, plus the opcode and operand tests, is
   * what keeps a crafted prototype from aiming the edit elsewhere. */
  if (isn < 1 || isn >= (ptrdiff_t)pos ||
      (bc_op(bc[isn]) != BC_ISNEXT && bc_op(bc[isn]) != BC_JMP) ||
      bc_a(bc[isn]) != ra)
    luaL_error(L, "eris-lj: for-in loop at %d has no loop-entry jump at its "
                  "head", (int)pos);
  setbc_op(&bc[pos], BC_ITERC);
  setbc_op(&bc[isn], BC_JMP);
  return 1;
}

/* ------------------------------------------------------- thread helpers */

/* Replica of the static func_finduv (lj_func.c), with one deliberate
 * difference established by prototype/coclone:
 *  - it allocates on L, not on `co`. A coroutine being restored has
 *    cframe == NULL, so an allocation failure there would PANIC instead of
 *    raising a catchable error.
 * The per-thread open list is kept sorted by descending slot, which
 * lj_func_closeuv relies on. */
static GCupval *elj_finduv(lua_State *L, lua_State *co, TValue *slot,
                           uint32_t dhash, int immutable)
{
  global_State *g = G(L);
  GCRef *pp = &co->openupval;
  GCupval *p, *uv;
  while (gcref(*pp) != NULL && uvval((p = gco2uv(gcref(*pp)))) >= slot) {
    if (uvval(p) == slot) {
      /* Resurrect, exactly as func_finduv does. Pass 4 creates open upvalues
       * that nothing references yet — they stay unreachable for marking until
       * the referrers are attached — so a collection flipping currentwhite in
       * between can leave one dead, and gc_sweep frees open upvalues off the
       * thread's own list. */
      if (isdead(g, obj2gco(p))) flipwhite(obj2gco(p));
      return p;                         /* already open for this slot */
    }
    pp = &p->nextgc;
  }
  uv = (GCupval *)lj_mem_realloc(L, NULL, 0, sizeof(GCupval));
  newwhite(g, uv);
  uv->gct = ~LJ_TUPVAL;
  uv->closed = 0;
  uv->immutable = (uint8_t)immutable;
  uv->dhash = dhash;
  setmref(uv->v, slot);
  /* NOBARRIER: freshly allocated (white) and open. */
  setgcrefr(uv->nextgc, *pp);
  setgcref(*pp, obj2gco(uv));
  setgcref(uv->prev, obj2gco(&g->uvhead));
  setgcrefr(uv->next, g->uvhead.next);
  setgcref(uvnext(uv)->prev, obj2gco(uv));
  setgcref(g->uvhead.next, obj2gco(uv));
  return uv;
}

/* A thread is persistable only if it is fully quiescent. cframe != NULL
 * catches a thread that is running or resuming another, but NOT the main
 * thread, which sits idle with cframe == NULL while the host drives a
 * coroutine from C — OC's exact pattern — so it needs its own check. */
static void check_persistable_thread(lua_State *L, lua_State *co)
{
  if (co == L)
    luaL_error(L, "eris-lj: cannot persist a running thread");
  if (co == mainthread(G(L)))
    luaL_error(L, "eris-lj: cannot persist the main thread");
  if (co->cframe != NULL)
    luaL_error(L, "eris-lj: cannot persist a thread that is running or "
                  "resuming another");
  /* A thread that died by error keeps its status byte but carries no live
   * frames; its stack is normalised to empty on the wire (see p_thread), so
   * there is nothing further to refuse here. */
}

/* ------------------------------------------------------------- p_thread */

static void p_thread(Info *I)  /* ... co */
{
  lua_State *L = I->L;
  lua_State *co = lua_tothread(L, -1);
  TValue *stack, *bot, *f;
  ptrdiff_t base_ofs, top_ofs, i;
  uint32_t nframes = 0, nrep = 0, k;
  int coidx = lua_gettop(L);            /* `co`; scratch is pushed above it */
  int statesidx = 0;
  ForinRec *recs = NULL;
  GCobj *o;

  check_persistable_thread(L, co);
  luaL_checkstack(L, 12, "eris-lj thread");

  stack = tvref(co->stack);
  bot = stack + LJ_FR2;
  base_ofs = co->base - stack;
  top_ofs = co->top - stack;

  /* A dead thread has no resumable state: whatever is left on its stack is
   * the error object or the return values, which the VM will never look at
   * again. Normalise it to an empty stack so the restored thread is inert and
   * reports "dead", and so no frame chain has to be encoded for it. */
  if (co->status > LUA_YIELD) {
    base_ofs = top_ofs = 1 + LJ_FR2;
  }

  /* Rewrite every live for-in loop over pairs()/next into replay form. This
   * runs before the slot loop and never touches `co`: the loop's hidden
   * triple is substituted on the wire only, so persist() stays observationally
   * pure and the saving program keeps iterating exactly as it was. */
  {
    /* The counting pass is allocation-free and reads no operands, so it is
     * safe before the flush. It exists to answer one question: is there a
     * loop here at all? */
    uint32_t cap = elj_forin_scan(I, co, (uint64_t)top_ofs, NULL, 0);
    if (cap && !I->flushed) {
      /* Locating a for-in loop means reading its prototype's bytecode, and a
       * compiled trace overwrites the very instruction we look for: trace_stop
       * replaces the loop head with BC_JLOOP, whose A operand is a slot count
       * rather than the loop base, and turns the following ITERL into a JITERL
       * whose D field is a trace number. Flushing unpatches every one of them.
       *
       * Gated on there being a loop, because the flush is not free and not
       * always available: it discards every compiled trace in the VM, and it
       * REFUSES while a GC hook is active. Persisting a coroutine with no
       * generic-for loop -- or a dead one, for which the scan returns 0 at its
       * first line -- therefore neither resets the host's JIT nor fails from
       * inside a __gc finalizer. */
      I->flushed = 1;
      if (lj_trace_flushall(L))
        luaL_error(L, "eris-lj: cannot persist a thread suspended in a for-in "
                      "loop from inside a GC hook (traces cannot be flushed)");
    }
    if (cap) {
      recs = (ForinRec *)lua_newuserdata(L, (size_t)cap * sizeof(ForinRec));
      memset(recs, 0, (size_t)cap * sizeof(ForinRec));
      lua_newtable(L);
      statesidx = lua_gettop(L);
      nrep = elj_forin_scan(I, co, (uint64_t)top_ofs, recs, cap);
      for (k = 0; k < nrep; k++) {
        TValue *fnv, *stv, *ctlv;
        /* Re-derive the stack each time: building a replay state allocates,
         * and a GC that traverses `co` can shrink and move its stack.
         *
         * And re-derive the CLASSIFICATION, not just the pointer. The scan
         * validated every triple in one allocation-free walk, but building an
         * earlier record allocates, and a GC step there can run a __gc
         * finalizer -- arbitrary Lua, which can reach this thread's slots
         * through debug.setlocal or a shared upvalue and replace them. Reading
         * a cached "this slot is a table" across that gap is how a wild
         * pointer gets dereferenced. */
        stack = tvref(co->stack);
        fnv = stack + recs[k].ctl - 2;
        stv = stack + recs[k].ctl - 1;
        ctlv = stack + recs[k].ctl;
        if (!tvistab(stv))
          luaL_error(L, "eris-lj: a for-in loop's slots changed while the "
                        "thread was being persisted");
        if (ctlv->u32.hi == LJ_KEYINDEX) {
          copyTV(L, L->top, stv); L->top++;
          elj_push_replay_state(L, ctlv->u32.lo);
        } else if (tvisfunc(fnv) && funcV(fnv)->c.ffid == FF_C &&
                   funcV(fnv)->c.f == elj_forin_replay) {
          copyTV(L, L->top, stv); L->top++;
          copyTV(L, L->top, ctlv); L->top++;
          elj_repack_replay_state(L);   /* drop the already-visited prefix */
        } else if (tvisfunc(fnv) && funcV(fnv)->c.ffid == FF_next_N) {
          uint32_t idx = lj_tab_keyindex(tabV(stv), ctlv);
          if (idx == ~(uint32_t)0)
            luaL_error(L, "eris-lj: a for-in loop's control value changed "
                          "while the thread was being persisted");
          copyTV(L, L->top, stv); L->top++;
          elj_push_replay_state(L, idx);
        } else {
          luaL_error(L, "eris-lj: a for-in loop's iterator changed while the "
                        "thread was being persisted");
        }
        lua_rawseti(L, statesidx, (int)(k + 1));
      }
    }
  }

  w_byte(I, TAG_THREAD);
  w_byte(I, (unsigned char)co->status);
  /* The slot span the restore must be able to address. A dead thread carries
   * no slots, so it declares the minimum: otherwise an 86-byte blob for a
   * thread that died deep in recursion would rebuild its whole stack (~230 KB
   * for a 5000-deep failure), and the value would additionally be stale if a
   * GC shrank the stack during the slot loop below. */
  w_uleb(I, co->status > LUA_YIELD
             ? (uint64_t)(2 + LJ_FR2)
             : (uint64_t)(co->stacksize - 1 - LJ_STACK_EXTRA));
  w_uleb(I, (uint64_t)base_ofs);
  w_uleb(I, (uint64_t)top_ofs);

  /* Slots [1+LJ_FR2, top). Slots 0 and 1 are stack_init's own: slot 0 names
   * the thread itself and must name the RESTORED thread, not this one. */
  for (i = 1 + LJ_FR2; i < top_ofs; i++) {
    int role = 0;                       /* 1 func, 2 state, 3 control */
    for (k = 0; k < nrep; k++) {
      if (i == recs[k].ctl - 2)      { role = 1; break; }
      else if (i == recs[k].ctl - 1) { role = 2; break; }
      else if (i == recs[k].ctl)     { role = 3; break; }
    }
    if (role == 1) lua_pushcfunction(L, elj_forin_replay);
    else if (role == 2) lua_rawgeti(L, statesidx, (int)(k + 1));
    else if (role == 3) lua_pushnil(L);
    else {
      /* persist() may have grown L and a GC may have moved co's stack, so the
       * base is re-derived rather than carried across the call. */
      copyTV(L, L->top, tvref(co->stack) + i);
      L->top++;
    }
    persist(I);
    lua_pop(L, 1);
  }

  /* persist() can run the GC, and a GC that traverses `co` shrinks its stack
   * (lj_state_shrinkstack -> resizestack -> lj_mem_realloc), which may MOVE
   * the block. base/top are carried along by resizestack so the offsets stay
   * valid, but any raw pointer into the stack must be re-derived. */
  stack = tvref(co->stack);
  bot = stack + LJ_FR2;

  /* Frames, walked top-down. Only a per-frame link is stored: positions are
   * re-derived on restore, so no stack address ever reaches the wire. */
  if (co->status <= LUA_YIELD)
    for (f = co->base - 1; f > bot; f = frame_islua(f) ? frame_prevl(f)
                                                       : frame_prevd(f))
      nframes++;
  w_uleb(I, (uint64_t)nframes);

  for (f = (co->status <= LUA_YIELD ? co->base - 1 : bot); f > bot; ) {
    TValue *prev;
    if (frame_islua(f)) {
      GCproto *pt;
      prev = frame_prevl(f);
      if (!tvisfunc(prev - 1) || !isluafunc(funcV(prev - 1)))
        luaL_error(L, "eris-lj: Lua frame whose caller is not a Lua function");
      pt = funcproto(funcV(prev - 1));
      w_byte(I, FR_LUA);
      w_uleb(I, (uint64_t)((char *)f - (char *)prev));
      w_uleb(I, (uint64_t)(frame_pc(f) - proto_bc(pt)));
    } else {
      int kind = (int)frame_typep(f);
      prev = frame_prevd(f);
      if (kind == FR_CONT) {
        uint64_t cv = frame_contv(f);
        GCproto *pt;
        int cs;
        for (cs = 0; cs < CS_MAX; cs++)
          if ((uint64_t)(uintptr_t)cont_addr[cs] == cv) break;
        if (cs == CS_MAX)
          luaL_error(L, "eris-lj: unknown continuation in a suspended frame "
                        "(FFI continuations are not supported)");
        if (cs == CS_HOOK)
          /* Reachable in this port: the timeout watchdog installs a NATIVE C
           * hook, and lua_yield's hook branch builds this frame. It is safe
           * only because watchdog_hook raises an error instead of yielding —
           * a constraint any future "yield to the host on deadline" watchdog
           * must keep. Name it, because this is what an operator would see. */
          luaL_error(L, "eris-lj: cannot persist a thread yielded from inside "
                        "a debug hook (a watchdog hook must raise, not yield)");
        if (!tvisfunc(prev - 1) || !isluafunc(funcV(prev - 1)))
          luaL_error(L, "eris-lj: continuation frame with a non-Lua caller");
        pt = funcproto(funcV(prev - 1));
        w_byte(I, FR_CONT);
        w_uleb(I, (uint64_t)frame_sized(f));
        w_byte(I, (unsigned char)cs);
        w_uleb(I, (uint64_t)(frame_contpc(f) - proto_bc(pt)));
      } else {
        if (kind != FR_C && kind != FR_CP && kind != FR_VARG &&
            kind != FR_PCALL && kind != FR_PCALLH)
          luaL_error(L, "eris-lj: unsupported frame type %d", kind);
        /* PCALLH records "a hook was active when this pcall was entered", and
         * the unwinder skips hook_leave() for it. That is only correct while
         * that hook is still on the stack; a restored one would latch
         * HOOK_ACTIVE on the first error and kill all hook dispatch. */
        if (kind == FR_PCALLH && !hook_active(G(L)))
          luaL_error(L, "eris-lj: cannot persist a pcall frame entered inside "
                        "a debug hook");
        if ((kind == FR_C || kind == FR_CP) && prev > bot)
          luaL_error(L, "eris-lj: interior C frame in a suspended thread");
        w_byte(I, (unsigned char)kind);
        w_uleb(I, (uint64_t)frame_sized(f));
      }
    }
    f = prev;
  }

  /* Open upvalues, as plain slot indices; the list is already descending. */
  {
    uint32_t nuv = 0;
    /* A coroutine that died BY ERROR still has its upvalues OPEN: the error
     * path unwinds to the resume frame and returns early, never reaching the
     * unwindstack() that would call lj_func_closeuv (only a normal return, or
     * closing the state, does that). Since the stack above is normalised to
     * empty, those slot indices no longer address anything — emitting them
     * produced a blob that saved happily and could never be loaded. A dead
     * thread has no live frames for an upvalue to alias, so it emits none. */
    if (co->status <= LUA_YIELD) {
      for (o = gcref(co->openupval); o; o = gcref(o->uv.nextgc)) nuv++;
      w_uleb(I, (uint64_t)nuv);
      for (o = gcref(co->openupval); o; o = gcref(o->uv.nextgc)) {
        ptrdiff_t slot = uvval(&o->uv) - tvref(co->stack);
        w_uleb(I, (uint64_t)slot);
        w_byte(I, (unsigned char)o->uv.immutable);
      }
    } else {
      w_uleb(I, 0);
    }
  }

  /* Every for-in loop rewritten into replay form, whether or not THIS VM had
   * it specialised. The restoring VM may disagree: a prototype that came back
   * from uperms is the host's own, freshly compiled, so a loop this VM had
   * already despecialised at runtime is BC_ITERN again over there -- and a
   * replay triple under a live BC_ITERN is precisely the memory-unsafe
   * combination the edit exists to prevent. The other side decides. */
  {
    w_uleb(I, (uint64_t)nrep);
    for (k = 0; k < nrep; k++) {
      w_uleb(I, (uint64_t)recs[k].ctl);
      w_uleb(I, (uint64_t)recs[k].ra);
      w_uleb(I, (uint64_t)recs[k].itern);
    }
  }

  /* The thread's environment. */
  lua_getfenv(L, coidx);
  persist(I);
  lua_pop(L, 1);
  lua_settop(L, coidx);                 /* drop the for-in scratch */
}

static void p_table(Info *I)  /* ... tbl */
{
  lua_State *L = I->L;
  int special = 0;
  luaL_checkstack(L, 4, "eris-lj spkey");
  if (lua_getmetatable(L, -1)) {        /* tbl mt */
    lua_pushvalue(L, SPKIDX);           /* tbl mt spkey */
    lua_rawget(L, -2);                  /* tbl mt sp? */
    if (lua_isnil(L, -1)) {
      lua_pop(L, 2);                    /* tbl */
    } else if (lua_isboolean(L, -1)) {
      if (!lua_toboolean(L, -1))
        luaL_error(L, "eris-lj: attempt to persist forbidden table");
      lua_pop(L, 2);                    /* tbl: true means persist literally */
    } else if (lua_isfunction(L, -1)) {
      lua_remove(L, -2);                /* tbl sp */
      special = 1;
    } else {
      luaL_error(L, "eris-lj: invalid '%s' metafield (%s)",
                 lua_tostring(L, SPKIDX), luaL_typename(L, -1));
    }
  }
  w_byte(I, TAG_TABLE);
  if (special) {                        /* tbl sp */
    PendingRef pr;
    w_byte(I, TABLE_SPECIAL);
    lua_pushvalue(L, -2);               /* tbl sp tbl */
    /* The callback is user code running mid-traversal of any enclosing
     * table: it must not add or remove keys of a table currently being
     * persisted (Lua leaves `next` undefined after such a mutation). */
    lua_call(L, 1, 1);                  /* tbl closure */
    if (!lua_isfunction(L, -1))
      luaL_error(L, "eris-lj: the '%s' function must return a function, got %s",
                 lua_tostring(L, SPKIDX), luaL_typename(L, -1));
    pr.id = I->curid;                   /* this table's own reference id */
    pr.prev = I->pending;
    I->pending = &pr;
    persist(I);                         /* tbl closure */
    I->pending = pr.prev;
    lua_pop(L, 1);                      /* tbl */
  } else {
    w_byte(I, TABLE_LITERAL);
    p_literaltable(I);
  }
}

static void persist_typed(Info *I, int type)  /* ... obj */
{
  switch (type) {
    case LUA_TSTRING: p_string(I); break;
    case LUA_TTABLE:  p_table(I); break;
    case LUA_TLIGHTUSERDATA:
      /* The for-in control slot is a lightuserdata carrying LJ_KEYINDEX in
       * its high half. Saying "put it in the perms table" would send someone
       * after an entry that cannot exist, so name the real cause. */
      if ((I->L->top - 1)->u32.hi == LJ_KEYINDEX)
        luaL_error(I->L, "eris-lj: cannot persist a thread suspended inside a "
                         "generic for-in loop over pairs()/next (its iteration "
                         "position is an index into the table's current layout)");
      luaL_error(I->L, "eris-lj: cannot persist light userdata by value "
                       "(process-local pointer); put it in the perms table");
      break;
    case LUA_TFUNCTION:
      if (lua_iscfunction(I->L, -1)) {
        /* The for-in replay iterator this serializer installs in place of
         * `next`. Everything it needs lives in the state table beside it, so
         * the tag alone reconstructs it. */
        if (lua_tocfunction(I->L, -1) == elj_forin_replay) {
          w_byte(I, TAG_FORIN_ITER);
          break;
        }
        luaL_error(I->L, "eris-lj: cannot persist a C function by value; "
                         "put it in the perms table");
      }
      p_function(I);
      break;
    case LUA_TUSERDATA:
      luaL_error(I->L, "eris-lj: cannot persist userdata yet (M3)");
      break;
    case LUA_TTHREAD: p_thread(I); break;
    default:
      luaL_error(I->L, "eris-lj: cannot persist %s", lua_typename(I->L, type));
  }
}

/* ... obj refkey -> ... obj   (refkey == obj for every M1 type) */
static void persist_keyed(Info *I, int type)
{
  lua_State *L = I->L;
  luaL_checkstack(L, 3, "eris-lj keyed");

  lua_pushvalue(L, -1);                 /* obj refkey refkey */
  lua_rawget(L, REFTIDX);               /* obj refkey ref? */
  if (!lua_isnil(L, -1)) {
    lua_Integer id = lua_tointeger(L, -1);
    PendingRef *p;
    for (p = I->pending; p; p = p->prev)
      if (p->id == id)
        luaL_error(L, "eris-lj: the '%s' function captured the object it "
                      "reconstructs; such a cycle can never be loaded back",
                   lua_tostring(L, SPKIDX));
    w_byte(I, TAG_REF);
    w_uleb(I, (uint64_t)id);
    lua_pop(L, 2);                      /* obj */
    return;
  }
  lua_pop(L, 1);                        /* obj refkey */

  /* Register BEFORE descending, so a cycle back to this object emits a
   * reference instead of recursing forever. */
  lua_pushvalue(L, -1);                 /* obj refkey refkey */
  I->curid = newref(I);
  lua_pushinteger(L, I->curid);         /* obj refkey refkey id */
  lua_rawset(L, REFTIDX);               /* obj refkey */

  /* Give the permanents table its chance (lua_gettable: __index applies).
   * The perms *key* is itself persisted as an ordinary value, so it must
   * restore to a key equal to the one in uperms: strings and numbers always
   * do; a bare table does not (it restores as a distinct object) unless it
   * is a permanent too. Upstream Eris has the same property; OC uses dotted
   * string names throughout. */
  lua_gettable(L, PERMIDX);             /* obj permkey? */
  if (!lua_isnil(L, -1)) {
    w_byte(I, TAG_PERMANENT);
    w_byte(I, (unsigned char)type);
    persist(I);                         /* obj permkey */
    lua_pop(L, 1);                      /* obj */
  } else {
    lua_pop(L, 1);                      /* obj */
    persist_typed(I, type);
  }
}

static void persist(Info *I)  /* ... obj */
{
  lua_State *L = I->L;
  int type = lua_type(L, -1);
  /* Every record costs one level, exactly as unpersist() charges one per
   * record — otherwise a graph could persist at a depth that can never be
   * read back (the nil terminator and metatable slot of the innermost
   * table sit one level below it on both sides). */
  enter(I);
  switch (type) {
    case LUA_TNIL:     w_byte(I, TAG_NIL); break;
    case LUA_TBOOLEAN: w_byte(I, lua_toboolean(L, -1) ? TAG_TRUE : TAG_FALSE);
                       break;
    case LUA_TNUMBER:  p_number(I); break;
    default:
      luaL_checkstack(L, 2, "eris-lj persist");
      lua_pushvalue(L, -1);             /* obj obj */
      persist_keyed(I, type);           /* obj */
      break;
  }
  leave(I);
}

/* ---------------------------------------------------------- unpersisting */

static void unpersist(Info *I);

static void u_string(Info *I)
{
  uint64_t len = r_uleb(I);
  r_need(I, (size_t)len);               /* also catches len > SIZE_MAX cases */
  if (len > (uint64_t)(I->inlen - I->pos))
    luaL_error(I->L, "eris-lj: string length exceeds remaining input");
  luaL_checkstack(I->L, 1, "eris-lj str");
  lua_pushlstring(I->L, (const char *)(I->in + I->pos), (size_t)len);
  I->pos += (size_t)len;
  registerobject(I);
}


/* Note that closure `fidx` refers to upvalue `id` through slot `n`. */
static void elj_note_referrer(lua_State *L, lua_Integer id, int fidx, int n)
{
  luaL_checkstack(L, 4, "eris-lj uvlist");
  lua_rawgeti(L, UPVLIST, (int)id);         /* list? */
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushvalue(L, -1);
    lua_rawseti(L, UPVLIST, (int)id);
  }
  lua_pushvalue(L, fidx);
  lua_rawseti(L, -2, (int)lua_objlen(L, -2) + 1);
  lua_pushinteger(L, n);
  lua_rawseti(L, -2, (int)lua_objlen(L, -2) + 1);
  lua_pop(L, 1);
}

/* Re-point every recorded referrer of `id` at `uv`. The barrier is required:
 * a closure restored earlier may already be black. */
static void elj_repoint_referrers(lua_State *L, lua_Integer id, GCupval *uv)
{
  int n, k;
  luaL_checkstack(L, 3, "eris-lj repoint");
  lua_rawgeti(L, UPVLIST, (int)id);
  if (!lua_istable(L, -1)) { lua_pop(L, 1); return; }
  n = (int)lua_objlen(L, -1);
  for (k = 1; k + 1 <= n; k += 2) {
    GCfunc *fn;
    int slot;
    lua_rawgeti(L, -1, k);
    lua_rawgeti(L, -2, k + 1);
    if (lua_isfunction(L, -2) && !lua_iscfunction(L, -2) && lua_isnumber(L, -1)) {
      fn = funcV(L->top - 2);
      slot = (int)lua_tointeger(L, -1);
      if (slot >= 1 && (uint32_t)slot <= fn->l.nupvalues) {
        setgcref(fn->l.uvptr[slot - 1], obj2gco(uv));
        lj_gc_objbarrier(L, fn, obj2gco(uv));
      }
    }
    lua_pop(L, 2);
  }
  lua_pop(L, 1);
}

/* The live-stack bound for an open-upvalue slot. A thread still being
 * restored has co->top parked at its declared span rather than at the write
 * cursor, so the declared top is the only truthful bound; once the restore is
 * finished co->top is the real one. */
static uint64_t elj_live_top(Info *I, lua_State *co)
{
  RThread *r;
  for (r = I->rthreads; r != NULL; r = r->prev)
    if (r->co == co) return r->top_ofs;
  return (uint64_t)(co->top - tvref(co->stack));
}

/* Reader for lua_loadx: hands the dump over in one go. The bytes live in the
 * input string, which is anchored at BUFIDX for the whole parse. */
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

static void u_function(Info *I)
{
  lua_State *L = I->L;
  SReader r;
  uint32_t dumplen = r_u32le(I);
  int fidx, nuv, claimed, i;

  r_need(I, (size_t)dumplen);
  r.s = (const char *)(I->in + I->pos);
  r.sz = (size_t)dumplen;
  r.done = 0;
  I->pos += (size_t)dumplen;

  luaL_checkstack(L, 6, "eris-lj func");
  /* Mode "b": bytecode only. See the trust-boundary note at the top of this
   * file — LuaJIT does not verify bytecode. */
  if (lua_loadx(L, sreader, &r, "=eris-lj", "b") != 0)
    luaL_error(L, "eris-lj: cannot load function (%s)",
               lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
  if (!lua_isfunction(L, -1) || lua_iscfunction(L, -1))
    luaL_error(L, "eris-lj: loaded chunk is not a Lua function");
  fidx = lua_gettop(L);
  /* Register before the upvalues, so a closure that refers to itself
   * through one of them resolves to a reference instead of recursing. */
  registerobject(I);

  claimed = (int)r_uleb(I);
  nuv = 0;
  while (lua_getupvalue(L, fidx, nuv + 1)) { lua_pop(L, 1); nuv++; }
  if (claimed != nuv)
    luaL_error(L, "eris-lj: upvalue count mismatch (blob says %d, proto has %d)",
               claimed, nuv);

  for (i = 1; i <= nuv; i++) {
    unsigned char t = r_byte(I);
    if (t == TAG_UPVAL) {
      lua_Integer id;
      if (I->upvcount >= ERIS_LJ_MAXREF)
        luaL_error(L, "eris-lj: too many distinct upvalues");
      id = ++I->upvcount;
      /* Publish the owner BEFORE reading the value, mirroring p_function,
       * which registers the upvalue id before walking into it. The value can
       * transitively reach another closure sharing this very upvalue (the
       * ordinary module pattern: two members capturing one local and the
       * module table), and that closure's join has to resolve while we are
       * still inside the value. lua_loadx has already allocated a distinct
       * upvalue for every slot, so joining only needs the slot to exist —
       * the lua_setupvalue below then writes into the now-shared upvalue. */
      lua_pushvalue(L, fidx);
      lua_rawseti(L, UPVIDX, (int)id);  /* id -> owning closure */
      lua_pushinteger(L, i);
      lua_rawseti(L, UPVNIDX, (int)id); /* id -> slot */
      elj_note_referrer(L, id, fidx, i);
      unpersist(I);                     /* value */
      if (!lua_setupvalue(L, fidx, i))  /* pops it */
        luaL_error(L, "eris-lj: cannot set upvalue %d", i);
    } else if (t == TAG_UPVALREF) {
      uint64_t id = r_uleb(I);
      int owner_n;
      if (id == 0 || id > (uint64_t)I->upvcount)
        luaL_error(L, "eris-lj: upvalue reference %d out of range (%d known)",
                   (int)id, (int)I->upvcount);
      lua_rawgeti(L, UPVIDX, (int)id);  /* owner */
      lua_rawgeti(L, UPVNIDX, (int)id); /* owner slot */
      if (!lua_isfunction(L, -2) || lua_iscfunction(L, -2) ||
          !lua_isnumber(L, -1))
        luaL_error(L, "eris-lj: corrupt upvalue reference %d", (int)id);
      owner_n = (int)lua_tointeger(L, -1);
      lua_pop(L, 1);                    /* owner */
      lua_upvaluejoin(L, fidx, i, lua_gettop(L), owner_n);
      lua_pop(L, 1);
      /* If this id later turns out to be an OPEN upvalue, this closure has
       * to be re-pointed along with the rest. */
      elj_note_referrer(L, id, fidx, i);
    } else if (t == TAG_UPVALOPEN) {
      lua_Integer id;
      lua_State *owner;
      uint64_t slot;
      GCupval *uv;
      if (I->upvcount >= ERIS_LJ_MAXREF)
        luaL_error(L, "eris-lj: too many distinct upvalues");
      id = ++I->upvcount;
      /* Publish the owner BEFORE restoring the thread: the thread's own
       * stack routinely holds other closures over this same upvalue, and
       * they join against this slot while we are still inside unpersist. */
      lua_pushvalue(L, fidx);
      lua_rawseti(L, UPVIDX, (int)id);
      lua_pushinteger(L, i);
      lua_rawseti(L, UPVNIDX, (int)id);
      elj_note_referrer(L, id, fidx, i);
      unpersist(I);                     /* the owning thread */
      if (!lua_isthread(L, -1))
        luaL_error(L, "eris-lj: open upvalue names a %s, expected a thread",
                   luaL_typename(L, -1));
      owner = lua_tothread(L, -1);
      slot = r_uleb(I);
      if (slot < (uint64_t)(1 + LJ_FR2) || slot >= elj_live_top(I, owner))
        luaL_error(L, "eris-lj: open upvalue slot %d outside the thread's "
                      "live stack", (int)slot);
      uv = elj_finduv(L, owner, tvref(owner->stack) + slot,
                      (uint32_t)(uintptr_t)(tvref(owner->stack) + slot), 0);
      lua_pop(L, 1);                    /* the thread */
      /* Now re-point this closure AND everything that joined to it while the
       * thread was being restored, so they all share the one open upvalue
       * that aliases the thread's live stack slot. */
      elj_repoint_referrers(L, id, uv);
    } else {
      luaL_error(L, "eris-lj: expected an upvalue record, got tag 0x%02x",
                 (int)t);
    }
  }

  unpersist(I);                         /* fenv */
  if (!lua_istable(L, -1))
    luaL_error(L, "eris-lj: function environment is a %s, expected a table",
               luaL_typename(L, -1));
  if (!lua_setfenv(L, fidx))
    luaL_error(L, "eris-lj: cannot set the function environment");
}

static void u_table(Info *I)
{
  lua_State *L = I->L;
  unsigned char flag = r_byte(I);
  luaL_checkstack(L, 4, "eris-lj table");
  if (flag == TABLE_SPECIAL) {
    /* Reserve the id before reading the closure, mirroring persist_keyed;
     * the table itself only exists once the closure has been called. */
    lua_Integer ref = newref(I);
    unpersist(I);                       /* closure */
    if (!lua_isfunction(L, -1))
      luaL_error(L, "eris-lj: special-persist record is a %s, expected a "
                    "function", luaL_typename(L, -1));
    lua_call(L, 0, 1);                  /* result */
    if (!lua_istable(L, -1))
      luaL_error(L, "eris-lj: special-persist function returned a %s, "
                    "expected a table", luaL_typename(L, -1));
    lua_pushvalue(L, -1);
    lua_rawseti(L, REFTIDX, (int)ref);
    return;
  }
  if (flag != TABLE_LITERAL)
    luaL_error(L, "eris-lj: unknown table flag %d", (int)flag);
  lua_newtable(L);                      /* tbl */
  registerobject(I);                    /* preregister: cycles resolve */
  for (;;) {
    unpersist(I);                       /* tbl k */
    if (lua_isnil(L, -1)) { lua_pop(L, 1); break; }
    unpersist(I);                       /* tbl k v */
    /* The writer never emits a nil value (lua_next skips them), so a nil
     * here is malformed data; rawset would silently drop the pair. */
    if (lua_isnil(L, -1))
      luaL_error(L, "eris-lj: table value is nil (malformed data)");
    lua_rawset(L, -3);                  /* tbl */
  }
  unpersist(I);                         /* tbl mt|nil */
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
  } else {
    if (!lua_istable(L, -1))
      luaL_error(L, "eris-lj: metatable slot holds a %s", luaL_typename(L, -1));
    lua_setmetatable(L, -2);
  }
}


/* ------------------------------------------------------------- u_thread */

/* One decoded frame record. Positions are DERIVED from the links, never read
 * from the blob, so no stack address can be forged. */
typedef struct {
  unsigned char kind, cs;
  uint64_t link;
  uint64_t bcofs;     /* FR_LUA: return pc; FR_CONT: continuation pc */
  ptrdiff_t at;       /* derived slot index of the frame word */
} FrameRec;

static void u_thread(Info *I)
{
  lua_State *L = I->L;
  lua_State *co;
  TValue *stack;
  unsigned char status = r_byte(I);
  uint64_t need = r_uleb(I);
  uint64_t base_ofs = r_uleb(I);
  uint64_t top_ofs = r_uleb(I);
  uint64_t nframes, nuv;
  FrameRec *fr = NULL;
  RThread rt;
  ptrdiff_t i;
  uint64_t k;

  /* Header sanity, before anything is allocated. */
  if (status != LUA_OK && status != LUA_YIELD &&
      status != LUA_ERRRUN && status != LUA_ERRMEM && status != LUA_ERRERR)
    luaL_error(L, "eris-lj: thread has an illegal status byte %d", (int)status);
  if (need < (uint64_t)(2 + LJ_FR2) || need >= LUAI_MAXSTACK)
    luaL_error(L, "eris-lj: thread stack size %d out of range", (int)need);
  if (base_ofs < (uint64_t)(1 + LJ_FR2) || top_ofs < base_ofs || top_ofs > need)
    luaL_error(L, "eris-lj: thread base/top out of range (%d/%d of %d)",
               (int)base_ofs, (int)top_ofs, (int)need);

  luaL_checkstack(L, 8, "eris-lj thread");
  co = lua_newthread(L);                /* anchored on L's stack */
  registerobject(I);                    /* before the slots, so cycles resolve */

  /* Grow once, up front, so every open upvalue points into the final
   * allocation and no raw slot pointer is held across a growth. */
  {
    MSize cur = (MSize)(mref(co->maxstack, TValue) - tvref(co->stack));
    if ((MSize)need > cur) {
      int rc = lj_state_cpgrowstack(co, (MSize)need - cur);
      if (rc != LUA_OK)
        luaL_error(L, "eris-lj: cannot grow the restored thread stack");
    }
  }

  /* co->top is parked at the END of the reserved span for the whole restore
   * and only lowered to the real top in pass 5. gc_traverse_thread nils
   * everything above top during GCSatomic, but it also ends in
   * lj_state_shrinkstack() with used = top - stack (base is at the bottom, so
   * no frame is walked). With top just above the last written slot that
   * `used` is tiny, and any GC landing mid-restore HALVES the block while
   * `need` stays fixed, so every later write runs off the end -- a heap
   * overflow reachable from an ordinary deep coroutine, with no tampering and
   * no explicit collectgarbage(). Parking top at stack+need keeps `used`
   * honest, so the 4*used < stacksize guard can never fire. Every slot in
   * [1+LJ_FR2, stacksize) is already nil: stack_init and resizestack both
   * clear what they hand out. */
  co->top = tvref(co->stack) + need;
  rt.co = co;
  rt.top_ofs = top_ofs;
  rt.prev = I->rthreads;
  I->rthreads = &rt;

  /* Pass 1: slot values. co->base stays at the bottom until the frames are in
   * place, so a GC can never walk a half-written frame chain. */
  for (i = 1 + LJ_FR2; i < (ptrdiff_t)top_ofs; i++) {
    unpersist(I);                       /* ... value */
    stack = tvref(co->stack);
    copyTV(co, stack + i, L->top - 1);  /* NOBARRIER: threads are never black */
    co->top = stack + need;             /* re-assert: unpersist can realloc */
    lua_pop(L, 1);
  }

  /* Pass 2: frame records, validated structurally with no protos needed. */
  nframes = r_uleb(I);
  if (status == LUA_YIELD) {
    if (nframes == 0)
      luaL_error(L, "eris-lj: suspended thread with no frames");
  } else if (nframes != 0) {
    luaL_error(L, "eris-lj: non-suspended thread must have no frames");
  }
  /* With no frames the thread never entered its body, so base MUST sit at the
   * stack bottom. gc_traverse_frames walks base-1 downwards unconditionally --
   * it consults neither the status nor whether a frame word was ever written
   * -- so a higher base makes it read a plain value slot as a frame word and
   * dereference the slot below it as a function. Checked before co->base is
   * moved, so a rejected blob leaves the thread inert. */
  if (nframes == 0 && base_ofs != (uint64_t)(1 + LJ_FR2))
    luaL_error(L, "eris-lj: thread has no frames but base is at %d, not the "
                  "stack bottom (%d)", (int)base_ofs, 1 + LJ_FR2);
  if (nframes > need)
    luaL_error(L, "eris-lj: thread claims more frames than stack slots");

  if (nframes) {
    fr = (FrameRec *)lua_newuserdata(L, (size_t)nframes * sizeof(FrameRec));
    memset(fr, 0, (size_t)nframes * sizeof(FrameRec));
  }
  for (k = 0; k < nframes; k++) {
    fr[k].kind = r_byte(I);
    fr[k].link = r_uleb(I);
    if (fr[k].kind == FR_LUA) {
      fr[k].bcofs = r_uleb(I);
    } else if (fr[k].kind == FR_CONT) {
      fr[k].cs = r_byte(I);
      fr[k].bcofs = r_uleb(I);
      /* The continuation word is jumped to directly by cont_dispatch, so it
       * must resolve inside the closed symbol set and never be a raw value. */
      if (fr[k].cs >= CS_MAX)
        luaL_error(L, "eris-lj: continuation symbol %d out of range",
                   (int)fr[k].cs);
      if (fr[k].cs == CS_HOOK)
        luaL_error(L, "eris-lj: hook continuation frames are not supported");
    } else if (fr[k].kind != FR_C && fr[k].kind != FR_CP &&
               fr[k].kind != FR_VARG && fr[k].kind != FR_PCALL &&
               fr[k].kind != FR_PCALLH) {
      luaL_error(L, "eris-lj: illegal frame kind %d", (int)fr[k].kind);
    }
    if (fr[k].kind == FR_PCALLH && !hook_active(G(L)))
      luaL_error(L, "eris-lj: FRAME_PCALLH frame with no active hook");
    /* The low 3 bits of a link are the frame type: a link that is not a
     * multiple of 8 would silently rewrite the kind just validated. */
    if ((fr[k].link & 7) != 0 || fr[k].link < 16)
      luaL_error(L, "eris-lj: frame link %d is not a valid frame size",
                 (int)fr[k].link);
    /* A continuation frame owns f-3..f (f-4..f for stitch). If the link is
     * short enough that the next-outer frame's ftsz lands on one of those,
     * pass 3's validated continuation address is overwritten by link|kind and
     * cont_dispatch jumps to it. */
    if (fr[k].kind == FR_CONT &&
        fr[k].link < (uint64_t)(fr[k].cs == CS_STITCH ? 40 : 32))
      luaL_error(L, "eris-lj: continuation frame link %d overlaps its own "
                    "continuation words", (int)fr[k].link);
  }

  /* Derive positions: the first frame word sits at base-1, the chain must
   * strictly descend, and it must terminate EXACTLY at stack+LJ_FR2 --
   * every VM walker loops on `frame > bot`. */
  {
    ptrdiff_t at = (ptrdiff_t)base_ofs - 1;
    for (k = 0; k < nframes; k++) {
      ptrdiff_t prev_at;
      if (at <= LJ_FR2 || at >= (ptrdiff_t)top_ofs)
        luaL_error(L, "eris-lj: frame %d outside the stack", (int)k);
      fr[k].at = at;
      prev_at = at - (ptrdiff_t)(fr[k].link / sizeof(TValue));
      if (prev_at < LJ_FR2 || prev_at >= at)
        luaL_error(L, "eris-lj: frame chain does not descend");
      if ((fr[k].kind == FR_C || fr[k].kind == FR_CP) && k + 1 != nframes)
        luaL_error(L, "eris-lj: interior C frame");
      /* cont_dispatch reads [base-4] and [base-3]; stitch also [base-5]. */
      if (fr[k].kind == FR_CONT &&
          at - (fr[k].cs == CS_STITCH ? 4 : 3) <= LJ_FR2)
        luaL_error(L, "eris-lj: continuation frame too close to the stack bottom");
      at = prev_at;
    }
    if (nframes && at != LJ_FR2)
      luaL_error(L, "eris-lj: frame chain does not terminate at the stack bottom");
    if (nframes &&
        fr[nframes - 1].kind != FR_C && fr[nframes - 1].kind != FR_CP)
      luaL_error(L, "eris-lj: bottom frame is not a resume frame");
  }

  /* Pass 3: write the frame words, now that the slots hold real functions. */
  stack = tvref(co->stack);
  for (k = 0; k < nframes; k++) {
    TValue *f = stack + fr[k].at;
    TValue *prev = f - (ptrdiff_t)(fr[k].link / sizeof(TValue));
    /* gc_traverse_frames dereferences every frame's func slot on the next
     * GC, before any resume, so this must hold for every frame. */
    if (!tvisfunc(f - 1))
      luaL_error(L, "eris-lj: frame %d has a non-function in its func slot",
                 (int)k);
    if (fr[k].kind == FR_LUA || fr[k].kind == FR_CONT) {
      GCproto *pt;
      const BCIns *pc;
      if (!tvisfunc(prev - 1) || !isluafunc(funcV(prev - 1)))
        luaL_error(L, "eris-lj: frame %d names a non-Lua caller", (int)k);
      pt = funcproto(funcV(prev - 1));
      if (fr[k].bcofs < 1 || fr[k].bcofs >= pt->sizebc)
        luaL_error(L, "eris-lj: bytecode offset %d out of range for the named "
                      "prototype", (int)fr[k].bcofs);
      pc = proto_bc(pt) + fr[k].bcofs;
      if (fr[k].kind == FR_LUA) {
        setframe_pc(f, pc);
        /* An in-range-but-wrong pc is memory-unsafe: BC_RET_Z shifts BASE by
         * bc_a(pc[-1]) and then dereferences [BASE-16] as a closure. These
         * two checks together are what reject it. */
        if (frame_prevl(f) != prev)
          luaL_error(L, "eris-lj: frame %d pc disagrees with its link", (int)k);
        switch (bc_op(pc[-1])) {
          case BC_CALL: case BC_CALLM: case BC_ITERC: case BC_ITERN: break;
          default:
            luaL_error(L, "eris-lj: frame %d return pc does not follow a call",
                       (int)k);
        }
      } else {
        /* An in-set-but-WRONG continuation symbol is memory-unsafe for the
         * same reason an in-range-but-wrong return pc is: cont_dispatch jumps
         * straight to cont_addr[cs], and each handler decodes the bytecode
         * around contpc assuming it is the site that attached it (cont_cat
         * reads a concat base, cont_ra writes to bc_a, the cond handlers
         * branch on bc_d of what they assume is a JMP). contpc points one
         * instruction past the triggering opcode, so the site identifies the
         * symbol. bcmode_mm returns an out-of-enum value for opcodes with no
         * metamethod, so every comparison fails closed. */
        MMS mm = bcmode_mm(bc_op(pc[-1]));
        int consistent;
        switch (fr[k].cs) {
          case CS_CAT:   consistent = (mm == MM_concat); break;
          case CS_RA:    consistent = (mm == MM_index || mm == MM_len ||
                                       (mm >= MM_add && mm <= MM_unm)); break;
          case CS_NOP:   consistent = (mm == MM_newindex); break;
          case CS_CONDT:
          case CS_CONDF: consistent = ((mm == MM_eq || mm == MM_lt ||
                                        mm == MM_le) &&
                                       bc_op(pc[0]) == BC_JMP); break;
          case CS_STITCH: consistent = (mm == MM_call); break;
          default:       consistent = 0; break;
        }
        if (!consistent)
          luaL_error(L, "eris-lj: frame %d continuation symbol %d does not "
                        "match the opcode at its continuation site",
                     (int)k, (int)fr[k].cs);
        (f - 3)->u64 = (uint64_t)(uintptr_t)cont_addr[fr[k].cs];
        setframe_pc(f - 2, pc);
        setframe_ftsz(f, (int64_t)(fr[k].link | FRAME_CONT));
        if (fr[k].cs == CS_STITCH)
          /* +0.0: cleartp() == 0 sends cont_stitch to cont_nop, and unlike a
           * zero-payload trace reference it is not a GC value, so the next
           * gc_traverse_thread does not dereference NULL. */
          (f - 4)->u64 = 0;
      }
    } else {
      if (fr[k].kind == FR_VARG &&
          (!isluafunc(funcV(f - 1)) ||
           !(funcproto(funcV(f - 1))->flags & PROTO_VARARG)))
        luaL_error(L, "eris-lj: vararg frame over a non-vararg function");
      setframe_ftsz(f, (int64_t)(fr[k].link | fr[k].kind));
    }
  }
  /* Pass 4: open upvalues, built through elj_finduv so the per-thread list
   * order is enforced by construction rather than trusted from the blob. */
  nuv = r_uleb(I);
  if (nuv > top_ofs)
    luaL_error(L, "eris-lj: thread claims more open upvalues than slots");
  {
    ptrdiff_t last = (ptrdiff_t)need + 1;
    for (k = 0; k < nuv; k++) {
      uint64_t slot = r_uleb(I);
      int immutable = r_byte(I) ? 1 : 0;
      if (slot < (uint64_t)(1 + LJ_FR2) || slot >= top_ofs)
        luaL_error(L, "eris-lj: open upvalue slot %d outside the live stack",
                   (int)slot);
      if ((ptrdiff_t)slot >= last)
        luaL_error(L, "eris-lj: open upvalues are not in descending order");
      last = (ptrdiff_t)slot;
      {
        GCupval *uv = elj_finduv(L, co, tvref(co->stack) + slot,
                                 (uint32_t)(uintptr_t)(tvref(co->stack) + slot),
                                 immutable);
        /* Pass 1 may already have created this upvalue for a closure living
         * in the thread's own stack, and elj_finduv leaves an existing object
         * alone, so the recorded bit is applied here. Pass 4 is the only site
         * that knows the true value (u_function's TAG_UPVALOPEN passes 0),
         * and it runs last, which is why it owns the bit. */
        uv->immutable = (uint8_t)immutable;
      }
    }
  }

  /* Pass 4b: despecialise the loops whose hidden triple was rewritten into
   * replay form. BC_ITERN reads the state slot as a raw GCtab and the control
   * slot as a raw index into it without validating either, so this MUST happen
   * before the thread can be resumed. It can only happen now, because naming
   * the loop needs the owning frame's base and prototype, which pass 3
   * established. Note the prototype may have come from uperms and be the
   * host's own -- that is the case a persist-side patch could never reach. */
  {
    uint64_t nrep = r_uleb(I);
    ptrdiff_t si;
    int touch;
    if (nrep > need)
      luaL_error(L, "eris-lj: thread claims more for-in loops than slots");
    /* Whether there is work to do is decided from the RESTORED SLOTS, not from
     * the trailer: a blob that under-reports -- an older writer, or a
     * persist-side detection miss -- must not be able to skip the guarantee
     * below simply by claiming nrep == 0. */
    touch = (nrep != 0);
    stack = tvref(co->stack);
    for (si = 1 + LJ_FR2; !touch && si < (ptrdiff_t)top_ofs; si++)
      if (tvisfunc(stack + si) && funcV(stack + si)->c.ffid == FF_C &&
          funcV(stack + si)->c.f == elj_forin_replay)
        touch = 1;
    /* A trace compiled over the loop would keep running the ITERN semantics
     * the patch is meant to remove, and would also have overwritten the
     * instruction we are about to inspect. */
    if (touch && lj_trace_flushall(L))
      luaL_error(L, "eris-lj: cannot restore a for-in loop from inside a GC "
                    "hook (JIT traces cannot be flushed)");
    for (k = 0; k < nrep; k++) {
      uint64_t ctl = r_uleb(I);
      uint64_t ra = r_uleb(I);
      uint64_t ipos = r_uleb(I);
      ptrdiff_t at = -1, base;
      GCproto *pt;
      TValue *fw;
      uint64_t j;
      int patched = 0;
      if (ctl < (uint64_t)(3 + LJ_FR2) || ctl >= top_ofs)
        luaL_error(L, "eris-lj: for-in control slot %d outside the live stack",
                   (int)ctl);
      /* Frame words descend, so the first one below the slot is the innermost
       * frame that contains it. */
      for (j = 0; j < nframes; j++)
        if (fr[j].at < (ptrdiff_t)ctl) { at = fr[j].at; break; }
      if (at < 0)
        luaL_error(L, "eris-lj: for-in control slot %d is not inside a frame",
                   (int)ctl);
      stack = tvref(co->stack);
      fw = stack + at;
      if (!tvisfunc(fw - 1) || !isluafunc(funcV(fw - 1)))
        luaL_error(L, "eris-lj: for-in control slot %d is not inside a Lua "
                      "frame", (int)ctl);
      pt = funcproto(funcV(fw - 1));
      base = at + 1;
      if (ra < 3 || ra > 255 || (uint32_t)(ra - 1) >= pt->framesize ||
          (ptrdiff_t)ctl != base + (ptrdiff_t)ra - 1)
        luaL_error(L, "eris-lj: for-in record disagrees with its frame");
      /* The three slots must really hold the triple the record describes,
       * otherwise the opcode edit below would be aimed at an ordinary loop. */
      if (!tvisfunc(stack + ctl - 2) ||
          funcV(stack + ctl - 2)->c.ffid != FF_C ||
          funcV(stack + ctl - 2)->c.f != elj_forin_replay ||
          !tvistab(stack + ctl - 1) || !tvisnil(stack + ctl))
        luaL_error(L, "eris-lj: for-in record does not name a replay triple");
      /* The property that has to hold afterwards is not "we patched the loop
       * the blob named" but "no BC_ITERN in this prototype has this A operand
       * any more" -- sequential loops at one nesting level share a base
       * register, so patching only the named head can leave a live ITERN
       * sitting on the very registers the replay triple occupies. So the
       * register scan is authoritative and the offset on the wire is only a
       * hint, cross-checked against what the scan found. Despecialising a loop
       * we are not in is harmless: it costs that loop its ITERN fast path,
       * which is exactly what blacklist_pc does to arbitrary loops. */
      {
        uint32_t pos, named = 0;
        for (pos = 1; pos + 1 < pt->sizebc; pos++) {
          BCOp o = bc_op(proto_bc(pt)[pos]);
          if (o != BC_ITERN && o != BC_ITERC) continue;
          if (!elj_despecialise(L, pt, pos, (uint32_t)ra)) continue;
          patched++;
          if (ipos == (uint64_t)pos) named = 1;
        }
        if (!patched)
          luaL_error(L, "eris-lj: for-in record names no loop to despecialise");
        if (ipos != 0 && !named)
          luaL_error(L, "eris-lj: for-in loop offset %d names no loop on "
                        "register %d", (int)ipos, (int)ra);
      }
    }

    /* The property that must hold before this thread can be resumed is "no
     * live BC_ITERN addresses a replay triple" -- BC_ITERN reads the state
     * slot as a raw GCtab and the control slot as a raw index into it, with no
     * validation whatsoever. The records above are the saving VM's account of
     * what it rewrote; this sweep is the restoring VM establishing the
     * property for itself, so the guarantee does not depend on the blob being
     * complete or honest. It only ever fires on a slot holding this
     * serializer's own iterator, so an ordinary generic-for is untouched. */
    if (touch) {
      uint64_t fi;
      for (fi = 0; fi < nframes; fi++) {
        GCproto *pt;
        TValue *fw;
        uint32_t pos;
        ptrdiff_t fbase;
        stack = tvref(co->stack);
        fw = stack + fr[fi].at;
        if (!tvisfunc(fw - 1) || !isluafunc(funcV(fw - 1))) continue;
        pt = funcproto(funcV(fw - 1));
        fbase = fr[fi].at + 1;
        for (pos = 1; pos + 1 < pt->sizebc; pos++) {
          uint32_t ra2;
          ptrdiff_t c;
          if (bc_op(proto_bc(pt)[pos]) != BC_ITERN) continue;
          ra2 = bc_a(proto_bc(pt)[pos]);
          if (ra2 < 3 || (uint32_t)(ra2 - 1) >= pt->framesize) continue;
          c = fbase + (ptrdiff_t)ra2 - 1;
          if (c < (ptrdiff_t)(3 + LJ_FR2) || c >= (ptrdiff_t)top_ofs) continue;
          if (tvisfunc(stack + c - 2) &&
              funcV(stack + c - 2)->c.ffid == FF_C &&
              funcV(stack + c - 2)->c.f == elj_forin_replay)
            elj_despecialise(L, pt, pos, ra2);
        }
      }
    }
  }
  if (nframes) lua_pop(L, 1);           /* the FrameRec scratch userdata */

  /* Pass 5: the environment, then the header. cframe is forced to NULL
   * rather than read from the blob: it is a host stack address. */
  unpersist(I);
  if (!lua_istable(L, -1))
    luaL_error(L, "eris-lj: thread environment is a %s, expected a table",
               luaL_typename(L, -1));
  setgcref(co->env, obj2gco(tabV(L->top - 1)));
  lua_pop(L, 1);

  stack = tvref(co->stack);
  co->base = stack + base_ofs;
  co->top = stack + top_ofs;
  co->status = status;
  co->cframe = NULL;
  I->rthreads = rt.prev;
}

static void u_permanent(Info *I)
{
  lua_State *L = I->L;
  int type = (int)r_byte(I);
  lua_Integer ref;
  /* The type byte indexes lua_typename() below, which in LuaJIT is an
   * unchecked array index — an out-of-range byte from a crafted blob would
   * read past the table and hand garbage to "%s". Bound it first. */
  if (type < 0 || type > LUA_TTHREAD)
    luaL_error(L, "eris-lj: permanent has invalid type byte %d", type);
  /* Reserve the id BEFORE unpersisting the key, mirroring persist_keyed. */
  ref = newref(I);
  luaL_checkstack(L, 2, "eris-lj perm");
  unpersist(I);                         /* permkey */
  lua_gettable(L, PERMIDX);             /* obj? */
  if (lua_isnil(L, -1))
    luaL_error(L, "eris-lj: unknown permanent (not in the perms table)");
  if (lua_type(L, -1) != type)
    luaL_error(L, "eris-lj: permanent changed type (saved %s, now %s)",
               lua_typename(L, type), luaL_typename(L, -1));
  lua_pushvalue(L, -1);
  lua_rawseti(L, REFTIDX, (int)ref);
}

static void unpersist(Info *I)
{
  lua_State *L = I->L;
  unsigned char tag = r_byte(I);
  enter(I);
  luaL_checkstack(L, 2, "eris-lj unpersist");
  switch (tag) {
    case TAG_NIL:   lua_pushnil(L); break;
    case TAG_FALSE: lua_pushboolean(L, 0); break;
    case TAG_TRUE:  lua_pushboolean(L, 1); break;
    case TAG_INT: {
      uint64_t zz = r_uleb(I);
      int64_t v = (int64_t)((zz >> 1) ^ (~(zz & 1) + 1));
      lua_pushnumber(L, (lua_Number)v);
      break;
    }
    case TAG_NUM: {
      uint64_t bits = r_u64le(I);
      double d;
      memcpy(&d, &bits, 8);
      lua_pushnumber(L, (lua_Number)d);
      break;
    }
    case TAG_STR: u_string(I); break;
    case TAG_TABLE: u_table(I); break;
    case TAG_FUNC: u_function(I); break;
    case TAG_THREAD: u_thread(I); break;
    case TAG_PERMANENT: u_permanent(I); break;
    case TAG_FORIN_ITER:
      lua_pushcfunction(L, elj_forin_replay);
      registerobject(I);
      break;
    case TAG_UPVAL:
    case TAG_UPVALREF:
      /* Only ever valid inside a function's upvalue list, where u_function
       * reads them directly; seeing one in a value slot is malformed. */
      luaL_error(L, "eris-lj: upvalue record outside a function");
      break;
    case TAG_REF: {
      uint64_t id = r_uleb(I);
      /* Compare unsigned: a signed cast would let ids >= 2^63 through. */
      if (id == 0 || id > (uint64_t)I->refcount)
        luaL_error(L, "eris-lj: reference %d out of range (%d known)",
                   (int)id, (int)I->refcount);
      lua_rawgeti(L, REFTIDX, (int)id);
      if (lua_isnil(L, -1))
        luaL_error(L, "eris-lj: dangling reference %d", (int)id);
      break;
    }
    default:
      luaL_error(L, "eris-lj: unknown tag 0x%02x at offset %d",
                 (int)tag, (int)(I->pos - 1));
  }
  leave(I);
}

/* -------------------------------------------------------------- settings */

static const char SETTINGS_KEY = 0;

static const char *const setting_names[] =
  { "spkey", "path", "maxrec", "debug", "spio", NULL };

static void push_default(lua_State *L, int opt)
{
  switch (opt) {
    case 0: lua_pushliteral(L, "__persist"); break;      /* spkey */
    case 1: lua_pushboolean(L, 0); break;                /* path */
    case 2: lua_pushinteger(L, ERIS_LJ_MAXREC_DEFAULT); break;
    case 3: lua_pushboolean(L, 1); break;                /* debug */
    default: lua_pushboolean(L, 0); break;               /* spio */
  }
}

static void push_settings(lua_State *L)
{
  lua_pushlightuserdata(L, (void *)&SETTINGS_KEY);
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (!lua_istable(L, -1)) {
    int i;
    lua_pop(L, 1);
    lua_newtable(L);
    for (i = 0; setting_names[i]; i++) {
      push_default(L, i);
      lua_setfield(L, -2, setting_names[i]);
    }
    lua_pushlightuserdata(L, (void *)&SETTINGS_KEY);
    lua_pushvalue(L, -2);
    lua_rawset(L, LUA_REGISTRYINDEX);
  }
}

static int l_settings(lua_State *L)
{
  int opt = luaL_checkoption(L, 1, NULL, setting_names);
  /* Eris's contract: a nil value RESETS to the default, so only a wholly
   * absent second argument means "just read". */
  int setting = !lua_isnone(L, 2);
  int reset = setting && lua_isnil(L, 2);

  if (setting && !reset) {
    switch (opt) {
      case 0: luaL_checktype(L, 2, LUA_TSTRING); break;
      case 2: luaL_checknumber(L, 2); break;
      case 4:
        if (lua_toboolean(L, 2))
          return luaL_error(L, "eris-lj: the 'spio' setting is not supported");
        break;
      default: break;  /* booleans: any value, truthiness is what counts */
    }
  }

  push_settings(L);                     /* ... settings */
  lua_getfield(L, -1, setting_names[opt]);  /* ... settings old */
  if (setting) {
    if (reset) {
      push_default(L, opt);
    } else if (opt == 2) {
      /* Normalise maxrec at set time so the getter reports the limit that
       * is actually enforced. */
      lua_Number v = lua_tonumber(L, 2);
      lua_Integer iv = (lua_Integer)v;
      if (!(v >= 1)) iv = 1;            /* also catches NaN */
      if (iv > ERIS_LJ_MAXREC_MAX) iv = ERIS_LJ_MAXREC_MAX;
      lua_pushinteger(L, iv);
    } else {
      lua_pushvalue(L, 2);
    }
    lua_setfield(L, -3, setting_names[opt]);
  }
  return 1;
}

static void load_settings(lua_State *L, Info *I)
{
  push_settings(L);                     /* ... settings */
  lua_getfield(L, -1, "maxrec");
  I->maxrec = (int)lua_tointeger(L, -1);
  if (I->maxrec <= 0) I->maxrec = ERIS_LJ_MAXREC_DEFAULT;
  /* Defensive ceiling: enter() must fire before the native stack does,
   * whatever ended up stored. */
  if (I->maxrec > ERIS_LJ_MAXREC_MAX) I->maxrec = ERIS_LJ_MAXREC_MAX;
  lua_pop(L, 1);
  lua_getfield(L, -1, "debug");
  I->wdebug = lua_toboolean(L, -1);
  lua_pop(L, 1);
  lua_getfield(L, -1, "spkey");         /* ... settings spkey */
  lua_remove(L, -2);                    /* ... spkey */
}

/* ------------------------------------------------------------ entry points */

static const char MAGIC[3] = { 'E', 'L', 'J' };

static int l_persist(lua_State *L)
{
  Info I;
  size_t fplen = strlen(ERIS_LJ_FINGERPRINT);
  WBuf *w;
  uint32_t crc;

  if (lua_gettop(L) == 1) {             /* value -> perms value */
    lua_newtable(L);
    lua_insert(L, 1);
  }
  luaL_checktype(L, PERMIDX, LUA_TTABLE);
  luaL_argcheck(L, lua_gettop(L) == 2, 3, "too many arguments");

  memset(&I, 0, sizeof(I));
  I.L = L;

  /* Lay out the fixed slots: perms reftbl buf spkey upv upvn value */
  luaL_checkstack(L, 10, "eris-lj setup");
  lua_newtable(L);                      /* perms value reftbl */
  lua_insert(L, 2);                     /* perms reftbl value */
  wbuf_new(L, 256);                     /* perms reftbl value buf */
  lua_insert(L, 3);                     /* perms reftbl buf value */
  load_settings(L, &I);                 /* perms reftbl buf value spkey */
  lua_insert(L, 4);                     /* perms reftbl buf spkey value */
  lua_newtable(L);
  lua_insert(L, UPVIDX);                /* ... upv value */
  lua_newtable(L);
  lua_insert(L, UPVNIDX);               /* ... upv upvn value */
  lua_newtable(L);
  lua_insert(L, UPVLIST);               /* ... upv upvn uvlist value */

  if (fplen > 255)
    return luaL_error(L, "eris-lj: fingerprint too long");
  w_raw(&I, MAGIC, sizeof(MAGIC));
  w_byte(&I, (unsigned char)ERIS_LJ_FORMAT);
  w_byte(&I, (unsigned char)fplen);
  w_raw(&I, ERIS_LJ_FINGERPRINT, fplen);

  persist(&I);                          /* ... value */

  w = (WBuf *)lua_touserdata(L, BUFIDX);
  crc = eris_crc32(w->p, I.len);
  {
    unsigned char c4[4];
    c4[0] = (unsigned char)(crc & 0xff);
    c4[1] = (unsigned char)((crc >> 8) & 0xff);
    c4[2] = (unsigned char)((crc >> 16) & 0xff);
    c4[3] = (unsigned char)((crc >> 24) & 0xff);
    w_raw(&I, c4, 4);
  }
  w = (WBuf *)lua_touserdata(L, BUFIDX);  /* w_raw may have reallocated */
  lua_pushlstring(L, (const char *)w->p, I.len);
  /* The string owns a copy now; release the buffer immediately rather than
   * waiting for a GC cycle that the host has very likely stopped. */
  wbuf_free(L, w);
  return 1;
}

static int l_unpersist(lua_State *L)
{
  Info I;
  size_t inlen, fplen = strlen(ERIS_LJ_FINGERPRINT);
  const unsigned char *in;
  unsigned char hdr_fplen;
  uint32_t stored, actual;

  if (lua_gettop(L) == 1) {             /* str -> uperms str */
    lua_newtable(L);
    lua_insert(L, 1);
  }
  luaL_checktype(L, PERMIDX, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TSTRING);
  luaL_argcheck(L, lua_gettop(L) == 2, 3, "too many arguments");

  memset(&I, 0, sizeof(I));
  I.L = L;

  luaL_checkstack(L, 10, "eris-lj setup");
  lua_newtable(L);                      /* uperms str reftbl */
  lua_insert(L, 2);                     /* uperms reftbl str */
  /* Slot 3 anchors the input string for the whole parse; nothing replaces
   * it, so the pointer below stays valid. */
  in = (const unsigned char *)lua_tolstring(L, BUFIDX, &inlen);
  I.in = in;
  I.inlen = inlen;
  load_settings(L, &I);                 /* uperms reftbl str spkey */
  lua_newtable(L);
  lua_insert(L, UPVIDX);
  lua_newtable(L);
  lua_insert(L, UPVNIDX);
  lua_newtable(L);
  lua_insert(L, UPVLIST);

  if (inlen < sizeof(MAGIC) + 2 + 4)
    return luaL_error(L, "eris-lj: data too short to be a valid blob");
  if (memcmp(in, MAGIC, sizeof(MAGIC)) != 0)
    return luaL_error(L, "eris-lj: bad magic (not an eris-lj blob)");
  I.pos = sizeof(MAGIC);
  if (r_byte(&I) != ERIS_LJ_FORMAT)
    return luaL_error(L, "eris-lj: format version mismatch (expected %d)",
                      ERIS_LJ_FORMAT);
  hdr_fplen = r_byte(&I);
  if (hdr_fplen != (unsigned char)fplen ||
      I.pos + hdr_fplen > inlen ||
      memcmp(in + I.pos, ERIS_LJ_FINGERPRINT, hdr_fplen) != 0)
    return luaL_error(L, "eris-lj: build fingerprint mismatch "
                         "(blob is from a different natives build)");
  I.pos += hdr_fplen;

  stored = (uint32_t)in[inlen - 4] | ((uint32_t)in[inlen - 3] << 8) |
           ((uint32_t)in[inlen - 2] << 16) | ((uint32_t)in[inlen - 1] << 24);
  actual = eris_crc32(in, inlen - 4);
  if (stored != actual)
    return luaL_error(L, "eris-lj: checksum mismatch (corrupt data)");
  I.inlen = inlen - 4;                  /* body ends before the checksum */

  unpersist(&I);                        /* ... value */
  if (I.pos != I.inlen)
    return luaL_error(L, "eris-lj: %d trailing bytes after the value",
                      (int)(I.inlen - I.pos));
  return 1;
}

static int l_version(lua_State *L)
{
  lua_pushliteral(L, ERIS_LJ_VERSION);
  lua_pushliteral(L, ERIS_LJ_FINGERPRINT);
  lua_pushinteger(L, ERIS_LJ_FORMAT);
  return 3;
}

static const luaL_Reg eris_lj_funcs[] = {
  { "persist",   l_persist },
  { "unpersist", l_unpersist },
  { "settings",  l_settings },
  { "version",   l_version },
  { NULL, NULL }
};

LUALIB_API int luaopen_eris_lj(lua_State *L)
{
  luaL_register(L, "eris", eris_lj_funcs);
  return 1;
}
