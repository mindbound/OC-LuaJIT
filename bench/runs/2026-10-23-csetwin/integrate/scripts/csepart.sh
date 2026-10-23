#!/bin/sh
# csepart.sh <fresh label> <OCLJ_BUILD> [parts] -- the scratch repo's
# (round/repo) test/native/run-bitjit.sh on one build, part cse by default,
# with the Windows PUC 5.3.6, into a fresh integrate/runs/<label>/; the log
# in runs/<label>.log, the exit code in runs/<label>.rc, the wall time in
# runs/<label>.time, the java processes at the start in
# runs/<label>.java.txt.  The build directory is only read.  Modelled on
# impl-tests/scripts/csepart.sh.  No backslashes.
set -u
I=/c/Users/astro/claude-tmp/oclj/csetwin/round/integrate
RP=/c/Users/astro/claude-tmp/oclj/csetwin/round/repo
L=${1:?usage: csepart.sh <fresh label> <OCLJ_BUILD> [parts]}
B=${2:?usage: csepart.sh <fresh label> <OCLJ_BUILD> [parts]}
P=${3:-cse}
mkdir -p "$I/runs" || exit 98
[ -e "$I/runs/$L" ] && { echo "REFUSING: $I/runs/$L exists"; exit 99; }
[ -e "$I/runs/$L.log" ] && { echo "REFUSING: $I/runs/$L.log exists"; exit 99; }
unset LUA_INIT LUA_INIT_5_3 LUA_PATH LUA_CPATH OCLJ_REPO
unset OCLJ_BITJIT_SEED OCLJ_BITJIT_SEEDS OCLJ_BITJIT_CASES OCLJ_BITJIT_GENMODE OCLJ_BITJIT_HOTMIN
tasklist 2>/dev/null | grep -i -E 'java(w)?[.]exe' > "$I/runs/$L.java.txt"
t0=$(date +%s)
OCLJ_BUILD=$B OCLJ_BITJIT_PARTS=$P OCLJ_BITJIT_OUT=$I/runs/$L OCLJ_LUA53=C:/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/lua.exe sh "$RP/test/native/run-bitjit.sh" > "$I/runs/$L.log" 2>&1
rc=$?
t1=$(date +%s)
echo "$rc" > "$I/runs/$L.rc"
echo "$((t1 - t0))" > "$I/runs/$L.time"
echo "$L rc=$rc $((t1 - t0))s"
grep -E '^(PASS|FAIL|PROVED|BITJIT SETUP|RUN-BITJIT|t_c|cseir)' "$I/runs/$L.log" | cut -c1-600
exit 0
