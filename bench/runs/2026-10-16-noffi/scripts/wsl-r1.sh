#!/bin/bash
# wsl-r1.sh <outdir> -- round 1 on Linux (inside WSL): build both variants, then every native suite that
# runs on Linux (shim, security, mem, vgc, wd, penalty; race is Win32-only and must say so with exit 2),
# then the serializer suite and its negctl.  Everything against the objects these builds just produced.
set -u
REPO=/mnt/c/Users/astro/Downloads/OC-LuaJIT
OUT=$1
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT"
export OCLJ_REPO=$REPO OCLJ_BUILD=$REPO/build/native CC=gcc
export OCLJ_JNLUA=/mnt/c/Users/astro/Downloads/OC-JNLua
export OCLJ_JNI=/usr/lib/jvm/java-17-openjdk-amd64/include
uname -s -m > "$OUT/host.txt"
for v in dropin additive; do
  OCLJ_VARIANT=$v sh "$REPO/native/build-native.sh" > "$OUT/build-$v.log" 2>&1
  echo "build-$v exit=$?" >> "$OUT/summary.txt"
  cp "$REPO/build/native/luajit_build.log" "$OUT/luajit_build-$v.log"
done
md5sum $REPO/build/native/luajit-linux-x86_64/src/libluajit.a $REPO/build/native/obj-linux-x86_64/*.o \
  $REPO/build/native/libdir/*.so $REPO/build/native/libdir-additive/*.so >> "$OUT/host.txt" 2>&1
for g in shim security race mem vgc wd penalty; do
  s=run-$g.sh; [ $g = shim ] && s=run.sh
  sh "$REPO/test/native/$s" > "$OUT/$g.log" 2>&1
  echo "$g exit=$? $(grep -E 'checks|failures' "$OUT/$g.log" | tail -1)" >> "$OUT/summary.txt"
done
make -C "$REPO/serializer" CC=gcc test > "$OUT/ser-test.log" 2>&1
echo "ser-test exit=$?" >> "$OUT/summary.txt"
make -C "$REPO/serializer" CC=gcc negctl > "$OUT/ser-negctl.log" 2>&1
echo "ser-negctl exit=$?" >> "$OUT/summary.txt"
cat "$OUT/summary.txt"
