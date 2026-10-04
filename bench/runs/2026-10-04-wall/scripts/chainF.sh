#!/bin/sh
# chainF.sh -- after race-2 and the jit.on no-op (OcljSmoke), with OcljArch back as committed:
#  1. race-2 (OCLJ_RACE_PHASE=boot), unlocked and locked alternately, 4 each: does the
#     reading through OpenOS's boot reproduce runSynchronized's :172?
#  2. race-1 (idle), 1 unlocked and 1 locked: the refactor onto RaceReads changed nothing
#  3. the full suite, JIT off, 6 on the additive and 6 on the dropin: j0 with the no-op
#  4. the full suite, JIT on, additive and dropin
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/chainlib.sh
RUNS=$W/runsF
LOG=$RUNS/chain.log
CADD=$(cygpath -m $W/C/libdir-additive)
CDROP=$(cygpath -m $W/C/libdir-dropin)
FULL=$(cygpath -m $W/full.sh)
RACE=$(cygpath -m $W/race.sh)
[ -e "$RUNS" ] && { echo "REFUSING: $RUNS exists"; exit 99; }
mkdir -p "$RUNS"
echo "== $(date -u '+%H:%M:%S') chainF start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')" > $LOG
race() { # name lock phase
  D=$RUNS/$1
  OCLJ_RACE_PHASE=$3 "$A" C03C03 default "$SH" "$RACE" "$(cygpath -m $D)" additive "$CADD" $2 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'MILESTONE (race-[12]|c-openos|d-autorun)[^ ]*:|race-[12] end|b-machine|quiesced after [0-9]+ spins, before the VM|NativeLuaArchitecture.scala|SMOKE (PASS|FAIL)' $D/run.log | cut -c1-330 | sed 's/^/    /' >> $LOG
}
for k in 1 2 3 4; do race race2-unlocked-$k off boot; race race2-locked-$k on boot; done
race race1-unlocked-1 off idle
race race1-locked-1 on idle
full() { # name native lib jit
  D=$RUNS/$1
  "$A" C03C03 default "$SH" "$FULL" "$(cygpath -m $D)" $2 "$3" $4 UNSET > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'MILESTONE b-machine|quiesced after [0-9]+ spins, before the VM|JIT PROBE: (jit.off|kernel=)|MILESTONE (j0|m1)[^ ]*:|SMOKE\| (CHECKS|VERDICT|MILESTONE [^ ]+: FAIL)' $D/run.log | cut -c1-220 | sed 's/^/    /' >> $LOG
}
for k in 1 2 3 4 5 6; do full fullF-additive-off-$k additive "$CADD" off; full fullF-dropin-off-$k luajit "$CDROP" off; done
full fullF-additive-on additive "$CADD" on
full fullF-dropin-on luajit "$CDROP" on
echo "== $(date -u '+%H:%M:%S') chainF done" >> $LOG
