#!/bin/sh
# census.sh <exe> <shape> <jit> <ncaps> <tag> [P] [seed]
# offsets 0,16,...,16*(ncaps-1) at capk 384, one process per cap (job.sh),
# P at a time (default 12).  Output out/<tag>.tsv, stderr per cap in
# out/<tag>.err/<off>.err.  Refuses to overwrite (fresh dirs only).
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/forensics
OUT=$WD/out/$5.tsv
ED=$WD/out/$5.err
[ -e "$OUT" ] && { echo "census.sh: $OUT exists; not overwriting" >&2; exit 1; }
[ -e "$ED" ] && { echo "census.sh: $ED exists; not overwriting" >&2; exit 1; }
n=$4
[ "$n" -ge 1 ] && [ "$n" -le 8192 ] || { echo "census.sh: ncaps out of bounds" >&2; exit 2; }
mkdir -p "$ED"
i=0
while [ $i -lt $n ]; do echo $((i*16)); i=$((i+1)); done | xargs -P ${6:-12} -I{} sh $WD/job.sh $1 $2 {} $3 "$ED" ${7:-} | cat > "$OUT"
echo "$5: $(wc -l < "$OUT") lines"
