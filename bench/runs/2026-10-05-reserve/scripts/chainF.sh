#!/bin/sh
# chainF.sh -- THE RESERVE'S SIZE's in-machine gate (d3-final §5), pinned, serial:
#   E   the control: THE WINDOW + the unwinder fix (E2: additive d9a51b6b, dropin 8635573e)
#   F   the final: E + THE RESERVE'S SIZE (sc/F: additive 45eb443b, dropin 8f9bc419)
#   E-i, F-i  the same as the instrumented natives (sc/refnative2, sc/finst-native), OCLJ_REFLOG on
#  1. amplified cells, instrumented, interleaved E/F by rep: D record x15, L record x5, O string x10
#  2. recovery cells (OCLJ_CAP_RECOVER=1, OCLJ_REFLOG=2): F D record x5 + O string x5; E 2 + 2
#  3. the batch-100 matrix, plain: chain V's layout for F (48) + E's 192 KB D/O cells (24) + stock (4)
#  4. the five full suites on F
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/chainlib2.sh
EADD=$(cygpath -m $W2/E2/libdir-additive);        EDROP=$(cygpath -m $W2/E2/libdir-dropin)
FADD=$(cygpath -m $W2/sc/F/libdir-additive);      FDROP=$(cygpath -m $W2/sc/F/libdir-dropin)
EIADD=$(cygpath -m $W2/sc/refnative2/libdir-additive);   EIDROP=$(cygpath -m $W2/sc/refnative2/libdir-dropin)
FIADD=$(cygpath -m $W2/sc/finst-native/libdir-additive); FIDROP=$(cygpath -m $W2/sc/finst-native/libdir-dropin)
for d in $W2/E2/libdir-additive $W2/E2/libdir-dropin $W2/sc/F/libdir-additive $W2/sc/F/libdir-dropin \
         $W2/sc/refnative2/libdir-additive $W2/sc/refnative2/libdir-dropin $W2/sc/finst-native/libdir-additive $W2/sc/finst-native/libdir-dropin; do
  [ -f "$d"/*.dll ] || { echo "MISSING native dir $d"; exit 98; }
done
ROOT=$W2/runsF
[ -e "$ROOT" ] && { echo "REFUSING: $ROOT exists"; exit 99; }
mkdir -p "$ROOT"
say() { echo "== $(date -u '+%H:%M:%S') $*" >> $ROOT/chain.log; }
say "chainF start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')"
md5sum $W2/E2/libdir-*/*.dll $W2/sc/F/libdir-*/*.dll $W2/sc/refnative2/libdir-*/*.dll $W2/sc/finst-native/libdir-*/*.dll >> $ROOT/chain.log
# 1. the amplified cells, instrumented (one OCLJREF line per refusal)
export OCLJ_REFLOG=1
RUNS=$ROOT/gate; LOG=$ROOT/gate.log; mkdir -p $RUNS
for rep in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  run2 g-record-r$rep-E-D additive "$EIADD" on - one 1.8 record 10 24
  run2 g-record-r$rep-F-D additive "$FIADD" on - one 1.8 record 10 24
  if [ $rep -le 5 ]; then
    run2 g-record-r$rep-E-L luajit "$EIDROP" on - one 1.8 record 10 24
    run2 g-record-r$rep-F-L luajit "$FIDROP" on - one 1.8 record 10 24
  fi
  if [ $rep -le 10 ]; then
    run2 g-string-r$rep-E-O additive "$EIADD" off off one 1.8 string 10 24
    run2 g-string-r$rep-F-O additive "$FIADD" off off one 1.8 string 10 24
  fi
done
say "gate done: $(grep -c ' CLASS=' $LOG) runs; classes: $(grep -oE 'CLASS=[A-Z-]+' $LOG | sort | uniq -c | tr '\n' ' ')"
# 2. the recovery cells: the realistic recovery (level 3: traceback, tty, event.onError) on F, E
#    and STOCK (the smoke runs showed E refused too: the reserve was spent by the second chance,
#    so the bar is parity with stock, not the pre-registered rr = 0); the lightest (level 1) on F
export OCLJ_REFLOG=2
RUNS=$ROOT/recover; LOG=$ROOT/recover.log; mkdir -p $RUNS
for rep in 1 2 3 4 5; do
  export OCLJ_CAP_RECOVER=3
  run2 rc3-record-r$rep-F-D additive "$FIADD" on - one 1.8 record 10 24
  run2 rc3-string-r$rep-F-O additive "$FIADD" off off one 1.8 string 10 24
  if [ $rep -le 3 ]; then
    run2 rc3-record-r$rep-E-D additive "$EIADD" on - one 1.8 record 10 24
    run2 rc3-string-r$rep-E-O additive "$EIADD" off off one 1.8 string 10 24
    run2 rc3-record-r$rep-S-stock stock - on - one 1.8 record 10 24
    run2 rc3-string-r$rep-S-stock stock - on - one 1.8 string 10 24
    export OCLJ_CAP_RECOVER=1
    run2 rc1-record-r$rep-F-D additive "$FIADD" on - one 1.8 record 10 24
  fi
done
unset OCLJ_CAP_RECOVER
say "recovery done: $(grep -c ' CLASS=' $LOG) runs; classes: $(grep -oE 'CLASS=[A-Z-]+' $LOG | sort | uniq -c | tr '\n' ' ')"
unset OCLJ_REFLOG
# 3. the batch-100 matrix, plain natives
RUNS=$ROOT/matrix; LOG=$ROOT/matrix.log; mkdir -p $RUNS
for tier in one onehalf threehalf; do
  reps=1; [ $tier = one ] && reps=3
  for rep in $(seq 1 $reps); do
    for shape in record array string closure; do
      run2 $tier-$shape-r$rep-D-F additive "$FADD" on - $tier 1.8 $shape 100 24
      run2 $tier-$shape-r$rep-O-F additive "$FADD" off off $tier 1.8 $shape 100 24
      if [ $tier = one ]; then
        run2 $tier-$shape-r$rep-D-E additive "$EADD" on - $tier 1.8 $shape 100 24
        run2 $tier-$shape-r$rep-O-E additive "$EADD" off off $tier 1.8 $shape 100 24
        [ $rep = 1 ] && run2 $tier-$shape-r1-S-stock stock - on - $tier 1.8 $shape 100 24
      fi
      if [ $rep = 1 ] && [ $tier != onehalf ]; then
        run2 $tier-$shape-r1-L-F luajit "$FDROP" on - $tier 1.8 $shape 100 24
      fi
    done
  done
done
say "matrix done: $(grep -c ' CLASS=' $LOG) runs; classes: $(grep -oE 'CLASS=[A-Z-]+' $LOG | sort | uniq -c | tr '\n' ' ')"
# 4. the suites on F
RUNS=$ROOT/full; LOG=$ROOT/full.log; mkdir -p $RUNS
for spec in "fullF-additive-on additive $FADD on UNSET" "fullF-dropin-on luajit $FDROP on UNSET" \
            "fullF-additive-off additive $FADD off UNSET" "fullF-additive-sieve additive $FADD on sieve" \
            "fullF-stock stock - on UNSET"; do
  set -- $spec; D=$RUNS/$1
  "$A" C03C03 default "$SH" "$FULL" "$(cygpath -m $D)" $2 "$3" $4 $5 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'SMOKE\| (CHECKS|VERDICT|MILESTONE [^ ]+: (FAIL|SKIP)|MILESTONE (km-1|b2|mem-2|acc-4|j0)[^ ]*:)|^SMOKE (PASS|FAIL)' $D/run.log | cut -c1-260 | sed 's/^/    /' >> $LOG
done
say "full suites done: $(grep -c 'VERDICT: PASS' $LOG) of 5 PASS"
say "chainF done"
