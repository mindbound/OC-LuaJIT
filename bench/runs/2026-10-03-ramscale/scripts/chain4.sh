#!/bin/sh
# chain4.sh -- the full suite, ours JIT on, at 1.8, twice: the new mem-2 clause (near-empty) on its first runs.
set -u
R=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/ramscale
A=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/pcore/affrun.exe
SH="C:/Program Files/Git/usr/bin/sh.exe"
ONE=$(cygpath -m $R/full.sh)
LOG=$R/chain4.log
echo "== $(date '+%H:%M:%S') chain4 start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')" > $LOG
for spec in "full18-additive-on-r2 additive on UNSET" "full18-additive-on-r3 additive on UNSET"; do
  set -- $spec; D=$R/runs/$1
  "$A" C03C03 default "$SH" "$ONE" "$(cygpath -m $D)" $2 $3 $4 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'SMOKE\| (MEM-2 reads|ramScale|RAM tier|CHECKS|VERDICT|MILESTONE [^ ]+: (FAIL|SKIP)|PHASE1 ROW)|^SMOKE (PASS|FAIL)' $D/run.log | cut -c1-220 | sed 's/^/    /' >> $LOG
done
echo "== $(date '+%H:%M:%S') chain4 done" >> $LOG
touch $R/chain4.done
