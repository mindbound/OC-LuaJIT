#!/bin/sh
# chain-r3.sh <tag> <natives-dir> -- round 3's harness arms on the frozen new natives, ONE JVM at a time
# (concurrent JVMs race on OC's native extraction).  <natives-dir> holds libdir/ and libdir-additive/.
# Predicted CHECKS (round 2 + d5): additive-on 82, dropin 69, additive-off 80, sieve 76, stock 53,
# disposeoff 82, bundleoff 82 (its 3 expected failures); d3, d4 and d5 PASS everywhere (stock: d4 and d5
# want absent).
set -u
T="$1"; N="$2"
O=/c/Users/astro/claude-tmp/oclj
RUNS=$O/runs
F="sh $O/full.sh"
LOG=$RUNS/chain-r3-$T.txt
[ -e "$LOG" ] && { echo "REFUSING: $LOG exists"; exit 99; }
[ -d "$N/libdir-additive" ] && [ -d "$N/libdir" ] || { echo "no natives under $N"; exit 98; }
echo "chain r3-$T started $(date -u +%H:%M:%S) natives=$N" > "$LOG"
one() {
  # one <name> <env|-> <native> <lib> <jit> <only>
  name=$1; envs=$2; nat=$3; lib=$4; jit=$5; only=$6
  echo "  $name env=[$envs] $nat $lib $jit $only" >> "$LOG"
  ( [ "$envs" != - ] && export $envs; $F "$RUNS/$name-$T" "$nat" "$lib" "$jit" "$only"; [ "$envs" != - ] && echo "$envs" > "$RUNS/$name-$T/env.txt" )
  echo "$name exit=$(cat "$RUNS/$name-$T/exit.txt" 2>/dev/null) $(grep -E 'CHECKS:' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null)" >> "$LOG"
  grep -E 'MILESTONE d[345]-' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null | cut -c1-220 | sed 's/^/      /' >> "$LOG"
  grep -E 'MILESTONE .*: FAIL' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null | cut -c1-220 | sed 's/^/      FAIL /' >> "$LOG"
}
one r3-additive-on - additive "$N/libdir-additive" on UNSET
one r3-dropin - luajit "$N/libdir" on UNSET
one r3-additive-off - additive "$N/libdir-additive" off UNSET
one r3-sieve - additive "$N/libdir-additive" on sieve
one r3-stock - stock - on UNSET
one r3-disposeoff OCLJ_DISPOSE=off additive "$N/libdir-additive" on UNSET
one r3-bundleoff OCLJ_PERSIST_BUNDLE=off additive "$N/libdir-additive" on UNSET
echo "chain r3-$T finished $(date -u +%H:%M:%S)" >> "$LOG"
touch "$RUNS/chain-r3-$T.done"
