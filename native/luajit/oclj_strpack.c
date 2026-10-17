/*
** native/luajit/oclj_strpack.c -- string.pack, string.unpack and
** string.packsize for OC-LuaJIT: Lua 5.3.6's PACK/UNPACK section
** (lstrlib.c:1100-1539), ported to a VM in which every Lua number is an
** IEEE double.  Ported from Lua 5.3.6, Copyright (C) 1994-2020 Lua.org,
** PUC-Rio, under the MIT license (the notice is in NOTICE).
**
** WHERE IT LIVES.  In OUR LuaJIT's own string library.  build-native.sh
** copies this file into the LuaJIT build copy's src/, and
** native/luajit/patch-strpack-register.sh makes that copy's lib_string.c
** include it and register the three entry points below as LJLIB_CF library
** functions (buildvm reads only lib_string.c, so the registrations are there
** and the code is here).  So luaopen_string itself carries them: jnlua's
** openlib(STRING) in both natives, luaL_openlibs in luajit.exe, in every
** native test and in the serializer's test host, and the string metatable's
** __index, so ("<i4"):pack(1) works as in 5.3.  It refuses to compile unless
** native/luajit/oclj_features.h says OCLJ_LIB_STRPACK 1, because
** serializer/eris_lj.c names the library in the blob fingerprint from that
** same macro (the word's "pack1" token).
**
** THE CONTRACT.  The same results, and the same errors (text and argument
** number, in the same order), as PUC Lua 5.3.6 on x86_64, except for the
** two deviations decided on 2026-10-13:
**   D1  an unpacked integer is computed exactly as 5.3.6 computes it -- a
**       64-bit two's-complement value, wrapping the way lua_Integer wraps
**       (I8 and J of 0xFF..FF are -1) -- and only then converted to a
**       double, rounding to nearest, ties to even.  Values that need more
**       than 53 bits come back rounded, never refused: Plan9k's GPT scanner
**       unpacks I8 fields of arbitrary sectors before it checks the
**       signature.  What 5.3.6 itself refuses stays refused, with its text:
**       an I9..I16 field whose extra bytes are not a sign extension.
**   D2  'l' and 'L' are 8 bytes on every platform (5.3.6: sizeof(long),
**       which is 4 on Win64), so a format means the same bytes on every
**       server.
** What the VM itself decides is not pack's to change: NaN payloads are
** canonicalized by lua_pushnumber (lj_api.c:624-628), one call returns at
** most LUAI_MAXCSTACK (8000) stack slots, numbers given to c, s and z are
** formatted by LuaJIT's tostring, and error messages name the function the
** way LuaJIT's luaL_argerror does.  Two more residuals follow from how pack
** is built, and are described where they are made: pk_str2d refuses the
** numerals LuaJIT's scanner refuses and strtod reads (D5/D7), and
** oclj_strpack_pack refuses an over-cap result as LUA_ERRMEM, after every
** argument check (a residual, D7; D4 is the LJ_MAX_STR text).
** Everything below that differs from the 5.3.6 text is marked "LJ:".
**
** INTEGERS.  Nothing here uses lua_Integer, lua_Unsigned, luaL_checkinteger,
** luaL_optinteger, lua_tointeger or lua_pushinteger: on this VM they are not
** 5.3's.  LuaJIT's luaL_checkinteger and lua_tointeger truncate a double with
** a bare C cast (lj_api.c:447-463, lj_obj.h:1010), so 1.5 becomes 1 and 2^63
** becomes INT64_MIN where 5.3 raises "number has no integer representation";
** lua_pushinteger rounds above 2^53; and the shim's lua_Unsigned is 32 bits
** (lj52shim.h:94).  So integers are int64_t/uint64_t throughout, arguments
** are converted by pk_checkint (5.3.6's luaL_checkinteger, strings
** included: a hex numeral wraps modulo 2^64, a decimal one must fit), and
** results are pushed with lua_pushnumber.
**
** MEMORY.  pack walks the format twice with one function (pk_walk): pass 1
** makes every check 5.3.6 makes, in 5.3.6's order, and measures; pass 2
** writes.  The output is built in ONE scratch block of exactly the measured
** size -- a C array for results up to PK_STACKBUF bytes, otherwise a full
** userdata (lua_newuserdata: lj_udata_new -> g->allocf, so the shim's
** lj52_alloc charges it against the machine's RAM cap and gc.total counts
** it; a refusal is LUA_ERRMEM before any byte is written, and the block is
** ordinary garbage once pack returns).  lua_pushlstring then interns a copy,
** which LuaJIT can only make from a finished buffer (lj_str_new), so the
** peak is two copies of the output.  LuaJIT's luaL_Buffer is 5.1's: it
** concatenates on the Lua stack and peaked at 3.8-4.6x for 1 MiB.
**
** BOUNDS.  The format is read only below its end (pk_Header.fe): a NUL
** inside it ends the format, exactly as 5.3.6's C-string loop does, and its
** end reads as one too.  unpack reads data[pos .. pos+size) only after
** 5.3.6's own overflow-safe check (lstrlib.c:1488-1489) has passed -- keep
** that form: after an unterminated 'z' the position is len+1, and 5.4's
** "ld - pos" form wraps there --, an 's' payload only after a length check
** that cannot wrap, and 'z' searches with memchr bounded by the data
** (5.3.6's strlen stops at the terminator LuaJIT also guarantees,
** lj_str.c:299-300; the result is the same).
**
** This file includes LuaJIT's internal lj_obj.h for LJ_MAX_STR and the
** feature set, and native/luajit/oclj_num53.h, 5.3.6's number readers,
** which it shares with the bitwise operators (oclj_bitop_meta.c) so that the
** two read every value alike; their string scan is LuaJIT's lj_strscan_scan,
** the call lua_tonumberx makes.  Everything else it calls is the public C
** API.
*/

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lj_obj.h"

