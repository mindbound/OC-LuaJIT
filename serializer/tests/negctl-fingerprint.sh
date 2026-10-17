#!/bin/sh
# tests/negctl-fingerprint.sh -- PROVE that tests/fingerprint.lua and
# test_main.c's layout gate have teeth.  Run from serializer/ as
# `make negctl`, after native/build-native.sh has built this platform's
# LuaJIT copy.  Four sabotaged builds, each required to fail EXACTLY as
# expected:
#
#   nocompare  eris_lj.c with the fingerprint compare's verdict thrown away
#              (one line, anchored, asserted to occur exactly once).
#              fingerprint.lua must exit 11 with exactly these failures: the
#              nine token flips, the three-field fingerprint, and the
#              CRC-order case -- every refusal the test exists to see.
#   packword   the real eris_lj.c compiled against a copy of the build copy's
#              headers whose oclj_features.h lacks '#define OCLJ_LIB_STRPACK
#              1', linked with the real archive, whose string library has
#              string.pack: its word says pack0.  fingerprint.lua must exit 1
#              with exactly one failure, the pack token's agreement with the
#              string library.
#   bitword    the same with '#define OCLJ_OPS_BIT64 1' removed instead: the
#              word says bit32, and the real archive's operators compute
#              64-bit results.  The copy keeps the build copy's lj_bcdump.h
#              (BCDUMP_VERSION 0x80), which eris_lj.c's #error allows: it
#              stops only the macro WITHOUT the bump.  fingerprint.lua must
#              exit 1 with exactly one failure, the bit token's agreement with
#              the archive's operators.
#   layout     the real eris_lj.c compiled against a copy of the build
#              copy's headers whose oclj_features.h lacks
#              '#define LUAJIT_DISABLE_FFI 1'.  The binary must exit 3 with
#              "LAYOUT MISMATCH" before it runs a single test.
#
# The copies and logs go to a fresh directory under $OCLJ_BUILD; nothing in
# serializer/ is written.  Exit 0 iff all four arms fail exactly as expected;
# 2 if the control itself could not be set up.
set -u
: "${LJSRC:?run this through make negctl (LJSRC is the LuaJIT build copy's src)}"
: "${OCLJ_BUILD:?run this through make negctl}"
: "${CC:=gcc}"
LIBS=${NEGCTL_LIBS:--lm}
fail() { echo "NEGCTL-FINGERPRINT SETUP FAIL: $*" >&2; exit 2; }
[ -f "$LJSRC/libluajit.a" ] || fail "no $LJSRC/libluajit.a -- run native/build-native.sh first (on this platform)"
[ -f "$LJSRC/oclj_features.h" ] || fail "no $LJSRC/oclj_features.h -- $LJSRC is not build-native.sh's build copy"
[ -f eris_lj.c ] && [ -f test_main.c ] && [ -f tests/fingerprint.lua ] || fail "run from serializer/"
WORK=$OCLJ_BUILD/negctl-fingerprint/$(date +%Y%m%d-%H%M%S)-$$
mkdir -p "$WORK/nocompare" "$WORK/packword/inc" "$WORK/bitword/inc" "$WORK/layout/inc" || fail "cannot create $WORK"
echo "[negctl-fingerprint] work dir $WORK"

bad=0
verdict() {  # verdict <0 = as expected> <label>
  if [ "$1" = 0 ]; then echo "  RESULT: PASS  $2"; else echo "  RESULT: FAIL  $2"; bad=1; fi
}
build() {  # build <dir> <include dir> <eris_lj.c>
  sh8=$(cat "$3" eris_lj.h | sha1sum | cut -c1-8)
  "$CC" -std=c11 -O2 -I "$2" -I . -DERIS_LJ_COMMIT='"negctl"' '-DERIS_LJ_SERHASH="'"$sh8"'"' \
    "$3" test_main.c "$LJSRC/libluajit.a" $LIBS -o "$1/erislj_test" 2>"$1/build.err" \
    || { head -20 "$1/build.err"; fail "$1: did not build"; }
}

# --- nocompare ---------------------------------------------------------------
LINE='    return fp_mismatch(L, in + I.pos, hdr_fplen);'
d=$WORK/nocompare
awk -v l="$LINE" '
  $0 == l { print "    (void)0;  /* SABOTAGE (negctl-fingerprint.sh): the compare decides nothing */"; n++; next }
  { print }
  END { exit n == 1 ? 0 : 1 }' eris_lj.c > "$d/eris_lj.c" \
  || fail "nocompare: the line '$LINE' does not occur exactly once in eris_lj.c"
build "$d" "$LJSRC" "$d/eris_lj.c"
"$d/erislj_test" tests/fingerprint.lua > "$d/run.log" 2>&1
st=$?
ntok=$(grep -c '^  FAIL: token ' "$d/run.log")
nthree=$(grep -c '^  FAIL: a three-field fingerprint' "$d/run.log")
ncrc=$(grep -c '^  FAIL: a mismatched fingerprint is named even when the CRC is also wrong' "$d/run.log")
nall=$(grep -c '^  FAIL: ' "$d/run.log")
echo "[negctl-fingerprint] nocompare: exit $st (want 11); FAIL lines $nall (want 11): token $ntok (9), three-field $nthree (1), crc-order $ncrc (1)"
if [ "$st" = 11 ] && [ "$nall" = 11 ] && [ "$ntok" = 9 ] && [ "$nthree" = 1 ] && [ "$ncrc" = 1 ]; then
  verdict 0 "a serializer that ignores the fingerprint is caught by fingerprint.lua"
