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
 * Hostile input is assumed. Every read is bounds-checked, every wire byte
 * that indexes anything is range-checked, and recursion is bounded on both
 * sides — a malformed or crafted blob must raise a catchable Lua error,
 * never crash. Depth costs ~128 bytes of C stack per level on the read
 * side at -O2, so ERIS_LJ_MAXREC_MAX is set to stay under 40% of a 1 MB
 * thread stack (the JVM per-thread default an OC computer runs on).
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

#include "eris_lj.h"

/* ---------------------------------------------------------------- limits */

#ifndef ERIS_LJ_MAXREC_DEFAULT
#define ERIS_LJ_MAXREC_DEFAULT 2000
#endif

#ifndef ERIS_LJ_MAXREC_MAX
/* Hard ceiling on the effective recursion limit, whatever a host asks for:
 * enter() must always raise its catchable error before the native stack is
 * exhausted. ~3000 levels is ~384 KB on the read side at -O2. */
#define ERIS_LJ_MAXREC_MAX 3000
#endif

/* Largest reference id we can hand to lua_rawseti/lua_rawgeti. */
#define ERIS_LJ_MAXREF 0x7fffffff

#define ERIS_LJ_FINGERPRINT ERIS_LJ_COMMIT "|" LUAJIT_VERSION

/* Fixed stack slots used by both directions. */
#define PERMIDX 1  /* perms (persist) / uperms (unpersist) table */
#define REFTIDX 2  /* reference table: obj->id persisting, id->obj restoring */
#define BUFIDX  3  /* write buffer userdata (persist) / input string anchor */
#define SPKIDX  4  /* the spkey string, kept alive here */

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
  /* Reserved for later milestones so adding them needs no version bump:
   * 9 = function, 10 = proto, 11 = upvalue, 12 = thread, 13 = userdata. */
  TAG_MAX_M1 = TAG_REF
};

/* Table record flags (byte after TAG_TABLE). */
#define TABLE_LITERAL 0
#define TABLE_SPECIAL 1  /* spkey function; M2 */

/* ------------------------------------------------------------------ info */

typedef struct {
  lua_State *L;
  size_t len;                 /* bytes written (persist) */
  const unsigned char *in;    /* input (unpersist) */
  size_t inlen, pos;
  lua_Integer refcount;
  int level, maxrec;
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

static int wbuf_gc(lua_State *L)
{
  WBuf *w = (WBuf *)lua_touserdata(L, 1);
  if (w && w->p) {
    wbuf_realloc(L, w->p, w->cap, 0);
    w->p = NULL;
    w->cap = 0;
  }
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

static void w_need(Info *I, size_t n)
{
  WBuf *w = (WBuf *)lua_touserdata(I->L, BUFIDX);
  if (I->len + n > w->cap) {
    size_t ncap = w->cap ? w->cap : 256;
    void *np;
    while (ncap < I->len + n) {
      if (ncap > ((size_t)-1) / 2)
        luaL_error(I->L, "eris-lj: buffer would exceed addressable memory");
      ncap *= 2;
    }
    np = wbuf_realloc(I->L, w->p, w->cap, ncap);
    if (!np) luaL_error(I->L, "eris-lj: out of memory growing buffer");
    w->p = (unsigned char *)np;
    w->cap = ncap;
  }
}

static void w_raw(Info *I, const void *p, size_t n)
{
  WBuf *w;
  w_need(I, n);
  w = (WBuf *)lua_touserdata(I->L, BUFIDX);
  memcpy(w->p + I->len, p, n);
  I->len += n;
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

static void p_table(Info *I)  /* ... tbl */
{
  lua_State *L = I->L;
  int literal = 1;
  luaL_checkstack(L, 3, "eris-lj spkey");
  if (lua_getmetatable(L, -1)) {        /* tbl mt */
    lua_pushvalue(L, SPKIDX);           /* tbl mt spkey */
    lua_rawget(L, -2);                  /* tbl mt sp? */
    if (!lua_isnil(L, -1)) {
      if (lua_isboolean(L, -1)) {
        if (!lua_toboolean(L, -1))
          luaL_error(L, "eris-lj: attempt to persist forbidden table");
        /* true: persist literally, exactly as Eris does. */
      } else if (lua_isfunction(L, -1)) {
        literal = 0;
      } else {
        luaL_error(L, "eris-lj: invalid '%s' metafield (%s)",
                   lua_tostring(L, SPKIDX), luaL_typename(L, -1));
      }
    }
    lua_pop(L, 2);                      /* tbl */
  }
  if (!literal)
    luaL_error(L, "eris-lj: spkey functions need closure support (M2); "
                  "this build is M1 (data only)");
  w_byte(I, TAG_TABLE);
  w_byte(I, TABLE_LITERAL);
  p_literaltable(I);
}

static void persist_typed(Info *I, int type)  /* ... obj */
{
  switch (type) {
    case LUA_TSTRING: p_string(I); break;
    case LUA_TTABLE:  p_table(I); break;
    case LUA_TLIGHTUSERDATA:
      luaL_error(I->L, "eris-lj: cannot persist light userdata by value "
                       "(process-local pointer); put it in the perms table");
      break;
    case LUA_TFUNCTION:
      luaL_error(I->L, "eris-lj: cannot persist functions yet (M2); "
                       "put C functions in the perms table");
      break;
    case LUA_TUSERDATA:
      luaL_error(I->L, "eris-lj: cannot persist userdata yet (M3)");
      break;
    case LUA_TTHREAD:
      luaL_error(I->L, "eris-lj: cannot persist threads yet (M3)");
      break;
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
    w_byte(I, TAG_REF);
    w_uleb(I, (uint64_t)lua_tointeger(L, -1));
    lua_pop(L, 2);                      /* obj */
    return;
  }
  lua_pop(L, 1);                        /* obj refkey */

  /* Register BEFORE descending, so a cycle back to this object emits a
   * reference instead of recursing forever. */
  lua_pushvalue(L, -1);                 /* obj refkey refkey */
  lua_pushinteger(L, newref(I));        /* obj refkey refkey id */
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

static void u_table(Info *I)
{
  lua_State *L = I->L;
  unsigned char flag = r_byte(I);
  if (flag != TABLE_LITERAL)
    luaL_error(L, "eris-lj: table flag %d unsupported in this build (M1)",
               (int)flag);
  luaL_checkstack(L, 4, "eris-lj table");
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
    case TAG_PERMANENT: u_permanent(I); break;
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

  /* Lay out the fixed slots: perms reftbl buf spkey value */
  lua_newtable(L);                      /* perms value reftbl */
  lua_insert(L, 2);                     /* perms reftbl value */
  wbuf_new(L, 256);                     /* perms reftbl value buf */
  lua_insert(L, 3);                     /* perms reftbl buf value */
  load_settings(L, &I);                 /* perms reftbl buf value spkey */
  lua_insert(L, 4);                     /* perms reftbl buf spkey value */

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

  lua_newtable(L);                      /* uperms str reftbl */
  lua_insert(L, 2);                     /* uperms reftbl str */
  /* Slot 3 anchors the input string for the whole parse; nothing replaces
   * it, so the pointer below stays valid. */
  in = (const unsigned char *)lua_tolstring(L, BUFIDX, &inlen);
  I.in = in;
  I.inlen = inlen;
  load_settings(L, &I);                 /* uperms reftbl str spkey */

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
