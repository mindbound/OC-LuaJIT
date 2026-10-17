#!/bin/sh
# native/luajit/patch-features-include.sh -- the fourth change to LuaJIT,
# and the first to a header: lj_arch.h includes native/luajit/
# oclj_features.h, the one file that names OC-LuaJIT's LuaJIT feature set.
# (The others: patch-penalty-scrub.sh, patch-fastfunc-errmem-top.sh,
# patch-strfmt-xint-noffi.sh, patch-strpack-register.sh, and round 3's
# seven, patch-bitop-parse.sh, -vm.sh, -meta.sh, -record.sh, -fold.sh,
# -bcdump.sh and -jitlib.sh; -bcdump.sh changes the second header,
# lj_bcdump.h.)
#
#     sh native/luajit/patch-features-include.sh <in lj_arch.h> <out lj_arch.h>
#
# <in> and <out> may name the SAME file.  build-native.sh re-copies the
# PRISTINE lj_arch.h over the build copy before every run, for the reason
# patch-penalty-scrub.sh's header gives, and copies oclj_features.h next to
# it; this script only adds the include line.
#
# WHY A HEADER AND NOT -D FLAGS.  The feature macros change LuaJIT's
# structures (GG_State is 6384 bytes with FFI, 6376 without), so every
# translation unit that includes a LuaJIT internal header must see exactly
# the archive's set.  With -D flags that is a promise every compile line must
# keep -- the shim's, the serializer's, eight in test/native, and every
# archived script under bench/runs.  Every one of them already passes
# -I<build copy>/src, and lj_arch.h is reached by every internal header
# (lj_obj.h:14, lj_bc.h:10, lj_target.h:10), so an include here makes the
# archive and all of them read the same bytes with no compile line changed.
# Measured 2026-10-16: the 77 objects of a build that gets its flags this way
# are identical to the -D build's, and so are buildvm_arch.h and the
# generated headers.
#
# Anchored on `#include "lua.h"` (lj_arch.h:9), which must occur EXACTLY
# once; the include goes on the next line.  Verified by content and by diff
# afterwards.  CRLF is stripped (the pinned tree checks out CRLF on Windows);
# the output is LF.  This script contains no backslashes and no tabs.
set -u

[ $# -eq 2 ] || { echo "usage: patch-features-include.sh <in lj_arch.h> <out lj_arch.h>" >&2; exit 2; }
IN=$1
OUT=$2
[ -f "$IN" ] || { echo "patch-features-include.sh: no $IN" >&2; exit 2; }

ANCHOR='#include "lua.h"'
INC='#include "oclj_features.h"'
LINE='#include "oclj_features.h"  /* OC-LuaJIT (native/luajit/patch-features-include.sh) */'
MARK='OC-LuaJIT (native/luajit/patch-features-include.sh)'

fail() { echo "patch-features-include.sh: $*" >&2; exit 1; }
count() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }

# How many times the include line directly follows the anchor line, CR
# stripped; and how many times the anchor occurs at all.
pairs() {
  awk -v a="$ANCHOR" -v l="$LINE" '
    BEGIN { CR = sprintf("%c", 13) }
    { if (substr($0, length($0)) == CR) $0 = substr($0, 1, length($0) - 1) }
    prev == a && $0 == l { n++ }
    { prev = $0 }
    END { print n + 0 }' "$1"
}
anchors() {
  awk -v a="$ANCHOR" '
    BEGIN { CR = sprintf("%c", 13) }
    { if (substr($0, length($0)) == CR) $0 = substr($0, 1, length($0) - 1) }
    $0 == a { n++ }
    END { print n + 0 }' "$1"
}

verify_patched() {
  f=$1
  [ "$(count "$MARK" "$f")" = 1 ] || fail "$f: marker present $(count "$MARK" "$f") times, expected 1"
  [ "$(count "$INC" "$f")" = 1 ]  || fail "$f: the oclj_features.h include occurs $(count "$INC" "$f") times, expected 1"
  [ "$(anchors "$f")" = 1 ]       || fail "$f: the lua.h include occurs $(anchors "$f") times, expected 1"
  [ "$(pairs "$f")" = 1 ]         || fail "$f: the oclj_features.h include does not directly follow the lua.h include"
}

# --- already patched?  verify, copy if asked, and say so ------------------
if grep -q -F -- "$INC" "$IN"; then
  verify_patched "$IN"
  if [ "$IN" != "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")" || exit 1
    cp "$IN" "$OUT" || fail "cannot copy $IN to $OUT"
  fi
  echo "patch-features-include.sh: $(basename "$OUT")  already includes oclj_features.h (verified: once, right after lua.h) -- unchanged"
  exit 0
fi

# --- patch ------------------------------------------------------------------
[ "$(anchors "$IN")" = 1 ] || fail "refusing -- expected the line '$ANCHOR' exactly once in $IN, found $(anchors "$IN") (has lj_arch.h changed shape?)"

mkdir -p "$(dirname "$OUT")" || exit 1
TMP=$OUT.tmp.$$
trap 'rm -f "$TMP"' EXIT
awk -v a="$ANCHOR" -v l="$LINE" '
  BEGIN { CR = sprintf("%c", 13) }
  { if (substr($0, length($0)) == CR) $0 = substr($0, 1, length($0) - 1) }
  { print }
  $0 == a { print l }
' "$IN" > "$TMP" || fail "awk failed writing $TMP"

# VERIFY, RATHER THAN TRUST THE AWK.
verify_patched "$TMP"
NL_IN=$(wc -l < "$IN" | tr -d ' ')
NL_OUT=$(wc -l < "$TMP" | tr -d ' ')
[ "$NL_OUT" = "$((NL_IN + 1))" ] || fail "line count: $NL_IN in + 1 != $NL_OUT out"
ADDED=$(diff --strip-trailing-cr "$IN" "$TMP" | grep -c '^>' || true)
REMOVED=$(diff --strip-trailing-cr "$IN" "$TMP" | grep -c '^<' || true)
if [ "$ADDED" != 1 ] || [ "$REMOVED" != 0 ]; then
  diff --strip-trailing-cr "$IN" "$TMP" | head -20 >&2
  fail "expected exactly 1 added and 0 removed lines, got $ADDED added / $REMOVED removed"
fi

mv -f "$TMP" "$OUT" || fail "cannot write $OUT"
trap - EXIT
echo "patch-features-include.sh: $(basename "$OUT")  includes oclj_features.h right after lua.h (1 line inserted, of $NL_OUT); verified by content and diff"