#ifndef OCLJ_LUAJIT_FEATURES
#error "oclj_strpack.c must be compiled inside native/build-native.sh's LuaJIT build copy, whose lj_arch.h includes native/luajit/oclj_features.h"
#endif
#if !defined(OCLJ_LIB_STRPACK) || OCLJ_LIB_STRPACK != 1
#error "oclj_strpack.c: native/luajit/oclj_features.h does not say OCLJ_LIB_STRPACK 1, so serializer/eris_lj.c would not name this library in the blob fingerprint"
#endif

#include "oclj_num53.h"

typedef int64_t  pk_Int;   /* LJ: 5.3.6's lua_Integer (64-bit) */
typedef uint64_t pk_Uns;   /* LJ: 5.3.6's lua_Unsigned (64-bit) */

/* The port assumes what 5.3.6 on x86_64 assumes; refuse to compile otherwise. */
typedef char pk_assert_charbit[CHAR_BIT == 8 ? 1 : -1];
typedef char pk_assert_number[sizeof(lua_Number) == sizeof(double) ? 1 : -1];
typedef char pk_assert_sizet[sizeof(size_t) == sizeof(pk_Uns) ? 1 : -1];

#define PK_PADBYTE	0x00
#define PK_MAXINTSIZE	16
#define PK_NB		CHAR_BIT
#define PK_MC		((1 << PK_NB) - 1)
#define PK_SZINT	((int)sizeof(pk_Int))
/* 5.3.6's MAXSIZE (lstrlib.c:46-49): INT_MAX wherever size_t is wider. */
#define PK_MAXSIZE \
	(sizeof(size_t) < sizeof(int) ? (size_t)~(size_t)0 : (size_t)INT_MAX)
/* LJ: lj_str_new interns lengths below LJ_MAX_STR only (lj_str.c:317). */
#define PK_MAXOUT	((uint64_t)LJ_MAX_STR)
/* LJ: results up to this size are built on the C stack, not in a userdata. */
#define PK_STACKBUF	512

static const union {
  int dummy;
  char little;  /* true iff machine is little endian */
} pk_nativeendian = {1};

/* 5.3.6's native alignment (lstrlib.c:1131-1136): 8 on x86_64. */
struct pk_cD {
  char c;
  union { double d; void *p; pk_Int i; lua_Number n; } u;
};
#define PK_MAXALIGN	((int)offsetof(struct pk_cD, u))

