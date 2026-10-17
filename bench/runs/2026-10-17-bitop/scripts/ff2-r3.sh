#!/bin/sh
# ff2-r3.sh -- the fixes' fail-firsts, BEFORE the rebuild: the fixed tests (working tree, after the user's
# "B plus a hint" and the review's fixes) against round 3's FIRST build in build/native (additive 8c272b0b,
# no hint, pristine lib_jit.c).  Expected: run-bitop.sh FAILS in the matrix (the 550/11/5 inexact lines
# want the hint) and BT3a-d; build-native.sh's new jit tools gate, its own text (run-gate.sh), FAILS
# (-bl raises at a FORI, -jdump aborts); the serializer suite fails exactly bitop.lua's message check.
# Output: bench/runs/2026-10-17-bitop/failfirst2/ (must not exist yet).
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
FF=$REPO/bench/runs/2026-10-17-bitop/failfirst2
[ -e "$FF" ] && { echo "REFUSING: $FF exists"; exit 99; }
mkdir -p "$FF"
cd "$REPO" || exit 98
export PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include"
B=$REPO/build/native
LJSRC=$B/luajit-windows-x86_64/src
md5sum $B/libdir-additive/*.dll $LJSRC/luajit.exe $LJSRC/*.o > "$FF/build-under-test.md5"
step() {
  # step <name> <command...>
  n=$1; shift
  date -u +%H:%M:%S > "$FF/$n.start"
  "$@" > "$FF/$n.log" 2>&1
  echo "$?" > "$FF/$n.exit"
  date -u +%H:%M:%S > "$FF/$n.end"
}
step run-bitop env OCLJ_BITOP_OUT=$B/bitop-ff2-r3 sh test/native/run-bitop.sh
step jit-gate sh bench/runs/2026-10-17-bitop/scripts/run-gate.sh jit "$LJSRC" "$FF/jit-gate-work"
step bitops-gate sh bench/runs/2026-10-17-bitop/scripts/run-gate.sh bitops "$LJSRC" "$FF/bitops-gate-work"
rm -f serializer/erislj_test.exe serializer/erislj_test
step serializer-test make -C serializer CC=gcc test
for f in "$FF"/*.exit; do echo "$(basename "$f") $(cat "$f")"; done
touch "$FF/ALL.done"
