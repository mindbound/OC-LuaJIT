#!/bin/sh
# alma-cse.sh <outdir, WSL form> -- in AlmaLinux 8: the round's run-bitjit.sh
# (the impl-tests copy) part cse on build/native's Linux tree (read only;
# the unfixed base, whose cited sources are the Windows build copy's byte
# for byte), with the Linux PUC 5.3.6.  Exit code in <outdir>/cse.rc; done
# file <outdir>/done.  Refuses an existing <outdir>.
set -u
A=${1:?usage: alma-cse.sh <outdir>}
[ -e "$A" ] && { echo "REFUSING: $A exists"; exit 99; }
mkdir -p "$A" || exit 98
R=/mnt/c/Users/astro/Downloads/OC-LuaJIT
T=/mnt/c/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests
PUCL=/mnt/c/Users/astro/claude-tmp/oclj/puc536-alma/lua
{ uname -a; readlink -f /bin/sh; md5sum "$R/build/native/luajit-linux-x86_64/src/luajit" "$R/build/native/luajit-linux-x86_64/src/lj_opt_fold.o"; "$PUCL" -v; } > "$A/host.txt" 2>&1
unset LUA_INIT LUA_INIT_5_3
env OCLJ_BUILD="$R/build/native" OCLJ_LUA53="$PUCL" OCLJ_BITJIT_PARTS=cse OCLJ_BITJIT_OUT="$A/out" \
  sh "$T/test/native/run-bitjit.sh" > "$A/cse.log" 2>&1
echo $? > "$A/cse.rc"
echo done > "$A/done"