typedef struct pk_Header {
  lua_State *L;
  int islittle;
  int maxalign;
  const char *fe;  /* LJ: end of the format string */
} pk_Header;

typedef enum pk_KOption {
  pk_Kint,	/* signed integers */
  pk_Kuint,	/* unsigned integers */
  pk_Kfloat,	/* floating-point numbers */
  pk_Kchar,	/* fixed-length strings */
  pk_Kstring,	/* strings with prefixed length */
  pk_Kzstr,	/* zero-terminated strings */
  pk_Kpadding,	/* padding */
  pk_Kpaddalign,	/* padding for alignment */
  pk_Knop	/* no-op (configuration or spaces) */
} pk_KOption;


/* {======================================================
** 5.3.6's argument conversions, on a double-only VM
** ======================================================= */

/* 5.3.6's readers, in native/luajit/oclj_num53.h, which the bitwise
** operators share (oclj_bitop_meta.c), so that pack and the operators read
** every argument alike: the two's-complement cast, l_str2int over
** [s, s+len), l_str2d through LuaJIT's scanner after the refusals described
** there (the RESID-scan residual, D5/D7), and the float->integer conversion
** with mode 0.  The pk_ names stay, so the code below reads as it did before
** the readers moved, and negctl-pack.sh's CHECKINT and LJCOERCE arms still
** find their lines in pk_checkint and pk_tonum. */
#define pk_u2s		oclj_u2s
#define pk_str2int	oclj_str2int
#define pk_str2d	oclj_str2d
#define pk_flt2int	oclj_flt2int

/* 5.3.6 lauxlib.c:182-193 (typeerror): __name, then "light userdata". */
static int pk_typeerror(lua_State *L, int arg, const char *tname)
{
  const char *typearg;
  if (luaL_getmetafield(L, arg, "__name") && lua_type(L, -1) == LUA_TSTRING)
    typearg = lua_tostring(L, -1);
  else if (lua_type(L, arg) == LUA_TLIGHTUSERDATA)
    typearg = "light userdata";
  else
    typearg = luaL_typename(L, arg);
  return luaL_argerror(L, arg,
                       lua_pushfstring(L, "%s expected, got %s", tname, typearg));
}

/* 5.3.6's luaL_checklstring: numbers are converted in place (here by
** LuaJIT's number formatting, as for every string function on this VM). */
static const char *pk_checklstring(lua_State *L, int arg, size_t *len)
{
  const char *s = lua_tolstring(L, arg, len);
  if (s == NULL) pk_typeerror(L, arg, "string");
  return s;
}

/* What 5.3.6 sees in an argument (lvm.c:94-117, lobject.c:331-343):
** 0 not a number, 1 an integer (*pi), 2 a float (*pn).  Every number of
** this VM is a float; only a string can yield a 5.3 integer. */
static int pk_tonum(lua_State *L, int arg, pk_Int *pi, double *pn)
{
  int t = lua_type(L, arg);
  if (t == LUA_TNUMBER) {
    *pn = (double)lua_tonumber(L, arg);
    return 2;
  }
  if (t == LUA_TSTRING) {
    size_t len;
    const char *s = lua_tolstring(L, arg, &len);
    if (pk_str2int(s, len, pi)) return 1;
    if (pk_str2d(s, len, pn)) return 2;
  }
  return 0;
}

/* 5.3.6's luaL_checkinteger (lauxlib.c:422-436, interror and the function). */
static pk_Int pk_checkint(lua_State *L, int arg)
{
  pk_Int i = 0;
  double n = 0;
  switch (pk_tonum(L, arg, &i, &n)) {
    case 1:
      return i;
    case 2:
      if (pk_flt2int(n, &i)) return i;
      luaL_argerror(L, arg, "number has no integer representation");
      break;
    default:
      pk_typeerror(L, arg, "number");
      break;
  }
  return 0;  /* not reached */
}

