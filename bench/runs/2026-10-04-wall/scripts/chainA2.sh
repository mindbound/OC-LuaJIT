#!/bin/sh
# chainA2.sh -- after acc-4 kept its fill reachable and CAP-MID counted only the running
# machine: the additive full suite on A's DLL, and one capacity run of each build so the
# sampler is seen on a run that goes down if one does.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/chainlib.sh
RUNS=$W/runsA2
LOG=$W/chainA2.log
AADD=$(cygpath -m $W/A/libdir-additive)
FULL=$(cygpath -m $W/full.sh)
[ -e "$RUNS" ] && { echo "REFUSING: $RUNS exists"; exit 99; }
mkdir -p "$RUNS"
echo "== $(date '+%H:%M:%S') chainA2 start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')" > $LOG
D=$RUNS/fullA2-additive-on
"$A" C03C03 default "$SH" "$FULL" "$(cygpath -m $D)" additive "$AADD" on UNSET > /dev/null 2>&1
echo "fullA2-additive-on exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
grep -E 'SMOKE\| (CHECKS|VERDICT|MILESTONE [^ ]+: (FAIL|SKIP)|MILESTONE acc-4)|^SMOKE (PASS|FAIL)' $D/run.log | cut -c1-400 | sed 's/^/    /' >> $LOG
for rep in 4 5; do
  run "one-record-r$rep-E-base" additive "$BASEADD" on off one 1.8 record
  run "one-record-r$rep-E-A" additive "$AADD" on off one 1.8 record
done
echo "== $(date '+%H:%M:%S') chainA2 done" >> $LOG
touch $W/chainA2.done
