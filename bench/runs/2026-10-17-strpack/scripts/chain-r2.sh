#!/bin/sh
# chain-r2.sh <tag> <natives-dir> -- round 2's harness arms on the frozen new natives, ONE JVM at a time
# (concurrent JVMs race on OC's native extraction).  <natives-dir> holds libdir/ and libdir-additive/.
# Predicted CHECKS (round 1 + d4): additive-on 81, dropin 68, additive-off 79, sieve 75, stock 52,
# disposeoff 81, bundleoff 81 (its 3 expected failures); d3 and d4 PASS everywhere (stock: d4 wants absent).
set -u
T="$1"; N="$2"
O=/c/Users/astro/claude-tmp/oclj
RUNS=$O/runs
F="sh $O/full.sh"
LOG=$RUNS/chain-r2-$T.txt
[ -e "$LOG" ] && { echo "REFUSING: $LOG exists"; exit 99; }
[ -d "$N/libdir-additive" ] && [ -d "$N/libdir" ] || { echo "no natives under $N"; exit 98; }
echo "chain r2-$T started $(date -u +%H:%M:%S) natives=$N" > "$LOG"
one() {
  # one <name> <env|-> <native> <lib> <jit> <only>
  name=$1; envs=$2; nat=$3; lib=$4; jit=$5; only=$6
  echo "  $name env=[$envs] $nat $lib $jit $only" >> "$LOG"
  ( [ "$envs" != - ] && export $envs; $F "$RUNS/$name-$T" "$nat" "$lib" "$jit" "$only"; [ "$envs" != - ] && echo "$envs" > "$RUNS/$name-$T/env.txt" )
  echo "$name exit=$(cat "$RUNS/$name-$T/exit.txt" 2>/dev/null) $(grep -E 'CHECKS:' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null)" >> "$LOG"
  grep -E 'MILESTONE d[34]-' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null | cut -c1-200 | sed 's/^/      /' >> "$LOG"
  grep -E 'MILESTONE .*: FAIL' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null | cut -c1-200 | sed 's/^/      FAIL /' >> "$LOG"
}
one r2-additive-on - additive "$N/libdir-additive" on UNSET
one r2-dropin - luajit "$N/libdir" on UNSET
one r2-additive-off - additive "$N/libdir-additive" off UNSET
one r2-sieve - additive "$N/libdir-additive" on sieve
one r2-stock - stock - on UNSET
one r2-disposeoff OCLJ_DISPOSE=off additive "$N/libdir-additive" on UNSET
one r2-bundleoff OCLJ_PERSIST_BUNDLE=off additive "$N/libdir-additive" on UNSET
echo "chain r2-$T finished $(date -u +%H:%M:%S)" >> "$LOG"
touch "$RUNS/chain-r2-$T.done"