/* 5.3.6's luaL_checknumber: a 5.3 integer is cast to a float (nearest). */
static double pk_checknumber(lua_State *L, int arg)
{
  pk_Int i = 0;
  double n = 0;
  switch (pk_tonum(L, arg, &i, &n)) {
    case 1: return (double)i;
    case 2: return n;
    default: pk_typeerror(L, arg, "number"); return 0;
  }
}

static pk_Int pk_optint(lua_State *L, int arg, pk_Int def)
{
  return lua_isnoneornil(L, arg) ? def : pk_checkint(L, arg);
}

/* }====================================================== */


/* {======================================================
** The format language (lstrlib.c:1180-1286)
** ======================================================= */

/* LJ: the byte at p, or '\0' at or past the end of the format. */
static int pk_peek(const pk_Header *h, const char *p)
{
  return p < h->fe ? (unsigned char)*p : '\0';
}

static int pk_digit(int c) { return '0' <= c && c <= '9'; }

static int pk_getnum(pk_Header *h, const char **fmt, int df)
{
  if (!pk_digit(pk_peek(h, *fmt)))  /* no number? */
    return df;  /* return default value */
  else {
    int a = 0;
    do {
      a = a*10 + (*((*fmt)++) - '0');
    } while (pk_digit(pk_peek(h, *fmt)) && a <= ((int)PK_MAXSIZE - 9)/10);
    return a;
  }
}

static int pk_getnumlimit(pk_Header *h, const char **fmt, int df)
{
  int sz = pk_getnum(h, fmt, df);
  if (sz > PK_MAXINTSIZE || sz <= 0)
    return luaL_error(h->L, "integral size (%d) out of limits [1,%d]",
                            sz, PK_MAXINTSIZE);
  return sz;
}

static void pk_initheader(lua_State *L, pk_Header *h, const char *fe)
{
  h->L = L;
  h->islittle = pk_nativeendian.little;
  h->maxalign = 1;
  h->fe = fe;
}

/* Called only where pk_peek(h, *fmt) != '\0'. */
static pk_KOption pk_getoption(pk_Header *h, const char **fmt, int *size)
{
  int opt = (unsigned char)*((*fmt)++);
  *size = 0;  /* default */
  switch (opt) {
    case 'b': *size = sizeof(char); return pk_Kint;
    case 'B': *size = sizeof(char); return pk_Kuint;
    case 'h': *size = sizeof(short); return pk_Kint;
    case 'H': *size = sizeof(short); return pk_Kuint;
    case 'l': *size = PK_SZINT; return pk_Kint;   /* LJ: D2, 8 everywhere */
    case 'L': *size = PK_SZINT; return pk_Kuint;  /* LJ: D2 */
    case 'j': *size = PK_SZINT; return pk_Kint;
    case 'J': *size = PK_SZINT; return pk_Kuint;
    case 'T': *size = sizeof(size_t); return pk_Kuint;
    case 'f': *size = sizeof(float); return pk_Kfloat;
    case 'd': *size = sizeof(double); return pk_Kfloat;
    case 'n': *size = sizeof(lua_Number); return pk_Kfloat;
    case 'i': *size = pk_getnumlimit(h, fmt, sizeof(int)); return pk_Kint;
    case 'I': *size = pk_getnumlimit(h, fmt, sizeof(int)); return pk_Kuint;
    case 's': *size = pk_getnumlimit(h, fmt, sizeof(size_t)); return pk_Kstring;
    case 'c':
      *size = pk_getnum(h, fmt, -1);
      if (*size == -1)
        luaL_error(h->L, "missing size for format option 'c'");
      return pk_Kchar;
    case 'z': return pk_Kzstr;
    case 'x': *size = 1; return pk_Kpadding;
    case 'X': return pk_Kpaddalign;
    case ' ': break;
    case '<': h->islittle = 1; break;
    case '>': h->islittle = 0; break;
    case '=': h->islittle = pk_nativeendian.little; break;
    case '!': h->maxalign = pk_getnumlimit(h, fmt, PK_MAXALIGN); break;
    default:
      /* LJ: 5.3.6's lua_pushfstring prints a byte that is not printable
      ** ASCII as "<\NNN>" (lobject.c:413-420); LuaJIT's %c prints it raw. */
      if (opt >= 0x20 && opt <= 0x7e)
        luaL_error(h->L, "invalid format option '%c'", opt);
      else
        luaL_error(h->L, "invalid format option '<\\%d>'", opt);
  }
  return pk_Knop;
}

