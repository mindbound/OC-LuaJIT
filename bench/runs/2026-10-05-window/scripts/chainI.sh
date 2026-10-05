#!/bin/sh
# chainI.sh -- the 256 KB idle question: stage C against E (THE WINDOW + the lj_err_mem fix) under
# the SAME (current) capacity probe, interleaved, JIT on, batch 100, the matrix's 256 KB cells.
# W and V read a median 4-5 arms per 400-tick idle window there; chain C (old probe) read 0.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/chainlib2.sh
EADD=$(cygpath -m $W2/E/libdir-additive)
ROOT=$W2/runsI
[ -e "$ROOT" ] && { echo "REFUSING: $ROOT exists"; exit 99; }
mkdir -p "$ROOT"
say() { echo "== $(date -u '+%H:%M:%S') $*" >> $ROOT/chain.log; }
say "chainI start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')"
md5sum $W/C/libdir-additive/*.dll $W2/E/libdir-additive/*.dll >> $ROOT/chain.log
RUNS=$ROOT/idle; LOG=$ROOT/idle.log; mkdir -p $RUNS
for rep in 1 2; do
  for shape in record array string closure; do
    run2 onehalf-$shape-r$rep-D-C additive "$CADD" on - onehalf 1.8 $shape 100 24
    run2 onehalf-$shape-r$rep-D-E additive "$EADD" on - onehalf 1.8 $shape 100 24
  done
done
say "idle done: $(grep -c ' CLASS=' $LOG) runs"
say "chainI done"
