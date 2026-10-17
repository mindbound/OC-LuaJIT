/*
** native/luajit/oclj_num53.h -- Lua 5.3.6's reading of a value as an
** integer, on a VM whose numbers are all doubles: luaO_str2num for a string
** (lobject.c:331-343: l_str2int, then l_str2d) and luaV_tointeger mode 0 for
** a float (lvm.c:94-117).  Ported from Lua 5.3.6, Copyright (C) 1994-2020
** Lua.org, PUC-Rio, under the MIT license (the notice is in NOTICE).
**
** ONE COPY, TWO USERS.  string.pack's arguments (native/luajit/
** oclj_strpack.c: pk_tonum, pk_checkint) and the bitwise operators' operands
** (native/luajit/oclj_bitop.h, oclj_bitop_meta.c) are read by these same
** functions, so the two agree on every value: "0x10", " 7 ", "1e3" and "-0"
** are integers to both, a hex numeral of any length wraps modulo 2^64 for
** both, and "1.5", "inf", "0b1" and the double 2^63 are refused by both.
** The operators' prototype carried a second copy; the two were measured
** equal on 51 strings before they were merged here, and
** test/native/bitop/coerce_agree.lua (run by test/native/run-bitop.sh)
** keeps comparing pack's reading with the operators'.
**
** Every function is static LJ_AINLINE and takes no Lua state.  A string
** comes as (pointer, length), and the pointer must be a Lua string's data:
** LuaJIT terminates every string with a NUL (lj_str.c:299-300), and
** lj_strscan_scan reads up to it (lj_strscan.c:397, :498).  Each includer
** is compiled inside native/build-native.sh's LuaJIT build copy, which is
** where build-native.sh copies this file.
*/
#ifndef OCLJ_NUM53_H
#define OCLJ_NUM53_H

#include <stddef.h>
#include <stdint.h>

#include "lj_obj.h"
#include "lj_strscan.h"

#ifndef OCLJ_LUAJIT_FEATURES
#error "oclj_num53.h must be compiled inside native/build-native.sh's LuaJIT build copy, whose lj_arch.h includes native/luajit/oclj_features.h"
#endif

/* uint64 -> int64, two's complement, without implementation-defined casts. */
static LJ_AINLINE int64_t oclj_u2s(uint64_t u)
{
  return u <= (uint64_t)INT64_MAX ? (int64_t)u : -(int64_t)(~u) - 1;
}

/* 5.3.6's float->integer with mode 0 (lvm.c:97-105, luaconf.h:449-451):
** exact integral values in [-2^63, 2^63) only; NaN fails the range test. */
static LJ_AINLINE int oclj_flt2int(double n, int64_t *p)
{
  if (!(n >= -9223372036854775808.0 && n < 9223372036854775808.0))
    return 0;
  *p = (int64_t)n;  /* in range, so defined (C99 6.3.1.4) */
  return (double)*p == n;
}

/* lctype's ASCII classes (5.3.6 builds with LUA_USE_CTYPE 0): no locale. */
static LJ_AINLINE int oclj_n53_isspace(int c)
{
  return c == ' ' || (c >= '\t' && c <= '\r');
}
static LJ_AINLINE int oclj_n53_isdigit(int c)
{
  return c >= '0' && c <= '9';
}
static LJ_AINLINE int oclj_n53_isxdigit(int c)
{
  return oclj_n53_isdigit(c) || ((c | 0x20) >= 'a' && (c | 0x20) <= 'f');
}
static LJ_AINLINE int oclj_n53_hexavalue(int c)
{
  return oclj_n53_isdigit(c) ? c - '0' : (c | 0x20) - 'a' + 10;
}

#define OCLJ_N53_MAXBY10	((uint64_t)(INT64_MAX / 10))
#define OCLJ_N53_MAXLASTD	((int)(INT64_MAX % 10))

/* 5.3.6 lobject.c:299-328 (l_str2int) over [s, s+len): a decimal numeral
** that fits, or a hex numeral of any length, wrapping modulo 2^64.  5.3.6
** also demands that the whole string be the numeral (luaO_str2num == len +
** 1), so an embedded NUL fails here as there. */
static LJ_AINLINE int oclj_str2int(const char *s, size_t len, int64_t *res)
{
  const char *e = s + len;
  uint64_t a = 0;
  int empty = 1;
  int neg = 0;
  while (s < e && oclj_n53_isspace((unsigned char)*s)) s++;
  if (s < e && *s == '-') { s++; neg = 1; }
  else if (s < e && *s == '+') s++;
  if (e - s >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
    s += 2;
    for (; s < e && oclj_n53_isxdigit((unsigned char)*s); s++) {
      a = a * 16 + (uint64_t)oclj_n53_hexavalue((unsigned char)*s);
      empty = 0;
    }
  }
  else {
    for (; s < e && oclj_n53_isdigit((unsigned char)*s); s++) {
      int d = *s - '0';
      if (a >= OCLJ_N53_MAXBY10 &&
          (a > OCLJ_N53_MAXBY10 || d > OCLJ_N53_MAXLASTD + neg))
        return 0;  /* overflow: not an integer (5.3.6 then tries a float) */
      a = a * 10 + (uint64_t)d;
      empty = 0;
    }
  }
  while (s < e && oclj_n53_isspace((unsigned char)*s)) s++;
  if (empty || s != e) return 0;
  *res = oclj_u2s(neg ? 0u - a : a);
  return 1;
}

/* 5.3.6 lobject.c:274-293 (l_str2d), whose conversion is strtod.  We
** convert with LuaJIT's own scanner instead, exactly as lua_tonumberx does
** (lj_api.c:370 -> lj_strscan_num, lj_strscan.c:535-541), which is
** locale-free -- a JVM may set a locale whose strtod wants ',' -- and first
** refuse the two numerals it reads that strtod does not: "inf"/"nan" (5.3.6
** rejects them itself, by the first of ".xXnN") and binary "0b..."
** (lj_strscan.c:417-418).  Left different, refused here and read by strtod
** (round 2's D5/D7, the RESID-scan residual): LuaJIT's scanner refuses a
** numeral with 2^20 or more digits after the radix point, leading zeros
** counted and trailing zeros not, decimal or hex (lj_strscan.c:449-453), or
** an exponent of 2^20 or more (:468).  strtod reads the first as its value,
** and the second as inf or 0.  *res is written only on success. */
static LJ_AINLINE int oclj_str2d(const char *s, size_t len, double *res)
{
  const char *p, *e = s + len;
  TValue tv;
  for (p = s; p < e; p++) {
    if (*p == '\0') return 0;
    if (*p == '.' || *p == 'x' || *p == 'X') break;
    if (*p == 'n' || *p == 'N') return 0;
  }
  p = s;
  while (p < e && oclj_n53_isspace((unsigned char)*p)) p++;
  if (p < e && (*p == '-' || *p == '+')) p++;
  if (e - p >= 2 && p[0] == '0' && (p[1] == 'b' || p[1] == 'B')) return 0;
  if (lj_strscan_scan((const uint8_t *)s, (MSize)len, &tv,
                      STRSCAN_OPT_TONUM) == STRSCAN_ERROR)
    return 0;
  *res = numV(&tv);
  return 1;
}

#endif