static pk_KOption pk_getdetails(pk_Header *h, size_t totalsize,
                                const char **fmt, int *psize, int *ntoalign)
{
  pk_KOption opt = pk_getoption(h, fmt, psize);
  int align = *psize;  /* usually, alignment follows size */
  if (opt == pk_Kpaddalign) {  /* 'X' gets alignment from following option */
    if (pk_peek(h, *fmt) == '\0' || pk_getoption(h, fmt, &align) == pk_Kchar ||
        align == 0)
      luaL_argerror(h->L, 1, "invalid next option for option 'X'");
  }
  if (align <= 1 || opt == pk_Kchar)  /* need no alignment? */
    *ntoalign = 0;
  else {
    if (align > h->maxalign)  /* enforce maximum alignment */
      align = h->maxalign;
    if ((align & (align - 1)) != 0)  /* is 'align' not a power of 2? */
      luaL_argerror(h->L, 1, "format asks for alignment not power of 2");
    *ntoalign = (align - (int)(totalsize & (align - 1))) & (align - 1);
  }
  return opt;
}

/* }====================================================== */


/* {======================================================
** pack
** ======================================================= */

/* The scratch block being filled by pass 2. */
typedef struct pk_Out {
  lua_State *L;
  char *b;
  size_t n, cap;
} pk_Out;

/* The next k bytes of the block.  Pass 1 measured exactly what pass 2
** writes, so the error is unreachable; it is here so that a disagreement
** between the passes could never become a write past the block. */
static char *pk_room(pk_Out *o, size_t k)
{
  char *p;
  if (k > o->cap - o->n)
    luaL_error(o->L, "string.pack: internal error (output size mismatch)");
  p = o->b + o->n;
  o->n += k;
  return p;
}

static void pk_packint(char *buff, pk_Uns n, int islittle, int size, int neg)
{
  int i;
  buff[islittle ? 0 : size - 1] = (char)(n & PK_MC);  /* first byte */
  for (i = 1; i < size; i++) {
    n >>= PK_NB;
    buff[islittle ? i : size - 1 - i] = (char)(n & PK_MC);
  }
  if (neg && size > PK_SZINT) {  /* negative number need sign extension? */
    for (i = PK_SZINT; i < size; i++)  /* correct extra bytes */
      buff[islittle ? i : size - 1 - i] = (char)PK_MC;
  }
}

static void pk_copywithendian(char *dest, const char *src, int size,
                              int islittle)
{
  if (islittle == pk_nativeendian.little)
    memcpy(dest, src, (size_t)size);
  else {  /* LJ: by index; 5.3.6's pointer walk ends one before 'dest' */
    int i;
    for (i = 0; i < size; i++)
      dest[size - 1 - i] = src[i];
  }
}

