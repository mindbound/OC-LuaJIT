#!/bin/sh
# run-race.sh -- build and run the cross-thread hookmask race test.
#
#   OCLJ_BUILD=<build dir used by build-native.sh> OCLJ_JNI=<jdk>/include \
#     sh run-race.sh [trials] [seconds_per_trial] [period_ms] [burn_us]
#
# Defaults (4 trials x 3 s, 0.1 ms period) reproduce the wedge in the OLD
# injection within a second or two.  The review's own measurements:
#   period 0.1 ms, no burn : 5/5 wedged in 16-547 ms, mean 3166 re-fires
#   period 50 ms, 2 us burn: wedged after 14.5 s = 234 re-fires
# The default here is the fast one, because the point is the A/B, not the rate.
#
# NOTE this test links lj52shim.o but does NOT force-include lj52shim.h: it
# needs the genuine lua_sethook to reproduce the old injection.
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
: "${OCLJ_SHIM:=$OCLJ_REPO/native}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${OCLJ_JNI:=}"
: "${CC:=gcc}"
LJ=$OCLJ_BUILD/luajit/src
fail() { echo "TEST FAIL: $*" >&2; exit 1; }

if [ -z "$OCLJ_JNI" ]; then
  for c in "${JAVA_HOME:-}/include" /c/Program\ Files/Java/*/include; do
    [ -f "$c/jni.h" ] && OCLJ_JNI="$c" && break
  done
fi
[ -n "$OCLJ_JNI" ] && [ -f "$OCLJ_JNI/jni.h" ] || fail "OCLJ_JNI must name a JDK include dir containing jni.h"
[ -f "$LJ/libluajit.a" ]            || fail "no $LJ/libluajit.a -- run build-native.sh first"
[ -f "$OCLJ_BUILD/obj/lj52shim.o" ] || fail "no $OCLJ_BUILD/obj/lj52shim.o -- run build-native.sh first"

"$CC" -O2 -Wall -Wextra -I"$LJ" -I"$OCLJ_SHIM" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" \
  "$SELF_DIR/race_test.c" "$OCLJ_BUILD/obj/lj52shim.o" "$OCLJ_BUILD/obj/eris_lj.o" \
  "$LJ/libluajit.a" -lm -o "$OCLJ_BUILD/race_test.exe" || fail "test did not build"

"$OCLJ_BUILD/race_test.exe" "$@"
