#!/bin/sh
# chainT.sh -- THE WINDOW's cost near the wall, against stage C IN THE SAME CHAIN (the standard
# matrix compares against chain C's ratios to a different chain's stock, one run per 256/1024 KB
# cell, at millisecond times: too noisy to judge R12).  Pinned, serial, BATCH 100, interleaved
# by rep: S stock, C stage C, W THE WINDOW.
#  192 KB: record, array, string, closure x arms D (JIT on) and O (JIT off) x 5 reps
#  1024 KB: closure, array, record x arm D x 4 reps (the cells that read 2-4x stock in chainG)
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/chainlib2.sh
ROOT=$W2/runsT
[ -e "$ROOT" ] && { echo "REFUSING: $ROOT exists"; exit 99; }
mkdir -p "$ROOT"
RUNS=$ROOT/runs; LOG=$ROOT/timing.log; mkdir -p $RUNS
say() { echo "== $(date -u '+%H:%M:%S') $*" >> $ROOT/chain.log; }
say "chainT start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')"
for rep in 1 2 3 4 5; do
  for shape in record array string closure; do
    run2 one-$shape-r$rep-S-stock stock - on - one 1.8 $shape 100 24
    for arm in D O; do
      if [ $arm = D ]; then jit=on; early=-; else jit=off; early=off; fi
      run2 one-$shape-r$rep-$arm-C additive "$CADD" $jit $early one 1.8 $shape 100 24
      run2 one-$shape-r$rep-$arm-W additive "$WADD" $jit $early one 1.8 $shape 100 24
    done
  done
  say "192 KB rep $rep done"
done
for rep in 1 2 3 4; do
  for shape in closure array record; do
    run2 threehalf-$shape-r$rep-S-stock stock - on - threehalf 1.8 $shape 100 24
    run2 threehalf-$shape-r$rep-D-C additive "$CADD" on - threehalf 1.8 $shape 100 24
    run2 threehalf-$shape-r$rep-D-W additive "$WADD" on - threehalf 1.8 $shape 100 24
  done
  say "1024 KB rep $rep done"
done
say "chainT done: $(grep -c ' CLASS=' $LOG) runs"
