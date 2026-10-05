#!/bin/sh
# chainG.sh -- THE WINDOW in the machine, pinned, serial.
#  0. sanity: one amplified run on stage C and one on THE WINDOW (the harness compiles, CAP-X prints)
#  1. the full suite on THE WINDOW: additive JIT on, the dropin, JIT off, sieve only, stock
#  2. THE GATE (d2-final 8.2): 192 KB, scale 1.8, BATCH 10, JUNK 24; S stock, C stage C, W THE WINDOW;
#     arms O (JIT off throughout), D (JIT on), L (the dropin); string and record; 10 reps (L 5);
#     interleaved by rep; stage C's D-string cells LAST (it reaches LuaJIT's unwinder crash hermetically)
#  3. the standard matrix at BATCH 100, chain C's layout with W for C (R12: capacity, last five, idle)
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/chainlib2.sh
ROOT=$W2/runsG
[ -e "$ROOT" ] && { echo "REFUSING: $ROOT exists"; exit 99; }
mkdir -p "$ROOT"
say() { echo "== $(date -u '+%H:%M:%S') $*" >> $ROOT/chain.log; }
say "chainG start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')"

# 0. sanity
RUNS=$ROOT/sanity; LOG=$ROOT/sanity.log; mkdir -p $RUNS
run2 sanity-C-O additive "$CADD" off off one 1.8 string 10 24
run2 sanity-W-O additive "$WADD" off off one 1.8 string 10 24
say "sanity done: $(grep -c 'CAP-X|' $LOG) CAP-X lines (want 2)"
[ "$(grep -c 'CAP-X|' $LOG)" = "2" ] || { say "SANITY FAILED -- stopping"; exit 1; }

# 1. full suites
RUNS=$ROOT/full; LOG=$ROOT/full.log; mkdir -p $RUNS
for spec in "fullW-additive-on additive $WADD on UNSET" "fullW-dropin-on luajit $WDROP on UNSET" \
            "fullW-additive-off additive $WADD off UNSET" "fullW-additive-sieve additive $WADD on sieve" \
            "fullW-stock stock - on UNSET"; do
  set -- $spec; D=$RUNS/$1
  "$A" C03C03 default "$SH" "$FULL" "$(cygpath -m $D)" $2 "$3" $4 $5 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'SMOKE\| (CHECKS|VERDICT|MILESTONE [^ ]+: (FAIL|SKIP)|MILESTONE (km-1|b2|mem-2|acc-4|j0)[^ ]*:)|^SMOKE (PASS|FAIL)' $D/run.log | cut -c1-260 | sed 's/^/    /' >> $LOG
done
say "full suites done: $(grep -c 'VERDICT: PASS' $LOG) of 5 PASS"

# 2. the gate
RUNS=$ROOT/gate; LOG=$ROOT/gate.log; mkdir -p $RUNS
for shape in record string; do
  for rep in 1 2 3 4 5 6 7 8 9 10; do
    run2 g-$shape-r$rep-S stock - on - one 1.8 $shape 10 24
    run2 g-$shape-r$rep-C-O additive "$CADD" off off one 1.8 $shape 10 24
    run2 g-$shape-r$rep-W-O additive "$WADD" off off one 1.8 $shape 10 24
    [ $shape = string ] || run2 g-$shape-r$rep-C-D additive "$CADD" on - one 1.8 $shape 10 24
    run2 g-$shape-r$rep-W-D additive "$WADD" on - one 1.8 $shape 10 24
    if [ $rep -le 5 ]; then
      run2 g-$shape-r$rep-C-L luajit "$CDROP" on - one 1.8 $shape 10 24
      run2 g-$shape-r$rep-W-L luajit "$WDROP" on - one 1.8 $shape 10 24
    fi
  done
  say "gate $shape done"
done
for rep in 1 2 3 4 5 6 7 8 9 10; do run2 g-string-r$rep-C-D additive "$CADD" on - one 1.8 string 10 24; done
say "gate done: $(grep -c ' CLASS=' $LOG) runs"

# 3. the standard matrix at BATCH 100
RUNS=$ROOT/matrix; LOG=$ROOT/matrix.log; mkdir -p $RUNS
for tier in one onehalf threehalf; do
  reps=1; [ $tier = one ] && reps=3
  for rep in $(seq 1 $reps); do
    for shape in record array string closure; do
      run2 $tier-$shape-r$rep-S stock - on - $tier 1.8 $shape 100 24
      run2 $tier-$shape-r$rep-D-W additive "$WADD" on - $tier 1.8 $shape 100 24
      run2 $tier-$shape-r$rep-O-W additive "$WADD" off off $tier 1.8 $shape 100 24
      if [ $rep = 1 ] && [ $tier != onehalf ]; then
        run2 $tier-$shape-r1-L-W luajit "$WDROP" on - $tier 1.8 $shape 100 24
      fi
    done
  done
done
say "matrix done: $(grep -c ' CLASS=' $LOG) runs"
say "chainG done"
