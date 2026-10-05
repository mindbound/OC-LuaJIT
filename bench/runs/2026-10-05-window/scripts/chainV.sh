#!/bin/sh
# chainV.sh -- THE WINDOW after the code review (W2: the fresh-record guard, the kernel-room
# pin, the harness's STOPPED class and step-entry label), in the machine, pinned, serial:
#  1. the full suite on W2: additive JIT on, the dropin, JIT off, sieve only, stock
#  2. the amplified gate's W cells (192 KB, BATCH 10, JUNK 24): O, D, L x string, record;
#     10 reps (L 5).  Stage C and stock are unchanged since runsG/gate.
#  3. the standard matrix's W cells at BATCH 100 (chain C's layout)
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/chainlib2.sh
VADD=$(cygpath -m $W2/W2/libdir-additive)
VDROP=$(cygpath -m $W2/W2/libdir-dropin)
ROOT=$W2/runsV
[ -e "$ROOT" ] && { echo "REFUSING: $ROOT exists"; exit 99; }
mkdir -p "$ROOT"
say() { echo "== $(date -u '+%H:%M:%S') $*" >> $ROOT/chain.log; }
say "chainV start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')"
RUNS=$ROOT/full; LOG=$ROOT/full.log; mkdir -p $RUNS
for spec in "fullV-additive-on additive $VADD on UNSET" "fullV-dropin-on luajit $VDROP on UNSET" \
            "fullV-additive-off additive $VADD off UNSET" "fullV-additive-sieve additive $VADD on sieve" \
            "fullV-stock stock - on UNSET"; do
  set -- $spec; D=$RUNS/$1
  "$A" C03C03 default "$SH" "$FULL" "$(cygpath -m $D)" $2 "$3" $4 $5 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'SMOKE\| (CHECKS|VERDICT|MILESTONE [^ ]+: (FAIL|SKIP)|MILESTONE (km-1|b2|mem-2|acc-4|j0)[^ ]*:)|^SMOKE (PASS|FAIL)' $D/run.log | cut -c1-260 | sed 's/^/    /' >> $LOG
done
say "full suites done: $(grep -c 'VERDICT: PASS' $LOG) of 5 PASS"
RUNS=$ROOT/gate; LOG=$ROOT/gate.log; mkdir -p $RUNS
for shape in record string; do
  for rep in 1 2 3 4 5 6 7 8 9 10; do
    run2 g-$shape-r$rep-V-O additive "$VADD" off off one 1.8 $shape 10 24
    run2 g-$shape-r$rep-V-D additive "$VADD" on - one 1.8 $shape 10 24
    [ $rep -le 5 ] && run2 g-$shape-r$rep-V-L luajit "$VDROP" on - one 1.8 $shape 10 24
  done
done
say "gate done: $(grep -c ' CLASS=' $LOG) runs"
RUNS=$ROOT/matrix; LOG=$ROOT/matrix.log; mkdir -p $RUNS
for tier in one onehalf threehalf; do
  reps=1; [ $tier = one ] && reps=3
  for rep in $(seq 1 $reps); do
    for shape in record array string closure; do
      run2 $tier-$shape-r$rep-D-V additive "$VADD" on - $tier 1.8 $shape 100 24
      run2 $tier-$shape-r$rep-O-V additive "$VADD" off off $tier 1.8 $shape 100 24
      if [ $rep = 1 ] && [ $tier != onehalf ]; then
        run2 $tier-$shape-r1-L-V luajit "$VDROP" on - $tier 1.8 $shape 100 24
      fi
    done
  done
done
say "matrix done: $(grep -c ' CLASS=' $LOG) runs"
say "chainV done"
