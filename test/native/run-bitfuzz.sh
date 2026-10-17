#!/bin/sh
# =====================================================================
# run-bitfuzz.sh -- differential fuzzing of Lua 5.3's bitwise operators
# (& | ~ << >> and unary ~) on our LuaJIT against PUC Lua 5.3.6, under the
# decided rule U1-B: an operator's 64-bit result is its double when it has at
# most 53 significant bits, and otherwise raises "result of '<op>' has more
# than 53 significant bits (mask each operand to 32 bits first)"
# (native/luajit/oclj_bitop.h; decided 2026-10-17).  The comparator classes
# that error by its operator and ignores the text after "bits"; run-bitop.sh
# pins the text.
#
#   OCLJ_BUILD=<build dir used by build-native.sh>  sh test/native/run-bitfuzz.sh
#
# Requires build-native.sh to have run first, on THIS platform: "ours" is the
# luajit.exe that links the same libluajit.a the natives link.  And a built
# PUC Lua 5.3.6 (bench/vendor/lua-5.3.6, git-ignored; or OCLJ_LUA53).
#
# The generator (bitop/bitfuzz.lua) draws the same cases on both VMs from a
# seeded integer-exact PRNG: random expression trees of the five binary
# operators and unary ~ over up to four operands, each case run with 16
# operand tuples (ints, powers of two, 63-bit values, masks, integral floats,
# numeric strings, and a few bad operands).  Ours computes each tuple five
# ways: K, every operand a literal (the parser's folding); V, arguments (the
# interpreter); P, V with minimal parentheses (the parser's precedence); H, a
# hot loop over all tuples (the JIT's recorder and assembler); U, literals
# stored to locals inside a hot loop (the JIT's fold engine).  The reference
# is PUC 5.3.6 with the rule applied at every operator (X in bitfuzz.lua).
# The comparator (bitop/bitfuzz-cmp.lua, run under PUC) wants every mode of
# every tuple equal to the reference; errors compare by kind, the rule's own
# error with its operator (E:INEXACT:<op>).  It runs ours twice, JIT on and
# -joff.  The JIT-on run's #cov line must say "jit on", and it must compile
# traces in at least OCLJ_BITFUZZ_HOTMIN of its cases' H loops and of its U
# loops, else the run proved nothing (bitfuzz-cmp.lua's header has the
# measurements behind the default).  An ours run that exits nonzero fails
# the seed whatever the comparator said, and an ours file without its #end
# line is a crash, never compared tuple by tuple.
#
# THREE CONTROLS, per seed, prove the instrument (PUC plays the VM):
#   sim-wrap   a correct VM, each op wrapped in the rule: must PASS;
#   sim-raw    exact 5.3.6, no rule: must FAIL in exactly the INEXACT tuples
#              (REF ~= RAW), and there must be some (the rule is not vacuous);
#   sim-round  the rejected U1-A, each result rounded to the nearest double:
#              must FAIL in exactly the tuples whose reference is E:INEXACT
#              (the instrument tells raising from rounding).
# A control that misbehaves makes the seed a 2 whatever the build did.
#
# Environment:
#   OCLJ_LUA53            the reference (default bench/vendor/lua-5.3.6/src/lua[.exe]);
#                         refused unless `-v` says "Lua 5.3.6"
#   OCLJ_BITFUZZ_SEED     first seed                                   (default 1)
#   OCLJ_BITFUZZ_SEEDS    how many consecutive seeds                    (default 1)
#   OCLJ_BITFUZZ_CASES    cases per seed                                (default 1000)
#   OCLJ_BITFUZZ_TUPLES   operand tuples per case                       (default 16)
#   OCLJ_BITFUZZ_HOTMIN   the coverage gate, a fraction                 (default 0.25)
#   OCLJ_BITFUZZ_STRICT   1: also compare the type error's verb ("bitwise
#                         operation" against LuaJIT's "arithmetic")    (default 0)
#   OCLJ_BITFUZZ_PRUNE    1: delete a passing seed's six tuple files, keeping
#                         its comparator outputs (default 0: keep all; about
#                         6.3 MB per 1000 cases, so a 50 x 20000 campaign
#                         writes about 6.3 GB unpruned)
#   OCLJ_BITFUZZ_OUT      results directory; must not exist
#                         (default $OCLJ_BUILD/bitfuzz-<UTC stamp>)
#
# Default: 1 seed x 1000 cases x 16 tuples, a few seconds.  The campaign is
#   OCLJ_BITFUZZ_SEED=11 OCLJ_BITFUZZ_SEEDS=50 OCLJ_BITFUZZ_CASES=20000
#
# Exit status 0 = every seed's every tuple equals the reference, and the
#                 controls behave.
#            1 = a MISMATCH, or a crash: an ours run that exits nonzero, or
#                an ours file without #end (today's 32-bit operators exit 1).
#            2 = the test proved nothing (no or wrong reference, no build, a
#                control misbehaved, desynchronised files, too few traces, a
#                JIT-on run whose #cov line says the JIT was off, a zero
#                seed, case or tuple count).
# A run with any seed at 1 exits 1; otherwise any 2 gives 2.
# =====================================================================
set -u
# Neither VM may run code from the caller's environment before the scripts:
# LUA_INIT (LuaJIT, and PUC without the next) and LUA_INIT_5_3 (PUC 5.3).
# (LUA_INIT='if jit then jit.off() end' once turned the JIT-on run into a
# second interpreter run that passed: review of 2026-10-17.)
unset LUA_INIT LUA_INIT_5_3
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${OCLJ_LUA53:=$OCLJ_REPO/bench/vendor/lua-5.3.6/src/lua.exe}"
: "${OCLJ_BITFUZZ_SEED:=1}"
: "${OCLJ_BITFUZZ_SEEDS:=1}"
: "${OCLJ_BITFUZZ_CASES:=1000}"
: "${OCLJ_BITFUZZ_TUPLES:=16}"
: "${OCLJ_BITFUZZ_HOTMIN:=0.25}"
: "${OCLJ_BITFUZZ_STRICT:=0}"
: "${OCLJ_BITFUZZ_PRUNE:=0}"
: "${OCLJ_BITFUZZ_OUT:=$OCLJ_BUILD/bitfuzz-$(date -u +%Y%m%dT%H%M%SZ)}"

