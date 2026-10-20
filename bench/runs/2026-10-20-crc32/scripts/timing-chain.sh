#!/bin/sh
# timing-chain.sh <fresh outdir> [rounds] -- THE MAIN SESSION'S timing chain
# for the CRC32 follow-up's design pass (crc/combine, 2026-10-20).  Run it
# with nohup and a monitor on <outdir>/done, on a quiet machine (no game,
# harness, campaign, build or other session's tests); never edit this file
# while it runs (P17):
#
#   nohup sh /c/Users/astro/claude-tmp/oclj/crc/combine/timing-chain.sh <outdir> > <outdir>.log 2>&1 &
#
# WHAT IT TIMES.  Five VMs: four builds of the pinned tree that differ only
# in lj_opt_fold.o -- base (HEAD eb47daf's tree, objects equal to
# build/native's), folda (the table-index fold), rg2 (the range guard),
# both (the combined repo) -- and PUC 5.3.6 (bench/vendor, Windows).  Each
# round runs every VM once, in an order rotated by one each round, so each
# VM takes each position equally often over five rounds; each VM runs six
# benchmark processes, each taking the best of 3 inside:
#   bench_bit.lua 2e7      bit (masked bit loop), ref, crc (bit-serial CRC32)
#   bench_bit2.lua 1e7     rgb, ref, crc-table (roadmap row 209's number)
#   bench_crcx.lua 1e7     crcprobe (guide 8.8's probe loop, its result
#                          checked first), crcmb (crc and byte masked)
#   bench_idx.lua 1e7      crct, crctm, idx, phi, phi2 (the fold's one
#                          possible cost), cnt
#   bench_spec.lua 2e7     mix, lo50, and the B-legal loops whose exact
#                          results leave [-2^53, 2^53): hi60, flag63, sh40,
#                          top8, half (where the range guard fails)
#   ident.lua 1e7 time     identity operations on doubles at and past 2^53
#                          (x | 0 and four more, big and small: the range
#                          guard's needless failures, verify-rg2)
# N stays at 2e7 or below (guide 11.12); os.clock's 1 ms step is 0.1 ns a
# unit at 1e7 and 0.05 ns at 2e7, so differences of a step or two are noise.
# After the rounds, one -Omaxside=0 pass of bench_spec.lua at 2e6 for base,
# rg2 and both: what a failing range guard costs with no side trace (0.5 ns
# step; read only the large rows).
#
# READING IT: summary.txt (summarize.py): per metric, each VM's per-round
# ns and median, and each variant's ratio to base IN THE SAME ROUND
# (median and range).  Every result (r=) must be equal across the four
# builds in every round, or the summary says RESULTS DIFFER; PUC's results
# are compared too and listed.  Two kinds differ by design, where plain
# arithmetic passes 2^53 (our numbers are doubles, PUC's integers):
# bench_bit2's rgb and ref (i * 2654435761 reaches 2.7e16) and ident's big
# rows (% of a double past 2^53).
#
# It refuses an existing outdir (exit 99), refuses to start while a java or
# javaw process runs (Minecraft; exit 97) and stops between rounds if one
# appears (exit 96, partial results kept, STOPPED written).  rounds: default
# 9, at least 2.  Measured on the smoke run (2 rounds, 2026-10-20, 100 s
# in all): about 50 s a round, so the default takes about 8 minutes.
set -u
OUT=${1:?usage: timing-chain.sh <fresh outdir> [rounds]}
ROUNDS=${2:-9}
case "$ROUNDS" in ''|*[!0-9]*) echo "rounds must be a whole number"; exit 2 ;; esac
[ "$ROUNDS" -ge 2 ] || { echo "rounds must be at least 2"; exit 2; }
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists; results are never overwritten"; exit 99; }
mkdir -p "$OUT" || exit 98
unset LUA_INIT LUA_INIT_5_3 LUA_INIT_5_2 LUA_PATH LUA_CPATH
C=/c/Users/astro/claude-tmp/oclj/crc/combine
BN=$C/bench
PUC=/c/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/lua.exe
VMS="base folda rg2 both puc"
exe() {  # exe <vm>: its executable
  case $1 in
    puc) echo "$PUC" ;;
    *) echo "$C/b-$1/luajit-windows-x86_64/src/luajit.exe" ;;
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
powershell -NoProfile -Command "(Get-CimInstance Win32_Processor).LoadPercentage" 2>/dev/null | tr -d '\r' > "$OUT/cpuload-before.txt"
for v in base folda rg2 both; do
  [ -x "$(exe $v)" ] || { echo "no $(exe $v)"; exit 2; }
done
[ -x "$PUC" ] || { echo "no $PUC"; exit 2; }
{
  for v in base folda rg2 both; do
    md5sum "$(exe $v)" "$C/b-$v/luajit-windows-x86_64/src/lj_opt_fold.o"
  done
  md5sum "$PUC" "$BN"/*.lua "$0" "$C/scripts/summarize.py" "$C/scripts/pairratio.py"
} | tr -d '*' > "$OUT/inputs.md5"
date -u +%Y-%m-%dT%H:%M:%SZ > "$OUT/start"
one() {  # one <round> <position> <vm>
  E=$(exe "$3")
  for b in "bench_bit.lua 2e7" "bench_bit2.lua 1e7" "bench_crcx.lua 1e7" "bench_idx.lua 1e7" "bench_spec.lua 2e7" "ident.lua 1e7 time"; do
    set -- "$1" "$2" "$3" $b
    line=$( cd "$BN" && "$E" $4 $5 ${6:-} 2>&1 | tr -d '\r' | tr '\n' ' ' )
    echo "round=$1 pos=$2 vm=$3 bench=${4%.lua}: $line" >> "$OUT/raw.txt"
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
  # rotate: round 1 base folda rg2 both puc, round 2 folda rg2 both puc base, ...
  k=$(( (r - 1) % 5 ))
  set -- $VMS
  i=0
  while [ "$i" -lt "$k" ]; do f=$1; shift; set -- "$@" "$f"; i=$((i + 1)); done
  ORDER="$*"
  p=1
  for v in $ORDER; do
    one "$r" "$p" "$v"
    p=$((p + 1))
  done
  echo "round $r done $(date -u +%H:%M:%SZ) order: $ORDER" >> "$OUT/progress.txt"
  r=$((r + 1))
done
for v in base rg2 both; do
  E=$(exe $v)
  line=$( cd "$BN" && "$E" -Omaxside=0 bench_spec.lua 2e6 2>&1 | tr -d '\r' | tr '\n' ' ' )
  echo "round=ms0 pos=0 vm=$v bench=bench_spec: $line" >> "$OUT/raw.txt"
done
date -u +%Y-%m-%dT%H:%M:%SZ > "$OUT/end"
tasklist 2>/dev/null | tr -d '\r' > "$OUT/procs-after.txt"
powershell -NoProfile -Command "(Get-CimInstance Win32_Processor).LoadPercentage" 2>/dev/null | tr -d '\r' > "$OUT/cpuload-after.txt"
rm -f "$OUT/tasks.tmp"
python -I "$C/scripts/summarize.py" "$OUT/raw.txt" > "$OUT/summary.txt" 2>&1
echo "summarize exit $?" >> "$OUT/summary.txt"
# the decision's own ratio: what rg2 adds on top of the table-index fold
python -I "$C/scripts/pairratio.py" "$OUT/raw.txt" both folda >> "$OUT/summary.txt" 2>&1
cat "$OUT/summary.txt"
touch "$OUT/done"
