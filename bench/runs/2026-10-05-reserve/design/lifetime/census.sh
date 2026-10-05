#!/bin/sh
# census.sh <exe> <shape> <jit> <ncaps> <tag> <probe.lua> <hb> [P] [seed]
# The forensics' census2.sh, writing into THIS directory's out/: offsets
# 0,16,...,16*(ncaps-1) at capk 384, one process per cap, P at a time
# (default 12), each pinned (affrun 3FC3FC default):
#   <probe.lua> <shape> <off> <off> 16 384 <jit> 1 1 <hb> 0 -1 24 10
# (arm, paint, heartbeat hb, no control, measure at the terminal event,
# junk 24, the amplified batch 10).  The probes are read from the
# forensics' drv/ (unchanged).  Output out/<tag>.tsv + out/<tag>.err/<off>.err.
# Refuses to overwrite.  OCLJ_REFLOG is inherited.
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/design/lifetime
OUT=$WD/out/$5.tsv
ED=$WD/out/$5.err
[ -e "$OUT" ] && { echo "census.sh: $OUT exists; not overwriting" >&2; exit 1; }
[ -e "$ED" ] && { echo "census.sh: $ED exists; not overwriting" >&2; exit 1; }
n=$4
[ "$n" -ge 1 ] && [ "$n" -le 8192 ] || { echo "census.sh: ncaps out of bounds" >&2; exit 2; }
mkdir -p "$ED"
i=0
while [ $i -lt $n ]; do echo $((i*16)); i=$((i+1)); done | xargs -P ${8:-12} -I{} sh $WD/job.sh $1 $2 {} $3 "$ED" $6 $7 ${9:-} | cat > "$OUT"
echo "$5: $(wc -l < "$OUT") lines"
