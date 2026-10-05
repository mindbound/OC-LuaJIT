#!/bin/sh
# sabotage.sh -- THE RECIPIENT's negative controls, on COPIES of src-id: each removes
# one rule, and mem_test_id must fail exactly that rule's case.  Writes src-sab-*/ and obj/sab-*.o.
set -eu
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/identify
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
SER=$REPO/serializer
cd "$WD"
sab() {  # sab <name> <sed expression> <marker>
  rm -rf "src-sab-$1"; mkdir -p "src-sab-$1"; cp src-id/lj52shim.h "src-sab-$1/"
  sed "$2" src-id/lj52shim.c > "src-sab-$1/lj52shim.c"
  grep -q "$3" "src-sab-$1/lj52shim.c" || { echo "$1: the sabotage did not apply"; exit 1; }
  gcc -c -O2 -Wall -Wextra -DLJ52_ADDITIVE -I"$LJ" -I"src-sab-$1" -I"$SER" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" \
    "src-sab-$1/lj52shim.c" -o "obj/sab-$1.o" 2> "obj/sab-$1.err" || { cat "obj/sab-$1.err"; exit 1; }
  echo "sab-$1: warnings=$(grep -c 'warning:' obj/sab-$1.err || true) md5=$(md5sum < obj/sab-$1.o | cut -c1-8)"
}
sab norecorder 's|^  if (G2J(g)->state == LJ_TRACE_IDLE) return 0;$|  return 0;  /* sabotage: no refusal is the recorder'"'"'s */|' 'sabotage: no refusal is the recorder'
sab literal    's|^  if (G2J(g)->state == LJ_TRACE_IDLE) return 0;$|  return G2J(g)->state != LJ_TRACE_IDLE;  /* sabotage: the literal predicate */|' 'sabotage: the literal predicate'
sab novmevent  's|^  if (g->hookmask \& HOOK_VMEVENT) return 0;   /\* THE RECIPIENT: as a finalizer \*/$|  /* sabotage: a vmevent handler gets credit */|; s|^  if (g->hookmask \& HOOK_VMEVENT) return;   /\* THE RECIPIENT: as a finalizer \*/$|  /* sabotage: and its refusal opens the reserve */|' 'sabotage: and its refusal opens the reserve'
sab reserveG   's|^  return c < (G >> 1) ? (G >> 1) : c > G ? G : c;$|  (void)c; return G;  /* sabotage: the reserve is G, whatever the refusal point */|' 'sabotage: the reserve is G'
sab nostrtab   's|^    M->gc_refstrtab++;$|    (void)0;  /* sabotage: doublings not counted */|' 'sabotage: doublings not counted'
