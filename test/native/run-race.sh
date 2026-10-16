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
# needs the genuine lua_sethook to reproduce the old injection.  It is
# Win32-only (race_test.c drives the injection from a CreateThread thread),
# so on any other host this script says so and exits 2.
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
: "${OCLJ_SHIM:=$OCLJ_REPO/native}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${OCLJ_JNI:=}"
: "${CC:=gcc}"
fail() { echo "TEST FAIL: $*" >&2; exit 1; }

# THE SAME PLATFORM FACTS build-native.sh DERIVES (run-wd.sh).  Until
# 2026-10-16 this script still named $OCLJ_BUILD/luajit/src and
# $OCLJ_BUILD/obj, which the per-platform build stopped writing on 2026-10-02.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) OCLJ_OS=windows ;;
  *) echo "run-race.sh: race_test.c is Win32-only (CreateThread); nothing to run on $(uname -s)" >&2; exit 2 ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  OCLJ_ARCH=x86_64  ;;
  aarch64|arm64) OCLJ_ARCH=aarch64 ;;
  *) fail "unsupported machine $(uname -m)" ;;
esac
PLATFORM="$OCLJ_OS-$OCLJ_ARCH"
LJ=$OCLJ_BUILD/luajit-$PLATFORM/src
OBJ=$OCLJ_BUILD/obj-$PLATFORM

if [ -z "$OCLJ_JNI" ]; then
  for c in "${JAVA_HOME:-}/include" /c/Program\ Files/Java/*/include; do
    [ -f "$c/jni.h" ] && OCLJ_JNI="$c" && break
  done
fi
[ -n "$OCLJ_JNI" ] && [ -f "$OCLJ_JNI/jni.h" ] || fail "OCLJ_JNI must name a JDK include dir containing jni.h"
[ -f "$LJ/libluajit.a" ] || fail "no $LJ/libluajit.a -- run build-native.sh first"
[ -f "$OBJ/lj52shim.o" ]  || fail "no $OBJ/lj52shim.o -- run build-native.sh first (on THIS platform)"
[ -f "$OBJ/eris_lj.o" ]   || fail "no $OBJ/eris_lj.o -- run build-native.sh first (on THIS platform)"

"$CC" -O2 -Wall -Wextra -I"$LJ" -I"$OCLJ_SHIM" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" \
  "$SELF_DIR/race_test.c" "$OBJ/lj52shim.o" "$OBJ/eris_lj.o" \
  "$LJ/libluajit.a" -lm -o "$OCLJ_BUILD/race_test.exe" || fail "test did not build"

"$OCLJ_BUILD/race_test.exe" "$@"
