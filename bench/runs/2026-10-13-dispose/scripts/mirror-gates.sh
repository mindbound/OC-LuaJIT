#!/bin/sh
# mirror-gates.sh <outdir> -- run.sh, run-security.sh and run-race.sh, which still name the
# pre-per-platform layout (luajit/src, obj/), against a mirror of it built from the current
# Windows objects (the 2026-10-05 gates.sh workaround).
set -u
OUT="$1"
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT" || exit 98
export PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include"
export OCLJ_JNLUA=C:/Users/astro/Downloads/OC-JNLua
REPO=/c/Users/astro/Downloads/OC-LuaJIT
cd "$REPO" || exit 97
B=$REPO/build/native
md5sum $B/obj-windows-x86_64/lj52shim.o $B/obj-windows-x86_64/eris_lj.o $B/libdir/*.dll $B/libdir-additive/*.dll > "$OUT/objects.md5"
MIR=$OUT/mirror
mkdir -p $MIR/luajit $MIR/obj
cp -r $B/luajit-windows-x86_64/src $MIR/luajit/src
cp $B/obj-windows-x86_64/lj52shim.o $B/obj-windows-x86_64/eris_lj.o $MIR/obj/
for t in shim security race; do
  case $t in shim) s=run.sh;; *) s=run-$t.sh;; esac
  OCLJ_BUILD=$MIR sh test/native/$s > "$OUT/$t.log" 2>&1
  echo "$t exit=$? $(grep -E 'checks=[0-9]+ failures=|PASS|FAIL' "$OUT/$t.log" | tail -1)" >> "$OUT/summary.txt"
done
cat "$OUT/summary.txt"
