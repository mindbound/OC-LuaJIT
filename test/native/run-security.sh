#!/bin/sh
# =====================================================================
# run-security.sh -- build and run test/native/security_test.c against the
# CANONICAL shim.
#
#   OCLJ_BUILD=<build dir used by build-native.sh>  sh test/native/run-security.sh
#
# Requires build-native.sh to have run first, on THIS platform: this links
# the SAME lj52shim.o, eris_lj.o and libluajit.a the shipped DLL links, so the
# test cannot pass against objects the DLL does not contain.
#
# Exit status 0 = every check passed.
#            1 = a check FAILED (a gate is open, __le is wrong, or FFI is
#                compiled in).
#            2 = the test proved nothing (fixture or link problem).
# =====================================================================
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

fail() { echo "SECURITY TEST SETUP FAIL: $*" >&2; exit 2; }

# THE SAME PLATFORM FACTS build-native.sh DERIVES (run-wd.sh).  Until
# 2026-10-16 this script still named $OCLJ_BUILD/luajit/src and
# $OCLJ_BUILD/obj, which the per-platform build stopped writing on
# 2026-10-02: it exited 2 here against a complete build, and security_test.c
# ran only inside negative-control.sh or through a scratch mirror.
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

if [ -z "$OCLJ_JNI" ]; then
  for c in "${JAVA_HOME:-}/include" /usr/lib/jvm/*/include /c/Program\ Files/Java/*/include; do
    [ -f "$c/jni.h" ] && OCLJ_JNI="$c" && break
  done
fi
[ -n "$OCLJ_JNI" ] && [ -f "$OCLJ_JNI/jni.h" ] || fail "OCLJ_JNI must name a JDK include dir containing jni.h.
       lj52shim.h includes <jni.h> for the memory-accounting types, so every
       translation unit that force-includes it needs the JDK headers."
[ -f "$LJ/libluajit.a" ] || fail "no $LJ/libluajit.a -- run build-native.sh first"
[ -f "$OBJ/lj52shim.o" ]  || fail "no $OBJ/lj52shim.o -- run build-native.sh first (on THIS platform)"
[ -f "$OBJ/eris_lj.o" ]   || fail "no $OBJ/eris_lj.o -- run build-native.sh first (on THIS platform)"

# -include lj52shim.h, exactly as build-native.sh compiles jnlua.c, so the
# test reaches lua_load through the MACRO OC's own code sees rather than
# calling lua_loadx behind the gate's back.
"$CC" -O2 -Wall -Wextra -I"$LJ" -I"$OCLJ_SHIM" -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" \
  -include "$OCLJ_SHIM/lj52shim.h" \
  "$SELF_DIR/security_test.c" \
  "$OBJ/lj52shim.o" "$OBJ/eris_lj.o" \
  "$LJ/libluajit.a" -lm $TEST_EXTRA -o "$OCLJ_BUILD/security_test$EXE" \
  || fail "security_test.c did not build"

"$OCLJ_BUILD/security_test$EXE"
