#!/bin/sh
# build-finst-native.sh -- the FINAL shim's instrumented copy (sc/finst/src: THE RESERVE'S SIZE +
# the OCLJREF/OCLJPRF/OCLJXP lines; logic unchanged, never shipped) built into OC natives, both
# variants, entirely in scratch (a scratch OCLJ_REPO with the instrumented shim; the pinned LuaJIT
# read-only; OCLJ_BUILD scratch).  Output: sc/finst-native/libdir-additive, libdir-dropin.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
REPO=/c/Users/astro/Downloads/OC-LuaJIT
SC=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc
D=$SC/finst-native
[ -e "$D" ] && { echo "REFUSING: $D exists"; exit 99; }
[ -f "$SC/finst/src/lj52shim.c" ] || { echo "no $SC/finst/src/lj52shim.c"; exit 98; }
mkdir -p "$D/repo/src/main/java" || exit 97
cp -r "$REPO/native" "$REPO/serializer" "$D/repo/"
cp -r "$REPO/src/main/java/li" "$D/repo/src/main/java/"
cp "$SC/finst/src/lj52shim.c" "$SC/finst/src/lj52shim.h" "$D/repo/native/"
md5sum "$D/repo/native/lj52shim.c" "$REPO/native/lj52shim.c" > "$D/shim.md5"
for v in additive dropin; do
  OCLJ_REPO="$D/repo" OCLJ_LUAJIT="$REPO/prototype/watchdog/luajit" OCLJ_BUILD="$D/build" OCLJ_VARIANT=$v sh "$D/repo/native/build-native.sh" > "$D/build-$v.log" 2>&1
  echo "$v exit $?"
done
mkdir -p "$D/libdir-additive" "$D/libdir-dropin"
cp "$D/build/libdir-additive/libjnluajit52-windows-x86_64.dll" "$D/libdir-additive/"
cp "$D/build/libdir/libjnlua52-windows-x86_64.dll" "$D/libdir-dropin/"
md5sum "$D"/libdir-*/*.dll "$D/build/obj-windows-x86_64/lj52shim.o" | tee "$D/natives.md5"
grep -c "OCLJREF" "$D/build/obj-windows-x86_64/lj52shim.o" || true
md5sum "$REPO/build/native/dist/"*.dll "$REPO/build/native/libdir/"*.dll
