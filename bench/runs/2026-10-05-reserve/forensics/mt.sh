#!/bin/sh
# mt.sh <tag> <shim.o> [extra env assignment, e.g. OCLJ_REFLOG=1]
# Build mem_test.c exactly as test/native/run-mem.sh does (its compile line,
# with OCLJ_SHIMOBJ = <shim.o>), into this directory, and run it pinned to the
# E-cores.  Output: mtout/<tag>.out (stdout), mtout/<tag>.err (stderr).
# Refuses to overwrite.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/forensics
A=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/pcore/affrun.exe
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
OBJ=$REPO/build/native/obj-windows-x86_64
T=$1; SO=$2
mkdir -p "$WD/mtout" "$WD/bin"
[ -e "$WD/mtout/$T.out" ] && { echo "mt.sh: $T exists"; exit 1; }
echo "mem_test: linking $SO ($(md5sum < "$SO" | cut -c1-32))" > "$WD/mtout/$T.out"
gcc -O2 -Wall -Wextra -I"$LJ" -I"$WD/src" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" \
  -include "$WD/src/lj52shim.h" \
  "$REPO/test/native/mem_test.c" "$SO" "$OBJ/eris_lj.o" \
  "$LJ/libluajit.a" -lm -o "$WD/bin/mem_test_$T.exe" 2> "$WD/mtout/$T.build" || { echo "build failed"; cat "$WD/mtout/$T.build"; exit 1; }
if [ $# -ge 3 ]; then export "$3"; fi
"$A" 3FC3FC default "$WD/bin/mem_test_$T.exe" >> "$WD/mtout/$T.out" 2> "$WD/mtout/$T.err"
rc=$?
echo "rc=$rc" >> "$WD/mtout/$T.out"
printf '%s: rc=%s %s fails=%s refline=%s\n' "$T" "$rc" "$(grep -E '^checks=' "$WD/mtout/$T.out")" \
  "$(grep -c '^  FAIL' "$WD/mtout/$T.out")" "$(grep -c '^OCLJREF|' "$WD/mtout/$T.err")"
