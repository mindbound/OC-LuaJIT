#!/bin/sh
# smoke-fwd.sh <fresh outdir> -- the CSE type twin round, impl-code: a smoke
# reading of the fix's forward half, by value only, with run-3's
# forward-only probe (scratch shiftexact/cse/cse-fwd2.lua: LuaJIT's bit
# library records its 32-bit op first, then the 5.3 operator; no reverse
# order, no slot can receive an int64 ref, safe on any build by the design's
# 1.3).  Run on build/native (the unfixed base, expected 682 mismatches as
# run-3) and on impl-code/build-fix (expected 0), JIT on and -joff.
# No backslashes.
set -u
O=${1:?usage: smoke-fwd.sh <fresh outdir>}
[ -e "$O" ] && { echo "REFUSING: $O exists"; exit 99; }
mkdir -p "$O" || exit 98
P=/c/Users/astro/claude-tmp/oclj/shiftexact/cse/cse-fwd2.lua
BASE=/c/Users/astro/Downloads/OC-LuaJIT/build/native/luajit-windows-x86_64/src/luajit.exe
FIX=/c/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/build-fix/luajit-windows-x86_64/src/luajit.exe
unset LUA_INIT LUA_INIT_5_3 LUA_PATH LUA_CPATH
md5sum "$P" "$BASE" "$FIX" > "$O/inputs.md5"
"$BASE" "$P" > "$O/base-jit.txt" 2> "$O/base-jit.err"; echo $? > "$O/base-jit.rc"
"$BASE" -joff "$P" > "$O/base-joff.txt" 2> "$O/base-joff.err"; echo $? > "$O/base-joff.rc"
"$FIX" "$P" > "$O/fix-jit.txt" 2> "$O/fix-jit.err"; echo $? > "$O/fix-jit.rc"
"$FIX" -joff "$P" > "$O/fix-joff.txt" 2> "$O/fix-joff.err"; echo $? > "$O/fix-joff.rc"
for r in base-jit base-joff fix-jit fix-joff; do
  echo "$r rc=$(cat "$O/$r.rc") stderr=$(wc -c < "$O/$r.err" | tr -d ' ') :: $(grep -E '^(lshift3|bnot|ctl-|failfirst ok|jit )' "$O/$r.txt" | awk '{ sub(/[[:cntrl:]]+$/, ""); gsub(/  +/, " "); printf "%s | ", $0 }')"
done > "$O/summary.txt"
cat "$O/summary.txt"
