# mkword.py SRC_DIR OUT_DIR [sabotage]
# Writes a prototype eris_lj.c/.h with the VM-features word into OUT_DIR.
# Every replacement is anchored and must match exactly once.
import sys, os, shutil
src, out = sys.argv[1], sys.argv[2]
sabotage = len(sys.argv) > 3 and sys.argv[3] == "sabotage"
os.makedirs(out, exist_ok=True)

def sub1(s, old, new, what):
    n = s.count(old)
    if n != 1:
        sys.exit("anchor %s matched %d times" % (what, n))
    return s.replace(old, new)

c = open(os.path.join(src, "eris_lj.c"), newline="").read()
h = open(os.path.join(src, "eris_lj.h"), newline="").read()

FEAT = '''/* THE VM-FEATURES WORD.  Compile-time properties of the LuaJIT this file is
 * compiled against that change what a blob's bytes mean: ffi (a prototype may
 * carry int64/uint64/complex constants, lj_bcwrite.c:214-226), lua52 (the
 * permanent set and MM enum, lj_obj.h:548-556), gc64/fr2 (frame layout: every
 * stack slot number in a thread record is offset by LJ_FR2), dn (DUALNUM:
 * a canonical number restores as an int or a double), le/be and p64/p32.
 * It is derived HERE, from this file's own macros, so it is only true when
 * this file is compiled with the same feature flags as libluajit.a: the
 * build's layout gates must cover eris_lj.o, not only the shim. */
#if LJ_HASFFI
#define ELJ_W_FFI "ffi1"
#else
#define ELJ_W_FFI "ffi0"
#endif
#if LJ_52
#define ELJ_W_52 "lua52"
#else
#define ELJ_W_52 "lua51"
#endif
#if LJ_GC64
#define ELJ_W_GC "gc64"
#else
#define ELJ_W_GC "gc32"
#endif
#if LJ_FR2
#define ELJ_W_FR "fr2"
#else
#define ELJ_W_FR "fr1"
#endif
#if LJ_DUALNUM
#define ELJ_W_DN "dn1"
#else
#define ELJ_W_DN "dn0"
#endif
#if LJ_BE
#define ELJ_W_END "be"
#else
#define ELJ_W_END "le"
#endif
#if LJ_64
#define ELJ_W_PTR "p64"
#else
#define ELJ_W_PTR "p32"
#endif
#define ERIS_LJ_FEATURES ELJ_W_FFI "." ELJ_W_52 "." ELJ_W_GC "." ELJ_W_FR "." ELJ_W_DN "." ELJ_W_END "." ELJ_W_PTR
#define ERIS_LJ_FINGERPRINT ERIS_LJ_COMMIT "|" LUAJIT_VERSION "|" ERIS_LJ_SERHASH "|" ERIS_LJ_FEATURES
/* The header stores the length in one byte.  Refuse at BUILD time: a runtime
 * check fails every persist, which the architecture answers by dropping the
 * saved state. */
_Static_assert(sizeof(ERIS_LJ_FINGERPRINT) - 1 <= 255, "eris-lj fingerprint exceeds the header's u8 length");

/* sizeof(GG_State) as THIS object sees it; the host compares it with the
 * first allocation lua_newstate makes (lj_state.c), which is the library's. */
size_t eris_lj_ggsize(void) { return sizeof(GG_State); }
'''

c = sub1(c, '#define ERIS_LJ_FINGERPRINT ERIS_LJ_COMMIT "|" LUAJIT_VERSION "|" ERIS_LJ_SERHASH\n',
         FEAT, "fingerprint define")
c = sub1(c, '#include "lj_trace.h"\n', '#include "lj_trace.h"\n#include "lj_dispatch.h"\n', "dispatch include")

