#!/bin/sh
# runners.sh <build dir> <fresh name> -- the CSE type twin round, impl-code:
# the scratch repo's (round/repo, HEAD 1a13bed's test/native, unchanged)
# run-bitop.sh, run-bitjit.sh (its default parts, gen floor fix1 idx sel nc,
# with the Windows PUC 5.3.6) and run-bitfuzz.sh on <build dir>.  Each runner
# writes to a fresh dir under impl-code/<name>/; exit codes in <name>/rc/;
# summary.txt and runners.done last.  Modelled on
# numconv/impl-code/scripts/runners.sh.  The round/repo tree's md5 manifest
# is taken before and after, so that a runner writing into it is seen.
# Written with a file tool; no backslashes.
set -u
I=/c/Users/astro/claude-tmp/oclj/csetwin/round/impl-code
RP=/c/Users/astro/claude-tmp/oclj/csetwin/round/repo
B=${1:?usage: runners.sh <build dir> <fresh name>}
N=${2:?usage: runners.sh <build dir> <fresh name>}
O=$I/$N
[ -e "$O" ] && { echo "REFUSING: $O exists"; exit 99; }
mkdir -p "$O/rc" || exit 98
T=$RP/test/native
PUCW=C:/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/lua.exe
unset LUA_INIT LUA_INIT_5_3 LUA_PATH LUA_CPATH OCLJ_REPO OCLJ_LUA53
unset OCLJ_BITJIT_PARTS OCLJ_BITJIT_SEED OCLJ_BITJIT_SEEDS OCLJ_BITJIT_CASES OCLJ_BITJIT_GENMODE OCLJ_BITJIT_HOTMIN OCLJ_BITJIT_OUT
unset OCLJ_BITOP_OUT OCLJ_BITFUZZ_OUT OCLJ_BITFUZZ_SEED OCLJ_BITFUZZ_SEEDS OCLJ_BITFUZZ_CASES OCLJ_BITFUZZ_TUPLES OCLJ_BITFUZZ_HOMIN OCLJ_BITFUZZ_STRICT OCLJ_BITFUZZ_PRUNE
PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export PATH
( cd "$RP" && find . -type f | LC_ALL=C sort | xargs md5sum ) > "$O/repo-before.md5"
md5sum "$B/luajit-windows-x86_64/src/luajit.exe" "$B/luajit-windows-x86_64/src/lj_opt_fold.o" "$T/run-bitop.sh" "$T/run-bitjit.sh" "$T/run-bitfuzz.sh" "$PUCW" > "$O/inputs.md5"
tasklist 2>/dev/null | grep -i -E 'java(w)?[.]exe' > "$O/java-procs.txt"
date +%H:%M:%S > "$O/t0.txt"
OCLJ_BUILD=$B OCLJ_LUA53=$PUCW OCLJ_BITOP_OUT=$O/bitop OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include" sh "$T/run-bitop.sh" > "$O/bitop.log" 2>&1
echo $? > "$O/rc/bitop.rc"
date +%H:%M:%S > "$O/t1.txt"
OCLJ_BUILD=$B OCLJ_LUA53=$PUCW OCLJ_BITJIT_OUT=$O/bitjit sh "$T/run-bitjit.sh" > "$O/bitjit.log" 2>&1
echo $? > "$O/rc/bitjit.rc"
date +%H:%M:%S > "$O/t2.txt"
OCLJ_BUILD=$B OCLJ_LUA53=$PUCW OCLJ_BITFUZZ_OUT=$O/bitfuzz sh "$T/run-bitfuzz.sh" > "$O/bitfuzz.log" 2>&1
echo $? > "$O/rc/bitfuzz.rc"
date +%H:%M:%S > "$O/t3.txt"
( cd "$RP" && find . -type f | LC_ALL=C sort | xargs md5sum ) > "$O/repo-after.md5"
if cmp -s "$O/repo-before.md5" "$O/repo-after.md5"; then rq=unchanged; else rq=CHANGED; fi
{ echo "bitop rc=$(cat "$O/rc/bitop.rc") :: $(grep -E '^(BITOP|RUN-BITOP)' "$O/bitop.log" | awk '{ printf "%s ", $0 }')"
  echo "bitjit rc=$(cat "$O/rc/bitjit.rc") :: $(grep '^RUN-BITJIT' "$O/bitjit.log" | awk '{ printf "%s ", $0 }')"
  echo "bitfuzz rc=$(cat "$O/rc/bitfuzz.rc") :: $(grep -E '^BITFUZZ' "$O/bitfuzz.log" | awk '{ printf "%s ", $0 }')"
  echo "times: $(cat "$O/t0.txt") $(cat "$O/t1.txt") $(cat "$O/t2.txt") $(cat "$O/t3.txt")"
  echo "java processes at start: $(wc -l < "$O/java-procs.txt" | tr -d ' ')"
  echo "round/repo during the runs: $rq"
} > "$O/summary.txt"
echo done > "$O/runners.done"
cat "$O/summary.txt"
