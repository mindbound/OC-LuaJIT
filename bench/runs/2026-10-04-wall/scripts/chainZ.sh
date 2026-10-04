#!/bin/sh
# chainZ.sh -- the final tree: one race-1 run locked, and the default full suite on the additive
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/chainlib.sh
RUNS=$W/runsZ
LOG=$RUNS/chain.log
CADD=$(cygpath -m $W/C/libdir-additive)
[ -e "$RUNS" ] && { echo "REFUSING: $RUNS exists"; exit 99; }
mkdir -p "$RUNS"
echo "== $(date -u '+%H:%M:%S') chainZ start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')" > $LOG
D=$RUNS/race1-locked
"$A" C03C03 default "$SH" "$(cygpath -m $W/race.sh)" "$(cygpath -m $D)" additive "$CADD" on > /dev/null 2>&1
echo "race1-locked exit=$(cat $D/exit.txt 2>/dev/null) $(grep -m1 'MILESTONE race-1' $D/run.log)" >> $LOG
D=$RUNS/fullZ-additive-on
"$A" C03C03 default "$SH" "$(cygpath -m $W/full.sh)" "$(cygpath -m $D)" additive "$CADD" on UNSET > /dev/null 2>&1
echo "fullZ-additive-on exit=$(cat $D/exit.txt 2>/dev/null) $(grep -h 'CHECKS:' $D/run.log | head -1)" >> $LOG
echo "== $(date -u '+%H:%M:%S') chainZ done" >> $LOG
