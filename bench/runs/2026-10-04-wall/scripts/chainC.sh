#!/bin/sh
# chainC.sh -- stage C (site 13: no compiled code in kernelMemory; the flush asked for inside
# half the watermark), pinned, serial.
#  1. the full suite -- additive JIT on, JIT off, sieve only; the dropin; stock
#  2. the capacity matrix at 1.8: S (stock) and ours D / O on 192 KB (3 reps), 256 and 1024 KB
#     (1 rep), four shapes; the dropin L on 192 and 1024 KB.  Arm E is dropped: with site 13
#     shipped, D is what E was (the JIT off through kernel init).
#  3. one D run at 192 KB NOT pinned: kernelMemory must not depend on the host's speed.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/chainlib.sh
RUNS=$W/runsC
LOG=$W/chainC.log
CADD=$(cygpath -m $W/C/libdir-additive)
CDROP=$(cygpath -m $W/C/libdir-dropin)
FULL=$(cygpath -m $W/full.sh)
[ -e "$RUNS" ] && { echo "REFUSING: $RUNS exists"; exit 99; }
mkdir -p "$RUNS"
echo "== $(date '+%H:%M:%S') chainC start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')" > $LOG
for spec in "fullC-additive-on additive $CADD on UNSET" "fullC-dropin-on luajit $CDROP on UNSET" \
            "fullC-additive-off additive $CADD off UNSET" "fullC-additive-sieve additive $CADD on sieve" \
            "fullC-stock stock - on UNSET"; do
  set -- $spec; D=$RUNS/$1
  "$A" C03C03 default "$SH" "$FULL" "$(cygpath -m $D)" $2 "$3" $4 $5 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'SMOKE\| (CHECKS|VERDICT|MILESTONE [^ ]+: (FAIL|SKIP)|MILESTONE km-1|MILESTONE b2|MILESTONE mem-2|PHASE1 ROW)|^SMOKE (PASS|FAIL)' $D/run.log | cut -c1-260 | sed 's/^/    /' >> $LOG
done
for tier in one onehalf threehalf; do
  reps=1; [ $tier = one ] && reps=3
  for rep in $(seq 1 $reps); do
    for shape in record array string closure; do
      run "$tier-$shape-r$rep-S-stock" stock - on - $tier 1.8 $shape
      run "$tier-$shape-r$rep-D-C" additive "$CADD" on - $tier 1.8 $shape
      run "$tier-$shape-r$rep-O-C" additive "$CADD" off off $tier 1.8 $shape
      if [ $rep = 1 ] && [ $tier != onehalf ]; then
        run "$tier-$shape-r1-L-C" luajit "$CDROP" on - $tier 1.8 $shape
      fi
    done
  done
done
# 3. unpinned: straight to cap.sh, no affrun
D=$RUNS/one-record-r9-D-Cunpinned
sh "$W/cap.sh" "$(cygpath -m $D)" additive "$CADD" on - one 1.8 record > /dev/null 2>&1
echo "one-record-r9-D-Cunpinned exit=$(cat $D/exit.txt 2>/dev/null) $(grep -E 'SMOKE\| CAPACITY\|' $D/run.log | cut -c9-)" >> $LOG
grep -E 'SMOKE\| CAP-(IDLE|LIVE|MID|GC)\|' $D/run.log | sed "s/^SMOKE| /    one-record-r9-D-Cunpinned /" >> $LOG
grep -E 'MILESTONE (cap-1|km-1)' $D/run.log | sed "s/^/    one-record-r9-D-Cunpinned /" >> $LOG
echo "== $(date '+%H:%M:%S') chainC done" >> $LOG
touch $W/chainC.done
