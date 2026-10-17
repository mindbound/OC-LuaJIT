#!/bin/sh
# chain-r3ff.sh <tag> <natives-dir> -- round 3's harness FAIL-FIRST: the round-3 OcljSmoke.scala (milestone
# d5-sandbox-bitwise) on round 2's frozen natives, ONE JVM at a time.
# Predicted: additive-on CHECKS 82, FAILURES 1 (d5 FAIL, the 32-bit line, '<- LuaJIT's 32-bit BitOp
# results'); stock CHECKS 53, FAILURES 0 (d5 PASS: absent).
set -u
T="$1"; N="$2"
O=/c/Users/astro/claude-tmp/oclj
RUNS=$O/runs
F="sh $O/full.sh"
LOG=$RUNS/chain-r3ff-$T.txt
[ -e "$LOG" ] && { echo "REFUSING: $LOG exists"; exit 99; }
[ -d "$N/libdir-additive" ] || { echo "no natives under $N"; exit 98; }
echo "chain r3ff-$T started $(date -u +%H:%M:%S) natives=$N" > "$LOG"
one() {
  # one <name> <env|-> <native> <lib> <jit> <only>
  name=$1; envs=$2; nat=$3; lib=$4; jit=$5; only=$6
  echo "  $name env=[$envs] $nat $lib $jit $only" >> "$LOG"
  ( [ "$envs" != - ] && export $envs; $F "$RUNS/$name-$T" "$nat" "$lib" "$jit" "$only" )
  echo "$name exit=$(cat "$RUNS/$name-$T/exit.txt" 2>/dev/null) $(grep -E 'CHECKS:' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null) d5=[$(grep -E 'MILESTONE d5-' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null | cut -c1-260 | head -1)]" >> "$LOG"
  grep -E 'MILESTONE .*: FAIL' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null | cut -c1-260 | sed 's/^/      /' >> "$LOG"
}
one r3ff-additive-on - additive "$N/libdir-additive" on UNSET
one r3ff-stock - stock - on UNSET
echo "chain r3ff-$T finished $(date -u +%H:%M:%S)" >> "$LOG"
touch "$RUNS/chain-r3ff-$T.done"
