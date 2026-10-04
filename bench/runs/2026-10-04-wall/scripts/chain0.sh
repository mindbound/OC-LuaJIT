#!/bin/sh
# chain0.sh -- stage 0: the new instrument against the BASELINE DLL (cb29485d).
# Must read wallstats=absent, and show stepmul 0 (and, if the fill parks, parked > 0) mid-fill.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/chainlib.sh
RUNS=$W/runs0
LOG=$W/chain0.log
[ -e "$RUNS" ] && { echo "REFUSING: $RUNS exists"; exit 99; }
mkdir -p "$RUNS"
echo "== $(date '+%H:%M:%S') chain0 start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')" > $LOG
run one-record-r1-E-base additive "$BASEADD" on off one 1.8 record
run one-array-r1-E-base additive "$BASEADD" on off one 1.8 array
echo "== $(date '+%H:%M:%S') chain0 done" >> $LOG
touch $W/chain0.done
