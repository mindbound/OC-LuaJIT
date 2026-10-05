#!/bin/sh
# build.sh [variant ...] -- design "lifetime": make each variant's sources
# (mklt.py over the repo's lj52shim.c = src-plain/, and over the forensics'
# instrumented copy), compile them exactly as build-native.sh stage 2 does
# (both variants, asserted warning-clean), run build-native.sh's source
# gates on the PLAIN copies, and link the hermetic driver bin/lref_lt-<v>.exe
# (the forensics' lj_ref.c + wrapcp.c, --wrap=lj_vm_cpcall, no ASLR, fixed
# seed) against the instrumented object.  Default variants: R0 R1K R4K R8K L4.
# Writes only into this directory.
set -eu
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/design/lifetime
FO=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/forensics
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
OBJ=$REPO/build/native/obj-windows-x86_64
SER=$REPO/serializer
[ $# -gt 0 ] && VARS="$*" || VARS="R0 R1K R4K R8K L4"
mkdir -p "$WD/obj" "$WD/bin"
codegrep() { grep -nE "$1" "$2/lj52shim.c" "$2/lj52shim.h" 2>/dev/null | grep -vE ':[0-9]+: *([*]|/[*]|//)'; }
gates() {
  bad=0
  for tok in OCLJ_NOMODECHECK LJ52_DROP_LOAD_MODE OCLJ_TRACE OCLJ_JITOFF OCLJ_JITOPT \
             OCLJ_JITATTACH LJ52_MEMLIMIT LJ52_NO_ALLOC_FIX LJ52_NO_RIDX \
             LJ52_NO_CFCACHE SHIM_ALLOC_NEUTERED SHIM_ALLOC_FAITHFUL LJ52_NOJIT; do
    if codegrep "$tok" "$1" | grep -q .; then echo "GATE escape hatch $tok"; bad=1; fi
  done
  if codegrep 'lj_gc_fullgc|lj_gc_step|luaC_|lua_gc *\(|LUA_GCCOLLECT|LUA_GCSTEP' "$1" | grep -q .; then echo "GATE collector"; bad=1; fi
  if codegrep getenv "$1" | grep -q .; then echo "GATE getenv"; bad=1; fi
  echo "source gates on $1: $([ $bad = 0 ] && echo pass || echo FAIL)"
  [ $bad = 0 ]
}
cc1() {  # cc1 <srcdir> <out.o> <defines>
  gcc -c -O2 -Wall -Wextra $3 -I"$LJ" -I"$1" -I"$SER" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" "$1/lj52shim.c" -o "$2" 2> "$2.err"
  w=$(grep -c 'warning:' "$2.err" || true); e=$(grep -c 'error:' "$2.err" || true)
  echo "$(basename $2): warnings=$w errors=$e md5=$(md5sum < "$2" | cut -c1-8)"
  [ "$w" = 0 ] && [ "$e" = 0 ] || { cat "$2.err"; exit 1; }
}
[ -f "$WD/obj/wrapcp.o" ] || gcc -c -O2 -Wall -Wextra -I"$LJ" "$FO/drv/wrapcp.c" -o "$WD/obj/wrapcp.o"
for v in $VARS; do
  P=$WD/src-plain-$v; I=$WD/src-instr-$v
  mkdir -p "$P" "$I"
  cp "$WD/src-plain/lj52shim.h" "$P/"; cp "$FO/src/lj52shim.h" "$I/"
  python "$WD/tools/mklt.py" "$WD/src-plain/lj52shim.c" "$P/lj52shim.c" "$v"
  python "$WD/tools/mklt.py" "$FO/src/lj52shim.c" "$I/lj52shim.c" "$v"
  printf 'CRs: plain %s instr %s\n' "$(tr -cd '\r' < "$P/lj52shim.c" | wc -c)" "$(tr -cd '\r' < "$I/lj52shim.c" | wc -c)"
  gates "$P"
  cc1 "$P" "$WD/obj/ltp-$v-additive.o" -DLJ52_ADDITIVE
  cc1 "$P" "$WD/obj/ltp-$v-dropin.o" ""
  cc1 "$I" "$WD/obj/lt-$v-additive.o" -DLJ52_ADDITIVE
  gcc -g -O2 -Wall -Wextra -I"$LJ" -I"$I" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" -include "$I/lj52shim.h" \
    -DFIXSEED -Wl,--wrap=lj_prng_seed_secure -Wl,--disable-dynamicbase,--disable-high-entropy-va \
    -Wl,--wrap=lj_vm_cpcall "$FO/drv/lj_ref.c" "$WD/obj/lt-$v-additive.o" "$WD/obj/wrapcp.o" \
    "$OBJ/eris_lj.o" "$LJ/libluajit.a" -lm -o "$WD/bin/lref_lt-$v.exe" 2> "$WD/bin/lref_lt-$v.build"
  echo "lref_lt-$v: warnings=$(grep -c 'warning:' "$WD/bin/lref_lt-$v.build" || true) md5=$(md5sum < "$WD/bin/lref_lt-$v.exe" | cut -c1-8)"
done
