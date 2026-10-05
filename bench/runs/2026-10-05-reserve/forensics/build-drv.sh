#!/bin/sh
# build-drv.sh -- the hermetic drivers, on the census's no-ASLR fixed-seed
# link line (errmem/census/build2.sh), against the CURRENT libluajit.a
# (a93f546e, which carries the lj_err_mem fix):
#   bin/orig_plain.exe  lj_repro.c (unchanged)        + obj/plain-additive.o (= W2/lj52shim-additive.o)
#   bin/orig_ref.exe    lj_repro.c (unchanged)        + obj/ref-additive.o   (the instrumented copy)
#   bin/lref_ref.exe    drv/lj_ref.c (mkdrv.py)       + obj/ref-additive.o + drv/wrapcp.c, --wrap=lj_vm_cpcall
#   bin/lref_<x>.exe    the same for obj/<x>.o, for each extra object named on the command line
set -eu
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/forensics
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
OBJ=$REPO/build/native/obj-windows-x86_64
R=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/repro
[ -f "$WD/drv/lj_repro.c" ] || cp "$R/lj_repro.c" "$WD/drv/lj_repro.c"
[ -f "$WD/drv/probe2.lua" ] || cp "$R/probe2.lua" "$WD/drv/probe2.lua"
cmp "$R/lj_repro.c" "$WD/drv/lj_repro.c" && cmp "$R/probe2.lua" "$WD/drv/probe2.lua"
python "$WD/drv/mkdrv.py" "$WD/drv/lj_repro.c" "$WD/drv/lj_ref.c"
FLAGS="-g -O2 -Wall -Wextra -I$LJ -I$WD/src"
LINK="-DFIXSEED -Wl,--wrap=lj_prng_seed_secure -Wl,--disable-dynamicbase,--disable-high-entropy-va"
gcc -c -O2 -Wall -Wextra -I"$LJ" "$WD/drv/wrapcp.c" -o "$WD/obj/wrapcp.o"
build() {  # build <exe> <driver.c> <shim.o> [extra]
  gcc $FLAGS -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" -include "$WD/src/lj52shim.h" $LINK $4 "$2" "$3" $5 "$OBJ/eris_lj.o" "$LJ/libluajit.a" -lm -o "$WD/bin/$1.exe" 2> "$WD/bin/$1.build"
  echo "$1: warnings=$(grep -c 'warning:' "$WD/bin/$1.build" || true) md5=$(md5sum < "$WD/bin/$1.exe" | cut -c1-8)"
}
if [ $# -eq 0 ]; then
  build orig_plain "$WD/drv/lj_repro.c" "$WD/obj/plain-additive.o" "" ""
  build orig_ref   "$WD/drv/lj_repro.c" "$WD/obj/ref-additive.o"   "" ""
  build lref_ref   "$WD/drv/lj_ref.c"   "$WD/obj/ref-additive.o"   "-Wl,--wrap=lj_vm_cpcall" "$WD/obj/wrapcp.o"
else
  for x in "$@"; do
    build "lref_$x" "$WD/drv/lj_ref.c" "$WD/obj/$x.o" "-Wl,--wrap=lj_vm_cpcall" "$WD/obj/wrapcp.o"
  done
fi
