#!/bin/sh
# chain-r2ff.sh <tag> <natives-dir> -- round 2's harness FAIL-FIRST: the round-2 OcljSmoke.scala (milestone
# d4-sandbox-string-pack) on round 1's frozen natives, ONE JVM at a time.
# Predicted: additive-on CHECKS 81, FAILURES 1 (d4 FAIL: absent); stock CHECKS 52, FAILURES 0 (d4 PASS: absent).
set -u
T="$1"; N="$2"
O=/c/Users/astro/claude-tmp/oclj
RUNS=$O/runs
F="sh $O/full.sh"
LOG=$RUNS/chain-r2ff-$T.txt
[ -e "$LOG" ] && { echo "REFUSING: $LOG exists"; exit 99; }
[ -d "$N/libdir-additive" ] || { echo "no natives under $N"; exit 98; }
echo "chain r2ff-$T started $(date -u +%H:%M:%S) natives=$N" > "$LOG"
one() {
  # one <name> <env|-> <native> <lib> <jit> <only>
  name=$1; envs=$2; nat=$3; lib=$4; jit=$5; only=$6
  echo "  $name env=[$envs] $nat $lib $jit $only" >> "$LOG"
  ( [ "$envs" != - ] && export $envs; $F "$RUNS/$name-$T" "$nat" "$lib" "$jit" "$only" )
  echo "$name exit=$(cat "$RUNS/$name-$T/exit.txt" 2>/dev/null) $(grep -E 'CHECKS:' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null) d4=[$(grep -E 'MILESTONE d4-' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null | cut -c1-220 | head -1)]" >> "$LOG"
  grep -E 'MILESTONE .*: FAIL' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null | cut -c1-220 | sed 's/^/      /' >> "$LOG"
}
one r2ff-additive-on - additive "$N/libdir-additive" on UNSET
one r2ff-stock - stock - on UNSET
echo "chain r2ff-$T finished $(date -u +%H:%M:%S)" >> "$LOG"
touch "$RUNS/chain-r2ff-$T.done"
