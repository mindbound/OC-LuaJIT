#!/bin/sh
# chain-ff.sh <tag> -- round-1 harness fail-first: the NEW OcljSmoke.scala (d3-sandbox-ffi-literal-refused)
# on HEAD's natives (new-6445f2e4 = 62970a0's DLLs), one JVM at a time.
# Predicted: additive JIT on -> d3 FAIL (ACCEPTED), CHECKS 80; stock -> d3 PASS, CHECKS 51.
set -u
T="$1"
O=/c/Users/astro/claude-tmp/oclj
RUNS=$O/runs
HEADA=$O/new-6445f2e4/libdir-additive
LOG=$RUNS/chain-r1ff-$T.txt
[ -e "$LOG" ] && { echo "REFUSING: $LOG exists"; exit 99; }
echo "chain ff-$T started $(date -u +%H:%M:%S)" > "$LOG"
one() {
  name=$1; nat=$2; lib=$3
  sh $O/full.sh "$RUNS/$name-$T" "$nat" "$lib" on UNSET
  echo "$name exit=$(cat "$RUNS/$name-$T/exit.txt" 2>/dev/null) $(grep -E 'CHECKS:' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null) d3=[$(grep -E 'd3-sandbox-ffi-literal-refused' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null | head -1)]" >> "$LOG"
}
one r1ff-head-additive additive "$HEADA"
one r1ff-head-stock stock -
echo "chain ff-$T finished $(date -u +%H:%M:%S)" >> "$LOG"
touch "$RUNS/chain-r1ff-$T.done"
