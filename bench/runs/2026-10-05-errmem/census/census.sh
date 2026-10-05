#!/bin/sh
# census.sh <exe> <shape> <ncaps> <tag> [seed]: offsets 0,16,...,16*(ncaps-1) at capk 384,
# one process per cap (job.sh), 8 at a time.  Output out/<tag>.tsv (refuses to overwrite).
D=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/errmem/census
OUT=$D/out/$4.tsv
mkdir -p $D/out
[ -e "$OUT" ] && { echo "census.sh: $OUT exists; not overwriting" >&2; exit 1; }
n=$3
[ "$n" -ge 1 ] && [ "$n" -le 8192 ] || { echo "census.sh: ncaps out of bounds" >&2; exit 2; }
i=0
while [ $i -lt $n ]; do echo $((i*16)); i=$((i+1)); done | xargs -P 8 -I{} sh $D/job.sh $1 $2 {} ${5:-} | cat > $OUT
echo "$4: $(wc -l < $OUT) lines"
