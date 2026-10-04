#!/bin/sh
# chainlib.sh -- sourced by the wall chains: run() and the paths.
W=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall
A=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/pcore/affrun.exe
SH="C:/Program Files/Git/usr/bin/sh.exe"
ONE=$(cygpath -m $W/cap.sh)
BASEADD=$(cygpath -m $W/base/libdir-additive)
BASEDROP=$(cygpath -m $W/base/libdir-dropin)
REPO=/c/Users/astro/Downloads/OC-LuaJIT
run() { # name native libdir jit early tier scale shape   (LOG and RUNS set by the chain)
  D=$RUNS/$1
  "$A" C03C03 default "$SH" "$ONE" "$(cygpath -m $D)" $2 "$3" $4 $5 $6 $7 $8 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null) $(grep -E 'SMOKE\| CAPACITY\|' $D/run.log | cut -c9-)" >> $LOG
  grep -E 'SMOKE\| CAP-(IDLE|LIVE|MID|GC)\|' $D/run.log | sed "s/^SMOKE| /    $1 /" >> $LOG
  grep -E 'MILESTONE cap-1' $D/run.log | sed "s/^/    $1 /" >> $LOG
  grep -qE 'MILESTONE (c-openos-shell|d-autorun-counter-live): FAIL|FATAL' $D/run.log && echo "    $1 BOOT-FAIL $(grep -E 'lastError =' $D/run.log | head -1)" >> $LOG
}
