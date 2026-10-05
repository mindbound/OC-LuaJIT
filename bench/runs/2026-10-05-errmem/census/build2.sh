#!/bin/sh
# build2.sh -- fixed seed AND no ASLR (--disable-dynamicbase), for the identity check:
#   <shim>_unpnf.exe  lj_err from libluajit.a (as shipped)
#   <shim>_ctlnf.exe  obj/lj_err_unp.o (unpatched copy) linked BEFORE libluajit.a -- the fix's link line, no clamp
#   <shim>_fixnf.exe  obj/lj_err_fix.o (patched copy) linked BEFORE libluajit.a
set -eu
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
W2=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2
D=$W2/errmem/census
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
OBJ=$REPO/build/native/obj-windows-x86_64
for shim in verdict window; do
  case $shim in verdict) SO=$W2/j2s/obj/verdict.o ;; window) SO=$W2/W2/lj52shim-additive.o ;; esac
  for lj in unp ctl fix; do
    case $lj in unp) EXTRA= ;; ctl) EXTRA=$D/obj/lj_err_unp.o ;; fix) EXTRA=$D/obj/lj_err_fix.o ;; esac
    gcc -g -O2 -Wall -Wextra -I$LJ -I$REPO/native -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" -include $REPO/native/lj52shim.h \
      -DFIXSEED -Wl,--wrap=lj_prng_seed_secure -Wl,--disable-dynamicbase,--disable-high-entropy-va \
      $W2/repro/lj_repro.c "$SO" $OBJ/eris_lj.o $EXTRA $LJ/libluajit.a -lm -o $D/bin/${shim}_${lj}nf.exe
  done
done
md5sum $D/bin/*nf.exe
