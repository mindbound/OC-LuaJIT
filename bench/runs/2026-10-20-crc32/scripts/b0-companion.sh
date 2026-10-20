#!/bin/sh
# b0-companion.sh <fresh outdir> [rounds] -- the main session's companion to
# crc/combine/timing-chain.sh (CRC32 follow-up, row 209, 2026-10-20): row
# 209's target, 2.8-2.9 ns/byte, is round 2's b0 build read on 2026-10-17, and
# the design pass did not time b0.  This runs b0 beside base, folda and both
# in one session, order rotated by one each round, so b0's crc-table can be
# read as a ratio in the same round.  Benches: bench_bit.lua 2e7 and
# bench_bit2.lua 1e7, from crc/combine/bench (bench_bit2 is byte-identical to
# bench/runs/2026-10-17-bitop/scripts/bench_bit2.lua).  b0's results differ
# from the others by design (32-bit operators in round 2), so only times are
# compared.  Every control character of a bench's output (CR, LF, TAB) becomes
# a space.  Refuses an existing outdir (99) and a running java/javaw (97).
# No backslashes in this file (P8).
set -u
OUT=${1:?usage: b0-companion.sh <fresh outdir> [rounds]}
ROUNDS=${2:-5}
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT" || exit 98
unset LUA_INIT LUA_INIT_5_3 LUA_INIT_5_2 LUA_PATH LUA_CPATH
C=/c/Users/astro/claude-tmp/oclj/crc/combine
BN=$C/bench
B0=/c/Users/astro/claude-tmp/oclj/r3/synth/b0/build/native/luajit-windows-x86_64/src/luajit.exe
exe() {
  case $1 in
    b0) echo "$B0" ;;
    *) echo "$C/b-$1/luajit-windows-x86_64/src/luajit.exe" ;;
  esac
}
tasklist 2>/dev/null > "$OUT/procs-before.txt"
if grep -iE '^(java|javaw)[.]exe' "$OUT/procs-before.txt" > "$OUT/jvms.txt"; then
  echo "REFUSING: a Java process is running"; cat "$OUT/jvms.txt"; exit 97
fi
for v in b0 base folda both; do
  [ -x "$(exe $v)" ] || { echo "no $(exe $v)"; exit 2; }
  md5sum "$(exe $v)" >> "$OUT/inputs.md5"
done
md5sum "$BN/bench_bit.lua" "$BN/bench_bit2.lua" "$0" >> "$OUT/inputs.md5"
date -u +%Y-%m-%dT%H:%M:%SZ > "$OUT/start"
r=1
while [ "$r" -le "$ROUNDS" ]; do
  k=$(( (r - 1) % 4 ))
  set -- b0 base folda both
  i=0
  while [ "$i" -lt "$k" ]; do f=$1; shift; set -- "$@" "$f"; i=$((i + 1)); done
  ORDER="$*"
  p=1
  for v in $ORDER; do
    E=$(exe "$v")
    a=$( cd "$BN" && "$E" bench_bit.lua 2e7 2>&1 | tr '[:cntrl:]' ' ' )
    echo "round=$r pos=$p vm=$v bench=bench_bit: $a" >> "$OUT/raw.txt"
    c=$( cd "$BN" && "$E" bench_bit2.lua 1e7 2>&1 | tr '[:cntrl:]' ' ' )
    echo "round=$r pos=$p vm=$v bench=bench_bit2: $c" >> "$OUT/raw.txt"
    p=$((p + 1))
  done
  echo "round $r done $(date -u +%H:%M:%SZ) order: $ORDER" >> "$OUT/progress.txt"
  r=$((r + 1))
done
date -u +%Y-%m-%dT%H:%M:%SZ > "$OUT/end"
tasklist 2>/dev/null > "$OUT/procs-after.txt"
touch "$OUT/done"
