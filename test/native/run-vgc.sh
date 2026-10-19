#!/bin/sh
# run-vgc.sh -- build and run the Value-disposal regression test (vgc_test.c:
# THE VALUE FINALIZER in lj52shim.c, against a strict fake JNI, no JVM).
#
#   OCLJ_BUILD=<build dir used by build-native.sh> OCLJ_JNI=<jdk>/include \
#     sh run-vgc.sh
#
#   OCLJ_SHIMOBJ=<file>   link THIS lj52shim.o instead of the build's, for a
#                         fail-first A/B against a copy of another object (the
#                         trick run-mem.sh's OCLJ_SHIMOBJ plays).  An object
#                         from before Value disposal does not LINK: no
#                         lj52_vgc_install, no lj52_vgc_counters -- that is
#                         this suite's fail-first on HEAD aa12418
#   OCLJ_VGCTEST_CFLAGS   extra flags for vgc_test.c
#
# Same shape as run-mem.sh and run-wd.sh: consumes build-native.sh's
# libluajit.a, lj52shim.o and eris_lj.o, so the test exercises exactly the
# objects the DLL links rather than a separately compiled copy.  The cores it
# drives (lj52_vgc_install, lj52_vgc_counters) are in both variants' objects;
# only their JNI wrappers are additive-only.
#
# OCLJ_JNI is REQUIRED: lj52shim.h includes <jni.h>, and the test fills jni.h's
# own function tables.  Any JDK's headers do; the fake answers as a Java 8 JVM
# whatever headers it was built against.
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
# From the REPO root, not $SELF_DIR/../native: see run-mem.sh for the
# consolidation that made the relative form resolve to test/native/.
: "${OCLJ_SHIM:=$OCLJ_REPO/native}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${OCLJ_JNI:=}"
: "${CC:=gcc}"
fail() { echo "TEST FAIL: $*" >&2; exit 1; }

# THE SAME PLATFORM FACTS build-native.sh DERIVES (see run-wd.sh for why):
# the objects live in per-platform directories, and a stale guess would link
# the other platform's build or report "run build-native.sh first" against a
# build that had just completed.
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
  # One Linux tail for every test link.  -pthread, not -lpthread: it sets the
  # preprocessor defines too.  -ldl: luaL_openlibs pulls LuaJIT's lib_package,
  # which calls dlopen.  Before glibc 2.34 (AlmaLinux 8, the release build's
  # host) both are outside libc and a link that needs one fails without it.
  *)       JNI_MD=$OCLJ_OS ; EXE= ; TEST_EXTRA="-pthread -ldl" ;;
esac
LJ=$OCLJ_BUILD/luajit-$PLATFORM/src
OBJ=$OCLJ_BUILD/obj-$PLATFORM
: "${OCLJ_SHIMOBJ:=$OBJ/lj52shim.o}"
: "${OCLJ_VGCTEST_CFLAGS:=}"

if [ -z "$OCLJ_JNI" ]; then
  for c in "${JAVA_HOME:-}/include" /usr/lib/jvm/*/include /c/Program\ Files/Java/*/include; do
    [ -f "$c/jni.h" ] && OCLJ_JNI="$c" && break
  done
fi
[ -n "$OCLJ_JNI" ] && [ -f "$OCLJ_JNI/jni.h" ] || fail "OCLJ_JNI must name a JDK include dir containing jni.h"
[ -f "$LJ/libluajit.a" ] || fail "no $LJ/libluajit.a -- run build-native.sh first"
[ -f "$OCLJ_SHIMOBJ" ]   || fail "no $OCLJ_SHIMOBJ -- run build-native.sh first (on THIS platform)"
# A shim object from before 2026-10-16 carries no layout gate (lj52_layout_ok)
# and was compiled for the FFI-on GG_State; linked with an archive without
# FFI nothing would refuse it, and it would read jit_State 8 bytes off.
# Refuse that one pairing; a pre-gate object with its own build is fine.
if ! grep -a -q 'LJ52 LAYOUT: refusing the state' "$OCLJ_SHIMOBJ" \
   && ! nm "$LJ/libluajit.a" 2>/dev/null | grep -q ' T luaopen_ffi$'; then
  fail "$OCLJ_SHIMOBJ predates the layout gate (2026-10-16) and reads the FFI-on GG_State,
       but $LJ/libluajit.a has no FFI: point OCLJ_BUILD at the build it came from"
fi
[ -f "$OBJ/eris_lj.o" ]  || fail "no $OBJ/eris_lj.o -- run build-native.sh first (on THIS platform)"

echo "vgc_test: linking $OCLJ_SHIMOBJ ($(md5sum < "$OCLJ_SHIMOBJ" | cut -c1-32), $(wc -c < "$OCLJ_SHIMOBJ" | tr -d ' ') bytes)${OCLJ_VGCTEST_CFLAGS:+  cflags: $OCLJ_VGCTEST_CFLAGS}"

# -include lj52shim.h, exactly as jnlua.c is compiled, so the test runs through
# the lua_setallocf / lua_setfield / lua_close MACROS -- lua_close is how it
# reaches lj52_close and its closing flag -- and sees the header's own
# LJ52_JNLUA_OBJECT and LJ52_VGC_* rather than copies.
"$CC" -O2 -Wall -Wextra -I"$LJ" -I"$OCLJ_SHIM" -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" \
  -include "$OCLJ_SHIM/lj52shim.h" $OCLJ_VGCTEST_CFLAGS \
  "$SELF_DIR/vgc_test.c" "$OCLJ_SHIMOBJ" "$OBJ/eris_lj.o" \
  "$LJ/libluajit.a" -lm $TEST_EXTRA -o "$OCLJ_BUILD/vgc_test$EXE" || fail "test did not build"

"$OCLJ_BUILD/vgc_test$EXE"