fail() { echo "BITFUZZ SETUP FAIL: $*" >&2; exit 2; }

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
B=$SELF_DIR/bitop
[ -x "$LJEXE" ] || fail "no $LJEXE -- run build-native.sh first (on THIS platform)"
[ -f "$B/bitfuzz.lua" ] && [ -f "$B/bitfuzz-cmp.lua" ] || fail "no $B/bitfuzz.lua or bitfuzz-cmp.lua"
for v in "$OCLJ_BITFUZZ_SEED" "$OCLJ_BITFUZZ_SEEDS" "$OCLJ_BITFUZZ_CASES" "$OCLJ_BITFUZZ_TUPLES"; do
  case "$v" in *[!0-9]*|'') fail "OCLJ_BITFUZZ_SEED, _SEEDS, _CASES and _TUPLES must be whole numbers" ;; esac
done
# Zero seeds, cases or tuples would compare nothing and pass.
[ "$OCLJ_BITFUZZ_SEEDS" -gt 0 ] && [ "$OCLJ_BITFUZZ_CASES" -gt 0 ] && [ "$OCLJ_BITFUZZ_TUPLES" -gt 0 ] \
  || fail "OCLJ_BITFUZZ_SEEDS, _CASES and _TUPLES must be at least 1 (0 would test nothing and pass)"
case "$OCLJ_BITFUZZ_HOTMIN" in
  0|0.[0-9]*|1) ;;
  *) fail "OCLJ_BITFUZZ_HOTMIN must be a fraction from 0 to 1, not '$OCLJ_BITFUZZ_HOTMIN'" ;;
esac
STRICT=
[ "$OCLJ_BITFUZZ_STRICT" = 1 ] && STRICT=strict

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

[ -e "$OCLJ_BITFUZZ_OUT" ] && fail "$OCLJ_BITFUZZ_OUT exists; results are never overwritten"
mkdir -p "$OCLJ_BITFUZZ_OUT" || fail "cannot create $OCLJ_BITFUZZ_OUT"
OUT=$OCLJ_BITFUZZ_OUT
md5sum "$LJEXE" "$OCLJ_LUA53" "$B/bitfuzz.lua" "$B/bitfuzz-cmp.lua" > "$OUT/inputs.md5"
# jit.vmdef (the abort reasons' names in the #cov line) lives beside the
# build's luajit.exe, in src/jit; the Windows exe needs a C:/ path.
LJDIR=$(dirname "$LJEXE"); command -v cygpath >/dev/null 2>&1 && LJDIR=$(cygpath -m "$LJDIR")
export LUA_PATH="$LJDIR/?.lua;;"

