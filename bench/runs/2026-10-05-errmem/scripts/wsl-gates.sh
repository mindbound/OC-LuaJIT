#!/bin/bash
# wsl-gates.sh -- the native gates on the Linux build (inside WSL), against the objects the
# Linux build-native.sh just produced: mem, wd, penalty.  Output: one log per gate.
set -u
REPO=/mnt/c/Users/astro/Downloads/OC-LuaJIT
OUT=$1
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT"
export OCLJ_REPO=$REPO OCLJ_BUILD=$REPO/build/native CC=gcc
export OCLJ_JNI=/usr/lib/jvm/java-17-openjdk-amd64/include
uname -s -m > "$OUT/host.txt"
md5sum $REPO/build/native/luajit-linux-x86_64/src/libluajit.a $REPO/build/native/dist/*.so >> "$OUT/host.txt"
for g in mem wd penalty; do
  sh "$REPO/test/native/run-$g.sh" > "$OUT/$g.log" 2>&1
  echo "$g exit=$? $(grep -E 'checks=[0-9]+ failures=[0-9]+' "$OUT/$g.log" | tail -1)" >> "$OUT/summary.txt"
done
cat "$OUT/summary.txt"
