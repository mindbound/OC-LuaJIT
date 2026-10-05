#!/bin/sh
# build.sh -- finst: the instrumented copy of the FINAL lj52shim.c (THE
# RESERVE'S SIZE, md5 28a8f091), its inertness objects and the hermetic
# drivers.  Writes only into this directory; reads the repo.
#   1. tools/frag-from-forensics.py, tools/mkref.py  -> src/lj52shim.c (+ the repo's header, copied)
#   2. build-native.sh stage 2's line (-c -O2 -Wall -Wextra [-DLJ52_ADDITIVE] -I LJ -I shim -I SER -I JNI -I JNI/win32),
#      both variants, PLAIN from the repo's native/ and INSTRUMENTED from src/, asserted warning-clean;
#      the plain objects cmp'd against sc/R/new-lj52shim-{additive,dropin}.o (= the shipped objects)
#   3. build-native.sh's source gates (escape hatches, collector, getenv) on src/, by its own codegrep
#   4. the drivers, on the forensics' link line (-DFIXSEED, --wrap=lj_prng_seed_secure, no ASLR), against the
#      CURRENT libluajit.a and eris_lj.o:
#        bin/orig_plain.exe  lj_repro.c + obj/plain-additive.o              (the forensics' plain driver)
#        bin/orig_ref.exe    lj_repro.c + obj/ref-additive.o                (instrumented, log off unless OCLJ_REFLOG)
#        bin/lref_F.exe      lj_ref.c + obj/ref-additive.o + wrapcp.o, --wrap=lj_vm_cpcall   (THE FINAL, instrumented)
#        bin/lref_E.exe      lj_ref.c + sc/forensics/obj/ref-additive.o (THE WINDOW's shim, instrumented) + wrapcp.o,
#                            relinked against the CURRENT libluajit.a (the forensics' lref_ref.exe was linked
#                            against a93f546e; the errmem-top patch has landed since): the lib confound's control
#        bin/lref_ref.exe    a COPY of sc/forensics/bin/lref_ref.exe (83a4f083), the baselines' own binary
# Every executable that runs here is gcc/python/cmp (tools); nothing is measured.
set -eu
S=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad
. $S/wall/env.sh
WD=$S/wall2/sc/finst
FO=$S/wall2/sc/forensics
R=$S/wall2/sc/R
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
OBJ=$REPO/build/native/obj-windows-x86_64
SER=$REPO/serializer
cd "$WD"
mkdir -p src obj bin out logs
echo "== 1. the instrumented copy"
python tools/frag-from-forensics.py
python tools/mkref.py "$REPO/native/lj52shim.c" src/lj52shim.c
cp "$REPO/native/lj52shim.h" src/lj52shim.h
cmp "$FO/src/lj52shim.h" src/lj52shim.h && echo "header: the forensics' copy, unchanged"
printf 'CR count in src/lj52shim.c: %s\n' "$(tr -cd '\r' < src/lj52shim.c | wc -c)"
echo "== 2. build-native.sh stage 2's line, both variants, plain and instrumented"
cc1() {  # cc1 <srcdir> <out.o> <defines>
  gcc -c -O2 -Wall -Wextra $3 -I"$LJ" -I"$1" -I"$SER" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" "$1/lj52shim.c" -o "$2" 2> "$2.err"
  w=$(grep -c 'warning:' "$2.err" || true); e=$(grep -c 'error:' "$2.err" || true)
  echo "$(basename $2): warnings=$w errors=$e md5=$(md5sum < "$2" | cut -c1-8)"
  [ "$w" = 0 ] && [ "$e" = 0 ] || { cat "$2.err"; exit 1; }
}
cc1 "$REPO/native" obj/plain-additive.o -DLJ52_ADDITIVE
cc1 "$REPO/native" obj/plain-dropin.o ""
cc1 src obj/ref-additive.o -DLJ52_ADDITIVE
cc1 src obj/ref-dropin.o ""
# the -include form too (jnlua.c's and mem_test.c's way of seeing the header)
gcc -c -O2 -Wall -Wextra -DLJ52_ADDITIVE -I"$LJ" -Isrc -I"$SER" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" \
  -include src/lj52shim.h src/lj52shim.c -o obj/ref-additive-inc.o 2> obj/ref-additive-inc.o.err
