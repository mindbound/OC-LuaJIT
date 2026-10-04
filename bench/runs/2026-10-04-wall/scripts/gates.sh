#!/bin/sh
# gates.sh <outdir> -- the native gates on the CURRENT build (build/native), each logged.
# run.sh, run-security.sh and run-race.sh still name the pre-per-platform layout
# (luajit/src, obj/), so they run against a mirror of it built from the same objects.
set -u
OUT="$1"
W=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall
REPO=/c/Users/astro/Downloads/OC-LuaJIT
. $W/env.sh
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT"
cd "$REPO" || exit 97
B=$REPO/build/native
md5sum $B/obj-windows-x86_64/lj52shim.o $B/libdir/*.dll $B/libdir-additive/*.dll > "$OUT/objects.md5"
MIR=$OUT/mirror
mkdir -p $MIR/luajit $MIR/obj
cp -r $B/luajit-windows-x86_64/src $MIR/luajit/src
cp $B/obj-windows-x86_64/lj52shim.o $B/obj-windows-x86_64/eris_lj.o $MIR/obj/
summ() { printf '%-10s exit=%s  %s\n' "$1" "$2" "$(grep -E '^checks=|checks=[0-9]+ failures=|PASS:|FAIL:|^[A-Z ]*: (PASS|FAIL)|RESULT|passed|failed' "$OUT/$1.log" | tail -2 | tr '\n' ' ')" >> "$OUT/summary.txt"; }
sh test/native/run-mem.sh > "$OUT/mem.log" 2>&1; summ mem $?
sh test/native/run-wd.sh > "$OUT/wd.log" 2>&1; summ wd $?
OCLJ_BUILD=$MIR sh test/native/run.sh > "$OUT/shim.log" 2>&1; summ shim $?
OCLJ_BUILD=$MIR sh test/native/run-security.sh > "$OUT/security.log" 2>&1; summ security $?
OCLJ_BUILD=$MIR sh test/native/run-race.sh > "$OUT/race.log" 2>&1; summ race $?
sh test/native/run-penalty.sh > "$OUT/penalty.log" 2>&1; summ penalty $?
sh test/native/negative-control.sh > "$OUT/negctl.log" 2>&1; summ negctl $?
touch "$OUT/done"
