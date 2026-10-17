#!/bin/sh
# native/luajit/patch-strpack-register.sh -- the fifth change to LuaJIT, and
# the first that ADDS a library function: lib_string.c registers Lua 5.3.6's
# string.pack, string.packsize and string.unpack, whose code is
# native/luajit/oclj_strpack.c.  (The others: patch-penalty-scrub.sh,
# patch-fastfunc-errmem-top.sh, patch-strfmt-xint-noffi.sh,
# patch-features-include.sh.)
#
#     sh native/luajit/patch-strpack-register.sh <in lib_string.c> <out lib_string.c>
#
# <in> and <out> may name the SAME file.  build-native.sh re-copies the
# PRISTINE lib_string.c over the build copy before every run, for the reason
# patch-penalty-scrub.sh's header gives, and copies oclj_strpack.c next to
# it; this script only adds the registration block.
#
# WHY lib_string.c AND NOT THE SHIM.  luaopen_string is what jnlua's
# openlib(STRING) runs in both natives (OC-JNLua jnlua.c:440, :469), what
# luaL_openlibs runs in luajit.exe, in every native test and in the
# serializer's test host, and what puts the table under the string
# metatable's __index.  So one definition reaches all of them, the gates and
# the tests run the code path that ships, ("<i4"):pack(1) works as in 5.3,
# and eris_lj.c, which must never see the shim's header, can name the
# library in the blob fingerprint (oclj_features.h's OCLJ_LIB_STRPACK).
#
# WHY THE REGISTRATIONS ARE HERE AND THE CODE IS NOT.  buildvm
# (host/buildvm_lib.c) reads only the files of the Makefile's LJLIB_C list,
# line by line, turns every tag it finds into a library entry and a
# fast-function id, and never follows an #include.  So the three
# registrations must sit in lib_string.c itself, inside its string module and
# above the include of lj_libdef.h, which names lj_cf_string_pack and the
# other two; the code they call can live in a real, tracked C file.  Nothing
# this script inserts contains buildvm's tag prefix except the three tags,
# and nothing is conditional: buildvm treats an #if it does not know as
# true.  `make clean` deletes the generated headers, so build-native.sh's
# make regenerates lj_ffdef.h, lj_libdef.h, lj_recdef.h and jit/vmdef.lua
# from the patched file every build; the three functions get fast-function
# ids after string.format's, and every builtin after them moves up by 3
# (visible only as the number in tostring(f), e.g. "builtin#95").
#
# Anchored on the line `#include "lj_libdef.h"` (lib_string.c:672 at
# 1ee778a4), which must occur EXACTLY once; the block goes directly above it.
# Verified by content and by diff afterwards, including that the string
# module is still the module in effect at the block: buildvm switches module
# at every line that carries its LJLIB_MODULE_ tag (host/buildvm_lib.c:409),
# so a second module between `#define LJLIB_MODULE_string` and the block
# (the shape of LuaJIT's own lib_buffer.c) would register the three there.
# The patch path writes LF; an already-patched input is verified and copied
# as is.  This script contains no backslashes and no tabs.
set -u

[ $# -eq 2 ] || { echo "usage: patch-strpack-register.sh <in lib_string.c> <out lib_string.c>" >&2; exit 2; }
IN=$1
OUT=$2
[ -f "$IN" ] || { echo "patch-strpack-register.sh: no $IN" >&2; exit 2; }

ANCHOR='#include "lj_libdef.h"'
MARK='OC-LuaJIT (native/luajit/patch-strpack-register.sh)'
INC='#include "oclj_strpack.c"'
NBLOCK=22

fail() { echo "patch-strpack-register.sh: $*" >&2; exit 1; }
countx() { grep -c -F -x -- "$1" "$2" 2>/dev/null || true; }
countsub() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }
lineno() { grep -n -F -x -- "$1" "$2" | head -1 | cut -d: -f1; }
anchors() {
  awk -v a="$ANCHOR" '
    BEGIN { CR = sprintf("%c", 13) }
    { if (substr($0, length($0)) == CR) $0 = substr($0, 1, length($0) - 1) }
    $0 == a { n++ }
    END { print n + 0 }' "$1"
}

