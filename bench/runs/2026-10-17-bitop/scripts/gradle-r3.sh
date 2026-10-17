#!/bin/sh
# gradle-r3.sh <outdir> -- gradle's verifyModAssets after round 3's builds, the real task each time:
#   bit32   a copy of the new additive DLL whose word '.pack1.bit64' is edited to '.pack1.bit32' (same
#           length; its serializer hash still right): must be REFUSED (exit 1) -- the word check alone;
#   control build/native/dist: must be accepted, the lifecycle line ending '(<hash>|ffi0.lua52....bit64)';
# then `./gradlew build` for the jar.  <outdir> must not exist.
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
OUT=$1
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT/bit32"
cd "$REPO" || exit 98
DLL=build/native/libdir-additive/libjnluajit52-windows-x86_64.dll
python -I -c "
import sys
s = open(sys.argv[1], 'rb').read()
n = s.count(b'.pack1.bit64')
assert n >= 1, n
open(sys.argv[2], 'wb').write(s.replace(b'.pack1.bit64', b'.pack1.bit32'))
print('edited', n, 'occurrence(s)')
" "$DLL" "$OUT/bit32/libjnluajit52-windows-x86_64.dll" > "$OUT/bit32-edit.txt" 2>&1
md5sum "$DLL" "$OUT/bit32/libjnluajit52-windows-x86_64.dll" build/native/dist/* >> "$OUT/bit32-edit.txt"
./gradlew verifyModAssets -Pocljit.nativesDir="$(cygpath -m "$OUT/bit32")" > "$OUT/bit32.log" 2>&1
echo "bit32 exit=$?" >> "$OUT/summary.txt"
./gradlew verifyModAssets > "$OUT/control.log" 2>&1
echo "control exit=$?" >> "$OUT/summary.txt"
./gradlew build > "$OUT/build.log" 2>&1
echo "build exit=$?" >> "$OUT/summary.txt"
ls -la build/libs >> "$OUT/summary.txt" 2>&1
md5sum build/libs/*.jar >> "$OUT/summary.txt" 2>&1
cat "$OUT/summary.txt" "$OUT/bit32-edit.txt"
grep -hE 'NOT built|native fingerprint|exports the four|packaging' "$OUT/bit32.log" "$OUT/control.log" | cut -c1-300