C=$OCLJ_BITFUZZ_CASES; T=$OCLJ_BITFUZZ_TUPLES
echo "bitfuzz: reference $ref_v; ours $LJEXE; seeds $OCLJ_BITFUZZ_SEED..$((OCLJ_BITFUZZ_SEED + OCLJ_BITFUZZ_SEEDS - 1)) x $C cases x $T tuples; hotmin $OCLJ_BITFUZZ_HOTMIN${STRICT:+; strict}; results $OUT"
any1=0; any2=0
i=0
while [ "$i" -lt "$OCLJ_BITFUZZ_SEEDS" ]; do
  s=$((OCLJ_BITFUZZ_SEED + i)); i=$((i + 1))
  # The reference and the three controls run on PUC; a failure there is the
  # instrument's, so the seed proves nothing.
  pucbad=
  for side in puc sim-wrap sim-raw sim-round; do
    if ! "$OCLJ_LUA53" "$B/bitfuzz.lua" "$side" "$s" "$C" "$OUT/$side-$s.txt" "$T" 2> "$OUT/$side-$s.err"; then
      pucbad="$side: $(head -c 300 "$OUT/$side-$s.err")"; break
    fi
  done
  if [ -n "$pucbad" ]; then echo "seed $s: 2 -- a PUC run failed ($pucbad)"; any2=1; continue; fi
  "$LJEXE" "$B/bitfuzz.lua" ours "$s" "$C" "$OUT/ours-jon-$s.txt" "$T" 2> "$OUT/ours-jon-$s.err"; rj=$?
  "$LJEXE" -joff "$B/bitfuzz.lua" ours "$s" "$C" "$OUT/ours-joff-$s.txt" "$T" 2> "$OUT/ours-joff-$s.err"; rf=$?

  # The controls.
  ctl=
  "$OCLJ_LUA53" "$B/bitfuzz-cmp.lua" "$OUT/puc-$s.txt" "$OUT/sim-wrap-$s.txt" hotmin=0 > "$OUT/cmp-sim-wrap-$s.txt"; ca=$?
  "$OCLJ_LUA53" "$B/bitfuzz-cmp.lua" "$OUT/puc-$s.txt" "$OUT/sim-raw-$s.txt" hotmin=0 maxex=1 > "$OUT/cmp-sim-raw-$s.txt"; cb=$?
  "$OCLJ_LUA53" "$B/bitfuzz-cmp.lua" "$OUT/puc-$s.txt" "$OUT/sim-round-$s.txt" hotmin=0 maxex=1 > "$OUT/cmp-sim-round-$s.txt"; cr=$?
  # From the reference line: the INEXACT tuples (REF ~= RAW), and the tuples
  # whose REF is E:INEXACT (the comparator has checked that they are equal).
  ni=$(sed -n 's/^reference: [0-9]* tuples, EXACT [0-9]*, INEXACT \([0-9]*\) .*/\1/p' "$OUT/cmp-sim-wrap-$s.txt")
  ne=$(sed -n 's/^reference: .*REF results: .*E:INEXACT \([0-9]*\).*/\1/p' "$OUT/cmp-sim-wrap-$s.txt")
  mm() { sed -n 's/^.*tuples, MISMATCH \([0-9]*\) (of them INEXACT in the reference: \([0-9]*\)).*/\1 \2/p' "$1"; }
  mb=$(mm "$OUT/cmp-sim-raw-$s.txt"); mr=$(mm "$OUT/cmp-sim-round-$s.txt")
  [ "$ca" = 0 ] || ctl="$ctl sim-wrap exited $ca (the comparator rejects a correct VM);"
  if [ "$cb" = 1 ] && [ -n "$ni" ] && [ "$ni" -gt 0 ] && [ "$mb" = "$ni $ni" ]; then :; else
    ctl="$ctl sim-raw exited $cb with mismatch/of-them-INEXACT '$mb' against INEXACT '${ni:-?}' (the rule is vacuous or leaks);"
  fi
  if [ "$cr" = 1 ] && [ -n "$ne" ] && [ "$ne" -gt 0 ] && [ "$mr" = "$ne $ne" ]; then :; else
    ctl="$ctl sim-round exited $cr with mismatch/of-them-INEXACT '$mr' against REF E:INEXACT '${ne:-?}' (rounding passes, or fails elsewhere);"
  fi

  # The build.
  "$OCLJ_LUA53" "$B/bitfuzz-cmp.lua" "$OUT/puc-$s.txt" "$OUT/ours-jon-$s.txt" "$OUT/ours-joff-$s.txt" \
    $STRICT hotmin="$OCLJ_BITFUZZ_HOTMIN" > "$OUT/cmp-ours-$s.txt"
  crc=$?
  # The reference ran (above), so a nonzero exit from our side is a failure
  # whatever the compare said, its 2 included: a crash can cut an ours file
  # at a tuple.
  if [ "$rj" -ne 0 ] || [ "$rf" -ne 0 ]; then crc=1; fi
  # The JIT-on run must have run with the JIT on, or H and U tested only the
  # interpreter: a pass then proves nothing (a mismatch is still a FAIL).
  jon=
  if grep -q '^#cov' "$OUT/ours-jon-$s.txt"; then
    grep -q '^#cov .* jit on$' "$OUT/ours-jon-$s.txt" \
      || jon="its #cov line ends '$(grep '^#cov' "$OUT/ours-jon-$s.txt" | sed 's/^.* jit /jit /')', not 'jit on'"
  else
    jon="it wrote no #cov line"
  fi
  if [ -n "$jon" ] && [ "$crc" -eq 0 ]; then crc=2; fi
  # A misbehaving control proves the instrument wrong: nothing is proved.
  [ -n "$ctl" ] && crc=2
  echo "seed $s: $crc -- $(sed -n 1p "$OUT/cmp-ours-$s.txt" | sed 's/^reference: //')"
  sed -n '/tuples, MISMATCH/p; /CRASH/p; /^  #cov/p; /^  =>/p' "$OUT/cmp-ours-$s.txt" | cut -c1-260 | sed 's/^/    /'
  [ -n "$jon" ] && [ "$rj" -eq 0 ] && echo "seed $s: the JIT-on run proved nothing: $jon"
  echo "    controls: sim-wrap $( [ "$ca" = 0 ] && echo PASS || echo "exit $ca"); sim-raw MISMATCH ${mb%% *} of INEXACT ${ni:-?}; sim-round MISMATCH ${mr%% *} of REF E:INEXACT ${ne:-?}"
  [ -n "$ctl" ] && echo "seed $s: CONTROL FAILED:$ctl"
  [ "$rj" -ne 0 ] && echo "seed $s: our JIT-on run exited $rj: $(head -c 300 "$OUT/ours-jon-$s.err")"
  [ "$rf" -ne 0 ] && echo "seed $s: our -joff run exited $rf: $(head -c 300 "$OUT/ours-joff-$s.err")"
  case $crc in
    0) [ "$OCLJ_BITFUZZ_PRUNE" = 1 ] && rm -f "$OUT/puc-$s.txt" "$OUT/sim-wrap-$s.txt" "$OUT/sim-raw-$s.txt" \
         "$OUT/sim-round-$s.txt" "$OUT/ours-jon-$s.txt" "$OUT/ours-joff-$s.txt" ;;
    1) any1=1
       if grep -q 'MISMATCH classes' "$OUT/cmp-ours-$s.txt"; then sed -n '/MISMATCH classes/,$p' "$OUT/cmp-ours-$s.txt" | head -40
       else head -20 "$OUT/cmp-ours-$s.txt"; fi ;;
    *) any2=1; grep -E 'INSTRUMENT|bitfuzz-cmp:' "$OUT/cmp-ours-$s.txt" | head -5 ;;
  esac
done
[ "$any1" -eq 1 ] && { echo "BITFUZZ FAIL (results: $OUT)"; exit 1; }
[ "$any2" -eq 1 ] && { echo "BITFUZZ PROVED NOTHING (results: $OUT)"; exit 2; }
echo "BITFUZZ PASS (results: $OUT)"
exit 0
