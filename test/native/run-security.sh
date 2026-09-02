#!/bin/sh
# =====================================================================
# run-security.sh -- build and run tests/security_test.c against the
# CANONICAL shim.
#
#   OCLJ_BUILD=<build dir used by build-native.sh>  sh tests/run-security.sh
#
# Requires build-native.sh to have run first: this links the SAME
# lj52shim.o, eris_lj.o and libluajit.a the shipped DLL links, so the test
# cannot pass against objects the DLL does not contain.
#
# Exit status 0 = every check passed.
#            1 = a check FAILED (a gate is open, or __le is wrong).
#            2 = the test proved nothing (fixture or link problem).
# =====================================================================
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_SHIM:=$SELF_DIR/../native}"
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${CC:=gcc}"
LJ=$OCLJ_BUILD/luajit/src

fail() { echo "SECURITY TEST SETUP FAIL: $*" >&2; exit 2; }

[ -f "$LJ/libluajit.a" ]            || fail "no $LJ/libluajit.a -- run build-native.sh first"
[ -f "$OCLJ_BUILD/obj/lj52shim.o" ] || fail "no $OCLJ_BUILD/obj/lj52shim.o -- run build-native.sh first"
[ -f "$OCLJ_BUILD/obj/eris_lj.o" ]  || fail "no $OCLJ_BUILD/obj/eris_lj.o -- run build-native.sh first"

# -include lj52shim.h, exactly as build-native.sh compiles jnlua.c, so the
# test reaches lua_load through the MACRO OC's own code sees rather than
# calling lua_loadx behind the gate's back.
"$CC" -O2 -Wall -Wextra -I"$LJ" -I"$OCLJ_SHIM" \
  -include "$OCLJ_SHIM/lj52shim.h" \
  "$SELF_DIR/security_test.c" \
  "$OCLJ_BUILD/obj/lj52shim.o" "$OCLJ_BUILD/obj/eris_lj.o" \
  "$LJ/libluajit.a" -lm -o "$OCLJ_BUILD/security_test.exe" \
  || fail "security_test.c did not build"

"$OCLJ_BUILD/security_test.exe"
