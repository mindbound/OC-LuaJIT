#!/bin/sh
# chainR.sh -- the second-chance path IN THE MACHINE with the instrumented shim (OCLJ_REFLOG=1: one
# "OCLJREF|" stderr line per refusal, into run.log), pinned, serial: the amplified gate's JIT-on
# record cells where W/V went down 3 in 30 (D x10, the dropin L x5), plus JIT-off record (O x5) and
# JIT-on string (D x5) as controls.  Same arguments as runsG/runsV's gate (192 KB, BATCH 10, JUNK 24).
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/chainlib2.sh
RADD=$(cygpath -m $W2/sc/refnative2/libdir-additive)
RDROP=$(cygpath -m $W2/sc/refnative2/libdir-dropin)
ROOT=$W2/runsR
[ -e "$ROOT" ] && { echo "REFUSING: $ROOT exists"; exit 99; }
mkdir -p "$ROOT"
say() { echo "== $(date -u '+%H:%M:%S') $*" >> $ROOT/chain.log; }
say "chainR start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')"
md5sum $W2/sc/refnative2/libdir-*/*.dll >> $ROOT/chain.log
export OCLJ_REFLOG=1
RUNS=$ROOT/gate; LOG=$ROOT/gate.log; mkdir -p $RUNS
for rep in 1 2 3 4 5 6 7 8 9 10; do
  run2 r-record-r$rep-R-D additive "$RADD" on - one 1.8 record 10 24
  [ $rep -le 5 ] && run2 r-record-r$rep-R-L luajit "$RDROP" on - one 1.8 record 10 24
  [ $rep -le 5 ] && run2 r-record-r$rep-R-O additive "$RADD" off off one 1.8 record 10 24
  [ $rep -le 5 ] && run2 r-string-r$rep-R-D additive "$RADD" on - one 1.8 string 10 24
done
say "gate done: $(grep -c ' CLASS=' $LOG) runs; classes: $(grep -oE 'CLASS=[A-Z-]+' $LOG | sort | uniq -c | tr '\n' ' ')"
for d in $RUNS/*/; do echo "$(basename $d) init=$(grep -c 'OCLJREFINIT|' $d/run.log) ref=$(grep -c 'OCLJREF|' $d/run.log)" >> $ROOT/reflines.txt; done
say "chainR done"
