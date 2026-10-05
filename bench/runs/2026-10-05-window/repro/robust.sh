#!/bin/sh
# robust.sh -- each chosen (shape, off): the fixed-seed stage-C binary twice
# (determinism), the instrumented one once (the refused request), then the
# random-seed stage-C binary N times (how the outcome depends on the string-
# hash seed, as an unwrapped mem_test would see it).
R=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/repro
cd "$R" || exit 1
N=${N:-20}
for so in record:10816 record:10864 record:10928 array:11728 array:11776 array:11904 \
          string:224 string:288 string:384 closure:6928 closure:6976 closure:7088; do
  s=${so%:*}; o=${so#*:}
  a=$(./lj_repro_Cf.exe probe2.lua $s $o $o 16 384 0 1 1 0 0 -1 | tail -1 | cut -f1-11,24-26,31)
  b=$(./lj_repro_Cf.exe probe2.lua $s $o $o 16 384 0 1 1 0 0 -1 | tail -1 | cut -f1-11,24-26,31)
  i=$(./lj_repro_If.exe probe2.lua $s $o $o 16 384 0 1 1 0 0 -1 | tail -1 | cut -f7,12,13,16,17,18)
  same=$([ "$a" = "$b" ] && echo identical || echo DIFFER)
  r=""
  k=0
  while [ $k -lt $N ]; do
    r="$r $(./lj_repro_C.exe probe2.lua $s $o $o 16 384 0 1 1 0 0 -1 | tail -1 | cut -f7)"
    k=$((k + 1))
  done
  echo "$s off=$o seed1: [$a] x2 $same | instr(term delta ref_used top tier armed): $i | random seeds term:$r"
done
