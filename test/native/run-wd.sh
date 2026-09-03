#!/bin/sh
# run-wd.sh -- build and run the deadline-watchdog regression test.
#
#   OCLJ_BUILD=<build dir used by build-native.sh> OCLJ_JNI=<jdk>/include \
#     sh run-wd.sh
#
# Same shape as run-mem.sh: consumes build-native.sh's libluajit.a and
# lj52shim.o so the test exercises exactly the objects the DLL links.
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
  -include "$OCLJ_SHIM/lj52shim.h" \
  "$SELF_DIR/wd_test.c" "$OCLJ_BUILD/obj/lj52shim.o" "$OCLJ_BUILD/obj/eris_lj.o" \
  "$LJ/libluajit.a" -lm -o "$OCLJ_BUILD/wd_test.exe" || fail "test did not build"

"$OCLJ_BUILD/wd_test.exe"
