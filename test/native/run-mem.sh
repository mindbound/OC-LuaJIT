#!/bin/sh
# run-mem.sh -- build and run the memory-accounting regression test.
#
#   OCLJ_BUILD=<build dir used by build-native.sh> OCLJ_JNI=<jdk>/include \
#     sh run-mem.sh
#
#   OCLJ_SHIMOBJ=<file>   link THIS lj52shim.o instead of the build's, for a
#                         fail-first A/B against a copy of the previous object
#                         (the same trick run-penalty.sh's OCLJ_LJLIB plays)
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
fail() { echo "TEST FAIL: $*" >&2; exit 1; }

# THE SAME PLATFORM FACTS build-native.sh DERIVES (see run-wd.sh for why):
# the objects live in per-platform directories, and this script's previous
# guess -- $OCLJ_BUILD/obj and $OCLJ_BUILD/luajit -- matched nothing after
# the per-platform move, so it reported "run build-native.sh first" against
# a build that had just completed.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) OCLJ_OS=windows ;;
  Linux)   OCLJ_OS=linux   ;;
  Darwin)  OCLJ_OS=darwin  ;;
  *) fail "unsupported host system $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  OCLJ_ARCH=x86_64  ;;
  aarch64|arm64) OCLJ_ARCH=aarch64 ;;
  *) fail "unsupported machine $(uname -m)" ;;
esac
PLATFORM="$OCLJ_OS-$OCLJ_ARCH"
case $OCLJ_OS in
  windows) JNI_MD=win32 ; EXE=.exe ; TEST_EXTRA= ;;
  darwin)  JNI_MD=darwin ; EXE= ; TEST_EXTRA= ;;
  *)       JNI_MD=$OCLJ_OS ; EXE= ; TEST_EXTRA=-pthread ;;
esac
LJ=$OCLJ_BUILD/luajit-$PLATFORM/src
OBJ=$OCLJ_BUILD/obj-$PLATFORM
: "${OCLJ_SHIMOBJ:=$OBJ/lj52shim.o}"

if [ -z "$OCLJ_JNI" ]; then
  for c in "${JAVA_HOME:-}/include" /usr/lib/jvm/*/include /c/Program\ Files/Java/*/include; do
    [ -f "$c/jni.h" ] && OCLJ_JNI="$c" && break
  done
fi
[ -n "$OCLJ_JNI" ] && [ -f "$OCLJ_JNI/jni.h" ] || fail "OCLJ_JNI must name a JDK include dir containing jni.h"
[ -f "$LJ/libluajit.a" ] || fail "no $LJ/libluajit.a -- run build-native.sh first"
[ -f "$OCLJ_SHIMOBJ" ]   || fail "no $OCLJ_SHIMOBJ -- run build-native.sh first (on THIS platform)"
[ -f "$OBJ/eris_lj.o" ]  || fail "no $OBJ/eris_lj.o -- run build-native.sh first (on THIS platform)"

echo "mem_test: linking $OCLJ_SHIMOBJ ($(md5sum < "$OCLJ_SHIMOBJ" | cut -c1-32), $(wc -c < "$OCLJ_SHIMOBJ" | tr -d ' ') bytes)"

# -include lj52shim.h, exactly as jnlua.c is compiled, so the test exercises
# the lua_setallocf / lua_setfield / lua_close MACROS and not merely the
# functions behind them.  mem_test.c supplies the jnlua-side names those
# macros reach for, which is also how their signatures stay pinned.
"$CC" -O2 -Wall -Wextra -I"$LJ" -I"$OCLJ_SHIM" -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" \
  -include "$OCLJ_SHIM/lj52shim.h" \
  "$SELF_DIR/mem_test.c" "$OCLJ_SHIMOBJ" "$OBJ/eris_lj.o" \
  "$LJ/libluajit.a" -lm $TEST_EXTRA -o "$OCLJ_BUILD/mem_test$EXE" || fail "test did not build"

"$OCLJ_BUILD/mem_test$EXE"
