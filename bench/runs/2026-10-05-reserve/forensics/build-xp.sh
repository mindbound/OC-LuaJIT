#!/bin/sh
# build-xp.sh -- the experiment variants (scratch only): for each of
# XA-lit XA-rec XB-lit XB-rec, mkxp.py over the instrumented copy into
# src-xp-<v>/, compiled as build-shim.sh compiles (both variants,
# warning-clean), then the hermetic driver bin/lref_xp-<v>-additive.exe.
set -eu
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/forensics
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
SER=$REPO/serializer
for v in XA-lit XA-rec XB-lit XB-rec; do
  k=${v%%-*}; k=${k#X}; p=${v#*-}
  S=$WD/src-xp-$v
  mkdir -p "$S"
  cp "$WD/src/lj52shim.h" "$S/"
  python "$WD/tools/mkxp.py" "$WD/src/lj52shim.c" "$S/lj52shim.c" "$k" "$p"
  for var in additive dropin; do
    case $var in additive) D=-DLJ52_ADDITIVE ;; dropin) D= ;; esac
    gcc -c -O2 -Wall -Wextra $D -I"$LJ" -I"$S" -I"$SER" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" \
      "$S/lj52shim.c" -o "$WD/obj/xp-$v-$var.o" 2> "$WD/obj/xp-$v-$var.err"
    echo "xp-$v-$var: warnings=$(grep -c 'warning:' "$WD/obj/xp-$v-$var.err" || true) errors=$(grep -c 'error:' "$WD/obj/xp-$v-$var.err" || true) md5=$(md5sum < "$WD/obj/xp-$v-$var.o" | cut -c1-8)"
  done
done
sh "$WD/build-drv.sh" xp-XA-lit-additive xp-XA-rec-additive xp-XB-lit-additive xp-XB-rec-additive
