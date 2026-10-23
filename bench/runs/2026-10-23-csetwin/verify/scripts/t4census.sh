#!/bin/sh
# t4census.sh <fresh name> <step> -- verify-code: run one step of my own
# refusal census on the instrumented copy verify-code/t4v (VCREFUSE lines on
# luajit's stderr), each step into verify-code/runs/<name>-<step>, then
# count VCREFUSE lines in the text files there (grep -I: binaries such as
# run-bitop's bitop_test.exe, linked with the instrumented libluajit.a,
# hold the string and are skipped).  Steps:
#   ff      the instrument's fail-first: the cse part and probes/bodyfwd.lua
#   bitjit  run-bitjit.sh's six earlier parts, gen at seeds 21-24 (not the
#           integrator's 1-4) and its side-trace sets as shipped
#   bitop   run-bitop.sh
#   fuzz    run-bitfuzz.sh, seeds 11-15
# No backslashes.
set -u
I=/c/Users/astro/claude-tmp/oclj/csetwin/round/verify-code
N=${1:?usage}; STEP=${2:?usage}
O=$I/runs/$N-$STEP
[ -e "$O" ] && { echo "REFUSING: $O exists"; exit 99; }
mkdir -p "$O" || exit 98
B=$I/t4v
T=$I/vrepo/test/native
PUCW=C:/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/lua.exe
unset LUA_INIT LUA_INIT_5_3 LUA_PATH LUA_CPATH OCLJ_REPO OCLJ_LUA53
unset OCLJ_BITJIT_PARTS OCLJ_BITJIT_SEED OCLJ_BITJIT_SEEDS OCLJ_BITJIT_CASES OCLJ_BITJIT_GENMODE OCLJ_BITJIT_HOTMIN OCLJ_BITJIT_OUT
unset OCLJ_BITOP_OUT OCLJ_BITFUZZ_OUT OCLJ_BITFUZZ_SEED OCLJ_BITFUZZ_SEEDS OCLJ_BITFUZZ_CASES OCLJ_BITFUZZ_TUPLES OCLJ_BITFUZZ_HOTMIN OCLJ_BITFUZZ_STRICT OCLJ_BITFUZZ_PRUNE
PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export PATH
tasklist 2>/dev/null | grep -i -E 'java(w)?[.]exe' > "$O/java-procs.txt"
md5sum "$B/luajit-windows-x86_64/src/luajit.exe" "$B/luajit-windows-x86_64/src/lj_opt_fold.o" > "$O/inputs.md5"
date +%H:%M:%S > "$O/t0.txt"
case $STEP in
  ff)
    OCLJ_BUILD=$B OCLJ_LUA53=$PUCW OCLJ_BITJIT_PARTS=cse OCLJ_BITJIT_OUT=$O/bitjit sh "$T/run-bitjit.sh" > "$O/run.log" 2>&1
    echo $? > "$O/rc.txt"
    S=$B/luajit-windows-x86_64/src
    LUA_PATH="$(cygpath -m "$S")/?.lua;;" "$S/luajit.exe" "$(cygpath -m "$I/probes/bodyfwd.lua")" - > "$O/bodyfwd.txt" 2> "$O/bodyfwd.err"
    echo $? >> "$O/rc.txt" ;;
  bitjit)
    OCLJ_BUILD=$B OCLJ_LUA53=$PUCW OCLJ_BITJIT_PARTS="gen floor fix1 idx sel nc" OCLJ_BITJIT_SEED=21 OCLJ_BITJIT_OUT=$O/bitjit sh "$T/run-bitjit.sh" > "$O/run.log" 2>&1
    echo $? > "$O/rc.txt" ;;
  bitop)
    OCLJ_BUILD=$B OCLJ_LUA53=$PUCW OCLJ_BITOP_OUT=$O/bitop OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include" sh "$T/run-bitop.sh" > "$O/run.log" 2>&1
    echo $? > "$O/rc.txt" ;;
  fuzz)
    OCLJ_BUILD=$B OCLJ_LUA53=$PUCW OCLJ_BITFUZZ_SEED=11 OCLJ_BITFUZZ_SEEDS=5 OCLJ_BITFUZZ_OUT=$O/bitfuzz sh "$T/run-bitfuzz.sh" > "$O/run.log" 2>&1
    echo $? > "$O/rc.txt" ;;
  *) echo "no step $STEP"; exit 2 ;;
esac
date +%H:%M:%S > "$O/t1.txt"
nfiles=$(find "$O" -type f | wc -l | tr -d ' ')
grep -I -r -c '^VCREFUSE' "$O" | awk -F: '$NF > 0' > "$O/refuse-files.txt"
nlines=$(awk -F: '{ s += $NF } END { print s + 0 }' "$O/refuse-files.txt")
nfwd=$(grep -I -r -h '^VCREFUSE fwd' "$O" | wc -l | tr -d ' ')
nrev=$(grep -I -r -h '^VCREFUSE rev' "$O" | wc -l | tr -d ' ')
echo "$STEP rc=$(awk '{ printf "%s ", $0 }' "$O/rc.txt") $(cat "$O/t0.txt")-$(cat "$O/t1.txt") java=$(wc -l < "$O/java-procs.txt" | tr -d ' ') files=$nfiles VCREFUSE lines=$nlines (fwd $nfwd, rev $nrev) in $(wc -l < "$O/refuse-files.txt" | tr -d ' ') files" | tee "$O/summary.txt"
grep -E '^(RUN-BIT|BITOP|BITFUZZ|PASS|FAIL|PROVED)' "$O/run.log" | cut -c1-200 | head -20
