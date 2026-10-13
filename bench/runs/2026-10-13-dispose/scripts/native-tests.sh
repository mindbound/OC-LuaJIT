#!/bin/sh
# native-tests.sh <outdir> -- every native suite in place, then negative-control.sh; one log each.
set -u
OUT="$1"
[ -e "$OUT" ] && { echo "REFUSING: $OUT already exists"; exit 99; }
mkdir -p "$OUT" || exit 98
export PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include"
export OCLJ_JNLUA=C:/Users/astro/Downloads/OC-JNLua
cd /c/Users/astro/Downloads/OC-LuaJIT || exit 97
for t in vgc mem wd penalty race security; do
  date -u +%H:%M:%S > "$OUT/$t.start"
  sh test/native/run-$t.sh > "$OUT/$t.log" 2>&1
  echo "$?" > "$OUT/$t.rc"
done
date -u +%H:%M:%S > "$OUT/negctl.start"
sh test/native/negative-control.sh > "$OUT/negctl.log" 2>&1
echo "$?" > "$OUT/negctl.rc"
echo done > "$OUT/ALL.done"
