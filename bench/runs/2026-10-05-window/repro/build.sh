#!/bin/sh
# build.sh -- link lj_repro.c the way run-mem.sh links mem_test.c:
#   -include lj52shim.h, the given lj52shim.o, the build's eris_lj.o and libluajit.a.
#   lj_repro_C.exe  the stage-C object (objC/lj52shim.o, md5 0259f0d1)
#   lj_repro_I.exe  the instrumented copy (shim_instr.o, mkinstr.py), -DINSTR
set -eu
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
R=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/repro
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
OBJ=$REPO/build/native/obj-windows-x86_64
SHIMC=$R/../objC/lj52shim.o
echo "stage-C object: $(md5sum < "$SHIMC" | cut -c1-32)"
for v in C I Cf If; do
  case $v in
    C)  SO=$SHIMC; DEF= ;;
    I)  SO=$R/shim_instr.o; DEF=-DINSTR ;;
    Cf) SO=$SHIMC; DEF="-DFIXSEED -Wl,--wrap=lj_prng_seed_secure" ;;
    If) SO=$R/shim_instr.o; DEF="-DINSTR -DFIXSEED -Wl,--wrap=lj_prng_seed_secure" ;;
  esac
  gcc -O2 -Wall -Wextra -I"$LJ" -I"$REPO/native" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" \
    -include "$REPO/native/lj52shim.h" $DEF \
    "$R/${1:-lj_repro}.c" "$SO" "$OBJ/eris_lj.o" "$LJ/libluajit.a" -lm -o "$R/${1:-lj_repro}_$v.exe"
done
ls -la "$R"/${1:-lj_repro}_*.exe
