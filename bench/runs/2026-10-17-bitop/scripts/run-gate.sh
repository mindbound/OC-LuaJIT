#!/bin/sh
# run-gate.sh <jit|bitops> <luajit src dir> <work dir> [build-native.sh]
# Runs one gate's own text, extracted from build-native.sh unchanged (from
# the gate's first comment line up to, not including, the next block), against
# the luajit.exe in <luajit src dir>; the gate writes its probe into <work dir>.
set -u
G=$1; LJ=$2; OCLJ_BUILD=$3; BN=${4:-/c/Users/astro/Downloads/OC-LuaJIT/native/build-native.sh}
[ -d "$OCLJ_BUILD" ] || mkdir -p "$OCLJ_BUILD"
case $G in
  jit) A="^# LuaJIT'S OWN jit[.][*] TOOLS" ;;
  bitops) A='^# THE BITWISE OPERATORS ARE LUA' ;;
  *) echo "bad gate" >&2; exit 2 ;;
esac
Z="^# LuaJIT'S OWN jit[.][*] TOOLS|^# -+ 1b$"
awk -v a="$A" -v z="$Z" 'p && $0 ~ z { exit } $0 ~ a { p = 1 } p { print }' "$BN" > "$OCLJ_BUILD/gate-$G.sh"
echo "extracted $(wc -l < "$OCLJ_BUILD/gate-$G.sh") lines of the $G gate from $BN"
fail() { echo "BUILD FAIL: $*" >&2; exit 1; }
say()  { echo "[build] $*"; }
LJEXE=$LJ/luajit.exe; [ -x "$LJEXE" ] || LJEXE=$LJ/luajit
. "$OCLJ_BUILD/gate-$G.sh"
echo "GATE PASSED ($G)"