else
  sed 's/^/  | /' "$d/run.log"
  verdict 1 "a serializer that ignores the fingerprint is caught by fingerprint.lua"
fi

# --- packword ----------------------------------------------------------------
d=$WORK/packword
cp "$LJSRC"/*.h "$d/inc/" || fail "packword: cannot copy $LJSRC/*.h"
grep -qx '#define OCLJ_LIB_STRPACK 1' "$LJSRC/oclj_features.h" \
  || fail "packword: oclj_features.h does not say '#define OCLJ_LIB_STRPACK 1'; this arm toggles exactly that line -- revisit it"
grep -vx '#define OCLJ_LIB_STRPACK 1' "$LJSRC/oclj_features.h" > "$d/inc/oclj_features.h"
cmp -s "$LJSRC/oclj_features.h" "$d/inc/oclj_features.h" && fail "packword: the header toggle did not take"
build "$d" "$d/inc" eris_lj.c
"$d/erislj_test" tests/fingerprint.lua > "$d/run.log" 2>&1
st=$?
nagree=$(grep -c '^  FAIL: the pack token agrees with this archive' "$d/run.log")
nall=$(grep -c '^  FAIL: ' "$d/run.log")
echo "[negctl-fingerprint] packword: exit $st (want 1); FAIL lines $nall (want 1): pack-token agreement $nagree (1)"
if [ "$st" = 1 ] && [ "$nall" = 1 ] && [ "$nagree" = 1 ]; then
  verdict 0 "a serializer whose word misnames the string library is caught by fingerprint.lua"
else
  sed 's/^/  | /' "$d/run.log"
  verdict 1 "a serializer whose word misnames the string library is caught by fingerprint.lua"
fi

# --- bitword -----------------------------------------------------------------
d=$WORK/bitword
cp "$LJSRC"/*.h "$d/inc/" || fail "bitword: cannot copy $LJSRC/*.h"
grep -qx '#define OCLJ_OPS_BIT64 1' "$LJSRC/oclj_features.h" \
  || fail "bitword: oclj_features.h does not say '#define OCLJ_OPS_BIT64 1'; this arm toggles exactly that line -- revisit it"
grep -vx '#define OCLJ_OPS_BIT64 1' "$LJSRC/oclj_features.h" > "$d/inc/oclj_features.h"
cmp -s "$LJSRC/oclj_features.h" "$d/inc/oclj_features.h" && fail "bitword: the header toggle did not take"
build "$d" "$d/inc" eris_lj.c
"$d/erislj_test" tests/fingerprint.lua > "$d/run.log" 2>&1
st=$?
nagree=$(grep -c '^  FAIL: the bit token agrees with this archive' "$d/run.log")
nall=$(grep -c '^  FAIL: ' "$d/run.log")
nword=$(grep -c '^  VM features: .*[.]bit32' "$d/run.log")   # no '$': a Windows binary writes CRLF
echo "[negctl-fingerprint] bitword: exit $st (want 1); word ends bit32 $nword (1); FAIL lines $nall (want 1): bit-token agreement $nagree (1)"
if [ "$st" = 1 ] && [ "$nword" = 1 ] && [ "$nall" = 1 ] && [ "$nagree" = 1 ]; then
  verdict 0 "a serializer whose word misnames the bitwise operators is caught by fingerprint.lua"
else
  sed 's/^/  | /' "$d/run.log"
  verdict 1 "a serializer whose word misnames the bitwise operators is caught by fingerprint.lua"
fi

# --- layout ------------------------------------------------------------------
d=$WORK/layout
cp "$LJSRC"/*.h "$d/inc/" || fail "layout: cannot copy $LJSRC/*.h"
grep -qx '#define LUAJIT_DISABLE_FFI 1' "$LJSRC/oclj_features.h" \
  || fail "layout: oclj_features.h no longer says '#define LUAJIT_DISABLE_FFI 1'; this arm toggles exactly that line -- revisit it"
grep -vx '#define LUAJIT_DISABLE_FFI 1' "$LJSRC/oclj_features.h" > "$d/inc/oclj_features.h"
cmp -s "$LJSRC/oclj_features.h" "$d/inc/oclj_features.h" && fail "layout: the header toggle did not take"
build "$d" "$d/inc" eris_lj.c
"$d/erislj_test" tests/m1.lua > "$d/run.log" 2>&1
st=$?
echo "[negctl-fingerprint] layout: exit $st (want 3); $(grep -m1 'LAYOUT MISMATCH' "$d/run.log" || echo 'no LAYOUT MISMATCH line')"
if [ "$st" = 3 ] && grep -q '^LAYOUT MISMATCH' "$d/run.log" && ! grep -q 'eris-lj test harness' "$d/run.log"; then
  verdict 0 "eris_lj.c compiled for another LuaJIT layout is refused before any test runs"
else
  sed 's/^/  | /' "$d/run.log" | head -40
  verdict 1 "eris_lj.c compiled for another LuaJIT layout is refused before any test runs"
fi

[ "$bad" = 0 ] && echo "NEGCTL-FINGERPRINT: PASS (all four sabotages caught)" || echo "NEGCTL-FINGERPRINT: FAIL"
exit "$bad"
