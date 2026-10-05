#!/bin/sh
# chainE.sh -- the unwinder-crash fix (lj_err_mem's top clamp) in the machine, pinned, serial:
# the full suite on E: additive JIT on, the dropin, JIT off, sieve only, stock.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/chainlib2.sh
EADD=$(cygpath -m $W2/E/libdir-additive)
EDROP=$(cygpath -m $W2/E/libdir-dropin)
ROOT=$W2/runsE
[ -e "$ROOT" ] && { echo "REFUSING: $ROOT exists"; exit 99; }
mkdir -p "$ROOT"
say() { echo "== $(date -u '+%H:%M:%S') $*" >> $ROOT/chain.log; }
say "chainE start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')"
md5sum $W2/E/libdir-additive/* $W2/E/libdir-dropin/* >> $ROOT/chain.log
RUNS=$ROOT/full; LOG=$ROOT/full.log; mkdir -p $RUNS
for spec in "fullE-additive-on additive $EADD on UNSET" "fullE-dropin-on luajit $EDROP on UNSET" \
            "fullE-additive-off additive $EADD off UNSET" "fullE-additive-sieve additive $EADD on sieve" \
            "fullE-stock stock - on UNSET"; do
  set -- $spec; D=$RUNS/$1
  "$A" C03C03 default "$SH" "$FULL" "$(cygpath -m $D)" $2 "$3" $4 $5 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'SMOKE\| (CHECKS|VERDICT|MILESTONE [^ ]+: (FAIL|SKIP)|MILESTONE (km-1|b2|mem-2|acc-4|j0)[^ ]*:)|^SMOKE (PASS|FAIL)' $D/run.log | cut -c1-260 | sed 's/^/    /' >> $LOG
done
say "full suites done: $(grep -c 'VERDICT: PASS' $LOG) of 5 PASS"
say "chainE done"
