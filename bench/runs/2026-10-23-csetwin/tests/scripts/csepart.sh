#!/bin/sh
# csepart.sh <label> <OCLJ_BUILD> [parts] [test tree] -- run a run-bitjit.sh
# (the impl-tests copy by default, or <test tree>/test/native/run-bitjit.sh)
# on one build, part cse by default, into a fresh runs/<label>/; the log in
# runs/<label>.log, the exit code in runs/<label>.rc, the wall time in
# runs/<label>.time.  The build directory is only read.
set -u
T=/c/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests
L=${1:?usage: csepart.sh <label> <OCLJ_BUILD> [parts] [test tree]}
B=${2:?usage: csepart.sh <label> <OCLJ_BUILD> [parts] [test tree]}
P=${3:-cse}
TREE=${4:-$T}
[ -e "$T/runs/$L" ] && { echo "REFUSING: $T/runs/$L exists"; exit 99; }
[ -e "$T/runs/$L.log" ] && { echo "REFUSING: $T/runs/$L.log exists"; exit 99; }
unset LUA_INIT LUA_INIT_5_3
t0=$(date +%s)
OCLJ_BUILD=$B OCLJ_BITJIT_PARTS=$P OCLJ_BITJIT_OUT=$T/runs/$L \
  OCLJ_LUA53=/c/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/lua.exe \
  sh "$TREE/test/native/run-bitjit.sh" > "$T/runs/$L.log" 2>&1
rc=$?
t1=$(date +%s)
echo "$rc" > "$T/runs/$L.rc"
echo "$((t1 - t0))" > "$T/runs/$L.time"
echo "$L rc=$rc $((t1 - t0))s"
grep -E '^(PASS|FAIL|PROVED|BITJIT SETUP|RUN-BITJIT|t_c|cseir)' "$T/runs/$L.log" | cut -c1-400
exit 0
