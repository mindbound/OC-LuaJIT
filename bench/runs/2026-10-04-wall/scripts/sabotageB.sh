#!/bin/sh
# sabotageB.sh -- each commit-B sabotage on a copy of B/lj52shim.c, mem_test.B.c against it.
set -u
W=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall
R=/c/Users/astro/Downloads/OC-LuaJIT
. $W/env.sh
OUT=$W/sabB-$1
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p $OUT
LJ=$R/build/native/luajit-windows-x86_64/src
one() { # name sed-expr marker
  d=$OUT/$1; mkdir -p $d
  cp $W/B/lj52shim.c $d/lj52shim.c
  sed -i "$2" $d/lj52shim.c
  grep -q "$3" $d/lj52shim.c || { echo "$1: PATCH DID NOT APPLY"; return; }
  gcc -c -O2 -I$LJ -I$R/native -I$R/serializer -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" $d/lj52shim.c -o $d/lj52shim.o 2>$d/cc.err || { echo "$1: compile failed"; return; }
  sh $W/dbg/build.sh "$W/mem_test.B.c" $d/lj52shim.o $d/mt.exe 2>$d/ld.err || { echo "$1: link failed"; return; }
  (cd $d && timeout 600 ./mt.exe > run.log 2>&1; echo $? > exit.txt)
  echo "$1 exit=$(cat $d/exit.txt) fails=[$(grep '^  FAIL ' $d/run.log | awk '{print $2}' | sort | tr '\n' ' ')]"
}
one nocredit 's|^  c = lj52_gc_odmax(total);$|  return 0;  /* sabotage: no credit */|' 'sabotage: no credit'
one norefusedarm 's|^  else lj52_gc_arm(M, g, used, LJ52_ARM_WALL);$|  else (void)0;  /* sabotage: a refusal does not arm */|' 'sabotage: a refusal does not arm'
one nohyst 's|^  if (!M->gc_hyst) {$|  if (1) {  /* sabotage: no hysteresis */|' 'sabotage: no hysteresis'
one unbounded 's|^  c = lj52_gc_odmax(total);$|  c = total;  /* sabotage: credit = total */|' 'sabotage: credit = total'
one nokslice 's|^  if (lj52_gc_kernel(M, g)) c += LJ52_GC_KSLICE;$|  /* sabotage: no kernel slice */|' 'sabotage: no kernel slice'
one nofresh 's|^  if (!M->gc_hyst \&\& used > total + (lj52_gc_odmax(total) >> 1)) {$|  if (0) {  /* sabotage: no fresh-record reserve */|' 'sabotage: no fresh-record reserve'
one nobackoff 's|^        M->gc_backoff = 1;$|        M->gc_backoff = 0;  /* sabotage: no back-off */|' 'sabotage: no back-off'
one closereserve 's|^      if (used <= total) M->gc_odstate = LJ52_OD_BURST;   /\* repaid \*/$|      M->gc_odstate = LJ52_OD_BURST;  /* sabotage: every proof closes the reserve */|' 'sabotage: every proof closes the reserve'