/* 5.3.6's str_pack loop (lstrlib.c:1339-1414).  o == NULL: pass 1, which
** makes every check and returns the size of the result; o != NULL: pass 2,
** which repeats the walk over the same (already converted) arguments and
** writes.  Nothing the checks call can change an argument a second time:
** pass 1 has already turned numbers given for c/s/z into strings in place,
** and the integer and float conversions are pure. */
static uint64_t pk_walk(lua_State *L, const char *fmt, const char *fe,
                        pk_Out *o)
{
  pk_Header h;
  int arg = 1;  /* current argument to pack */
  uint64_t totalsize = 0;  /* LJ: 64-bit on every size_t; cannot wrap */
  pk_initheader(L, &h, fe);
  while (pk_peek(&h, fmt) != '\0') {
    int size, ntoalign;
    pk_KOption opt = pk_getdetails(&h, (size_t)totalsize, &fmt, &size,
                                   &ntoalign);
    totalsize += (uint64_t)ntoalign + (uint64_t)size;
    if (o != NULL && ntoalign > 0)
      memset(pk_room(o, (size_t)ntoalign), PK_PADBYTE, (size_t)ntoalign);
    arg++;
    switch (opt) {
      case pk_Kint: {  /* signed integers */
        pk_Int n = pk_checkint(L, arg);
        if (size < PK_SZINT) {  /* need overflow check? */
          pk_Int lim = (pk_Int)1 << ((size * PK_NB) - 1);
          luaL_argcheck(L, -lim <= n && n < lim, arg, "integer overflow");
        }
        if (o != NULL)
          pk_packint(pk_room(o, (size_t)size), (pk_Uns)n, h.islittle, size,
                     (n < 0));
        break;
      }
      case pk_Kuint: {  /* unsigned integers */
        pk_Int n = pk_checkint(L, arg);
        if (size < PK_SZINT)  /* need overflow check? */
          luaL_argcheck(L, (pk_Uns)n < ((pk_Uns)1 << (size * PK_NB)),
                           arg, "unsigned overflow");
        if (o != NULL)
          pk_packint(pk_room(o, (size_t)size), (pk_Uns)n, h.islittle, size, 0);
        break;
      }
      case pk_Kfloat: {  /* floating-point options */
        double n = pk_checknumber(L, arg);
        if (o != NULL) {
          char *buff = pk_room(o, (size_t)size);
          if (size == (int)sizeof(float)) {
            float f = (float)n;  /* IEEE (Annex F): out of range -> inf */
            pk_copywithendian(buff, (const char *)&f, size, h.islittle);
          }
          else
            pk_copywithendian(buff, (const char *)&n, size, h.islittle);
        }
        break;
      }
      case pk_Kchar: {  /* fixed-size string */
        size_t len;
        const char *s = pk_checklstring(L, arg, &len);
        luaL_argcheck(L, len <= (size_t)size, arg,
                         "string longer than given size");
        if (o != NULL) {
          char *buff = pk_room(o, (size_t)size);
          memcpy(buff, s, len);
          memset(buff + len, PK_PADBYTE, (size_t)size - len);
        }
        break;
      }
      case pk_Kstring: {  /* strings with length count */
        size_t len;
        const char *s = pk_checklstring(L, arg, &len);
        luaL_argcheck(L, size >= (int)sizeof(size_t) ||
                         (pk_Uns)len < ((pk_Uns)1 << (size * PK_NB)),
                         arg, "string length does not fit in given size");
        if (o != NULL) {
          char *buff = pk_room(o, (size_t)size + len);
          pk_packint(buff, (pk_Uns)len, h.islittle, size, 0);  /* pack length */
          memcpy(buff + size, s, len);
        }
        totalsize += len;
        break;
      }
      case pk_Kzstr: {  /* zero-terminated string */
        size_t len;
        const char *s = pk_checklstring(L, arg, &len);
        /* 5.3.6: strlen(s) == len; the same verdict without the terminator */
        luaL_argcheck(L, memchr(s, 0, len) == NULL, arg,
                         "string contains zeros");
        if (o != NULL) {
          char *buff = pk_room(o, len + 1);
          memcpy(buff, s, len);
          buff[len] = '\0';  /* add zero at the end */
        }
        totalsize += (uint64_t)len + 1;
        break;
      }
      case pk_Kpadding:
        if (o != NULL) *pk_room(o, 1) = (char)PK_PADBYTE;
        arg--;  /* undo increment */
        break;
      case pk_Kpaddalign: case pk_Knop:
        arg--;  /* undo increment */
        break;
    }
  }
  return totalsize;
}