echo "ref-additive with -include lj52shim.h: warnings=$(grep -c 'warning:' obj/ref-additive-inc.o.err || true) errors=$(grep -c 'error:' obj/ref-additive-inc.o.err || true)"
echo "== 2b. INERTNESS 1: the plain objects against sc/R's (the shipped objects)"
same=1
for v in additive dropin; do
  if cmp -s "obj/plain-$v.o" "$R/new-lj52shim-$v.o"; then echo "plain-$v.o == R/new-lj52shim-$v.o  (byte-identical)"
  else echo "plain-$v.o DIFFERS from R/new-lj52shim-$v.o"; same=0; fi
done
[ $same = 1 ] || echo "WARNING: the compile line does not reproduce the shipped objects"
echo "== 3. build-native.sh's source gates on src/ (its codegrep)"
codegrep() { grep -nE "$1" src/lj52shim.c src/lj52shim.h 2>/dev/null | grep -vE ':[0-9]+: *([*]|/[*]|//)'; }
bad=0
for tok in OCLJ_NOMODECHECK LJ52_DROP_LOAD_MODE OCLJ_TRACE OCLJ_JITOFF OCLJ_JITOPT \
           OCLJ_JITATTACH LJ52_MEMLIMIT LJ52_NO_ALLOC_FIX LJ52_NO_RIDX \
           LJ52_NO_CFCACHE SHIM_ALLOC_NEUTERED SHIM_ALLOC_FAITHFUL LJ52_NOJIT; do
  if codegrep "$tok" | grep -q .; then echo "GATE escape hatch $tok"; bad=1; fi
done
if codegrep 'lj_gc_fullgc|lj_gc_step|luaC_|lua_gc *\(|LUA_GCCOLLECT|LUA_GCSTEP' | grep -q .; then echo "GATE collector"; bad=1; fi
if codegrep getenv | grep -q .; then echo "GATE getenv"; bad=1; fi
echo "source gates on src/: $([ $bad = 0 ] && echo pass || echo FAIL)"
[ $bad = 0 ]
echo "== 4. the drivers (the forensics' link line; the CURRENT libluajit.a $(md5sum < "$LJ/libluajit.a" | cut -c1-8), eris_lj.o $(md5sum < "$OBJ/eris_lj.o" | cut -c1-8))"
gcc -c -O2 -Wall -Wextra -I"$LJ" "$FO/drv/wrapcp.c" -o obj/wrapcp.o
LINK="-DFIXSEED -Wl,--wrap=lj_prng_seed_secure -Wl,--disable-dynamicbase,--disable-high-entropy-va"
build() {  # build <exe> <driver.c> <shim.o> <shimdir> <extra link> <extra obj>
  gcc -g -O2 -Wall -Wextra -I"$LJ" -I"$4" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" -include "$4/lj52shim.h" $LINK $5 \
    "$2" "$3" $6 "$OBJ/eris_lj.o" "$LJ/libluajit.a" -lm -o "bin/$1.exe" 2> "bin/$1.build"
  echo "$1: warnings=$(grep -c 'warning:' "bin/$1.build" || true) md5=$(md5sum < "bin/$1.exe" | cut -c1-8)"
}
build orig_plain "$FO/drv/lj_repro.c" obj/plain-additive.o     "$REPO/native" "" ""
build orig_ref   "$FO/drv/lj_repro.c" obj/ref-additive.o       src            "" ""
build lref_F     "$FO/drv/lj_ref.c"   obj/ref-additive.o       src            "-Wl,--wrap=lj_vm_cpcall" obj/wrapcp.o
build lref_E     "$FO/drv/lj_ref.c"   "$FO/obj/ref-additive.o" "$FO/src"      "-Wl,--wrap=lj_vm_cpcall" obj/wrapcp.o
cp "$FO/bin/lref_ref.exe" bin/lref_ref.exe
echo "lref_ref: copied, md5=$(md5sum < bin/lref_ref.exe | cut -c1-8) (want 83a4f083)"
echo "== md5s"
md5sum "$REPO/native/lj52shim.c" "$REPO/native/lj52shim.h" src/lj52shim.c src/lj52shim.h tools/*.c tools/*.py obj/*.o bin/*.exe "$LJ/libluajit.a" "$OBJ/eris_lj.o" | tee logs/md5.txt
