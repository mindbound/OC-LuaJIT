#!/bin/sh
# run.sh -- build and run the shim regression tests.
#
#   OCLJ_BUILD=<build dir used by build-native.sh>  sh run.sh
#
# Needs build-native.sh to have run first: it consumes that build's
# libluajit.a and lj52shim.o so the test exercises exactly the objects the DLL
# links, not a separately compiled copy.
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_SHIM:=$SELF_DIR/../native}"
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${CC:=gcc}"
LJ=$OCLJ_BUILD/luajit/src
fail() { echo "TEST FAIL: $*" >&2; exit 1; }

[ -f "$LJ/libluajit.a" ]              || fail "no $LJ/libluajit.a -- run build-native.sh first"
[ -f "$OCLJ_BUILD/obj/lj52shim.o" ]   || fail "no $OCLJ_BUILD/obj/lj52shim.o -- run build-native.sh first"

# -include lj52shim.h, exactly as jnlua.c is compiled, so the test sees the
# MACROS (lua_load -> lua_loadx, lua_pushcfunction -> memo, luaL_newstate ->
# lj52_newstate) and not merely the functions.
"$CC" -O2 -Wall -Wextra -I"$LJ" -I"$OCLJ_SHIM" \
  -include "$OCLJ_SHIM/lj52shim.h" \
  "$SELF_DIR/shim_test.c" "$OCLJ_BUILD/obj/lj52shim.o" "$OCLJ_BUILD/obj/eris_lj.o" \
  "$LJ/libluajit.a" -lm -o "$OCLJ_BUILD/shim_test.exe" || fail "test did not build"

"$OCLJ_BUILD/shim_test.exe"