static int oclj_strpack_pack(lua_State *L)
{
  char sbuf[PK_STACKBUF];
  size_t fl;
  const char *fmt = pk_checklstring(L, 1, &fl);  /* format string */
  uint64_t total;
  pk_Out o;
  /* 5.3.6's mark (lstrlib.c:1337).  It sits where the first missing
  ** argument would be, so a short argument list reads "got nil", and no
  ** option accepts nil, so nothing past it is ever read. */
  lua_pushnil(L);
  total = pk_walk(L, fmt, fmt + fl, NULL);  /* pass 1: check and measure */
  /* LJ: D4.  A result of LJ_MAX_STR bytes or more is longer than any LuaJIT
  ** string can be, so it is refused here, before anything is allocated,
  ** with the text 5.3.6's luaL_Buffer raises when its allocation fails
  ** (lauxlib.c:468).  It is reached only at LJ_MAX_STR, which no OC cap
  ** reaches.  An over-cap result below that is refused by the allocation
  ** itself (lua_newuserdata below, or lua_pushlstring) as LUA_ERRMEM "not
  ** enough memory", unpositioned, and only after every argument check, which
  ** pass 1 has made.  5.3.6 grows its buffer as it walks: a refused growth
  ** raises the buffer text (positioned when a Lua function is the caller),
  ** possibly before a later bad argument
  ** is reached, and a refused final string is LUA_ERRMEM. */
  if (total >= PK_MAXOUT)
    luaL_error(L, "not enough memory for buffer allocation");
  o.L = L;
  o.n = 0;
  o.cap = (size_t)total;
  o.b = o.cap <= sizeof(sbuf) ? sbuf : (char *)lua_newuserdata(L, o.cap);
  pk_walk(L, fmt, fmt + fl, &o);  /* pass 2: fill */
  if (o.n != o.cap)
    luaL_error(L, "string.pack: internal error (output size mismatch)");
  lua_pushlstring(L, o.b, o.cap);
  return 1;
}

static int oclj_strpack_packsize(lua_State *L)
{
  pk_Header h;
  size_t fl;
  const char *fmt = pk_checklstring(L, 1, &fl);  /* format string */
  size_t totalsize = 0;  /* accumulate total size of result */
  pk_initheader(L, &h, fmt + fl);
  while (pk_peek(&h, fmt) != '\0') {
    int size, ntoalign;
    pk_KOption opt = pk_getdetails(&h, totalsize, &fmt, &size, &ntoalign);
    size += ntoalign;  /* total space used by option */
    luaL_argcheck(L, totalsize <= PK_MAXSIZE - (size_t)size, 1,
                     "format result too large");
    totalsize += (size_t)size;
    /* 5.3.6 order: the size check above comes first (5.4 swapped them) */
    if (opt == pk_Kstring || opt == pk_Kzstr)
      luaL_argerror(L, 1, "variable-length format");
  }
  lua_pushnumber(L, (lua_Number)totalsize);
  return 1;
}

/* }====================================================== */


/* {======================================================
** unpack
** ======================================================= */

static pk_Int pk_unpackint(lua_State *L, const char *str,
                           int islittle, int size, int issigned)
{
  pk_Uns res = 0;
  int i;
  int limit = (size <= PK_SZINT) ? size : PK_SZINT;
  for (i = limit - 1; i >= 0; i--) {
    res <<= PK_NB;
    res |= (pk_Uns)(unsigned char)str[islittle ? i : size - 1 - i];
  }
  if (size < PK_SZINT) {  /* real size smaller than lua_Integer? */
    if (issigned) {  /* needs sign extension? */
      pk_Uns mask = (pk_Uns)1 << (size*PK_NB - 1);
      res = ((res ^ mask) - mask);  /* do sign extension */
    }
  }
  else if (size > PK_SZINT) {  /* must check unread bytes */
    int mask = (!issigned || pk_u2s(res) >= 0) ? 0 : PK_MC;
    for (i = limit; i < size; i++) {
      if ((unsigned char)str[islittle ? i : size - 1 - i] != mask)
        luaL_error(L, "%d-byte integer does not fit into Lua Integer", size);
    }
  }
  return pk_u2s(res);
}

/* 5.3.6 lstrlib.c:61-65 (5.4's posrelatI clips 0 and far-negative to 1;
** 5.3.6 maps them to 0, which the caller then refuses). */
static pk_Int pk_posrelat(pk_Int pos, size_t len)
{
  if (pos >= 0) return pos;
  else if (0u - (size_t)pos > len) return 0;
  else return (pk_Int)len + pos + 1;
}

