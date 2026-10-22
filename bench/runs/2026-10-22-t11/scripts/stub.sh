#!/bin/sh
# The yield-gap check on the reviewed script: stubrun.lua (the draft agent's
# instrument) with a stub computer and an os.sleep that records the longest
# stretch between yields, on luajit.exe and PUC 5.3.6.
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
T=/c/Users/astro/claude-tmp/oclj/t10
O=$T/v2/stub-1
[ -e "$O" ] && { echo "REFUSING: $O exists"; exit 99; }
mkdir -p "$O" || exit 98
LJ=$REPO/build/native/luajit-windows-x86_64/src/luajit.exe
PUC=$REPO/bench/vendor/lua-5.3.6/src/lua.exe
PROG=$T/v2/ingame-bitops.lua
md5sum "$PROG" "$T/stub/stubrun.lua" "$LJ" "$PUC" > "$O/inputs.md5"
for arm in "lj LuaJIT" "puc Lua%205.3"; do
  set -- $arm
  cpu=$1
  name=$(echo "$2" | sed 's/%20/ /')
  if [ "$cpu" = lj ]; then BIN=$LJ; else BIN=$PUC; fi
  D=$O/$cpu
  mkdir -p "$D"
  "$BIN" "$T/stub/stubrun.lua" "$PROG" "$name" "$D" > "$D/stdout.txt" 2>&1
  echo "$cpu rc=$? $(grep -E '^STUB|^verdict' "$D/stdout.txt" | tr '[:cntrl:]' ' ')" >> "$O/summary.txt"
done
