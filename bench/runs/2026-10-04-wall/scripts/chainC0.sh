#!/bin/sh
# chainC0.sh -- stage C, step 1: the site-13 kernel (JIT off through kernel init) on stage B's
# DLLs.  The full suites (km-1 must pass), then D at 192 KB x3 against one E: D's kernelMemory
# and idle should now match E's.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/chainlib.sh
RUNS=$W/runsC0
LOG=$W/chainC0.log
BADD=$(cygpath -m $W/B3/libdir-additive)
BDROP=$(cygpath -m $W/B3/libdir-dropin)
FULL=$(cygpath -m $W/full.sh)
[ -e "$RUNS" ] && { echo "REFUSING: $RUNS exists"; exit 99; }
mkdir -p "$RUNS"
echo "== $(date '+%H:%M:%S') chainC0 start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')" > $LOG
for spec in "fullC0-additive-on additive $BADD on UNSET" "fullC0-dropin-on luajit $BDROP on UNSET"; do
  set -- $spec; D=$RUNS/$1
  "$A" C03C03 default "$SH" "$FULL" "$(cygpath -m $D)" $2 "$3" $4 $5 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'SMOKE\| (CHECKS|VERDICT|MILESTONE [^ ]+: (FAIL|SKIP)|MILESTONE km-1|MILESTONE b2)|^SMOKE (PASS|FAIL)' $D/run.log | cut -c1-300 | sed 's/^/    /' >> $LOG
done
for rep in 1 2 3; do
  run "one-record-r$rep-D-C0" additive "$BADD" on - one 1.8 record
done
run "one-record-r1-E-C0" additive "$BADD" on off one 1.8 record
echo "== $(date '+%H:%M:%S') chainC0 done" >> $LOG
touch $W/chainC0.done
