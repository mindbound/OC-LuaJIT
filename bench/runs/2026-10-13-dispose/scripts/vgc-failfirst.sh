#!/bin/sh
# vgc-failfirst.sh <outdir> -- vgc_test against HEAD aa12418's shim object (fail-first: it must not link),
# then against this build's object (must pass). HEAD's lj52shim.{c,h} come from git; the object is compiled
# with build-native.sh step 2's own line (dropin flags, Windows).
set -u
OUT="$1"
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT/head-src" || exit 98
export PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include"
REPO=/c/Users/astro/Downloads/OC-LuaJIT
cd "$REPO" || exit 97
git show aa12418:native/lj52shim.c > "$OUT/head-src/lj52shim.c"
git show aa12418:native/lj52shim.h > "$OUT/head-src/lj52shim.h"
LJ=$REPO/build/native/luajit-windows-x86_64/src
gcc -c -O2 -Wall -Wextra -I"$LJ" -I"$OUT/head-src" -I"$REPO/serializer" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" \
  "$OUT/head-src/lj52shim.c" -o "$OUT/head-lj52shim.o" 2> "$OUT/head-compile.err"
echo "head object compile exit=$?" > "$OUT/summary.txt"
md5sum "$OUT/head-src/lj52shim.c" "$OUT/head-src/lj52shim.h" "$OUT/head-lj52shim.o" | sed "s|$OUT/||" >> "$OUT/summary.txt"
nm --defined-only "$OUT/head-lj52shim.o" | grep -c "lj52_vgc_" | sed 's/^/head object lj52_vgc_* defined: /' >> "$OUT/summary.txt"
OCLJ_SHIMOBJ="$OUT/head-lj52shim.o" sh test/native/run-vgc.sh > "$OUT/vgc-head.log" 2>&1
echo "vgc_test on HEAD's object exit=$?" >> "$OUT/summary.txt"
sh test/native/run-vgc.sh > "$OUT/vgc-new.log" 2>&1
echo "vgc_test on this build's object exit=$? $(grep -E 'checks=[0-9]+ failures=' "$OUT/vgc-new.log")" >> "$OUT/summary.txt"
cat "$OUT/summary.txt"