MISMATCH = '''/* Name the first '|'-separated field of the fingerprint that differs, with
 * both sides quoted (bytes outside printable ASCII shown as '?', each side
 * capped), so a server log says WHICH build property moved. */
static void fp_quote(luaL_Buffer *B, const unsigned char *p, size_t n)
{
  size_t i;
  luaL_addchar(B, '\\'');
  for (i = 0; i < n && i < 64; i++)
    luaL_addchar(B, (p[i] >= 0x20 && p[i] < 0x7f) ? (char)p[i] : '?');
  if (n > 64) luaL_addstring(B, "...");
  luaL_addchar(B, '\\'');
}

static int fp_report(lua_State *L, int field, const unsigned char *b,
                     size_t bn, const unsigned char *o, size_t on)
{
  static const char *const names[] = {
    "LuaJIT commit", "LuaJIT version", "serializer hash", "VM features"
  };
  luaL_Buffer B;
  luaL_buffinit(L, &B);
  luaL_addstring(&B, "eris-lj: build fingerprint mismatch: ");
  luaL_addstring(&B, field < 4 ? names[field] : "extra field");
  luaL_addstring(&B, " differs (blob ");
  fp_quote(&B, b, bn);
  luaL_addstring(&B, ", this build ");
  fp_quote(&B, o, on);
  luaL_addstring(&B, "); the blob is from a different natives build");
  luaL_pushresult(&B);
  return lua_error(L);
}

static int fp_mismatch(lua_State *L, const unsigned char *b, size_t blen)
{
  const unsigned char *o = (const unsigned char *)ERIS_LJ_FINGERPRINT;
  size_t olen = sizeof(ERIS_LJ_FINGERPRINT) - 1, bi = 0, oi = 0;
  int field = 0;
  for (;;) {
    size_t bs = bi, os = oi;
    int bend, oend;
    while (bi < blen && b[bi] != '|') bi++;
    while (oi < olen && o[oi] != '|') oi++;
    if (bi - bs != oi - os || memcmp(b + bs, o + os, bi - bs) != 0)
      return fp_report(L, field, b + bs, bi - bs, o + os, oi - os);
    bend = bi >= blen; oend = oi >= olen;
    if (bend || oend)   /* equal so far; one side has a field the other lacks */
      return fp_report(L, field + 1, b + bi + !bend, bend ? 0 : blen - bi - 1,
                       o + oi + !oend, oend ? 0 : olen - oi - 1);
    bi++; oi++; field++;
  }
}

static int l_unpersist(lua_State *L)
'''
c = sub1(c, 'static int l_unpersist(lua_State *L)\n', MISMATCH, "unpersist head")

OLDCHK = '''  hdr_fplen = r_byte(&I);
  if (hdr_fplen != (unsigned char)fplen ||
      I.pos + hdr_fplen > inlen ||
      memcmp(in + I.pos, ERIS_LJ_FINGERPRINT, hdr_fplen) != 0)
    return luaL_error(L, "eris-lj: build fingerprint mismatch "
                         "(blob is from a different natives build)");
'''
if sabotage:
    NEWCHK = '''  hdr_fplen = r_byte(&I);
  if (I.pos + hdr_fplen > inlen)
    return luaL_error(L, "eris-lj: data too short to be a valid blob");
'''
else:
    NEWCHK = '''  hdr_fplen = r_byte(&I);
  if (I.pos + hdr_fplen > inlen)
    return luaL_error(L, "eris-lj: data too short to be a valid blob");
  if (hdr_fplen != (unsigned char)fplen ||
      memcmp(in + I.pos, ERIS_LJ_FINGERPRINT, hdr_fplen) != 0)
    return fp_mismatch(L, in + I.pos, hdr_fplen);
'''
c = sub1(c, OLDCHK, NEWCHK, "fingerprint check")

c = sub1(c, '''  lua_pushliteral(L, ERIS_LJ_FINGERPRINT);
  lua_pushinteger(L, ERIS_LJ_FORMAT);
  return 3;
''', '''  lua_pushliteral(L, ERIS_LJ_FINGERPRINT);
  lua_pushinteger(L, ERIS_LJ_FORMAT);
  lua_pushliteral(L, ERIS_LJ_FEATURES);
  return 4;
''', "version")

h = sub1(h, "LUALIB_API int luaopen_eris_lj(lua_State *L);\n",
         "LUALIB_API int luaopen_eris_lj(lua_State *L);\n\n/* sizeof(GG_State) as eris_lj.o was compiled; see eris_lj.c. */\nsize_t eris_lj_ggsize(void);\n",
         "header decl")

open(os.path.join(out, "eris_lj.c"), "w", newline="").write(c)
open(os.path.join(out, "eris_lj.h"), "w", newline="").write(h)
print("wrote", out, "sabotage" if sabotage else "")
