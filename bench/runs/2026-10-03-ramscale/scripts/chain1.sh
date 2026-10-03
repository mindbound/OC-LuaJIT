#!/bin/sh
# chain1.sh -- the capacity matrix at OC's 1.8, serial, pinned to the P-cores.
set -u
R=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/ramscale
A=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/pcore/affrun.exe
SH="C:/Program Files/Git/usr/bin/sh.exe"
ONE=$(cygpath -m $R/cap.sh)
LOG=$R/chain1.log
run() { # name native jit early tier scale shape
  D=$R/runs/$1
  "$A" C03C03 default "$SH" "$ONE" "$(cygpath -m $D)" $2 $3 $4 $5 $6 $7 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null) $(grep -E 'SMOKE\| CAPACITY\|' $D/run.log | cut -c9-)" >> $LOG
  grep -E 'SMOKE\| CAP-(IDLE|LIVE)\|' $D/run.log | sed "s/^SMOKE| /    $1 /" >> $LOG
  grep -qE 'MILESTONE (c-openos-shell|d-autorun-counter-live): FAIL|FATAL' $D/run.log && echo "    $1 BOOT-FAIL $(grep -E 'lastError =' $D/run.log | head -1)" >> $LOG
}
echo "== $(date '+%H:%M:%S') chain1 start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')" > $LOG
for tier in one onehalf threehalf; do
  reps=1; [ $tier = one ] && reps=3
  for rep in $(seq 1 $reps); do
    for shape in record array string closure; do
      run "$tier-$shape-r$rep-S" stock on - $tier 1.8 $shape
      run "$tier-$shape-r$rep-D" additive on - $tier 1.8 $shape
      run "$tier-$shape-r$rep-E" additive on off $tier 1.8 $shape
      run "$tier-$shape-r$rep-O" additive off off $tier 1.8 $shape
    done
  done
done
run "one-record-scale1.0-S" stock on - one 1.0 record
run "one-record-scale1.0-D" additive on - one 1.0 record
echo "== $(date '+%H:%M:%S') chain1 done" >> $LOG
touch $R/chain1.done
