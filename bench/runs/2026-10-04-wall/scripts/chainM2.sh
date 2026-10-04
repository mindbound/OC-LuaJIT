#!/bin/sh
# chainM2.sh <tag> <libdir-dir> -- the dropin and additive full suites, to read mem-2's cadence trace.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/chainlib.sh
TAG=$1; LD=$2
RUNS=$W/runs-$TAG
LOG=$W/chain-$TAG.log
FULL=$(cygpath -m $W/full.sh)
[ -e "$RUNS" ] && { echo "REFUSING: $RUNS exists"; exit 99; }
mkdir -p "$RUNS"
echo "== $(date '+%H:%M:%S') $TAG start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')" > $LOG
for spec in "full-$TAG-dropin luajit $(cygpath -m $LD/libdir-dropin) on UNSET" "full-$TAG-additive additive $(cygpath -m $LD/libdir-additive) on UNSET"; do
  set -- $spec; D=$RUNS/$1
  "$A" C03C03 default "$SH" "$FULL" "$(cygpath -m $D)" $2 "$3" $4 $5 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'SMOKE\| (CHECKS|MILESTONE [^ ]+: FAIL|MEM-2 cadence|MILESTONE mem-2)' $D/run.log | cut -c1-6000 | sed 's/^/    /' >> $LOG
done
echo "== $(date '+%H:%M:%S') $TAG done" >> $LOG
