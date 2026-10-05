#!/bin/sh
# mt.sh <tag> <shim.o> <srcdir with lj52shim.h> [mem_test.c] [extra env]
# Build a mem_test exactly as test/native/run-mem.sh does (its compile line,
# OCLJ_SHIMOBJ = <shim.o>, -include <srcdir>/lj52shim.h), the repo's
# test/native/mem_test.c unless a copy is named, and run it pinned to the
# E-cores.  Output mtout/<tag>.{out,err}.  Refuses to overwrite.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/design/lifetime
A=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/pcore/affrun.exe
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
OBJ=$REPO/build/native/obj-windows-x86_64
T=$1; SO=$2; S=$3; MT=${4:-$REPO/test/native/mem_test.c}
mkdir -p "$WD/mtout" "$WD/bin"
[ -e "$WD/mtout/$T.out" ] && { echo "mt.sh: $T exists"; exit 1; }
echo "mem_test: linking $SO ($(md5sum < "$SO" | cut -c1-32)) source $MT ($(md5sum < "$MT" | cut -c1-8))" > "$WD/mtout/$T.out"
gcc -O2 -Wall -Wextra -I"$LJ" -I"$S" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" \
  -include "$S/lj52shim.h" \
  "$MT" "$SO" "$OBJ/eris_lj.o" \
  "$LJ/libluajit.a" -lm -o "$WD/bin/mem_test_$T.exe" 2> "$WD/mtout/$T.build" || { echo "build failed"; cat "$WD/mtout/$T.build"; exit 1; }
if [ $# -ge 5 ]; then export "$5"; fi
"$A" 3FC3FC default "$WD/bin/mem_test_$T.exe" >> "$WD/mtout/$T.out" 2> "$WD/mtout/$T.err"
rc=$?
echo "rc=$rc" >> "$WD/mtout/$T.out"
printf '%s: rc=%s %s fails=%s: %s\n' "$T" "$rc" "$(grep -E '^checks=' "$WD/mtout/$T.out")" \
  "$(grep -c '^  FAIL' "$WD/mtout/$T.out")" "$(grep '^  FAIL' "$WD/mtout/$T.out" | awk '{print $2}' | tr '\n' ' ')"
