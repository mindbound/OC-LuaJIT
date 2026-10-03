#!/bin/sh
# chain3.sh -- the full suite at the new default scale 1.8, four arms, pinned.
set -u
R=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/ramscale
A=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/pcore/affrun.exe
SH="C:/Program Files/Git/usr/bin/sh.exe"
ONE=$(cygpath -m $R/full.sh)
LOG=$R/chain3.log
echo "== $(date '+%H:%M:%S') chain3 start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')" > $LOG
for spec in "full18-additive-on additive on UNSET" "full18-additive-off additive off UNSET" "full18-additive-sieve additive on sieve" "full18-stock stock on UNSET"; do
  set -- $spec; D=$R/runs/$1
  "$A" C03C03 default "$SH" "$ONE" "$(cygpath -m $D)" $2 $3 $4 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'SMOKE\| (ramScale|RAM tier|CHECKS|VERDICT|MILESTONE [^ ]+: (FAIL|SKIP)|PHASE1 ROW)|^SMOKE (PASS|FAIL)' $D/run.log | cut -c1-220 | sed 's/^/    /' >> $LOG
done
echo "== $(date '+%H:%M:%S') chain3 done" >> $LOG
touch $R/chain3.done
