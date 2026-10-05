#!/bin/sh
# build.sh -- the A/B drivers for the lj_err_mem stale-top fix.
#   obj/lj_err_unp.o   a copy of the build copy's lj_err.c, unpatched, Makefile flags
#   obj/lj_err_fix.o   the same copy run through patch-fastfunc-errmem-top.sh
#   obj/lj_err_arc.o   the archive's own member (ar x), for the reproduction check
#   bin/<shim>_<lj>[f].exe   shim in {verdict, window}, lj in {unp, fix};
#                            "f" = fixed seed (FIXSEED, OCLJ_SEED default 1)
# unp drivers link NOTHING extra: lj_err comes from libluajit.a as shipped.
# fix drivers link obj/lj_err_fix.o BEFORE libluajit.a, so it overrides the member.
set -eu
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
W2=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2
D=$W2/errmem/census
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
OBJ=$REPO/build/native/obj-windows-x86_64
VERDICT=$W2/j2s/obj/verdict.o
WINDOW=$W2/W2/lj52shim-additive.o
mkdir -p $D/obj $D/bin $D/src

cp $LJ/lj_err.c $D/src/lj_err_unp.c
sh $W2/crash/patch-fastfunc-errmem-top.sh $D/src/lj_err_unp.c $D/src/lj_err_fix.c
LJFLAGS="-O2 -fomit-frame-pointer -Wall -DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_CHECKHOOK -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -U_FORTIFY_SOURCE"
gcc $LJFLAGS -I$LJ -c -o $D/obj/lj_err_unp.o $D/src/lj_err_unp.c
gcc $LJFLAGS -I$LJ -c -o $D/obj/lj_err_fix.o $D/src/lj_err_fix.c
( cd $D/obj && ar x $LJ/libluajit.a lj_err.o && mv lj_err.o lj_err_arc.o )

for shim in verdict window; do
  case $shim in verdict) SO=$VERDICT ;; window) SO=$WINDOW ;; esac
  for lj in unp fix; do
    case $lj in unp) EXTRA= ;; fix) EXTRA=$D/obj/lj_err_fix.o ;; esac
    gcc -g -O2 -Wall -Wextra -I$LJ -I$REPO/native -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" -include $REPO/native/lj52shim.h \
      $W2/repro/lj_repro.c "$SO" $OBJ/eris_lj.o $EXTRA $LJ/libluajit.a -lm -o $D/bin/${shim}_${lj}.exe
    gcc -g -O2 -Wall -Wextra -I$LJ -I$REPO/native -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" -include $REPO/native/lj52shim.h \
      -DFIXSEED -Wl,--wrap=lj_prng_seed_secure \
      $W2/repro/lj_repro.c "$SO" $OBJ/eris_lj.o $EXTRA $LJ/libluajit.a -lm -o $D/bin/${shim}_${lj}f.exe
  done
done
cp $W2/repro/probe2.lua $D/probe2.lua
md5sum $VERDICT $WINDOW $LJ/libluajit.a $W2/repro/lj_repro.c $D/probe2.lua $D/obj/*.o $D/bin/*.exe
