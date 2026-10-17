#!/bin/sh
# =====================================================================
# run-packfuzz.sh -- differential fuzzing of string.pack / string.unpack /
# string.packsize: OUR implementation (native/luajit/oclj_strpack.c, in the
# string library of the build's LuaJIT) against PUC Lua 5.3.6.
#
#   OCLJ_BUILD=<build dir used by build-native.sh>  sh test/native/run-packfuzz.sh
#
# Requires build-native.sh to have run first, on THIS platform: "ours" is the
# luajit.exe that links the same libluajit.a the natives link, so the fuzzer
# runs the code path that ships (lib_string.c; test/native/pack_test.c, run by
# run-pack.sh, checks the shim reaches the same functions).  And a built PUC
# Lua 5.3.6 (bench/vendor/lua-5.3.6, git-ignored; or OCLJ_LUA53).
#
# The generator (pack/packfuzz.lua) draws the same cases on both VMs from a
# seeded integer-exact PRNG: ~240 fixed edge cases, then OCLJ_PACKFUZZ_CASES
# random ones of seven kinds (round trips, model-built data, hostile
# arguments, malformed formats, edge positions, crafted s[n] lengths, large
# strings).  The comparator (pack/packfuzz-cmp.lua, run under PUC) accepts a
# line only if it is identical, or differs exactly as the decided rounding
# says (PUC's integer, rounded to the nearest double, is ours); error
# messages are compared exactly, with only the function name normalised.
#
# Environment:
#   OCLJ_LUA53             the reference (default bench/vendor/lua-5.3.6/src/lua[.exe]);
#                          refused unless `-v` says "Lua 5.3.6"
#   OCLJ_PACKFUZZ_SEED     first seed                                   (default 1)
#   OCLJ_PACKFUZZ_SEEDS    how many consecutive seeds                    (default 1)
#   OCLJ_PACKFUZZ_CASES    random cases per seed, after the fixed edges  (default 20000)
#   OCLJ_PACKFUZZ_PROFILE  default | long | coerce | limits              (default default)
#                          long adds strings up to 16 MiB (slow: ~25 s a seed
#                          at 300 cases).  The default mix's hostile arguments
#                          include the numerals LuaJIT's own scanner reads
#                          differently from 5.3.6 ("0xffffffffffffffff", "inf",
#                          "9007199254740993", "0b101"): pack converts them by
#                          5.3.6's rules (decided), so they must match, and the
#                          default run gates that.  coerce and limits DOCUMENT
#                          what the VM decides and are expected to report
#                          MISMATCH, in exactly one class each (measured
#                          2026-10-17; no code checks the count): coerce,
#                          numbers given to c/s/z (LuaJIT writes 1e14 as
#                          "1e+14", -0 as "-0"); limits, unpack past the C
#                          stack's 8000 slots.
#   OCLJ_PACKFUZZ_OUT      results directory; must not exist
#                          (default $OCLJ_BUILD/packfuzz-<UTC stamp>)
#
# Default: 1 seed x 20000 cases, about 4 s.  The longer campaign is
#   OCLJ_PACKFUZZ_SEED=1000 OCLJ_PACKFUZZ_SEEDS=50 OCLJ_PACKFUZZ_CASES=100000
# (5 million cases; a passing seed's two output files are deleted to bound
# the disk).
#
# Exit status 0 = every seed EXACT or the decided rounding.
#            1 = a MISMATCH, a crash, or string.pack missing (every build
#                before 2026-10-17 exits 1 here).
#            2 = the test proved nothing (no or wrong reference, no build,
#                desynchronised generator, coverage hole).
# A run with any seed at 1 exits 1; otherwise any 2 gives 2.
# =====================================================================
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${OCLJ_LUA53:=$OCLJ_REPO/bench/vendor/lua-5.3.6/src/lua.exe}"
: "${OCLJ_PACKFUZZ_SEED:=1}"
: "${OCLJ_PACKFUZZ_SEEDS:=1}"
: "${OCLJ_PACKFUZZ_CASES:=20000}"
: "${OCLJ_PACKFUZZ_PROFILE:=default}"
: "${OCLJ_PACKFUZZ_OUT:=$OCLJ_BUILD/packfuzz-$(date -u +%Y%m%dT%H%M%SZ)}"

fail() { echo "PACKFUZZ SETUP FAIL: $*" >&2; exit 2; }

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) OCLJ_OS=windows ; EXE=.exe ;;
  Linux)   OCLJ_OS=linux  ; EXE= ;;
  Darwin)  OCLJ_OS=darwin ; EXE= ;;
  *) fail "unsupported host system $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  OCLJ_ARCH=x86_64  ;;
  aarch64|arm64) OCLJ_ARCH=aarch64 ;;
  *) fail "unsupported machine $(uname -m)" ;;
