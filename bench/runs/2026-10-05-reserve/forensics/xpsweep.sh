#!/bin/sh
# xpsweep.sh <variant> <part>: the JIT-on cells for one experiment variant,
# with OCLJ_REFLOG=1, tags <variant>_<cell>.  part 1: probe2 string, record
# at 4096 caps; part 2: probe2oe string, record, probe2k_2048 string, record,
# probe2 hb3 string at 2048.
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/forensics
cd $WD || exit 1
export OCLJ_REFLOG=1
E=lref_xp-$1-additive.exe
[ -f bin/$E ] || { echo "no bin/$E"; exit 1; }
case $2 in
  1)
    sh census2.sh $E string 1 4096 $1_string_j1 probe2.lua 0
    sh census2.sh $E record 1 4096 $1_record_j1 probe2.lua 0 ;;
  2)
    sh census2.sh $E string 1 2048 $1_oe_string_j1 probe2oe.lua 0
    sh census2.sh $E record 1 2048 $1_oe_record_j1 probe2oe.lua 0
    sh census2.sh $E string 1 2048 $1_k2048_string_j1 probe2k_2048.lua 0
    sh census2.sh $E record 1 2048 $1_k2048_record_j1 probe2k_2048.lua 0
    sh census2.sh $E string 1 2048 $1_hb3_string_j1 probe2.lua 3 ;;
esac
