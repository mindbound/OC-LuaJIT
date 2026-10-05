#!/bin/sh
# build.sh -- the "identify" prototypes (THE RECIPIENT), built exactly as
# build-native.sh stage 2 compiles lj52shim.c (the forensics' build-shim.sh
# line), warning-clean, both variants:
#   src-id/        the repo's lj52shim.c + mkid.py rec,res,vmevent  (THE SHIPPABLE DIFF)
#   src-ref-id/    the instrumented copy + the same + the OCLJID line   (measurement)
#   src-ref-rec/   instrumented + rec only
#   src-ref-res/   instrumented + res only
#   src-ref-vme/   instrumented + vmevent only
#   src-ref-cnt/   instrumented + counters only (the control: must be identical to the baseline)
# Then build-native.sh's source gates on src-id, the hermetic drivers
# bin/lref_<variant>.exe (build-drv.sh's census link line: no ASLR, fixed
# seed, the cpcall wrap) and nothing else.  Writes into this directory only.
set -eu
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/identify
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJ=$REPO/build/native/luajit-windows-x86_64/src
SER=$REPO/serializer
OBJ=$REPO/build/native/obj-windows-x86_64
cd "$WD"
mk() {  # mk <dir> <base> <flags...>
  d=$1; b=$2; shift 2
  mkdir -p "$d"
  cp "$b/lj52shim.h" "$d/"
  python tools/mkid.py "$b/lj52shim.c" "$d/lj52shim.c" "$@"
  printf '  CR count: %s\n' "$(tr -cd '\r' < "$d/lj52shim.c" | wc -c)"
}
mk src-id      src-plain rec res vmevent
mk src-ref-id  src-ref   rec res vmevent instr
mk src-ref-rec src-ref   rec instr
mk src-ref-res src-ref   res instr
mk src-ref-vme src-ref   vmevent instr
mk src-ref-cnt src-ref   instr
for v in id ref-id ref-rec ref-res ref-vme ref-cnt; do
  S=$WD/src-$v
  for var in additive dropin; do
    case $var in additive) D=-DLJ52_ADDITIVE ;; dropin) D= ;; esac
    gcc -c -O2 -Wall -Wextra $D -I"$LJ" -I"$S" -I"$SER" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" \
      "$S/lj52shim.c" -o "$WD/obj/$v-$var.o" 2> "$WD/obj/$v-$var.err"
    w=$(grep -c 'warning:' "$WD/obj/$v-$var.err" || true)
    e=$(grep -c 'error:' "$WD/obj/$v-$var.err" || true)
    echo "$v-$var: warnings=$w errors=$e md5=$(md5sum < "$WD/obj/$v-$var.o" | cut -c1-8)"
    [ "$w" = 0 ] && [ "$e" = 0 ] || { cat "$WD/obj/$v-$var.err"; exit 1; }
  done
done
# build-native.sh's source gates, by its own codegrep, on the shippable copy
codegrep() { grep -nE "$1" "$WD/src-id/lj52shim.c" "$WD/src-id/lj52shim.h" 2>/dev/null | grep -vE ':[0-9]+: *([*]|/[*]|//)'; }
bad=0
for tok in OCLJ_NOMODECHECK LJ52_DROP_LOAD_MODE OCLJ_TRACE OCLJ_JITOFF OCLJ_JITOPT \
           OCLJ_JITATTACH LJ52_MEMLIMIT LJ52_NO_ALLOC_FIX LJ52_NO_RIDX \
           LJ52_NO_CFCACHE SHIM_ALLOC_NEUTERED SHIM_ALLOC_FAITHFUL LJ52_NOJIT; do
  if codegrep "$tok" | grep -q .; then echo "GATE escape hatch $tok"; bad=1; fi
done
if codegrep 'lj_gc_fullgc|lj_gc_step|luaC_|lua_gc *\(|LUA_GCCOLLECT|LUA_GCSTEP' | grep -q .; then echo "GATE collector"; bad=1; fi
if codegrep getenv | grep -q .; then echo "GATE getenv"; bad=1; fi
echo "source gates on src-id: $([ $bad = 0 ] && echo pass || echo FAIL)"
# the diff against the repo
diff -u "$WD/src-plain/lj52shim.c" "$WD/src-id/lj52shim.c" > "$WD/identify.diff" || true
echo "identify.diff: $(grep -c '^+[^+]' "$WD/identify.diff") lines added, $(grep -c '^-[^-]' "$WD/identify.diff") removed"
# the drivers: lj_ref.c (mkdrv.py over lj_repro.c) + wrapcp.c, the census link line
python "$WD/drv/mkdrv.py" "$WD/drv/lj_repro.c" "$WD/drv/lj_ref.c" > /dev/null
FLAGS="-g -O2 -Wall -Wextra -I$LJ"
LINK="-DFIXSEED -Wl,--wrap=lj_prng_seed_secure -Wl,--disable-dynamicbase,--disable-high-entropy-va"
gcc -c -O2 -Wall -Wextra -I"$LJ" "$WD/drv/wrapcp.c" -o "$WD/obj/wrapcp.o"
for v in ref-id ref-rec ref-res ref-cnt; do
  gcc $FLAGS -I"$WD/src-$v" -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" -include "$WD/src-$v/lj52shim.h" $LINK \
    -Wl,--wrap=lj_vm_cpcall "$WD/drv/lj_ref.c" "$WD/obj/$v-additive.o" "$WD/obj/wrapcp.o" \
    "$OBJ/eris_lj.o" "$LJ/libluajit.a" -lm -o "$WD/bin/lref_$v.exe" 2> "$WD/bin/lref_$v.build"
  echo "lref_$v: warnings=$(grep -c 'warning:' "$WD/bin/lref_$v.build" || true) md5=$(md5sum < "$WD/bin/lref_$v.exe" | cut -c1-8)"
done
