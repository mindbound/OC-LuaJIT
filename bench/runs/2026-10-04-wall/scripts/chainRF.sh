#!/bin/sh
# chainRF.sh -- after the fix (guard, f6 and gc-pace read under the machine's monitor):
#  1. the race probe with the ticks/2 heartbeat bar, unlocked and locked alternately, three
#     each (the unlocked must fail -- crash or wedge -- and the locked pass)
#  2. the full suite: additive JIT on, the dropin, JIT off (f6's re-apply), stock, and
#     additive JIT off with OCLJ_GCSTEPMUL=400 (gc-pace's re-apply)
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/chainlib.sh
RUNS=$W/runsRF
LOG=$RUNS/chain.log
CADD=$(cygpath -m $W/C/libdir-additive)
CDROP=$(cygpath -m $W/C/libdir-dropin)
FULL=$(cygpath -m $W/full.sh)
RACE=$(cygpath -m $W/race.sh)
[ -e "$RUNS" ] && { echo "REFUSING: $RUNS exists"; exit 99; }
mkdir -p "$RUNS"
echo "== $(date -u '+%H:%M:%S') chainRF start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')" > $LOG
for x in race-unlocked-1:off race-locked-1:on race-unlocked-2:off race-locked-2:on race-unlocked-3:off race-locked-3:on; do
  name=${x%%:*}; lock=${x##*:}; D=$RUNS/$name
  "$A" C03C03 default "$SH" "$RACE" "$(cygpath -m $D)" additive "$CADD" $lock > /dev/null 2>&1
  echo "$name exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'MILESTONE race-1|race-1 end|dirty stack|SMOKE (PASS|FAIL)' $D/run.log | cut -c1-300 | sed 's/^/    /' >> $LOG
done
for spec in "fullRF-additive-on additive $CADD on UNSET 0" "fullRF-dropin-on luajit $CDROP on UNSET 0" \
            "fullRF-additive-off additive $CADD off UNSET 0" "fullRF-stock stock - on UNSET 0" \
            "fullRF-additive-off-stepmul400 additive $CADD off UNSET 400"; do
  set -- $spec; D=$RUNS/$1
  OCLJ_GCSTEPMUL=$6 "$A" C03C03 default "$SH" "$FULL" "$(cygpath -m $D)" $2 "$3" $4 $5 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'SMOKE\| (CHECKS|VERDICT|MILESTONE [^ ]+: (FAIL|SKIP)|MILESTONE (f6|gc-pace)[^ ]*:|GUARD VM|GC PACE)|dirty stack|^SMOKE (PASS|FAIL)' $D/run.log | cut -c1-300 | sed 's/^/    /' >> $LOG
done
echo "== $(date -u '+%H:%M:%S') chainRF done" >> $LOG
