#!/bin/sh
# chainB.sh -- stage B (the credit at the cap and the re-arm cadence), pinned, serial.
#  1. regression: the full suite -- additive JIT on, JIT off, sieve only; the dropin; stock
#  2. the capacity matrix at OC's 1.8, the 2026-10-03 chain1 layout: S (stock) and ours
#     D / E / O on 192 KB (3 reps) and 256 / 1024 KB (1 rep), four shapes; plus the
#     dropin L (legacy path) on 192 and 1024 KB, four shapes.  B's DLLs, snapshotted.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/chainlib.sh
RUNS=$W/runsB
LOG=$W/chainB.log
BADD=$(cygpath -m $W/B/libdir-additive)
BDROP=$(cygpath -m $W/B/libdir-dropin)
FULL=$(cygpath -m $W/full.sh)
[ -e "$RUNS" ] && { echo "REFUSING: $RUNS exists"; exit 99; }
[ -f "$W/B/libdir-additive/libjnluajit52-windows-x86_64.dll" ] || { echo "no B additive DLL"; exit 98; }
mkdir -p "$RUNS"
echo "== $(date '+%H:%M:%S') chainB start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')" > $LOG
for spec in "fullB-additive-on additive $BADD on UNSET" "fullB-additive-off additive $BADD off UNSET" \
            "fullB-additive-sieve additive $BADD on sieve" "fullB-dropin-on luajit $BDROP on UNSET" \
            "fullB-stock stock - on UNSET"; do
  set -- $spec; D=$RUNS/$1
  "$A" C03C03 default "$SH" "$FULL" "$(cygpath -m $D)" $2 "$3" $4 $5 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'SMOKE\| (ramScale|RAM tier|CHECKS|VERDICT|MILESTONE [^ ]+: (FAIL|SKIP)|PHASE1 ROW)|^SMOKE (PASS|FAIL)' $D/run.log | cut -c1-220 | sed 's/^/    /' >> $LOG
done
for tier in one onehalf threehalf; do
  reps=1; [ $tier = one ] && reps=3
  for rep in $(seq 1 $reps); do
    for shape in record array string closure; do
      run "$tier-$shape-r$rep-S-stock" stock - on - $tier 1.8 $shape
      run "$tier-$shape-r$rep-D-B" additive "$BADD" on - $tier 1.8 $shape
      run "$tier-$shape-r$rep-E-B" additive "$BADD" on off $tier 1.8 $shape
      run "$tier-$shape-r$rep-O-B" additive "$BADD" off off $tier 1.8 $shape
      if [ $rep = 1 ] && [ $tier != onehalf ]; then
        run "$tier-$shape-r1-L-B" luajit "$BDROP" on - $tier 1.8 $shape
      fi
    done
  done
done
echo "== $(date '+%H:%M:%S') chainB done" >> $LOG
touch $W/chainB.done
