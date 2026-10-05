#!/bin/sh
# shipcheck.sh -- the census's patched side, rebuilt on the SHIPPED libluajit.a (lj_err.o from
# native/luajit/patch-fastfunc-errmem-top.sh via build-native.sh, a93f546e), same shim (the
# rejected verdict design's, where the crash was frequent), fixed seed, no ASLR: every cap's
# whole output line must equal the census's verdict_fixnf run (the investigator's else-if form).
set -eu
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
W2=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2
D=$W2/errmem/census
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
OBJ=$REPO/build/native/obj-windows-x86_64
md5sum $LJ/libluajit.a
[ -e $D/bin/verdict_shipnf.exe ] && { echo "exists: verdict_shipnf.exe"; exit 1; }
gcc -g -O2 -Wall -Wextra -I$LJ -I$REPO/native -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" -include $REPO/native/lj52shim.h \
  -DFIXSEED -Wl,--wrap=lj_prng_seed_secure -Wl,--disable-dynamicbase,--disable-high-entropy-va \
  $W2/repro/lj_repro.c $W2/j2s/obj/verdict.o $OBJ/eris_lj.o $LJ/libluajit.a -lm -o $D/bin/verdict_shipnf.exe
objdump -d --no-show-raw-insn $D/bin/verdict_shipnf.exe | awk '/<lj_err_mem>:/,/^$/' | grep -c 'cmp    %rdx,0x28(%rbx)'
