#!/bin/sh
# timing-chain.sh <fresh outdir> [rounds] -- THE MAIN SESSION'S timing chain
# for FIX-NUMCONV's step 1 (roadmap row 211 (5); numconv/proto, 2026-10-21):
# what the rule gains on top of the shipped table-index fold.  Run it with
# nohup and a monitor on <outdir>/done, on a quiet machine (no game, harness,
# campaign, build or other session's tests); never edit this file, the
# benches or summarize.py while it runs (P17):
#
#   nohup sh /c/Users/astro/claude-tmp/oclj/numconv/timing-chain.sh <outdir> > <outdir>.log 2>&1 &
#
# WHAT IT TIMES.  Two VMs that differ only in lj_opt_fold.o:
#   base   build/native's luajit.exe, the shipped release (lj_opt_fold.o
#          1d018acc..., the table-index fold, commit 209aa95's natives)
#   proto  numconv/proto/b's luajit.exe, built pinned by build-native.sh
#          from a git-archive copy of 209aa95 with FIX-NUMCONV
#          (lj_opt_fold.o bbfab438...; its other 79 objects equal base's)
# Each round runs both, in an order that alternates (round 1 base proto,
# round 2 proto base, ...), so with an even round count each VM takes each
# position equally often.  Each VM runs six benchmark processes in
# numconv/bench, each row the best of 3 inside its process:
#   ident.lua 1e7 time      the rule's target: x | 0, x & -1, x ~ 0, x << 0,
#                           x >> 0 on doubles at and past 2^53 (big) and
#                           small (verify-rg2's probe, as archived by the
#                           CRC32 round)
#   bench_numconv.lua 2e7   realistic uses of an identity result: ref (no bit
#                           operator: a control), arith, key, bits, floor
#   bench_bit2.lua 1e7      controls: rgb, ref, crc-table (row 209's number)
#   bench_idx.lua 1e7       controls: the table-index fold's rows (ref, crct,
#                           crctm, idx, phi, phi2, cnt)
#   bench_spec.lua 2e7 mix  control: a three-xor chain on table values
#   bench_spec.lua 2e7 lo50 control: x ~ ((i & 7) << 50), every value < 2^53
# N stays at 2e7 or below (guide 11.12); os.clock's 1 ms step is 0.1 ns a
# unit at 1e7 and 0.05 ns at 2e7, so differences of a step or two are noise.
#
# READING IT: summary.txt (summarize.py beside this file): per metric,
# base's and proto's medians and proto's ratio to base IN THE SAME ROUND
# (median and range), marked target or control; every result (r=) must be
# equal between the two in every round, or the summary says RESULTS DIFFER
# and this script exits 1 (after writing done).
#
# REFUSALS, before anything else runs: an existing outdir (exit 99); an
# outdir inside the OC-LuaJIT repository, by identity (exit 95); a running
# java or javaw process (Minecraft; exit 97); a VM, a fold object or a bench
# whose md5 is not the one this chain was written for (exit 2).  Between
# rounds it stops if a java or javaw process appears (exit 96, partial
# results kept, STOPPED written).  rounds: default 20, even, at least 2.
# Measured on the smoke runs (2 rounds, 2026-10-21, numconv/proto/
# chain-smoke-1 and -2): 5-6 s a round, 16 s in all; the default 20 rounds
# take about 2 minutes.  Each refusal was seen to fire on a test copy
# (numconv/proto/scripts/ff-chain.sh, proto/ff-chain-1), and summarize.py's
# RESULTS DIFFER and MISSING exits on doctored raw files (proto/ff-summ-1).
set -u
OUT=${1:?usage: timing-chain.sh <fresh outdir> [rounds]}
ROUNDS=${2:-20}
case "$ROUNDS" in ''|*[!0-9]*) echo "rounds must be a whole number"; exit 2 ;; esac
[ "$ROUNDS" -ge 2 ] || { echo "rounds must be at least 2"; exit 2; }
[ $((ROUNDS % 2)) -eq 0 ] || { echo "rounds must be even (two VMs, alternating order)"; exit 2; }
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists; results are never overwritten"; exit 99; }
REPO=/c/Users/astro/Downloads/OC-LuaJIT
# The outdir's deepest existing ancestor, and every ancestor of that, must
# not be the repository (compared by identity: -ef, not by spelling).
a=$OUT
while [ ! -d "$a" ]; do
  case "$a" in */*) a=${a%/*}; [ -n "$a" ] || a=/ ;; *) a=. ;; esac
done
a=$(cd -P -- "$a" && pwd -P) || exit 98
while :; do
  if [ "$a" -ef "$REPO" ]; then echo "REFUSING: $OUT lies inside the repository $REPO"; exit 95; fi
  [ "$a" = / ] && break
  n=${a%/*}; [ -n "$n" ] || n=/
  [ "$n" = "$a" ] && break
  a=$n
done
mkdir -p "$OUT" || exit 98
unset LUA_INIT LUA_INIT_5_3 LUA_INIT_5_2 LUA_PATH LUA_CPATH
N=/c/Users/astro/claude-tmp/oclj/numconv
BN=$N/bench
BASE=$REPO/build/native/luajit-windows-x86_64/src
PROTO=$N/proto/b/luajit-windows-x86_64/src
VMS="base proto"
exe() {  # exe <vm>: its executable
  case $1 in
    base) echo "$BASE/luajit.exe" ;;
    proto) echo "$PROTO/luajit.exe" ;;
  esac
}
javacheck() {  # 0 when a java or javaw process runs; writes jvms.txt
  tasklist 2>/dev/null | tr -d '\r' > "$OUT/tasks.tmp"
  grep -iE '^(java|javaw)[.]exe' "$OUT/tasks.tmp" > "$OUT/jvms.txt"
  [ -s "$OUT/jvms.txt" ]
}
if javacheck; then
  echo "REFUSING: a Java process is running (Minecraft?); close it and start again:"
  cat "$OUT/jvms.txt"
  exit 97
fi
cp "$OUT/tasks.tmp" "$OUT/procs-before.txt"
# The instrument's fingerprint: the VMs' fold objects and the benches.
want() {  # want <file> <md5>
  [ -f "$1" ] || { echo "REFUSING: no $1"; exit 2; }
  got=$(md5sum < "$1" | cut -c1-32)
  [ "$got" = "$2" ] || { echo "REFUSING: $1 is $got, not $2 (this chain was written for another file)"; exit 2; }
}
want "$BASE/luajit.exe" 17f96322d746201a8c15d1edfcfe1f41
want "$BASE/lj_opt_fold.o" 1d018acc8b2ce53076dfbb2e63aa5cdd
want "$PROTO/lj_opt_fold.o" bbfab4387e3112cf0eb8a4e02e919dc0
[ -x "$PROTO/luajit.exe" ] || { echo "REFUSING: no $PROTO/luajit.exe"; exit 2; }
want "$BN/ident.lua" 5a0429552f6a808731b13a57bf10cce7
want "$BN/bench_numconv.lua" c15c325eb474b7458a753a637335ecae
want "$BN/bench_bit2.lua" 7bb3ab87a8e0c3d9fbe618875e680f56
want "$BN/bench_idx.lua" a9a6495030ee87d94a289d23b0e03351
want "$BN/bench_spec.lua" 35b9bec162f31b664fc84c1f6a8761da
[ -f "$N/summarize.py" ] || { echo "REFUSING: no $N/summarize.py"; exit 2; }
{
  md5sum "$BASE/luajit.exe" "$BASE/lj_opt_fold.o" "$PROTO/luajit.exe" "$PROTO/lj_opt_fold.o"
  md5sum "$BN"/*.lua "$0" "$N/summarize.py"
} | tr -d '*' > "$OUT/inputs.md5"
powershell -NoProfile -Command "(Get-CimInstance Win32_Processor).LoadPercentage" 2>/dev/null | tr -d '\r' > "$OUT/cpuload-before.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$OUT/start"
one() {  # one <round> <position> <vm>
  E=$(exe "$3")
  for b in "ident ident.lua 1e7 time" "bench_numconv bench_numconv.lua 2e7" "bench_bit2 bench_bit2.lua 1e7" \
           "bench_idx bench_idx.lua 1e7" "bench_spec-mix bench_spec.lua 2e7 mix" "bench_spec-lo50 bench_spec.lua 2e7 lo50"; do
    set -- "$1" "$2" "$3" $b
    line=$( cd "$BN" && "$E" $5 $6 ${7:-} 2>&1 | tr -d '\r' | tr '\n' ' ' )
    echo "round=$1 pos=$2 vm=$3 bench=$4: $line" >> "$OUT/raw.txt"
  done
}
r=1
while [ "$r" -le "$ROUNDS" ]; do
  if javacheck; then
    echo "STOPPED before round $r: a Java process started" > "$OUT/STOPPED"
    cat "$OUT/jvms.txt" >> "$OUT/STOPPED"
    cat "$OUT/STOPPED"
    exit 96
  fi
  t0=$(date +%s)
  if [ $((r % 2)) -eq 1 ]; then ORDER="base proto"; else ORDER="proto base"; fi
  p=1
  for v in $ORDER; do
    one "$r" "$p" "$v"
    p=$((p + 1))
  done
  echo "round $r done $(date -u +%H:%M:%SZ) in $(( $(date +%s) - t0 )) s, order: $ORDER" >> "$OUT/progress.txt"
  r=$((r + 1))
done
date -u +%Y-%m-%dT%H:%M:%SZ > "$OUT/end"
tasklist 2>/dev/null | tr -d '\r' > "$OUT/procs-after.txt"
powershell -NoProfile -Command "(Get-CimInstance Win32_Processor).LoadPercentage" 2>/dev/null | tr -d '\r' > "$OUT/cpuload-after.txt"
rm -f "$OUT/tasks.tmp"
python -I "$N/summarize.py" "$OUT/raw.txt" > "$OUT/summary.txt" 2>&1
st=$?
echo "summarize exit $st" >> "$OUT/summary.txt"
cat "$OUT/summary.txt"
touch "$OUT/done"
exit $st
