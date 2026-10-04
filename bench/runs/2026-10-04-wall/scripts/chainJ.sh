#!/bin/sh
# chainJ.sh <runs-subdir> <label> <n> [additive|luajit] -- the full suite, JIT off, n times, pinned, serial:
# does j0 (the JIT-off control) hold?  Site 13 restores the JIT after the kernelMemory baseline
# when it was on at the kernel's first line, and the harness's own jit.off() can land before that.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/chainlib.sh
RUNS=$W/$1; LABEL=$2; N=$3; NAT=${4:-additive}
LOG=$RUNS/chain.log
if [ $NAT = luajit ]; then LIBD=$(cygpath -m $W/C/libdir-dropin); else LIBD=$(cygpath -m $W/C/libdir-additive); fi
FULL=$(cygpath -m $W/full.sh)
[ -e "$RUNS" ] && { echo "REFUSING: $RUNS exists"; exit 99; }
mkdir -p "$RUNS"
echo "== $(date -u '+%H:%M:%S') chainJ $LABEL native=$NAT start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')" > $LOG
for i in $(seq 1 $N); do
  D=$RUNS/fullJ-$LABEL-off-$i
  "$A" C03C03 default "$SH" "$FULL" "$(cygpath -m $D)" $NAT "$LIBD" off UNSET > /dev/null 2>&1
  echo "fullJ-$LABEL-off-$i exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'MILESTONE b-machine|quiesced after [0-9]+ spins, before the (VM|JIT)|JIT PROBE: (jit.off|kernel=)|MILESTONE (j0|m1|k3)[^ ]*:|before kernel init|SMOKE\| VERDICT' $D/run.log | cut -c1-200 | sed 's/^/    /' >> $LOG
done
echo "== $(date -u '+%H:%M:%S') chainJ $LABEL done" >> $LOG
