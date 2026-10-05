#!/bin/sh
# build-shim.sh -- make the instrumented copy and compile it, and the plain
# copy, exactly as build-native.sh stage 2 compiles lj52shim.c:
#   gcc -c -O2 $PICFLAG -Wall -Wextra [-DLJ52_ADDITIVE] -I$LJ -I$SHIM -I$SER -I$JNI -I$JNI/win32
# for BOTH variants, and asserts warning-clean; then runs build-native.sh's
# source gates (escape hatches, the collector gate, the environment gate) on
# the instrumented copy, by the same codegrep.  Writes into this directory only.
set -eu
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/forensics
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
SER=$REPO/serializer
python "$WD/tools/mkref.py" "$WD/src-plain/lj52shim.c" "$WD/src/lj52shim.c"
cmp -s "$WD/src-plain/lj52shim.h" "$WD/src/lj52shim.h" || { echo "header differs"; exit 1; }
printf 'CR count in src/lj52shim.c: %s\n' "$(tr -cd '\r' < "$WD/src/lj52shim.c" | wc -c)"
for kind in plain ref; do
  case $kind in plain) S=$WD/src-plain ;; ref) S=$WD/src ;; esac
  for v in additive dropin; do
    case $v in additive) D=-DLJ52_ADDITIVE ;; dropin) D= ;; esac
    gcc -c -O2 -Wall -Wextra $D -I"$LJ" -I"$S" -I"$SER" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" \
      "$S/lj52shim.c" -o "$WD/obj/$kind-$v.o" 2> "$WD/obj/$kind-$v.err"
    w=$(grep -c 'warning:' "$WD/obj/$kind-$v.err" || true)
    e=$(grep -c 'error:' "$WD/obj/$kind-$v.err" || true)
    echo "$kind-$v: warnings=$w errors=$e md5=$(md5sum < "$WD/obj/$kind-$v.o" | cut -c1-8)"
    [ "$w" = 0 ] && [ "$e" = 0 ] || { cat "$WD/obj/$kind-$v.err"; exit 1; }
  done
done
# build-native.sh's source gates, by its own codegrep, on the instrumented copy
codegrep() { grep -nE "$1" "$WD/src/lj52shim.c" "$WD/src/lj52shim.h" 2>/dev/null | grep -vE ':[0-9]+: *([*]|/[*]|//)'; }
bad=0
for tok in OCLJ_NOMODECHECK LJ52_DROP_LOAD_MODE OCLJ_TRACE OCLJ_JITOFF OCLJ_JITOPT \
           OCLJ_JITATTACH LJ52_MEMLIMIT LJ52_NO_ALLOC_FIX LJ52_NO_RIDX \
           LJ52_NO_CFCACHE SHIM_ALLOC_NEUTERED SHIM_ALLOC_FAITHFUL LJ52_NOJIT; do
  if codegrep "$tok" | grep -q .; then echo "GATE escape hatch $tok"; bad=1; fi
done
if codegrep 'lj_gc_fullgc|lj_gc_step|luaC_|lua_gc *\(|LUA_GCCOLLECT|LUA_GCSTEP' | grep -q .; then echo "GATE collector"; bad=1; fi
if codegrep getenv | grep -q .; then echo "GATE getenv"; bad=1; fi
echo "source gates: $([ $bad = 0 ] && echo pass || echo FAIL)"
# the -include form too (jnlua.c's and mem_test.c's way of seeing the header)
gcc -c -O2 -Wall -Wextra -DLJ52_ADDITIVE -I"$LJ" -I"$WD/src" -I"$SER" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" \
  -include "$WD/src/lj52shim.h" "$WD/src/lj52shim.c" -o "$WD/obj/ref-additive-inc.o" 2> "$WD/obj/ref-additive-inc.err"
echo "ref-additive with -include lj52shim.h: warnings=$(grep -c 'warning:' "$WD/obj/ref-additive-inc.err" || true) errors=$(grep -c 'error:' "$WD/obj/ref-additive-inc.err" || true)"
md5sum "$WD/src-plain/lj52shim.c" "$WD/src/lj52shim.c" "$WD/src/lj52shim.h"
