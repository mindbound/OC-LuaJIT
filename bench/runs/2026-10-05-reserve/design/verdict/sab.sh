#!/bin/sh
# sab.sh -- THE ADDRESS's negative controls: one exact-line sabotage each on
# src-v/lj52shim.c (negative-control.sh's sabotage_mem shape: sed, the marker
# asserted present, gcc -c -O2 without -Wall and without -DLJ52_ADDITIVE as
# build_variant_mem compiles), linked with mem_test_v.c, run pinned.  Each must
# fail EXACTLY its expected set.  Also the one existing anchor this design
# moves (4.19 refusalkeeps), re-anchored, and 4.23 noverdict unchanged.
# Writes sab/ only; refuses to overwrite a variant already run.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/verdict
A=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/pcore/affrun.exe
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
OBJ=$REPO/build/native/obj-windows-x86_64
SER=$REPO/serializer
S=$WD/sab6
mkdir -p "$S"
run_one() {  # run_one <name> <sed-expr> <marker> <expected...>
  name=$1; expr=$2; marker=$3; shift 3
  [ -e "$S/$name/out.txt" ] && { echo "$name: already run (not overwriting)"; return; }
  mkdir -p "$S/$name"
  cp "$WD/src-v/lj52shim.h" "$S/$name/"
  sed "$expr" "$WD/src-v/lj52shim.c" > "$S/$name/lj52shim.c"
  if ! grep -qF "$marker" "$S/$name/lj52shim.c"; then echo "$name: SABOTAGE DID NOT APPLY"; return; fi
  gcc -c -O2 -I"$LJ" -I"$S/$name" -I"$SER" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" "$S/$name/lj52shim.c" -o "$S/$name/lj52shim.o" 2> "$S/$name/cc.err" || { echo "$name: compile failed"; cat "$S/$name/cc.err"; return; }
  gcc -O2 -I"$LJ" -I"$S/$name" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" -include "$S/$name/lj52shim.h" \
    "$WD/mem_test_v.c" "$S/$name/lj52shim.o" "$OBJ/eris_lj.o" "$LJ/libluajit.a" -lm -o "$S/$name/mem_test.exe" 2> "$S/$name/ld.err" || { echo "$name: link failed"; cat "$S/$name/ld.err"; return; }
  "$A" 3FC3FC default "$S/$name/mem_test.exe" > "$S/$name/out.txt" 2> "$S/$name/err.txt"
  got=$(grep '^  FAIL' "$S/$name/out.txt" | sed 's/^  FAIL  \([A-Za-z0-9]*\).*/\1/' | sort | tr '\n' ' ')
  exp=$(printf '%s\n' "$@" | sort | tr '\n' ' ')
  if [ "$got" = "$exp" ]; then v=PASS; else v=MISMATCH; fi
  echo "$name: $v  expected [$exp] got [$got]  ($(grep -E '^checks=' "$S/$name/out.txt"))"
}
# the design's own rules: each "what must fail without it"
run_one noaddress 's|^  M->gc_addr = !M->gc_rec \&\& M->gc_handL == (const void \*)L \&\& M->gc_hand == id;$|  M->gc_addr = 1;  /* sabotage: everyone is the addressee */|' 'sabotage: everyone is the addressee' W20 W21 W22 W25
run_one servesall 's|^  if (M->gc_win == 2 \&\& M->gc_low > top \&\& !M->gc_addr)  /\* THE ADDRESS: another.s crossing \*/$|  if (0)  /* sabotage: the verdict serves anyone */|' 'sabotage: the verdict serves anyone' W20 W21 W22 W25
run_one recopens 's|^  if (!M->gc_rec) {                     /\* THE ADDRESS: not the recorder.s own \*/$|  if (1) {  /* sabotage: the recorder opens the reserve */|' 'sabotage: the recorder opens the reserve' W21
run_one norecorder 's|^  M->gc_rec = G2J(g)->state != LJ_TRACE_IDLE \&\& g->vmstate < 0 \&\& g->vmstate != ~LJ_VMST_C$|  M->gc_rec = 0 \&\& G2J(g)->state != LJ_TRACE_IDLE \&\& g->vmstate < 0 \&\& g->vmstate != ~LJ_VMST_C  /* sabotage: no recorder */|' 'sabotage: no recorder' W21
run_one novote 's|^  else if (M->gc_handn > 0) M->gc_handn--;$|  else if (M->gc_handn > 0) (void)0;  /* sabotage: the first handler keeps the address */|' 'sabotage: the first handler keeps the address' W23
run_one noholdroom 's|^  long long room = LJ52_GC_LEND + (M->gc_odstate == LJ52_OD_RESERVE ? 0 : LJ52_GC_HOLD);$|  long long room = LJ52_GC_LEND;  /* sabotage: no room past the window */|' 'sabotage: no room past the window' W21 W22 W25
run_one nokernelhold 's|^    c += LJ52_GC_HOLD;                  /\* THE ADDRESS: the slice past the hold \*/$|    c += 0;  /* sabotage: the kernel keeps no room past the hold */|' 'sabotage: the kernel keeps no room past the hold' W22
run_one demote 's|^                 : (M->gc_win == 2 \|\| used - M->gc_grown > top) ? 2 : 1;   /\* verdict stands \*/$|                 : used - M->gc_grown > top ? 2 : 1;  /* sabotage: a proof demotes a standing verdict */|' 'sabotage: a proof demotes a standing verdict' W25
# 4.17 rawverdict, re-anchored on the proof's two lines (expected set as negative-control.sh has it)
run_one rawverdict 's|^        M->gc_win = used <= top ? 0                       /\* THE ADDRESS: a standing \*/$|        M->gc_win = used <= top ? 0 : 2;  /* sabotage: the verdict on the raw heap */|; s|^                 : (M->gc_win == 2 \|\| used - M->gc_grown > top) ? 2 : 1;   /\* verdict stands \*/$|                 ;|' 'sabotage: the verdict on the raw heap' W16 W16L
# the re-anchored existing sabotage, and the unchanged one.  Expected sets RE-SCOPED:
#   refusalkeeps: W16Rj/W16RjL no longer fail -- the between-step allocation after the
#   fill's own caught refusal is another handler's, so a standing verdict is HELD for it
#   rather than refusing it (the hold rescues the landing); W19 still fails.
#   noverdict: W23 asserts the verdict's placement (within half the window), so it fails too.
run_one refusalkeeps 's|^    M->gc_win = 0;                      /\* THE WINDOW: its cycle decides anew \*/$|    /* sabotage: a refusal keeps the window */|' 'sabotage: a refusal keeps the window' W19
run_one noverdict 's#^  if (M->gc_win == 2 \&\& M->gc_low > top) return 0;      /\* the verdict \*/$#  /* sabotage: no verdict */#' 'sabotage: no verdict' W17 W23
