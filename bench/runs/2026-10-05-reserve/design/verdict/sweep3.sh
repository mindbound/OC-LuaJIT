#!/bin/sh
# sweep.sh -- the hermetic measurement of the verdict prototype (lref_vref.exe,
# OCLJ_REFLOG=1), the forensics' cells, tags V3_<cell>: probe2 string/record
# JIT on at 4096 caps (the baseline L4_*_j1's size) and JIT off at 1024
# (the first quarter of L4_*_j0); probe2oe string/record and probe2k_2048
# string/record at 2048 (the baseline X_*).  Bounded: eight cells.
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/verdict
cd $WD || exit 1
export OCLJ_REFLOG=1
E=lref_vref.exe
date
sh census2.sh $E string 1 4096 V3_string_j1 probe2.lua 0
sh census2.sh $E record 1 4096 V3_record_j1 probe2.lua 0
sh census2.sh $E string 0 1024 V3_string_j0 probe2.lua 0
sh census2.sh $E record 0 1024 V3_record_j0 probe2.lua 0
sh census2.sh $E string 1 2048 V3_oe_string_j1 probe2oe.lua 0
sh census2.sh $E record 1 2048 V3_oe_record_j1 probe2oe.lua 0
sh census2.sh $E string 1 2048 V3_k2048_string_j1 probe2k_2048.lua 0
sh census2.sh $E record 1 2048 V3_k2048_record_j1 probe2k_2048.lua 0
date
echo SWEEP-DONE
