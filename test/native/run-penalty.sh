#!/bin/sh
# run-penalty.sh -- build and run the penalty-cache regression test.
#
#   OCLJ_BUILD=<build dir used by build-native.sh> sh run-penalty.sh
#
#   OCLJ_PENALTY_RUNS=<N>   re-loads (default 40)
#   OCLJ_LJLIB=<file>       link THIS libluajit.a instead of the build's, for
#                           the fail-first A/B: the headers still come from the
#                           build copy (the patch changes no header)
#
# Same shape as run-wd.sh: consumes build-native.sh's libluajit.a so the test
# exercises exactly the archive the DLL links.  No shim and no JNI: the defect
# is LuaJIT's, and the host supplies the one thing the shim would -- a CRT
# realloc/free allocator (penalty_test.c).
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${OCLJ_PENALTY_RUNS:=40}"
: "${CC:=gcc}"
fail() { echo "TEST FAIL: $*" >&2; exit 1; }

# THE SAME PLATFORM FACTS build-native.sh DERIVES (see run-wd.sh for why).
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
  windows) EXE=.exe ; TEST_EXTRA= ;;
  darwin)  EXE= ; TEST_EXTRA= ;;
  *)       EXE= ; TEST_EXTRA=-ldl ;;
esac
LJ=$OCLJ_BUILD/luajit-$PLATFORM/src
: "${OCLJ_LJLIB:=$LJ/libluajit.a}"

[ -f "$LJ/lj_jit.h" ]  || fail "no $LJ/lj_jit.h -- run build-native.sh first"
[ -f "$OCLJ_LJLIB" ]   || fail "no $OCLJ_LJLIB -- run build-native.sh first"
[ -f "$OCLJ_REPO/bench/oc/mandelbrot.lua" ] || fail "no $OCLJ_REPO/bench/oc/mandelbrot.lua"

SCRIPT=$SELF_DIR/penalty_test.lua
BENCH=$OCLJ_REPO/bench/oc/mandelbrot.lua
if [ "$OCLJ_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
  SCRIPT=$(cygpath -m "$SCRIPT"); BENCH=$(cygpath -m "$BENCH")
fi

echo "penalty_test: linking $OCLJ_LJLIB ($(md5sum < "$OCLJ_LJLIB" | cut -c1-32), $(wc -c < "$OCLJ_LJLIB" | tr -d ' ') bytes)"
"$CC" -O2 -Wall -Wextra -I"$LJ" \
  "$SELF_DIR/penalty_test.c" "$OCLJ_LJLIB" -lm $TEST_EXTRA -o "$OCLJ_BUILD/penalty_test$EXE" \
  || fail "test did not build"

"$OCLJ_BUILD/penalty_test$EXE" "$SCRIPT" "$OCLJ_PENALTY_RUNS" "$BENCH"