verify_patched() {
  f=$1
  [ "$(countsub "$MARK" "$f")" = 1 ] || fail "$f: marker present $(countsub "$MARK" "$f") times, expected 1"
  [ "$(countx "$INC" "$f")" = 1 ] || fail "$f: the oclj_strpack.c include occurs $(countx "$INC" "$f") times, expected 1"
  for t in 'LJLIB_CF(string_pack)' 'LJLIB_CF(string_packsize)' 'LJLIB_CF(string_unpack)'; do
    [ "$(countx "$t" "$f")" = 1 ] || fail "$f: '$t' occurs $(countx "$t" "$f") times, expected 1"
  done
  [ "$(anchors "$f")" = 1 ] || fail "$f: the lj_libdef.h include occurs $(anchors "$f") times, expected 1"
  [ "$(countx '#define LJLIB_MODULE_string' "$f")" = 1 ] || fail "$f: not lib_string.c (no '#define LJLIB_MODULE_string' line)"
  LM=$(lineno '#define LJLIB_MODULE_string' "$f")
  LI=$(lineno "$INC" "$f")
  LP=$(lineno 'LJLIB_CF(string_pack)' "$f")
  LS=$(lineno 'LJLIB_CF(string_packsize)' "$f")
  LU=$(lineno 'LJLIB_CF(string_unpack)' "$f")
  LA=$(lineno "$ANCHOR" "$f")
  # the string module's define, the code above its callers, all above lj_libdef.h
  if [ "$LM" -lt "$LI" ] && [ "$LI" -lt "$LP" ] && [ "$LP" -lt "$LS" ] && [ "$LS" -lt "$LU" ] && [ "$LU" -lt "$LA" ]; then :; else
    fail "$f: the block is out of order (module $LM, include $LI, pack $LP, packsize $LS, unpack $LU, lj_libdef.h $LA)"
  fi
  # ... and the string module still in effect at all three: the LAST line above
  # the last registration that carries buildvm's module tag must be that define
  LT=$(grep -n -F 'LJLIB_MODULE_' "$f" | awk -F: -v u="$LU" '$1 + 0 < u + 0 { l = $1 } END { print l + 0 }')
  [ "$LT" = "$LM" ] || fail "$f: the last module tag above the registrations is line $LT ($(sed -n "${LT}p" "$f" | tr -d '[:cntrl:]')), not the string module's '#define LJLIB_MODULE_string' at line $LM, so buildvm would register the three in that module -- has lib_string.c changed shape?"
}

# --- already patched?  verify, copy if asked, and say so ------------------
if grep -q -F -- "$MARK" "$IN"; then
  verify_patched "$IN"
  if [ "$IN" != "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")" || exit 1
    cp "$IN" "$OUT" || fail "cannot copy $IN to $OUT"
  fi
  echo "patch-strpack-register.sh: $(basename "$OUT")  already registers string.pack/packsize/unpack (verified) -- unchanged"
  exit 0
fi

# --- patch ------------------------------------------------------------------
[ "$(anchors "$IN")" = 1 ] || fail "refusing -- expected the line '$ANCHOR' exactly once in $IN, found $(anchors "$IN") (has lib_string.c changed shape?)"
[ "$(countsub 'LJLIB_CF(string_pack' "$IN")" = 0 ] || fail "refusing -- $IN already defines a string_pack* library function"

mkdir -p "$(dirname "$OUT")" || exit 1
TMP=$OUT.tmp.$$
trap 'rm -f "$TMP"' EXIT
awk -v a="$ANCHOR" -v m="$MARK" -v inc="$INC" '
  BEGIN { CR = sprintf("%c", 13) }
  { if (substr($0, length($0)) == CR) $0 = substr($0, 1, length($0) - 1) }
  $0 == a {
    print "/* " m ": string.pack,"
    print "** string.packsize and string.unpack of Lua 5.3.6.  The code is"
    print "** native/luajit/oclj_strpack.c, which build-native.sh copies next to this file. */"
    print inc
    print ""
    print "LJLIB_CF(string_pack)"
    print "{"
    print "  return oclj_strpack_pack(L);"
    print "}"
    print ""
    print "LJLIB_CF(string_packsize)"
    print "{"
    print "  return oclj_strpack_packsize(L);"
    print "}"
    print ""
    print "LJLIB_CF(string_unpack)"
    print "{"
    print "  return oclj_strpack_unpack(L);"
    print "}"
    print ""
    print "/* ------------------------------------------------------------------------ */"
    print ""
  }
  { print }
' "$IN" > "$TMP" || fail "awk failed writing $TMP"

# VERIFY, RATHER THAN TRUST THE AWK.
verify_patched "$TMP"
NL_IN=$(wc -l < "$IN" | tr -d ' ')
NL_OUT=$(wc -l < "$TMP" | tr -d ' ')
[ "$NL_OUT" = "$((NL_IN + NBLOCK))" ] || fail "line count: $NL_IN in + $NBLOCK != $NL_OUT out"
ADDED=$(diff --strip-trailing-cr "$IN" "$TMP" | grep -c '^>' || true)
REMOVED=$(diff --strip-trailing-cr "$IN" "$TMP" | grep -c '^<' || true)
if [ "$ADDED" != "$NBLOCK" ] || [ "$REMOVED" != 0 ]; then
  diff --strip-trailing-cr "$IN" "$TMP" | head -40 >&2
  fail "expected exactly $NBLOCK added and 0 removed lines, got $ADDED added / $REMOVED removed"
fi
# The only tags added are the three registrations.
NTAG_IN=$(grep -c 'LJLIB_' "$IN" || true)
NTAG_OUT=$(grep -c 'LJLIB_' "$TMP" || true)
[ "$NTAG_OUT" = "$((NTAG_IN + 3))" ] || fail "expected exactly 3 more lines carrying buildvm's tag prefix, got $NTAG_IN -> $NTAG_OUT"

mv -f "$TMP" "$OUT" || fail "cannot write $OUT"
trap - EXIT
echo "patch-strpack-register.sh: $(basename "$OUT")  registers string.pack/packsize/unpack ($NBLOCK lines above the lj_libdef.h include, of $NL_OUT); verified by content and diff"
