#!/bin/sh
# linux-cc.sh -- run inside WSL: compile the plain and the instrumented
# lj52shim.c as build-native.sh stage 2 does on Linux (-fPIC), both
# variants, against the repo's Linux LuaJIT build headers; count warnings.
WDL=/mnt/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/forensics
REPO=/mnt/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-linux-x86_64/src
SER=$REPO/serializer
JNI=/usr/lib/jvm/java-17-openjdk-amd64/include
mkdir -p $WDL/obj-linux
for kind in plain ref; do
  case $kind in plain) S=$WDL/src-plain ;; ref) S=$WDL/src ;; esac
  for v in additive dropin; do
    case $v in additive) D=-DLJ52_ADDITIVE ;; dropin) D= ;; esac
    gcc -c -O2 -fPIC -Wall -Wextra $D -I"$LJ" -I"$S" -I"$SER" -I"$JNI" -I"$JNI/linux" \
      "$S/lj52shim.c" -o "$WDL/obj-linux/$kind-$v.o" 2> "$WDL/obj-linux/$kind-$v.err"
    echo "linux $kind-$v: rc=$? warnings=$(grep -c 'warning:' "$WDL/obj-linux/$kind-$v.err") errors=$(grep -c 'error:' "$WDL/obj-linux/$kind-$v.err")"
  done
done
