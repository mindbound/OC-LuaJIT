#!/bin/sh
# negctl.sh <fresh label> <arms> [build dir] [test tree] -- one call of
# negctl-bitop.sh (the scratch repo's round/repo/test/native by default, or
# <test tree>/test/native) on the integrator's Windows build (default
# integrate/b1), with OCLJ_REPO=round/repo and OCLJ_NEGCTL_ARMS=<arms>
# (canon always runs).  Log integrate/runs/<label>.log, exit status in
# runs/<label>.rc, the running java processes before the call in
# runs/<label>.java.txt, start and end times in runs/<label>.t, input md5s
# in runs/<label>.inputs.md5.  negctl writes its work dir under the build
# dir ($OCLJ_BUILD/negctl-bitop/<stamp>-<pid>), fresh each call.  Modelled
# on numconv/integrate/scripts/negctl.sh.  No backslashes.
set -u
I=/c/Users/astro/claude-tmp/oclj/csetwin/round/integrate
RP=/c/Users/astro/claude-tmp/oclj/csetwin/round/repo
L=${1:?usage: negctl.sh <fresh label> <arms> [build dir] [test tree]}
ARMS=${2:?usage: negctl.sh <fresh label> <arms> [build dir] [test tree]}
B=${3:-$I/b1}
TT=${4:-$RP}
mkdir -p "$I/runs" || exit 98
[ -e "$I/runs/$L.log" ] && { echo "REFUSING: $I/runs/$L.log exists"; exit 99; }
unset LUA_INIT LUA_INIT_5_3 LUA_PATH LUA_CPATH
unset OCLJ_BITJIT_PARTS OCLJ_BITJIT_SEED OCLJ_BITJIT_SEEDS OCLJ_BITJIT_CASES OCLJ_BITJIT_GENMODE OCLJ_BITJIT_HOTMIN OCLJ_BITJIT_OUT
unset OCLJ_BITOP_OUT OCLJ_BITFUZZ_OUT NEGCTL_GEN_SEEDS NEGCTL_FUZZ_CASES
PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export PATH
tasklist 2>/dev/null | grep -i -E 'java(w)?[.]exe' > "$I/runs/$L.java.txt"
md5sum "$TT/test/native/negctl-bitop.sh" "$TT/test/native/run-bitjit.sh" "$TT/test/native/bitop/t_csefwd.lua" "$TT/test/native/bitop/cseir.lua" "$TT/test/native/bitop/t_cserev.lua" "$B/luajit-windows-x86_64/src/lj_opt_fold.o" "$B/luajit-windows-x86_64/src/lj_opt_fold.c" > "$I/runs/$L.inputs.md5"
echo "start $(date +%H:%M:%S)" > "$I/runs/$L.t"
OCLJ_REPO=$RP OCLJ_BUILD=$B OCLJ_LUAJIT=C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit OCLJ_LUA53=C:/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/lua.exe OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include" CC=gcc OCLJ_NEGCTL_ARMS=$ARMS sh "$TT/test/native/negctl-bitop.sh" > "$I/runs/$L.log" 2>&1
rc=$?
echo "$rc" > "$I/runs/$L.rc"
echo "end $(date +%H:%M:%S)" >> "$I/runs/$L.t"
echo "negctl $L rc=$rc ($(tr '\n' ' ' < "$I/runs/$L.t"))"
tail -n 12 "$I/runs/$L.log"
exit $rc
