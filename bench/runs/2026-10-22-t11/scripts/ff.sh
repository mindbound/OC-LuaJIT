#!/bin/sh
# Fail-first runs of ingame-bitops.lua v2 through ff.lua, standalone.
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
V=/c/Users/astro/claude-tmp/oclj/t10/v2
O=$V/ff-1
[ -e "$O" ] && { echo "REFUSING: $O exists"; exit 99; }
mkdir -p "$O" || exit 98
LJ=$REPO/build/native/luajit-windows-x86_64/src/luajit.exe
PUC=$REPO/bench/vendor/lua-5.3.6/src/lua.exe
md5sum "$V/ingame-bitops.lua" "$V/ff.lua" "$LJ" "$PUC" > "$O/inputs.md5"
for cpu in lj puc; do
  if [ "$cpu" = lj ]; then BIN=$LJ; else BIN=$PUC; fi
  for mode in none err bad clock skip; do
    D=$O/$mode-$cpu
    mkdir -p "$D"
    "$BIN" "$V/ff.lua" "$mode" "$V/ingame-bitops.lua" "$D" > "$D/stdout.txt" 2>&1
    echo "$mode-$cpu rc=$? $(grep -E '^verdict' "$D/stdout.txt")" >> "$O/summary.txt"
  done
done
echo done >> "$O/summary.txt"
