#!/bin/sh
# chain-r1.sh <tag> <natives-dir> -- round 1's harness arms on the frozen new natives, ONE JVM at a time
# (concurrent JVMs race on OC's native extraction).  <natives-dir> holds libdir/ and libdir-additive/.
# Predicted CHECKS: additive-on 80, dropin 67, additive-off 78, sieve 74, stock 51, disposeoff 80,
# bundleoff 80 (3 expected failures); d3 PASS everywhere.
set -u
T="$1"; N="$2"
O=/c/Users/astro/claude-tmp/oclj
RUNS=$O/runs
F="sh $O/full.sh"
LOG=$RUNS/chain-r1-$T.txt
[ -e "$LOG" ] && { echo "REFUSING: $LOG exists"; exit 99; }
[ -d "$N/libdir-additive" ] && [ -d "$N/libdir" ] || { echo "no natives under $N"; exit 98; }
echo "chain r1-$T started $(date -u +%H:%M:%S) natives=$N" > "$LOG"
one() {
  # one <name> <env|-> <native> <lib> <jit> <only>
  name=$1; envs=$2; nat=$3; lib=$4; jit=$5; only=$6
  echo "  $name env=[$envs] $nat $lib $jit $only" >> "$LOG"
  ( [ "$envs" != - ] && export $envs; $F "$RUNS/$name-$T" "$nat" "$lib" "$jit" "$only"; [ "$envs" != - ] && echo "$envs" > "$RUNS/$name-$T/env.txt" )
  echo "$name exit=$(cat "$RUNS/$name-$T/exit.txt" 2>/dev/null) $(grep -E 'CHECKS:' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null) d3=[$(grep -E 'MILESTONE d3-' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null | cut -c1-160 | head -1)]" >> "$LOG"
  grep -E 'MILESTONE .*: FAIL' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null | cut -c1-200 | sed 's/^/      /' >> "$LOG"
}
one r1-additive-on - additive "$N/libdir-additive" on UNSET
one r1-dropin - luajit "$N/libdir" on UNSET
one r1-additive-off - additive "$N/libdir-additive" off UNSET
one r1-sieve - additive "$N/libdir-additive" on sieve
one r1-stock - stock - on UNSET
one r1-disposeoff OCLJ_DISPOSE=off additive "$N/libdir-additive" on UNSET
one r1-bundleoff OCLJ_PERSIST_BUNDLE=off additive "$N/libdir-additive" on UNSET
echo "chain r1-$T finished $(date -u +%H:%M:%S)" >> "$LOG"
touch "$RUNS/chain-r1-$T.done"
