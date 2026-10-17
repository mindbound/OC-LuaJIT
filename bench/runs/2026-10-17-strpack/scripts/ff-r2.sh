#!/bin/sh
# ff-r2.sh -- round 2's fail-firsts, BEFORE any rebuild: the round-2 tests (working tree) against round 1's
# build in build/native (Windows; DLL md5 aa0f3fa9 additive / a0bbb5fa dropin, = claude-tmp/oclj/new-r1-aa0f3fa9).
# Output: bench/runs/2026-10-17-strpack/failfirst/ (must not exist yet).
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
FF=$REPO/bench/runs/2026-10-17-strpack/failfirst
[ -e "$FF" ] && { echo "REFUSING: $FF exists"; exit 99; }
mkdir -p "$FF"
cd "$REPO" || exit 98
export PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export OCLJ_JNI="/c/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include"
B=$REPO/build/native
md5sum $B/libdir/*.dll $B/libdir-additive/*.dll $B/luajit-windows-x86_64/src/luajit.exe \
  $B/luajit-windows-x86_64/src/libluajit.a $B/obj-windows-x86_64/*.o > "$FF/build-under-test.md5"
grep -c 'string_pack' $B/luajit-windows-x86_64/src/lj_ffdef.h > "$FF/ffdef-string_pack.count" 2>&1
OCLJ_PACK_OUT=$B/pack-ff-r2 sh test/native/run-pack.sh > "$FF/run-pack.log" 2>&1; echo $? > "$FF/run-pack.exit"
OCLJ_PACKFUZZ_OUT=$B/packfuzz-ff-r2 sh test/native/run-packfuzz.sh > "$FF/run-packfuzz.log" 2>&1; echo $? > "$FF/run-packfuzz.exit"
cp /c/Users/astro/claude-tmp/oclj/r2/fix/verify-plumbing/add/build/native/strpack.lua "$FF/strpack-gate.lua"
$B/luajit-windows-x86_64/src/luajit.exe "$FF/strpack-gate.lua" > "$FF/strpack-gate.out" 2>&1; echo $? >> "$FF/strpack-gate.out"
make -C serializer CC=gcc test > "$FF/serializer-test.log" 2>&1; echo $? > "$FF/serializer-test.exit"
for f in "$FF"/*.exit; do echo "$(basename $f) $(cat $f)"; done
cat "$FF/strpack-gate.out"
