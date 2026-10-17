#!/bin/sh
# ff-r3.sh -- round 3's fail-firsts, BEFORE any rebuild: the round-3 tests (working tree) against round 2's
# build in build/native (Windows; DLL md5 0f55e727 additive / f554beeb dropin, luajit.exe c33d49d1,
# = claude-tmp/oclj/new-r2-0f55e727).  Expected: run-bitop, run-bitjit and run-bitfuzz exit 1; security
# fails FF9, FF10 and FF12 (the 0x80 fixtures); the build's bitops gate, run on round 2's luajit.exe, differs
# from its wanted line; the serializer suite fails exactly bitop.lua (3 FAILs; fingerprint.lua passes 20/20,
# since the new eris_lj.c on round 2's headers says bit32 and the operators agree); gradle refuses round 2's
# natives.
# Output: bench/runs/2026-10-17-bitop/failfirst/ (must not exist yet).
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
FF=$REPO/bench/runs/2026-10-17-bitop/failfirst
[ -e "$FF" ] && { echo "REFUSING: $FF exists"; exit 99; }
mkdir -p "$FF"
cd "$REPO" || exit 98
export PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include"
B=$REPO/build/native
LJSRC=$B/luajit-windows-x86_64/src
md5sum $B/libdir/*.dll $B/libdir-additive/*.dll $LJSRC/luajit.exe $LJSRC/libluajit.a \
  $B/obj-windows-x86_64/*.o > "$FF/build-under-test.md5"
step() {
  # step <name> <command...>
  n=$1; shift
  date -u +%H:%M:%S > "$FF/$n.start"
  "$@" > "$FF/$n.log" 2>&1
  echo "$?" > "$FF/$n.exit"
  date -u +%H:%M:%S > "$FF/$n.end"
}
step run-bitop env OCLJ_BITOP_OUT=$B/bitop-ff-r3 sh test/native/run-bitop.sh
step run-bitjit env OCLJ_BITJIT_OUT=$B/bitjit-ff-r3 sh test/native/run-bitjit.sh
step run-bitfuzz env OCLJ_BITFUZZ_OUT=$B/bitfuzz-ff-r3 sh test/native/run-bitfuzz.sh
step security sh test/native/run-security.sh
# The build's bitops gate, its own text, on round 2's luajit.exe.
awk 'f && $0 == "EOF" { exit } f { print } index($0, "cat > ") && index($0, "bitops.lua") && index($0, "<<") { f = 1 }' \
  native/build-native.sh > "$FF/bitops-gate.lua"
awk -F"'" '/^BO_WANT=/ { print $2 }' native/build-native.sh > "$FF/bitops-gate.want"
( cd "$LJSRC" && ./luajit.exe "$FF/bitops-gate.lua" ) > "$FF/bitops-gate.out" 2>&1
echo "$?" > "$FF/bitops-gate.exit"
if [ "$(tr -d '\r' < "$FF/bitops-gate.out")" = "$(cat "$FF/bitops-gate.want")" ]; then
  echo SAME > "$FF/bitops-gate.verdict"; else echo DIFFERS > "$FF/bitops-gate.verdict"; fi
# The serializer suite, its host rebuilt from the working tree's eris_lj.c against round 2's archive.
rm -f serializer/erislj_test.exe serializer/erislj_test
step serializer-test make -C serializer CC=gcc test
# gradle's verifyModAssets, the real task, on round 2's frozen natives.
step gradle-r2 ./gradlew verifyModAssets -Pocljit.nativesDir=C:/Users/astro/claude-tmp/oclj/new-r2-0f55e727/libdir-additive
for f in "$FF"/*.exit; do echo "$(basename "$f") $(cat "$f")"; done
echo "bitops-gate $(cat "$FF/bitops-gate.verdict")"
touch "$FF/ALL.done"
