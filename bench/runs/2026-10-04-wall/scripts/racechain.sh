#!/bin/sh
# racechain.sh <runs-subdir> <name:lock> ...   -- race.sh runs one after another, pinned
W=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall
A=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/pcore/affrun.exe
SH="C:/Program Files/Git/usr/bin/sh.exe"
RACE=$(cygpath -m $W/race.sh)
NATIVE=${NATIVE:-additive}
LIB=${LIB:-$(cygpath -m $W/C/libdir-$NATIVE)}
RUNS=$W/$1; shift
mkdir -p $RUNS
LOG=$RUNS/chain.log
for x in "$@"; do
  name=${x%%:*}; lock=${x##*:}
  D=$RUNS/$name
  echo "$(date -u +%H:%M:%S) start $name lock=$lock native=$NATIVE phase=${OCLJ_RACE_PHASE:-idle}" >> $LOG
  "$A" C03C03 default "$SH" "$RACE" "$(cygpath -m $D)" $NATIVE "$LIB" $lock > /dev/null 2>&1
  v=$(grep -m1 -E 'MILESTONE race-[12]' $D/run.log 2>/dev/null | sed 's/^SMOKE| //')
  echo "$(date -u +%H:%M:%S) end   $name exit=$(cat $D/exit.txt 2>/dev/null) $v" >> $LOG
done
echo "$(date -u +%H:%M:%S) CHAIN DONE" >> $LOG
