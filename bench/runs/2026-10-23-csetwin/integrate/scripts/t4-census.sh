#!/bin/sh
# t4-census.sh <instrumented build> <fresh name> -- T4 (design 4.5), the
# refusal census: on the instrumented scratch build (lj_opt_fold.c prints
# CSEREFUSE to stderr each time hunk 12's predicate refuses a candidate),
# run the existing suites and count the refusals.
#   1. integrate/t4-tree's run-bitjit.sh (round/repo's, with every option
#      list holding the default and two side-trace sets, t4-tree.py), parts
#      gen floor fix1 idx sel nc (gen 4 seeds x 2000 loops), PUC 5.3.6;
#   2. round/repo's run-bitop.sh (part 1's matrix t_ops t_fold t_sar t_bit
#      JIT on and -joff, part 2, part 3's bitop_test linked with the
#      instrumented libluajit.a);
#   3. direct runs, from the build's src (jit.vmdef found through ./?.lua),
#      of bitop/t_ops t_fold t_sar t_bit p4v phiidx under the default, he1
#      (-Ohotloop=1 -Ohotexit=1) and ts1 (-Otryside=1 -Ohotexit=2), stdout
#      and stderr kept apart (P57), only counted, not judged.
# Then every file under integrate/<name>/ is searched for CSEREFUSE:
# census.txt, per file with any, and the total.  The cse part is not run
# here (its refusals are the instrument's fail-first, runs/t4-cse-1).
# Exit codes in <name>/rc/; census.done last.  No backslashes.
set -u
I=/c/Users/astro/claude-tmp/oclj/csetwin/round/integrate
RP=/c/Users/astro/claude-tmp/oclj/csetwin/round/repo
B=${1:?usage: t4-census.sh <instrumented build> <fresh name>}
N=${2:?usage: t4-census.sh <instrumented build> <fresh name>}
O=$I/$N
[ -e "$O" ] && { echo "REFUSING: $O exists"; exit 99; }
mkdir -p "$O/rc" "$O/direct" || exit 98
LJ=$B/luajit-windows-x86_64/src
PUCW=C:/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/lua.exe
unset LUA_INIT LUA_INIT_5_3 LUA_PATH LUA_CPATH OCLJ_REPO OCLJ_LUA53
unset OCLJ_BITJIT_PARTS OCLJ_BITJIT_SEED OCLJ_BITJIT_SEEDS OCLJ_BITJIT_CASES OCLJ_BITJIT_GENMODE OCLJ_BITJIT_HOTMIN OCLJ_BITJIT_OUT
unset OCLJ_BITOP_OUT
PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export PATH
grep -c CSEREFUSE "$LJ/lj_opt_fold.c" > "$O/instrument-lines.txt"
md5sum "$LJ/luajit.exe" "$LJ/lj_opt_fold.o" "$LJ/lj_opt_fold.c" "$I/t4-tree/test/native/run-bitjit.sh" "$RP/test/native/run-bitop.sh" > "$O/inputs.md5"
tasklist 2>/dev/null | grep -i -E 'java(w)?[.]exe' > "$O/java-procs.txt"
date +%H:%M:%S > "$O/t0.txt"
OCLJ_BUILD=$B OCLJ_LUA53=$PUCW OCLJ_BITJIT_PARTS="gen floor fix1 idx sel nc" OCLJ_BITJIT_OUT=$O/bitjit sh "$I/t4-tree/test/native/run-bitjit.sh" > "$O/bitjit.log" 2>&1
echo $? > "$O/rc/bitjit.rc"
date +%H:%M:%S > "$O/t1.txt"
OCLJ_BUILD=$B OCLJ_LUA53=$PUCW OCLJ_BITOP_OUT=$O/bitop OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include" sh "$RP/test/native/run-bitop.sh" > "$O/bitop.log" 2>&1
echo $? > "$O/rc/bitop.rc"
date +%H:%M:%S > "$O/t2.txt"
P=$(cd "$RP/test/native/bitop" && pwd -W 2>/dev/null || pwd)
for f in t_ops t_fold t_sar t_bit p4v phiidx; do
  for s in jon he1 ts1; do
    case $s in jon) fl= ;; he1) fl="-Ohotloop=1 -Ohotexit=1" ;; ts1) fl="-Otryside=1 -Ohotexit=2" ;; esac
    ( cd "$LJ" && ./luajit.exe $fl "$P/$f.lua" ) < /dev/null > "$O/direct/$f-$s.txt" 2> "$O/direct/$f-$s.err"
    echo $? > "$O/direct/$f-$s.rc"
  done
done
date +%H:%M:%S > "$O/t3.txt"
# Text files only (-I): bitop_test.exe, linked with the instrumented
# libluajit.a, holds the format string itself (t4-census-1's one hit).
grep -r -I -c CSEREFUSE "$O" | grep -v ':0$' | grep -v '/census' > "$O/census-files.txt"
tot=0
for f in $(cut -d: -f1 "$O/census-files.txt"); do tot=$((tot + $(grep -c CSEREFUSE "$f"))); done
nf=$(find "$O" -type f | wc -l | tr -d ' ')
{ echo "files searched: $nf (every file under $O)"
  echo "files with a CSEREFUSE line: $(grep -c . "$O/census-files.txt")"
  echo "CSEREFUSE lines in all: $tot"
  echo "bitjit rc=$(cat "$O/rc/bitjit.rc") :: $(grep '^RUN-BITJIT' "$O/bitjit.log" | awk '{ printf "%s ", $0 }')"
  echo "bitop rc=$(cat "$O/rc/bitop.rc") :: $(grep -E '^(BITOP|RUN-BITOP)' "$O/bitop.log" | awk '{ printf "%s ", $0 }')"
  echo "direct runs: $(ls "$O/direct" | grep -c '[.]rc$'), exit codes: $(cat "$O"/direct/*.rc | sort | uniq -c | awk '{ printf "%s x%s ", $2, $1 }')"
  echo "times: $(cat "$O/t0.txt") $(cat "$O/t1.txt") $(cat "$O/t2.txt") $(cat "$O/t3.txt")"
  echo "java processes at start: $(wc -l < "$O/java-procs.txt" | tr -d ' ')"
} > "$O/census.txt"
echo done > "$O/census.done"
cat "$O/census.txt"
