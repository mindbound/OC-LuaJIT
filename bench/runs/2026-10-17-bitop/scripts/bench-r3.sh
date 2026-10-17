#!/bin/sh
# bench-r3.sh <outdir> -- the round-3 speed rows on the SHIPPED build, the design stage's benchmark
# (bench_bit.lua: a masked bit loop against an arithmetic loop of the same shape, and CRC32 bit-serial;
# bench_bit2.lua: RGB pack/unpack against arithmetic, and CRC32 by table), three runs, alternating the
# round-2 baseline (b0: the design stage's build of the pre-round-3 tree, 32-bit operators) with the shipped
# build, so the two share each run's machine state.  Unpinned, indicative: the ratio within a run is the
# reading, not the absolute ns.  Run on a quiet machine (no harness, campaign or game).
set -u
OUT="$1"
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT" || exit 98
S=/c/Users/astro/Downloads/OC-LuaJIT/bench/runs/2026-10-17-bitop/scripts
B0=/c/Users/astro/claude-tmp/oclj/r3/synth/b0/build/native/luajit-windows-x86_64/src
SH=/c/Users/astro/Downloads/OC-LuaJIT/build/native/luajit-windows-x86_64/src
md5sum "$B0/luajit.exe" "$SH/luajit.exe" "$S/bench_bit.lua" "$S/bench_bit2.lua" > "$OUT/inputs.md5"
tasklist 2>/dev/null | grep -iE 'java|minecraft' > "$OUT/jvms.txt"
for run in 1 2 3; do
  for b in b0 shipped; do
    case $b in b0) D=$B0 ;; shipped) D=$SH ;; esac
    a=$( cd "$D" && ./luajit.exe "$S/bench_bit.lua" 2>&1 | tr -d '\r' | tr '\n' ' ' )
    c=$( cd "$D" && ./luajit.exe "$S/bench_bit2.lua" 2>&1 | tr -d '\r' | tr '\n' ' ' )
    echo "$b run$run: $a|| $c" >> "$OUT/bench.txt"
  done
done
cat "$OUT/bench.txt"
