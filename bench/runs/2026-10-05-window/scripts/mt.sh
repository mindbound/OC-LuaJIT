#!/bin/sh
# mt.sh <outdir> <tag:object:runs> ... -- the repo's mem_test.c linked against each object
# (run-mem.sh's own line), then run N times (each process draws a fresh string-hash seed).
set -u
W=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall
REPO=/c/Users/astro/Downloads/OC-LuaJIT
. $W/env.sh
OUT=$1; shift
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT"
for spec in "$@"; do
  tag=${spec%%:*}; rest=${spec#*:}; obj=${rest%%:*}; n=${rest##*:}
  B=$OUT/build-$tag; mkdir -p $B
  cp -r $REPO/build/native/luajit-windows-x86_64 $B/ 2>/dev/null
  mkdir -p $B/obj-windows-x86_64 && cp $REPO/build/native/obj-windows-x86_64/eris_lj.o $B/obj-windows-x86_64/
  OCLJ_BUILD=$B OCLJ_SHIMOBJ=$obj sh $REPO/test/native/run-mem.sh > $OUT/$tag-1.log 2>&1
  echo "$tag $(md5sum < $obj | cut -c1-8) run 1: $(tail -1 $OUT/$tag-1.log)" >> $OUT/summary.txt
  i=2
  while [ $i -le $n ]; do
    $B/mem_test.exe > $OUT/$tag-$i.log 2>&1
    echo "$tag run $i: $(tail -1 $OUT/$tag-$i.log)" >> $OUT/summary.txt
    i=$((i+1))
  done
  echo "$tag failing sets:" >> $OUT/summary.txt
  for f in $OUT/$tag-*.log; do grep -o '^  FAIL  [A-Za-z0-9]*' $f | awk '{print $2}' | tr '\n' ' '; echo; done | sort | uniq -c >> $OUT/summary.txt
done
echo DONE >> $OUT/summary.txt
