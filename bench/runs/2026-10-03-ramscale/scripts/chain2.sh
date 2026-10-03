#!/bin/sh
# chain2.sh -- AxisOS (1 stick) and MineOS (2 sticks, its declared floor) at OC's 1.8, stock vs ours, pinned.
set -u
R=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/ramscale
A=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/pcore/affrun.exe
SH="C:/Program Files/Git/usr/bin/sh.exe"
ONE=$(cygpath -m $R/census.sh)
LOG=$R/chain2.log
run() { # name native scale sticks os ticks
  D=$R/runs/$1
  "$A" C03C03 default "$SH" "$ONE" "$(cygpath -m $D)" $2 $3 $4 $5 $6 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'CENSUS\| (ticks run|totalMemory|PEAK USED|lastError|GC PRESSURE|VERDICT|architecture|native marker)' $D/run.log | sed "s/^/    /" >> $LOG
}
echo "== $(date '+%H:%M:%S') chain2 start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')" > $LOG
run census-axis-S stock 1.8 1 axis 14000
run census-axis-D additive 1.8 1 axis 14000
run census-mineos-S stock 1.8 2 mineos 14000
run census-mineos-D additive 1.8 2 mineos 14000
echo "== $(date '+%H:%M:%S') chain2 done" >> $LOG
touch $R/chain2.done
