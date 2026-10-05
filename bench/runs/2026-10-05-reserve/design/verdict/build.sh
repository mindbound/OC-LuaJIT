#!/bin/sh
# build.sh -- the "verdict" prototype (THE ADDRESS):
#   src-v/     = the repo's lj52shim.c (9b912f60) + tools/mkverdict.py
#   src-vref/  = the forensics' instrumented copy (33edc64b) + mkverdict.py ref
# compiled exactly as build-native.sh stage 2 compiles (both variants for
# src-v, additive for src-vref), warning-clean asserted; build-native.sh's
# source gates on src-v; then the drivers on the census's no-ASLR fixed-seed
# link line:
#   bin/orig_v.exe     lj_repro.c + obj/v-additive.o        (identity against forensics/bin/orig_plain.exe)
#   bin/lref_vref.exe  lj_ref.c + obj/vref-additive.o + wrapcp.o, --wrap=lj_vm_cpcall (the census)
# Writes into this directory only.
set -eu
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/verdict
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
OBJ=$REPO/build/native/obj-windows-x86_64
SER=$REPO/serializer
cp "$WD/src-plain/lj52shim.h" "$WD/src-v/lj52shim.h"
cp "$WD/src-ref/lj52shim.h" "$WD/src-vref/lj52shim.h"
python "$WD/tools/mkverdict.py" "$WD/src-plain/lj52shim.c" "$WD/src-v/lj52shim.c"
python "$WD/tools/mkverdict.py" "$WD/src-ref/lj52shim.c" "$WD/src-vref/lj52shim.c" ref
printf 'CR count: src-v %s, src-vref %s\n' "$(tr -cd '\r' < "$WD/src-v/lj52shim.c" | wc -c)" "$(tr -cd '\r' < "$WD/src-vref/lj52shim.c" | wc -c)"
cc1() {  # cc1 <srcdir> <tag> <variant>
  case $3 in additive) D=-DLJ52_ADDITIVE ;; dropin) D= ;; esac
  gcc -c -O2 -Wall -Wextra $D -I"$LJ" -I"$1" -I"$SER" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" \
    "$1/lj52shim.c" -o "$WD/obj/$2-$3.o" 2> "$WD/obj/$2-$3.err"
  w=$(grep -c 'warning:' "$WD/obj/$2-$3.err" || true)
  e=$(grep -c 'error:' "$WD/obj/$2-$3.err" || true)
  echo "$2-$3: warnings=$w errors=$e md5=$(md5sum < "$WD/obj/$2-$3.o" | cut -c1-8)"
  [ "$w" = 0 ] && [ "$e" = 0 ] || { cat "$WD/obj/$2-$3.err"; exit 1; }
}
cc1 "$WD/src-v" v additive
cc1 "$WD/src-v" v dropin
cc1 "$WD/src-vref" vref additive
cc1 "$WD/src-vref" vref dropin
# build-native.sh's source gates, by its own codegrep, on the shippable copy
codegrep() { grep -nE "$1" "$WD/src-v/lj52shim.c" "$WD/src-v/lj52shim.h" 2>/dev/null | grep -vE ':[0-9]+: *([*]|/[*]|//)'; }
bad=0
for tok in OCLJ_NOMODECHECK LJ52_DROP_LOAD_MODE OCLJ_TRACE OCLJ_JITOFF OCLJ_JITOPT \
           OCLJ_JITATTACH LJ52_MEMLIMIT LJ52_NO_ALLOC_FIX LJ52_NO_RIDX \
           LJ52_NO_CFCACHE SHIM_ALLOC_NEUTERED SHIM_ALLOC_FAITHFUL LJ52_NOJIT; do
  if codegrep "$tok" | grep -q .; then echo "GATE escape hatch $tok"; bad=1; fi
done
if codegrep 'lj_gc_fullgc|lj_gc_step|luaC_|lua_gc *\(|LUA_GCCOLLECT|LUA_GCSTEP' | grep -q .; then echo "GATE collector"; bad=1; fi
if codegrep getenv | grep -q .; then echo "GATE getenv"; bad=1; fi
echo "source gates on src-v: $([ $bad = 0 ] && echo pass || echo FAIL)"
# the diff against the repo source, for the design document
diff -u "$WD/src-plain/lj52shim.c" "$WD/src-v/lj52shim.c" > "$WD/verdict-shim.diff" || true
echo "diff: $(grep -c '^+' "$WD/verdict-shim.diff") added, $(grep -c '^-' "$WD/verdict-shim.diff") removed lines (headers included)"
# the drivers
FLAGS="-g -O2 -Wall -Wextra -I$LJ -I$WD/src-vref"
LINK="-DFIXSEED -Wl,--wrap=lj_prng_seed_secure -Wl,--disable-dynamicbase,--disable-high-entropy-va"
gcc -c -O2 -Wall -Wextra -I"$LJ" "$WD/drv/wrapcp.c" -o "$WD/obj/wrapcp.o"
build() {  # build <exe> <driver.c> <shim.o> <incdir> [extra] [extraobj]
  gcc $FLAGS -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" -include "$4/lj52shim.h" $LINK ${5:-} "$2" "$3" ${6:-} "$OBJ/eris_lj.o" "$LJ/libluajit.a" -lm -o "$WD/bin/$1.exe" 2> "$WD/bin/$1.build"
  echo "$1: warnings=$(grep -c 'warning:' "$WD/bin/$1.build" || true) md5=$(md5sum < "$WD/bin/$1.exe" | cut -c1-8)"
}
build orig_v    "$WD/drv/lj_repro.c" "$WD/obj/v-additive.o"    "$WD/src-v"
build lref_vref "$WD/drv/lj_ref.c"   "$WD/obj/vref-additive.o" "$WD/src-vref" "-Wl,--wrap=lj_vm_cpcall" "$WD/obj/wrapcp.o"
md5sum "$WD/src-v/lj52shim.c" "$WD/src-vref/lj52shim.c"