esac
PLATFORM="$OCLJ_OS-$OCLJ_ARCH"
LJEXE=$OCLJ_BUILD/luajit-$PLATFORM/src/luajit$EXE
P=$SELF_DIR/pack
[ -x "$LJEXE" ] || fail "no $LJEXE -- run build-native.sh first (on THIS platform)"
[ -f "$P/packfuzz.lua" ] && [ -f "$P/packfuzz-cmp.lua" ] || fail "no $P/packfuzz.lua or packfuzz-cmp.lua"
case "$OCLJ_PACKFUZZ_SEED$OCLJ_PACKFUZZ_SEEDS$OCLJ_PACKFUZZ_CASES" in
  *[!0-9]*|'') fail "OCLJ_PACKFUZZ_SEED, _SEEDS and _CASES must be whole numbers" ;;
esac

# THE REFERENCE.  Without it nothing is compared, so its absence is a 2.
[ -x "$OCLJ_LUA53" ] || OCLJ_LUA53=${OCLJ_LUA53%.exe}
[ -x "$OCLJ_LUA53" ] || fail "no PUC Lua 5.3.6 at $OCLJ_LUA53 (build bench/vendor/lua-5.3.6 or set OCLJ_LUA53)"
ref_v=$("$OCLJ_LUA53" -v 2>&1)
case "$ref_v" in
  "Lua 5.3.6"*) ;;
  *) fail "the reference reports '$ref_v', not Lua 5.3.6" ;;
esac
ours_v=$("$LJEXE" -v 2>&1)
case "$ours_v" in
  LuaJIT*) ;;
  *) fail "the build's interpreter reports '$ours_v', not LuaJIT" ;;
esac

[ -e "$OCLJ_PACKFUZZ_OUT" ] && fail "$OCLJ_PACKFUZZ_OUT exists; results are never overwritten"
mkdir -p "$OCLJ_PACKFUZZ_OUT" || fail "cannot create $OCLJ_PACKFUZZ_OUT"
OUT=$OCLJ_PACKFUZZ_OUT

echo "packfuzz: reference $ref_v; ours $LJEXE; profile $OCLJ_PACKFUZZ_PROFILE; seeds $OCLJ_PACKFUZZ_SEED..$((OCLJ_PACKFUZZ_SEED + OCLJ_PACKFUZZ_SEEDS - 1)) x $OCLJ_PACKFUZZ_CASES cases; results $OUT"
any1=0; any2=0
i=0
while [ "$i" -lt "$OCLJ_PACKFUZZ_SEEDS" ]; do
  s=$((OCLJ_PACKFUZZ_SEED + i)); i=$((i + 1))
  if ! "$OCLJ_LUA53" "$P/packfuzz.lua" "$OUT/puc-$s.txt" puc "$s" "$OCLJ_PACKFUZZ_CASES" "$OCLJ_PACKFUZZ_PROFILE" 2> "$OUT/puc-$s.err"; then
    echo "seed $s: 2 -- the reference run failed: $(head -c 300 "$OUT/puc-$s.err")"; any2=1; continue
  fi
  "$LJEXE" "$P/packfuzz.lua" "$OUT/ours-$s.txt" ours "$s" "$OCLJ_PACKFUZZ_CASES" "$OCLJ_PACKFUZZ_PROFILE" 2> "$OUT/ours-$s.err"
  orc=$?
  if [ ! -s "$OUT/ours-$s.txt" ]; then
    # the script raised before writing: string.pack missing, or the VM refused the script
    echo "seed $s: 1 -- no output from our side (exit $orc): $(head -c 300 "$OUT/ours-$s.err")"; any1=1; continue
  fi
  "$OCLJ_LUA53" "$P/packfuzz-cmp.lua" "$OUT/puc-$s.txt" "$OUT/ours-$s.txt" 3 > "$OUT/cmp-$s.txt"
  crc=$?
  # The reference run succeeded (above), so a nonzero exit from our side is a
  # failure whatever the compare said: a crash can cut the ours file at a
  # case boundary, before its #cov/#ops/#end lines, or mid-line.
  [ "$orc" -ne 0 ] && crc=1
  echo "seed $s: $crc -- $(sed -n 2p "$OUT/cmp-$s.txt" | sed 's/^ *//')"
  [ "$orc" -ne 0 ] && echo "seed $s: our side exited $orc: $(head -c 300 "$OUT/ours-$s.err")"
  case $crc in
    0) [ "$OCLJ_PACKFUZZ_SEEDS" -gt 1 ] && rm -f "$OUT/puc-$s.txt" "$OUT/ours-$s.txt" ;;  # bound disk on campaigns
    1) any1=1
       if grep -q '^MISMATCH classes' "$OUT/cmp-$s.txt"; then sed -n '/^MISMATCH classes/,$p' "$OUT/cmp-$s.txt" | head -40
       else head -20 "$OUT/cmp-$s.txt"; fi ;;
    *) any2=1; head -20 "$OUT/cmp-$s.txt" ;;
  esac
done
[ "$any1" -eq 1 ] && { echo "PACKFUZZ FAIL (results: $OUT)"; exit 1; }
[ "$any2" -eq 1 ] && { echo "PACKFUZZ PROVED NOTHING (results: $OUT)"; exit 2; }
echo "PACKFUZZ PASS (results: $OUT)"
exit 0
