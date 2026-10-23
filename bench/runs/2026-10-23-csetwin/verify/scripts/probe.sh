#!/bin/sh
# probe.sh <fresh name> <probe.lua> [luajit options...] -- verify-code: run
# a forward-order probe on build/native (base) and on verify-code/bfix
# (fixed), JIT on with the cseir reader, and -joff, into a fresh
# verify-code/runs/<name>.  No backslashes.
set -u
I=/c/Users/astro/claude-tmp/oclj/csetwin/round/verify-code
N=${1:?usage: probe.sh <fresh name> <probe.lua> [opts]}
PR=${2:?usage: probe.sh <fresh name> <probe.lua> [opts]}
shift 2
O=$I/runs/$N
[ -e "$O" ] && { echo "REFUSING: $O exists"; exit 99; }
mkdir -p "$O" || exit 98
unset LUA_INIT LUA_INIT_5_3 LUA_PATH LUA_CPATH
tasklist 2>/dev/null | grep -i -E 'java(w)?[.]exe' > "$O/java-procs.txt"
CSEIR=C:/Users/astro/claude-tmp/oclj/csetwin/round/verify-code/vrepo/test/native/bitop/cseir.lua
for b in base fix; do
  case $b in
    base) S=C:/Users/astro/Downloads/OC-LuaJIT/build/native/luajit-windows-x86_64/src ;;
    fix) S=C:/Users/astro/claude-tmp/oclj/csetwin/round/verify-code/bfix/luajit-windows-x86_64/src ;;
  esac
  md5sum "$S/luajit.exe" "$S/lj_opt_fold.o" "$PR" >> "$O/inputs.md5"
  LUA_PATH="$S/?.lua;;" "$S/luajit.exe" "$@" "$PR" "$CSEIR" > "$O/$b-jit.txt" 2> "$O/$b-jit.err"; echo $? > "$O/$b-jit.rc"
  "$S/luajit.exe" -joff "$PR" - > "$O/$b-joff.txt" 2> "$O/$b-joff.err"; echo $? > "$O/$b-joff.rc"
  for r in jit joff; do
    echo "== $b-$r rc=$(cat "$O/$b-$r.rc") stderr=$(wc -c < "$O/$b-$r.err" | tr -d ' ')"
    cat "$O/$b-$r.txt"
  done
done | tee "$O/summary.txt"
