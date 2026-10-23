#!/bin/sh
# csepart.sh <build dir> <fresh name> [parts] -- the CSE type twin round,
# verify-code: run-bitjit.sh from verify-code/vrepo (HEAD 60a24ec plus the
# round's eight files) with OCLJ_BITJIT_PARTS=<parts> (default cse) on
# <build dir>, PUC 5.3.6 for Windows, into a fresh verify-code/runs/<name>.
# The cse part holds only forward-order cases and t_cserev's two no-slot
# reverse shapes (R5, R6), which the user's decision D2 allows on any build.
# No backslashes.
set -u
I=/c/Users/astro/claude-tmp/oclj/csetwin/round/verify-code
RP=$I/vrepo
B=${1:?usage: csepart.sh <build dir> <fresh name> [parts]}
N=${2:?usage: csepart.sh <build dir> <fresh name> [parts]}
P=${3:-cse}
O=$I/runs/$N
[ -e "$O" ] && { echo "REFUSING: $O exists"; exit 99; }
mkdir -p "$O" || exit 98
T=$RP/test/native
PUCW=C:/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/lua.exe
unset LUA_INIT LUA_INIT_5_3 LUA_PATH LUA_CPATH OCLJ_REPO OCLJ_LUA53
unset OCLJ_BITJIT_PARTS OCLJ_BITJIT_SEED OCLJ_BITJIT_SEEDS OCLJ_BITJIT_CASES OCLJ_BITJIT_GENMODE OCLJ_BITJIT_HOTMIN OCLJ_BITJIT_OUT
PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export PATH
tasklist 2>/dev/null | grep -i -E 'java(w)?[.]exe' > "$O/java-procs.txt"
md5sum "$B/luajit-windows-x86_64/src/luajit.exe" "$B/luajit-windows-x86_64/src/lj_opt_fold.o" "$T/run-bitjit.sh" "$T/bitop/t_csefwd.lua" "$T/bitop/cseir.lua" "$T/bitop/t_cserev.lua" "$PUCW" > "$O/inputs.md5"
date +%H:%M:%S > "$O/t0.txt"
OCLJ_BUILD=$B OCLJ_LUA53=$PUCW OCLJ_BITJIT_PARTS=$P OCLJ_BITJIT_OUT=$O/bitjit sh "$T/run-bitjit.sh" > "$O/bitjit.log" 2>&1
echo $? > "$O/rc.txt"
date +%H:%M:%S > "$O/t1.txt"
echo "rc=$(cat "$O/rc.txt") $(cat "$O/t0.txt")-$(cat "$O/t1.txt") java=$(wc -l < "$O/java-procs.txt" | tr -d ' ')"
grep -E '^(PASS|FAIL|PROVED|RUN-BITJIT|t_c)' "$O/bitjit.log" | cut -c1-400
