#!/bin/bash
# wsl-r2.sh <outdir> -- round 2 on Linux (inside the Ubuntu WSL distro): build both variants into the shared
# build/native (so dist/ gets the .so gradle packs), then every native suite that runs on Linux (race is
# Win32-only and must say so with exit 2), run-pack.sh with a Linux PUC 5.3.6 for part 2, the default fuzz
# run, the serializer suite and its negctl.  Everything against the objects these builds just produced.
set -u
REPO=/mnt/c/Users/astro/Downloads/OC-LuaJIT
OUT=$1
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT"
export OCLJ_REPO=$REPO OCLJ_BUILD=$REPO/build/native CC=gcc
export OCLJ_JNLUA=/mnt/c/Users/astro/Downloads/OC-JNLua
export OCLJ_JNI=/usr/lib/jvm/java-17-openjdk-amd64/include
export OCLJ_LUA53=/mnt/c/Users/astro/claude-tmp/oclj/puc536-linux/lua
{ uname -s -m; cat /etc/os-release | head -2; ldd --version | head -1; gcc --version | head -1; } > "$OUT/host.txt"
for v in dropin additive; do
  OCLJ_VARIANT=$v sh "$REPO/native/build-native.sh" > "$OUT/build-$v.log" 2>&1
  echo "build-$v exit=$?" >> "$OUT/summary.txt"
  cp "$REPO/build/native/luajit_build.log" "$OUT/luajit_build-$v.log"
done
md5sum $REPO/build/native/luajit-linux-x86_64/src/libluajit.a $REPO/build/native/obj-linux-x86_64/*.o \
  $REPO/build/native/libdir/*.so $REPO/build/native/libdir-additive/*.so $REPO/build/native/dist/*.so >> "$OUT/host.txt" 2>&1
for f in $REPO/build/native/libdir-additive/*.so $REPO/build/native/libdir/*.so; do
  echo "== $f" >> "$OUT/glibc.txt"
  objdump -T "$f" | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1 >> "$OUT/glibc.txt"
done
for g in shim security race mem vgc wd penalty; do
  s=run-$g.sh; [ $g = shim ] && s=run.sh
  sh "$REPO/test/native/$s" > "$OUT/$g.log" 2>&1
  echo "$g exit=$? $(grep -iE 'checks|failures|TESTS:' "$OUT/$g.log" | tail -1)" >> "$OUT/summary.txt"
done
sh "$REPO/test/native/run-pack.sh" > "$OUT/run-pack.log" 2>&1
echo "run-pack exit=$? $(grep -E 'RUN-PACK' "$OUT/run-pack.log" | tail -1)" >> "$OUT/summary.txt"
sh "$REPO/test/native/run-packfuzz.sh" > "$OUT/run-packfuzz.log" 2>&1
echo "run-packfuzz exit=$? $(grep -E '^seed|PACKFUZZ' "$OUT/run-packfuzz.log" | tail -2 | tr '\n' ' ')" >> "$OUT/summary.txt"
make -C "$REPO/serializer" CC=gcc test > "$OUT/ser-test.log" 2>&1
echo "ser-test exit=$? $(grep -E 'RESULT' "$OUT/ser-test.log" | tr '\n' ' ' | cut -c1-400)" >> "$OUT/summary.txt"
make -C "$REPO/serializer" CC=gcc negctl > "$OUT/ser-negctl.log" 2>&1
echo "ser-negctl exit=$? $(grep -E 'NEGCTL' "$OUT/ser-negctl.log" | tail -1)" >> "$OUT/summary.txt"
cat "$OUT/summary.txt"
touch "$OUT/ALL.done"
