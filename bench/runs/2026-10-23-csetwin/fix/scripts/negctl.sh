#!/bin/sh
# negctl.sh <fresh label> <arms> -- one call of round/repo's
# test/native/negctl-bitop.sh on the fixer's Windows build round/fix/b1,
# with OCLJ_REPO=round/repo and OCLJ_NEGCTL_ARMS=<arms> (canon always runs).
# Log fix/runs/<label>.log, exit status runs/<label>.rc, the java processes
# before the call runs/<label>.java.txt, start and end times runs/<label>.t,
# input md5s runs/<label>.inputs.md5.  negctl writes its work directory
# under the build ($OCLJ_BUILD/negctl-bitop/<stamp>-<pid>), fresh each call.
# Modelled on integrate/scripts/negctl.sh.  No backslashes.
set -u
F=/c/Users/astro/claude-tmp/oclj/csetwin/round/fix
RP=/c/Users/astro/claude-tmp/oclj/csetwin/round/repo
L=${1:?usage: negctl.sh <fresh label> <arms>}
ARMS=${2:?usage: negctl.sh <fresh label> <arms>}
B=$F/b1
mkdir -p "$F/runs" || exit 98
[ -e "$F/runs/$L.log" ] && { echo "REFUSING: $F/runs/$L.log exists"; exit 99; }
unset LUA_INIT LUA_INIT_5_3 LUA_PATH LUA_CPATH
unset OCLJ_BITJIT_PARTS OCLJ_BITJIT_SEED OCLJ_BITJIT_SEEDS OCLJ_BITJIT_CASES OCLJ_BITJIT_GENMODE OCLJ_BITJIT_HOTMIN OCLJ_BITJIT_OUT
unset OCLJ_BITOP_OUT OCLJ_BITFUZZ_OUT NEGCTL_GEN_SEEDS NEGCTL_FUZZ_CASES
PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export PATH
tasklist 2>/dev/null | grep -i -E '^(java|javaw)[.]exe' > "$F/runs/$L.java.txt"
md5sum "$RP/test/native/negctl-bitop.sh" "$RP/test/native/run-bitjit.sh" "$RP/test/native/bitop/t_csefwd.lua" "$RP/test/native/bitop/cseir.lua" "$RP/test/native/bitop/t_cserev.lua" "$B/luajit-windows-x86_64/src/lj_opt_fold.o" "$B/luajit-windows-x86_64/src/lj_opt_fold.c" > "$F/runs/$L.inputs.md5"
echo "start $(date +%H:%M:%S)" > "$F/runs/$L.t"
env OCLJ_REPO="$RP" OCLJ_BUILD="$B" OCLJ_LUAJIT=C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit OCLJ_LUA53=C:/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/lua.exe OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include" CC=gcc OCLJ_NEGCTL_ARMS="$ARMS" sh "$RP/test/native/negctl-bitop.sh" > "$F/runs/$L.log" 2>&1
rc=$?
echo "$rc" > "$F/runs/$L.rc"
echo "end $(date +%H:%M:%S)" >> "$F/runs/$L.t"
echo "negctl $L rc=$rc ($(tr -d '[:cntrl:]' < "$F/runs/$L.t"))"
tail -n 12 "$F/runs/$L.log"
exit $rc
