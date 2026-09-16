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
fail() { echo "TEST FAIL: $*" >&2; exit 1; }

# THE SAME PLATFORM FACTS build-native.sh DERIVES, because this test links the
# very objects that build produced -- and those now live in per-platform
# directories, so a stale guess would silently link the other platform's build
# or, worse, find nothing and report it as "run build-native.sh first".
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
  # -pthread, not -lpthread: it sets the preprocessor defines too, and on glibc
  # 2.34+ the library is folded into libc so -lpthread alone links nothing.
  *)       JNI_MD=$OCLJ_OS ; EXE= ; TEST_EXTRA=-pthread ;;
esac
LJ=$OCLJ_BUILD/luajit-$PLATFORM/src
OBJ=$OCLJ_BUILD/obj-$PLATFORM

if [ -z "$OCLJ_JNI" ]; then
  for c in "${JAVA_HOME:-}/include" /usr/lib/jvm/*/include /c/Program\ Files/Java/*/include; do
    [ -f "$c/jni.h" ] && OCLJ_JNI="$c" && break
  done
fi
[ -n "$OCLJ_JNI" ] && [ -f "$OCLJ_JNI/jni.h" ] || fail "OCLJ_JNI must name a JDK include dir containing jni.h"
[ -f "$LJ/libluajit.a" ]            || fail "no $LJ/libluajit.a -- run build-native.sh first"
[ -f "$OBJ/lj52shim.o" ] || fail "no $OBJ/lj52shim.o -- run build-native.sh first (on THIS platform)"

"$CC" -O2 -Wall -Wextra -I"$LJ" -I"$OCLJ_SHIM" -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" \
  -include "$OCLJ_SHIM/lj52shim.h" \
  "$SELF_DIR/wd_test.c" "$OBJ/lj52shim.o" "$OBJ/eris_lj.o" \
  "$LJ/libluajit.a" -lm $TEST_EXTRA -o "$OCLJ_BUILD/wd_test$EXE" || fail "test did not build"

"$OCLJ_BUILD/wd_test$EXE"
