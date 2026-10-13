#!/bin/sh
# chain-seq.sh <tag> -- batch 3 of chain-fix.sh, one run at a time: three JVMs started in the same
# second race to extract OC's bundled natives into the shared working directory (chain a, batch 3:
# LuaStateFactory.isAvailable == false in all three at +12 s).
set -u
T="$1"
O=/c/Users/astro/claude-tmp/oclj
RUNS=$O/runs
NEWA=$O/new-6445f2e4/libdir-additive
SAB=$O/sabotage
LOG=$RUNS/chain-$T.txt
[ -e "$LOG" ] && { echo "REFUSING: $LOG exists"; exit 99; }
echo "chain $T started $(date -u +%H:%M:%S)" > "$LOG"
one() {
  name=$1; envs=$2
  echo "  $name env=[$envs]" >> "$LOG"
  ( export $envs; sh $O/full.sh "$RUNS/$name-$T" additive "$NEWA" on UNSET; echo "$envs" > "$RUNS/$name-$T/env.txt" )
  echo "$name exit=$(cat "$RUNS/$name-$T/exit.txt" 2>/dev/null) $(grep -E 'CHECKS:' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null)" >> "$LOG"
}
one fix-bundleoff OCLJ_PERSIST_BUNDLE=off
one sab-onecollect OCLJ_ARCH_SRC=$SAB/OcljArch-onecollect.scala
one sab-countafter OCLJ_JAVA_SRC=$SAB/countafter/LuaStateLuaJIT.java
echo "chain $T finished $(date -u +%H:%M:%S)" >> "$LOG"
touch "$RUNS/chain-$T.done"
