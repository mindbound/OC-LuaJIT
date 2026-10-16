#!/bin/sh
# Interleave bench.lua processes across builds: P rounds, build order rotated
# each round.  Appends one line per process to the output file (never reused).
set -u
S=/c/Users/astro/claude-tmp/oclj/r1/fmtx
OUT=$1
P=${2:-5}
R=${3:-5}
[ -e "$OUT" ] && { echo "$OUT exists: refusing to overwrite a results file" >&2; exit 1; }
BUILDS="ffi noffi fmtx alt"
for p in $(seq 1 "$P"); do
  case $((p % 4)) in
    1) ORDER="ffi noffi fmtx alt" ;;
    2) ORDER="noffi fmtx alt ffi" ;;
    3) ORDER="fmtx alt ffi noffi" ;;
    0) ORDER="alt ffi noffi fmtx" ;;
  esac
  for V in $ORDER; do
    L=$("$S/lj-$V/src/luajit.exe" "$S/bench.lua" 1 "$R" 2>&1)
    echo "round=$p build=$V $L" >> "$OUT"
  done
done
echo "done: $OUT"