static int oclj_strpack_unpack(lua_State *L)
{
  pk_Header h;
  size_t fl;
  const char *fmt = pk_checklstring(L, 1, &fl);
  size_t ld;
  const char *data = pk_checklstring(L, 2, &ld);
  size_t pos = (size_t)pk_posrelat(pk_optint(L, 3, 1), ld) - 1;
  int n = 0;  /* number of results */
  luaL_argcheck(L, pos <= ld, 3, "initial position out of string");
  pk_initheader(L, &h, fmt + fl);
  while (pk_peek(&h, fmt) != '\0') {
    int size, ntoalign;
    pk_KOption opt = pk_getdetails(&h, pos, &fmt, &size, &ntoalign);
    if ((size_t)ntoalign + (size_t)size > ~pos ||
        pos + (size_t)ntoalign + (size_t)size > ld)
      luaL_argerror(L, 2, "data string too short");
    pos += (size_t)ntoalign;  /* skip alignment */
    /* from here pos + size <= ld */
    /* stack space for item + next position */
    luaL_checkstack(L, 2, "too many results");
    n++;
    switch (opt) {
      case pk_Kint:
      case pk_Kuint: {
        pk_Int res = pk_unpackint(L, data + pos, h.islittle, size,
                                  (opt == pk_Kint));
        lua_pushnumber(L, (lua_Number)res);  /* LJ: D1, the nearest double */
        break;
      }
      case pk_Kfloat: {
        if (size == (int)sizeof(float)) {
          float f;
          pk_copywithendian((char *)&f, data + pos, size, h.islittle);
          lua_pushnumber(L, (lua_Number)f);
        }
        else {
          double d;
          pk_copywithendian((char *)&d, data + pos, size, h.islittle);
          lua_pushnumber(L, (lua_Number)d);
        }
        break;
      }
      case pk_Kchar: {
        lua_pushlstring(L, data + pos, (size_t)size);
        break;
      }
      case pk_Kstring: {
        pk_Uns len = (pk_Uns)pk_unpackint(L, data + pos, h.islittle, size, 0);
        /* LJ: 5.3.6 tests pos + len + size <= ld in size_t (lstrlib.c:1518),
        ** and the sum wraps when len > SIZE_MAX - pos - size: the test then
        ** passes, and 5.3.6 is saved only by luaS_newlstr refusing such a
        ** length, "memory allocation error: block too big".  Here neither
        ** comparison can wrap (pos + size <= ld holds), nothing is read, and
        ** the same inputs fail with the same two texts.  The first carries no
        ** position, as in 5.3.6, whose luaG_runerror adds one only when the
        ** running function is a Lua function (ldebug.c:653-663) and here it
        ** is str_unpack: so lua_error, which adds none (lj_err.c:1129-1133),
        ** not luaL_error, which adds a Lua caller's "chunk:line: ". */
        if (len > (pk_Uns)(ld - pos - (size_t)size)) {
          if (len > (pk_Uns)(SIZE_MAX - pos - (size_t)size))
            { lua_pushliteral(L, "memory allocation error: block too big"); lua_error(L); }
          luaL_argerror(L, 2, "data string too short");
        }
        lua_pushlstring(L, data + pos + size, (size_t)len);
        pos += (size_t)len;  /* skip string */
        break;
      }
      case pk_Kzstr: {
        /* LJ: bounded; 5.3.6's strlen finds the same NUL or the terminator */
        const char *z = (const char *)memchr(data + pos, 0, ld - pos);
        size_t len = z != NULL ? (size_t)(z - (data + pos)) : ld - pos;
        lua_pushlstring(L, data + pos, len);
        pos += len + 1;  /* skip string plus final '\0' (may reach ld + 1,
                            as in 5.3.6; any later option then fails) */
        break;
      }
      case pk_Kpaddalign: case pk_Kpadding: case pk_Knop:
        n--;  /* undo increment */
        break;
    }
    pos += (size_t)size;
  }
  lua_pushnumber(L, (lua_Number)(pos + 1));  /* next position */
  return n + 1;
}

/* }====================================================== */
