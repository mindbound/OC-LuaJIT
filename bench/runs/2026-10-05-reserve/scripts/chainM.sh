#!/bin/sh
# chainM.sh -- THE RESERVE'S SIZE's native measurements, serial, on the E-cores:
#   M3  mem_test on the final objects: 30 runs additive, 10 dropin (wall2/mt.sh), the fast form once,
#       and the fail-first against THE WINDOW's object once more (the final mem_test.c)
#   M2  the negative control as a MEASUREMENT: every sabotage's actual failing set on the final source
#       (the expected sets in the script are predictions; the log's want/got lines are the data)
set -u
S=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad
SC=$S/wall2/sc; R=$SC/R
A=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/pcore/affrun.exe
SH="C:/Program Files/Git/usr/bin/sh.exe"
REPO=/c/Users/astro/Downloads/OC-LuaJIT
. $S/wall/env.sh
LOG=$R/chainM.log
say() { echo "== $(date -u '+%H:%M:%S') $*" >> $LOG; }
[ -e "$R/mt" ] && { echo "REFUSING: $R/mt exists"; exit 99; }
say "chainM start"
cd $REPO || exit 97
# M3: the final object, 30 + 10, plus the fast form, plus the fail-first on THE WINDOW's object
"$A" 3FC3FC default "$SH" "$(cygpath -m $S/wall2/mt.sh)" "$(cygpath -m $R/mt)" "F:$R/new-lj52shim-additive.o:30" "FL:$R/new-lj52shim-dropin.o:10" "E:$R/old-lj52shim-dropin.o:3" > $R/mt.out 2>&1
say "mt done: $(grep -h 'checks=' $R/mt/*/*.log 2>/dev/null | sort | uniq -c | tr '\n' ';')"
OCLJ_SHIMOBJ=$R/new-lj52shim-additive.o OCLJ_MEMTEST_CFLAGS="-DW16_N=8 -DW16R_N=8" "$A" 3FC3FC default "$SH" test/native/run-mem.sh > $R/mem-fast.log 2>&1
say "fast form: $(grep -E '^checks=' $R/mem-fast.log)"
# M2: the negative control, measured
"$A" 3FC3FC default "$SH" test/native/negative-control.sh > $R/negctl-measure.log 2>&1
say "negctl exit $?: PASS $(grep -c 'RESULT: PASS' $R/negctl-measure.log) FAIL $(grep -c 'RESULT: FAIL' $R/negctl-measure.log)"
say "chainM done"
