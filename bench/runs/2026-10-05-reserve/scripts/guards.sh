#!/bin/sh
# guards.sh <fresh dir> -- the shim compiles as written (both variants, -Wall -Wextra, no warnings),
# and THE RESERVE'S SIZE's two #error guards FIRE: LJ52_GC_RSV at 1 KiB (under one window) and at
# 16 KiB (R + LEND past G_min/2 = 16 KiB).  Scratch copies only.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
D=$1
[ -e "$D" ] && { echo "REFUSING: $D exists"; exit 99; }
mkdir -p "$D"
res() { if [ "$1" = "$2" ]; then echo "OK   $3 (exit $1)"; else echo "BAD  $3 (exit $1, want $2)"; fi; }
cc1() { gcc -c -O2 -Wall -Wextra $2 -I"$LJ" -I"$(dirname "$1")" -I"$REPO/serializer" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" "$1" -o "$3" 2>"$3.err"; }
for v in additive dropin; do
  case $v in additive) DEF=-DOCLJ_ADDITIVE ;; dropin) DEF= ;; esac
  mkdir -p "$D/$v"; cp "$REPO/native/lj52shim.c" "$REPO/native/lj52shim.h" "$D/$v/"
  cc1 "$D/$v/lj52shim.c" "$DEF" "$D/$v/lj52shim.o"; res $? 0 "$v compiles"
  echo "     warnings: $(grep -c 'warning:' "$D/$v/lj52shim.o.err")"
done
for k in 1 16; do
  mkdir -p "$D/rsv$k"; cp "$REPO/native/lj52shim.c" "$REPO/native/lj52shim.h" "$D/rsv$k/"
  sed -i "s|^#define LJ52_GC_RSV    (8 \* 1024) |#define LJ52_GC_RSV    ($k * 1024) |" "$D/rsv$k/lj52shim.c"
  grep -q "LJ52_GC_RSV    ($k \* 1024)" "$D/rsv$k/lj52shim.c" || { echo "BAD  rsv$k: the sed did not apply"; continue; }
  cc1 "$D/rsv$k/lj52shim.c" "" "$D/rsv$k/lj52shim.o"; res $? 1 "rsv$k refused to compile"
  grep -o '#error.*' "$D/rsv$k/lj52shim.o.err" | head -1 | cut -c1-120
done
grep -n "SHIMDEF=" "$REPO/native/build-native.sh" | head -3
