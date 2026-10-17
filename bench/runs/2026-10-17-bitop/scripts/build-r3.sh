#!/bin/sh
# build-r3.sh <outdir> -- round 3's Windows builds into build/native (dropin, then additive), each log kept,
# then the md5s of what was built.  <outdir> must not exist.  luajit.exe's md5 changes on every link (the PE
# time stamp), so the objects' md5s are the build's fingerprint.
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
OUT=$1
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT"
cd "$REPO" || exit 98
export PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export OCLJ_JNI="/c/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include"
export OCLJ_JNLUA=C:/Users/astro/Downloads/OC-JNLua
for v in dropin additive; do
  OCLJ_VARIANT=$v sh native/build-native.sh > "$OUT/build-$v.log" 2>&1
  echo "build-$v exit=$?" >> "$OUT/summary.txt"
  cp build/native/luajit_build.log "$OUT/luajit_build-$v.log"
done
B=build/native
L=$B/luajit-windows-x86_64/src
md5sum $B/libdir/*.dll $B/libdir-additive/*.dll $B/dist/*.dll $L/luajit.exe $L/libluajit.a \
  $L/*.o $L/host/*.o $B/obj-windows-x86_64/*.o > "$OUT/natives.md5"
md5sum native/luajit/*.sh native/luajit/*.h native/luajit/*.c native/*.c native/*.h native/build-native.sh \
  serializer/eris_lj.c serializer/eris_lj.h > "$OUT/sources.md5"
cat "$OUT/summary.txt"
grep -hE 'patch-bitop|pristine copies re-taken|round 3:|OCLJ_OPS_BIT64|BCDUMP_VERSION|oclj_bitop.h, oclj|bitwise-operator gate|lib_string.o recompiled|Wextra warnings|GG=|GG-LAYOUT|serializer hash|VM-features|ABI surface' "$OUT"/build-*.log
