#!/bin/sh
# exportgate-proof.sh <dll> <additive|dropin> -- build-native.sh step 6's three count gates, each evaluated
# on its own (no early exit), with the reader and regex copied verbatim from native/build-native.sh.
set -u
DLL="$1"; VARIANT="$2"
SYMS=$(objdump -p "$DLL" | grep -E '[+]base[[][ 0-9]+[]][ ]+[0-9a-f]{4} ' | awk '{print $NF}' | sort -u)
syms() { printf '%s\n' "$SYMS"; }
NSYM=$(syms | grep -c .)
EXPORTS=$(syms | grep -c '^Java_')
OCLJN=$(syms | grep -cxE 'Java_li_cil_repack_com_naef_jnlua_LuaStateLuaJIT_oclj(UsedMemory|SetTotalMemory|InstallValueFinalizer|ValueGcCounters)')
if [ "$VARIANT" = additive ]; then WANT_J=91; WANT_PE=93; WANT_O=4; else WANT_J=87; WANT_PE=89; WANT_O=0; fi
v() { if [ "$1" = "$2" ]; then echo PASS; else echo FAIL; fi; }
echo "dll=$DLL md5=$(md5sum "$DLL" | cut -c1-8) variant=$VARIANT"
echo "  oclj natives  $OCLJN want $WANT_O  -> $(v "$OCLJN" "$WANT_O")"
echo "  Java_* count  $EXPORTS want $WANT_J -> $(v "$EXPORTS" "$WANT_J")"
echo "  PE names      $NSYM want $WANT_PE -> $(v "$NSYM" "$WANT_PE")"
for n in ocljUsedMemory ocljSetTotalMemory ocljInstallValueFinalizer ocljValueGcCounters; do
  c=$(grep -c -a "Java_li_cil_repack_com_naef_jnlua_LuaStateLuaJIT_$n" "$DLL")
  echo "  gradle need: $n byte matches $c"
done
