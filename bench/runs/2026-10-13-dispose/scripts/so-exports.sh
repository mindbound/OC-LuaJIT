#!/bin/bash
# so-exports.sh <so>... -- for each Linux .so: the Java_* and oclj export counts build-native.sh step 6 takes
# (nm -D --defined-only), and the four oclj names gradle's verifyModAssets `need` looks for (byte matches).
for f in "$@"; do
  S=$(nm -D --defined-only "$f" | awk '{print $NF}' | sort -u)
  J=$(printf '%s\n' "$S" | grep -c '^Java_')
  O=$(printf '%s\n' "$S" | grep -cxE 'Java_li_cil_repack_com_naef_jnlua_LuaStateLuaJIT_oclj(UsedMemory|SetTotalMemory|InstallValueFinalizer|ValueGcCounters)')
  echo "so=$(basename "$(dirname "$f")")/$(basename "$f") md5=$(md5sum "$f" | cut -c1-8)"
  echo "  oclj natives  $O want 4  -> $([ "$O" = 4 ] && echo PASS || echo FAIL)"
  echo "  Java_* count  $J want 91 -> $([ "$J" = 91 ] && echo PASS || echo FAIL)"
  for n in ocljUsedMemory ocljSetTotalMemory ocljInstallValueFinalizer ocljValueGcCounters; do
    echo "  gradle need: $n byte matches $(grep -c -a "Java_li_cil_repack_com_naef_jnlua_LuaStateLuaJIT_$n" "$f")"
  done
done
