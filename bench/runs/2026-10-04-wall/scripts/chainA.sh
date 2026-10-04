#!/bin/sh
# chainA.sh -- commit A (P3: park reset, attempt-only valve), pinned to the P-cores, serial.
#  1. regression: the full suite, additive JIT on and the dropin, on A's DLLs
#  2. the reduced capacity matrix: arm E (JIT off through kernel init), 192 KB, 1.8,
#     4 shapes x 3 reps on A's DLL, with the baseline DLL (cb29485d) at rep 1 of each
#     shape interleaved as the in-chain reference.  chain1 (2026-10-03) read E at 192 KB:
#     5 clean, 3 recovery refused, 3 down, 1 boot failed.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/chainlib.sh
RUNS=$W/runsA
LOG=$W/chainA.log
AADD=$(cygpath -m $W/A/libdir-additive)
ADROP=$(cygpath -m $W/A/libdir-dropin)
FULL=$(cygpath -m $W/full.sh)
[ -e "$RUNS" ] && { echo "REFUSING: $RUNS exists"; exit 99; }
mkdir -p "$RUNS"
echo "== $(date '+%H:%M:%S') chainA start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')" > $LOG
for spec in "fullA-additive-on additive $AADD on UNSET" "fullA-dropin-on luajit $ADROP on UNSET"; do
  set -- $spec; D=$RUNS/$1
  "$A" C03C03 default "$SH" "$FULL" "$(cygpath -m $D)" $2 "$3" $4 $5 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'SMOKE\| (ramScale|RAM tier|CHECKS|VERDICT|MILESTONE [^ ]+: (FAIL|SKIP)|PHASE1 ROW)|^SMOKE (PASS|FAIL)' $D/run.log | cut -c1-220 | sed 's/^/    /' >> $LOG
done
for rep in 1 2 3; do
  for shape in record array string closure; do
    [ $rep = 1 ] && run "one-$shape-r1-E-base" additive "$BASEADD" on off one 1.8 $shape
    run "one-$shape-r$rep-E-A" additive "$AADD" on off one 1.8 $shape
  done
done
echo "== $(date '+%H:%M:%S') chainA done" >> $LOG
touch $W/chainA.done
