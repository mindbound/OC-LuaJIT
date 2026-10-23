#!/bin/sh
# csepart.sh <label> <base|fix|<OCLJ_BUILD>> [parts] [test tree] -- the
# fixer's runner: run-bitjit.sh (round/repo's, or <test tree>'s
# test/native/run-bitjit.sh) on one build (base: the real repo's
# build/native, read only; fix: round/fix/b1), part cse by default, with PUC
# 5.3.6, into a fresh fix/runs/<label>/; log runs/<label>.log, exit status
# runs/<label>.rc, wall time runs/<label>.time, the java processes before
# the run runs/<label>.java.txt.  Modelled on impl-tests/scripts/csepart.sh.
# The build directory is only read.  No backslashes.
set -u
F=/c/Users/astro/claude-tmp/oclj/csetwin/round/fix
RP=/c/Users/astro/claude-tmp/oclj/csetwin/round/repo
L=${1:?usage: csepart.sh <label> <base|fix|build dir> [parts] [test tree]}
case ${2:?usage: csepart.sh <label> <base|fix|build dir> [parts] [test tree]} in
  base) B=/c/Users/astro/Downloads/OC-LuaJIT/build/native ;;
  fix) B=$F/b1 ;;
  *) B=$2 ;;
esac
P=${3:-cse}
TREE=${4:-$RP}
[ -e "$F/runs/$L" ] && { echo "REFUSING: $F/runs/$L exists"; exit 99; }
[ -e "$F/runs/$L.log" ] && { echo "REFUSING: $F/runs/$L.log exists"; exit 99; }
mkdir -p "$F/runs" || exit 98
unset LUA_INIT LUA_INIT_5_3 LUA_PATH LUA_CPATH OCLJ_REPO
unset OCLJ_BITJIT_SEED OCLJ_BITJIT_SEEDS OCLJ_BITJIT_CASES OCLJ_BITJIT_GENMODE OCLJ_BITJIT_HOTMIN
tasklist 2>/dev/null | grep -i -E '^(java|javaw)[.]exe' > "$F/runs/$L.java.txt"
t0=$(date +%s)
env OCLJ_BUILD="$B" OCLJ_BITJIT_PARTS="$P" OCLJ_BITJIT_OUT="$F/runs/$L" OCLJ_LUA53=C:/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/lua.exe sh "$TREE/test/native/run-bitjit.sh" > "$F/runs/$L.log" 2>&1
rc=$?
t1=$(date +%s)
echo "$rc" > "$F/runs/$L.rc"
echo "$((t1 - t0))" > "$F/runs/$L.time"
echo "$L rc=$rc $((t1 - t0))s"
grep -E '^(PASS|FAIL|PROVED|BITJIT SETUP|RUN-BITJIT)' "$F/runs/$L.log" | cut -c1-700
exit 0
