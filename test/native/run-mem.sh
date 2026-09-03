#!/bin/sh
# run-mem.sh -- build and run the memory-accounting regression test.
#
#   OCLJ_BUILD=<build dir used by build-native.sh> OCLJ_JNI=<jdk>/include \
#     sh run-mem.sh
#
# Needs build-native.sh to have run first: it consumes that build's
# libluajit.a and lj52shim.o, so the test exercises exactly the objects the
# DLL links rather than a separately compiled copy.
#
# OCLJ_JNI is REQUIRED here where it is optional for run.sh, because
# lj52shim.h includes <jni.h> for the accounting types.
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
# OCLJ_SHIM is derived from the REPO root, not from $SELF_DIR/../native.
# These tests used to live in tests/ at the top level, where ../native was
# right; after the consolidation moved them to test/native/ the same string
# resolves back to test/native/ and the build fails with
#   fatal error: .../test/native/../native/lj52shim.h: No such file
# -- but only when OCLJ_SHIM is not already set in the environment, which is
# why it survived every run during development.
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

# -include lj52shim.h, exactly as jnlua.c is compiled, so the test exercises
# the lua_setallocf / lua_setfield / lua_close MACROS and not merely the
# functions behind them.  mem_test.c supplies the jnlua-side names those
# macros reach for, which is also how their signatures stay pinned.
"$CC" -O2 -Wall -Wextra -I"$LJ" -I"$OCLJ_SHIM" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" \
  -include "$OCLJ_SHIM/lj52shim.h" \
  "$SELF_DIR/mem_test.c" "$OCLJ_BUILD/obj/lj52shim.o" "$OCLJ_BUILD/obj/eris_lj.o" \
  "$LJ/libluajit.a" -lm -o "$OCLJ_BUILD/mem_test.exe" || fail "test did not build"

"$OCLJ_BUILD/mem_test.exe"
