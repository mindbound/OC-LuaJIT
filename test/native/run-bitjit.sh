#!/bin/sh
# =====================================================================
# run-bitjit.sh -- the JIT against the interpreter, and both against PUC Lua
# 5.3.6, for Lua 5.3's bitwise operators (& | ~ << >> ~>> and unary ~) under
# the decided rule U1-B: an operator's 64-bit result is its double when it
# has at most 53 significant bits, and otherwise raises "result of '<op>' has
# more than 53 significant bits (mask each operand to 32 bits first)"
# (decided 2026-10-17).  The suites here classify that error by its operator
# and ignore the text after "bits"; run-bitop.sh pins the text.
#
#   OCLJ_BUILD=<build dir used by build-native.sh>  sh test/native/run-bitjit.sh
#
# Requires build-native.sh to have run first, on THIS platform: the luajit.exe
# that links the same libluajit.a the natives link, and its src/jit/vmdef.lua.
# PUC Lua 5.3.6 (bench/vendor/lua-5.3.6, git-ignored; or OCLJ_LUA53) is
# required unless the caller declines it: when OCLJ_LUA53 names no PUC Lua
# 5.3.6 (its -v, and a 5.3 chunk it runs: luac's -v is the same), every PUC
# comparison says SKIPPED and the run ends PROVED NOTHING (exit 2), since its
# default is relative to OCLJ_REPO and a git-archive scratch repo has no
# bench/vendor (until 2026-10-20 such a run passed: verify-folda F11).
# OCLJ_LUA53=none runs without PUC on purpose, and the run can pass.
# Seven parts (the fifth, sel, is not about the bit operators: it is the
# JIT-against-interpreter runner's home for the select fix):
#
#   1. THE GENERATOR (gen).  bitop/gen.lua, the round-3 width-fold reviewer's
#      adversarial loop generator, writes OCLJ_BITJIT_SEEDS seeds of
#      OCLJ_BITJIT_CASES loops each (carried values, branches, flipped types,
#      inner loops, helper calls, table and upvalue round trips, double
#      arithmetic, shift counts and masks at the fold engine's width bound).
#      bitop/drv.lua runs each loop from seven starts under -joff and under
#      five JIT option sets -- the default, -O3 -Ohotloop=1, -Omaxside=0,
#      -Ohotloop=1 -Ohotexit=1, -O3 -O-loop -- once with one closure per loop
#      (shared: later starts run the first start's traces and side exits) and
#      once with a fresh closure per start.  Every output must equal -joff's
#      in the same mode, line for line; errors print as ERR@<loop variable>:
#      <kind>.  With PUC, drv.lua also runs the PUC twin (the same loops with
#      U1-B's rule at every operator), which must equal -joff's too.  A
#      coverage line per seed counts the cases, the runs, the runs that
#      raised, the runs that raised after their 60th iteration (likely from
#      compiled code: the default hotloop is 56) and the cases in which a
#      trace completed; the JIT-on shared run must complete one in at least
#      OCLJ_BITJIT_HOTMIN of the cases, else the part proved nothing.
#      Measured 2026-10-17 on r3/b/bB, seeds 1-3: traced 67-70% of the cases;
#      on a copy whose recorder refuses every bit operator, 1.5-2.1%.
#   2. THE FLOOR (floor).  bitop/t_rec.lua (loop-carried recurrences; seeds 1
#      and 2, and seeds 3 and 4 with out-of-range shift counts; 400 each)
#      under the default options, -O3 -Ohotloop=1 and -Omaxside=0, and
#      bitop/t_jit2.lua (27 hand-built loops) under the default, -O0, -O1,
#      -O3 -Ohotloop=1, -Omaxside=0 and -Ohotloop=1 -Ohotexit=1: each output
#      must equal -joff's.  With PUC, t_jit2.lua's PUC text must equal
#      -joff's output too, but for its one LuaJIT-only line (sar: ~>>).
#      bitop/t_rg2.lua (15 loops at a result guard's 2^53 boundary: in range
#      at both bounds, exact past it, inexact just past it, crossing it after
#      the loop compiled; written for the CRC32 follow-up's range guard, rg2,
#      which was prototyped and not shipped, 2026-10-20) under t_jit2.lua's
#      option sets, against -joff, and its PUC text against -joff but for
#      sar-edge (~>>).
#   3. FIX1 (fix1).  bitop/p4v.lua: the eight loops that carry a value set
#      from the loop index through an identity bit operation must compile --
#      no "persistent type instability" abort, a trace attached to the loop
#      (JFORL), not blacklisted (IFORL) -- and their results must equal
#      -joff's.  Without fix1 (lj_opt_fold.c simplify_conv_i64_num's PHI
#      condition) seven of them are blacklisted; no timing is involved.
#   4. THE TABLE-INDEX FOLD (idx; the CRC32 follow-up, roadmap row 209:
#      patch-bitop-fold.sh's hunk 11 folds CONV int.num (CONV num.i64 y) to
#      the unguarded CONV int.i64 y when oclj_bitwidth(y) <= 32, never across
#      a PHI).  bitop/t_idx.lua (bit results as table keys, string.byte and
#      string.sub arguments, shift counts and an int for loop's stop, at
#      bounds 32 and 33), bitop/t_cnt33.lua (variable shift counts of 33
#      bits whose low 32 bits are small) and bitop/t_idx2.lua (rawget,
#      narrowing's leaves, string.byte, sub, find, char and rep, table.concat
#      and unpack, shift counts and a loop stop, each plain, in a branch and
#      with a carried key; select is left out, see its header) under the
#      default, -O0, -O1, -O3 -Ohotloop=1, -Omaxside=0, -Ohotloop=1
#      -Ohotexit=1, -O3 -O-loop, -O3 -O-fold and -O3 -O-cse: each output must
#      equal -joff's, and with PUC the twin's (bitop/twin.lua: U1-B's rule at
#      every operator, ~>> as SAR) must equal -joff's too (t_idx2.lua: its
#      "puc" part, the consumers whose meaning PUC shares).  Each suite's
#      default run's #cov line must say jit on, a trace completed in
#      OCLJ_BITJIT_HOTMIN of the cases, and at least one CONV int.i64 (the
#      fold fired), else the part proved nothing.  Then bitop/phiidx.lua
#      reads the compiled loops: the fold folds where it belongs and never
#      across a PHI (a crossing fold computes the right values, so only the
#      IR shows it), every loop compiles (no type instability, JFORL), and
#      the results equal -joff's.  The generator's idx and rg2 modes are not
#      in the default run: they are campaigns (below).
#   5. SELECT (sel; roadmap row 213, JIT guide P54: patch-bitop-record.sh's
#      hunks 4 and 5 bound select's index k in rec_varg, aborting the
#      recording for a k above 2^27 and, where k is beyond the varargs,
#      exiting unless 1 <= k <= 2^27 before the 32-bit 8*k+frofs).
#      bitop/t_select.lua records select(k, ...) loops on each of rec_varg's
#      paths (a constant k, k within the varargs, k beyond them, '#'; k from
#      a table, a string, narrowing's unchecked ADD, a bit result, the loop
#      index; calls with fewer arguments than fixed parameters) and feeds
#      them k in range, past the end, negative, 0, wrapping, large and out of
#      int32, under the idx part's nine option sets and six more for exits,
#      side traces, ABC and narrowing (SELOPTS): each output, results and
#      raises, must equal -joff's; with PUC its "puc" part (integral k below
#      2^31, where select's meaning is the same) must equal -joff's.  Its
#      default run's #cov line must say jit on, a trace in OCLJ_BITJIT_HOTMIN
#      of the cases, each path's guard and the fix's guard at least once, and
#      the three loops recorded with k = 2^27 compiled; and in every JIT run
#      no loop recorded only with k above 2^27 may compile a select trace
#      (t_select-kmax).
#   6. FIX-NUMCONV (nc; roadmap row 211 (5), JIT guide 3.11:
#      patch-bitop-fold.sh's hunk 7 folds (i64)(num)y ==> y in
#      simplify_conv_i64_num when y is an unguarded CONV i64.num of a
#      double, oclj_isnumconv, so an identity operation's result guard, which
#      cannot fail, goes).  bitop/t_numconv.lua runs identities (x | 0,
#      x & -1, x ~ 0, x << 0, x >> 0, x ~>> 0, x & x, ...), cancellations
#      (~~x, (x ~ y) ~ y, ...) and controls whose guard must stay (x | 1,
#      x ~ y, ~x, ...), each recorded on small values and then met in the
#      same compiled loop by values at and past 2^53, -0.0, NaN, infinities
#      and +-2^63 and beyond, on a table's double, on a carried identity
#      result, and through the loop's PHI, under the sel part's fifteen
#      option sets: each output must equal -joff's, and with PUC the twin's
#      (bitop/twin.lua) must equal -joff's.  Its default run's #cov line must
#      say jit on, a trace in OCLJ_BITJIT_HOTMIN of the cases and at least
#      one marked CONV num.i64 of an unmarked conversion of a double (ncin:
#      the pair the rule reads), else it proved nothing.  Then bitop/ncir.lua
#      reads the compiled loops under the thirteen of those sets that fold
#      (no rule runs under -O0 or -O-fold, and ncir refuses them): no
#      identity keeps a result guard on its operand's own conversion, each
#      cancellation and control keeps exactly its one, every loop compiles
#      (no type instability, JFORL; the rule returns a pre-roll ref across a
#      PHI), the body's guard on a PHI-marked fleft is gone (swap1), the
#      results equal -joff's, and a run with no summary line read nothing.
#   7. THE CSE TWINS (cse; JIT guide P63, 3.9: patch-bitop-fold.sh's hunk
#      12 makes lj_opt_cse refuse a match when exactly one of the two
#      instructions is IRT_I64; before it, on x64, where simplify_conv_sext
#      hands our int64 operators the int loop index or a string.byte value
#      directly, a 32-bit instruction on the same operands served our
#      operator, and the 5.3 operator got the 32-bit value, zero-extended).
#      bitop/t_csefwd.lua runs 32 loops, the forward order only (the
#      32-bit producer first: the bit library, select beyond its varargs, a
#      narrowed string.byte or string.sub argument, an inner for loop's
#      step), 13 whose served value is wrong (bit.lshift(i, 3) then i << 3,
#      the bnot and bxor forms, a masked count, a u8 operand, the nested
#      (i & m) << k, reassoc_shift, a chain, variable counts of 32-63, a
#      pair that forms only in the loop copy and one only in a side trace),
#      7 whose served value is right (the in-game families among them) and
#      12 controls, each checked against a plain-arithmetic reference (the
#      file exits 1 otherwise, -joff included) and compared whole with
#      -joff under the sel part's fifteen option sets; no PUC twin, by
#      design (the bit library).  Its default run's #cov line must say jit
#      on, a trace in OCLJ_BITJIT_HOTMIN of the cases, and at least one
#      pair formed.  bitop/t_cserev.lua runs the reverse order (our
#      operator first) ONLY in the two shapes whose 32-bit consumer stores
#      nothing in a Lua slot (its header argues it from the source, and the
#      user's decision of 2026-10-23 allows no other): select(j, ...)
#      beyond the varargs, and string.byte or string.sub of i + i or i * 2,
#      each after i << 1 or j << 3; its fields 1-2 must equal -joff's under
#      the fifteen sets, PUC 5.3.6's whole output must equal -joff's, every
#      JIT run must print its summary line, and its own IR read (the
#      pair kept apart, split, and no 32-bit instruction consuming our
#      int64 one, rserved, where fold, CSE and narrowing are on; never an
#      int64 instruction in a snapshot) must pass, judging all four reverse
#      cases in the default run.  bitop/cseir.lua reads t_csefwd's loops'
#      IR under the twelve of those sets with fold and CSE on (no pair
#      forms under -O0 and -O-fold, none merges under -O-cse, and it
#      refuses them, P61): our operator never served by a 32-bit
#      instruction, every pair kept apart where it forms, no int64
#      instruction in a snapshot, every loop compiled, results equal to
#      -joff's, a summary line in every run and every pair judged in the
#      default one.
#
# Each part's catches, measured on one-line sabotages of the reference build
# (2026-10-17, role C2's report has the counts): the generator catches every
# fold-rule sabotage (SELFGUARD, WIDTH55, WSHR, WBAND, WADD0, WSHL0), the
# missing exactness guard, NARROW and KFOLD64, in every seed; the floor
# catches NARROW, KFOLD64, the missing guards (result and operand) and
# SELFGUARD, not the width rule's off-by-ones; fix1 catches FIX1, a JIT that
# records no bit operator, and (by its results) KFOLD64.  The idx part
# (2026-10-20, proto-folda and verify-folda): t_idx, t_cnt33 and t_idx2
# catch WIDTHIDX33 (the fold's bound at 33) and no other part does; phiidx
# catches PHIIDX (the fold across a PHI) and NOLOOPFOLD (no fold in a loop
# body), which change no value, so no differential suite can see them.
# The sel part (2026-10-20): t_select catches SELGUARD (no guard before
# the shift: upstream's nil for a wrapping or non-positive k), and
# t_select-kmax SELRECK (no record-time bound, which changes no value).
# The nc part (2026-10-21, on sabotage copies of the FIX-NUMCONV
# prototype's build): t_numconv catches NUMCONVOP1 (the rule widened to a
# bit operator on a converted double) and NUMCONVW (a converted double
# scored 54 bits wide in oclj_bitwidth), whose dropped guards return
# rounded doubles where the interpreter raises; ncir catches NUMCONVOFF
# (the rule switched off, which changes no value, so no differential suite
# can see it), and the two value arms too, and fails on any build without
# the rule (build/native at 209aa95).
# The cse part (2026-10-23, the round's test implementer, and its fixer
# after adding the copy and side cases): on build/native at 1a13bed
# (luajit.exe f4038cd6, no fix) it FAILs, in six runs on Windows (cseir's
# judge as now in the last five) and one in AlmaLinux 8: t_csefwd in 13
# cases in 7 of the 10 sets with fold, CSE and narrowing on, 12 under
# -O-loop and the two -Omaxside=0 sets, 2 under -O1 and -O-narrow, 0 under
# -O0, -O-fold and -O-cse, except that the side case's value depends on
# whether a trace compiles its branch, which varied: 12 once under
# -Ohotloop=1 -Ohotexit=1, 13 once in 14 readings of the -Omaxside=0 sets;
# cseir in 20 (19 under -O-loop and the two -Omaxside=0 sets, 2 under -O1
# and -O-narrow) in every run; t_cserev in its 4 reverse cases wherever it
# judges them.  With the fix (impl-tests' prototype, lj_opt_fold.o
# a6c5fcc2, five runs before copy and side, and the fixer's build of the
# same object) every check passes; with CSEFWD's sabotage
# text (forward merges only) t_csefwd and cseir fail as on build/native
# and t_cserev passes.
# Proof that the checks can fail: negctl-bitop.sh.
#
# Environment:
#   OCLJ_LUA53            PUC Lua 5.3.6 (default bench/vendor/lua-5.3.6/src/lua[.exe]),
#                         or "none": no PUC comparison, on purpose
#   OCLJ_BITJIT_PARTS     the parts to run, of "gen floor fix1 idx sel nc cse"  (default all seven)
#   OCLJ_BITJIT_SEED      the generator's first seed                  (default 1)
#   OCLJ_BITJIT_SEEDS     how many consecutive seeds                   (default 4)
#   OCLJ_BITJIT_CASES     loops per seed                               (default 2000)
#   OCLJ_BITJIT_GENMODE   empty; "phi": half the generated statements carry a
#                         finitely-bounded value across the loop's PHI;
#                         "idx": index expressions at the table-index fold's
#                         bound, as keys, string.byte arguments and counts;
#                         or "rg2": results at and past 2^53 (exact values in
#                         bits 53-63 among them); each mode passes on any
#                         build whose results equal the interpreter's
#   OCLJ_BITJIT_HOTMIN    the coverage gate of the generator and of the idx,
#                         sel, nc and cse parts, a fraction             (default 0.25)
#   OCLJ_BITJIT_OUT       results directory; must not exist
#                         (default $OCLJ_BUILD/bitjit-<UTC stamp>)
#
# Default: about 70 s (61 s for all six parts on FIX-NUMCONV's prototype,
# 2026-10-21; 68 s for all seven on the CSE round's prototype, 2026-10-23;
# 4 seeds x 2000 loops, about 7 s a seed with PUC; the idx part about 10
# s; the sel part about 6 s, 2026-10-20; the nc part 6-8 s; the cse part
# 9-12 s).
# A campaign is OCLJ_BITJIT_PARTS=gen OCLJ_BITJIT_SEED=101
# OCLJ_BITJIT_SEEDS=20, and again with OCLJ_BITJIT_GENMODE=phi, idx and rg2;
# a change to the table-index fold runs the idx mode, and one to a result's
# guard the rg2 mode, at least over seeds 1-4.  Every seed's files are kept
# (about 9.6 MB a seed of 2000 loops; the default run wrote 41,580,593 bytes
# on 2026-10-17, the four seeds 9.62-9.67 MB each and the floor 3.0 MB,
# before the idx part).
#
# Exit status 0 = every comparison equal, every check passed (PUC parts
#                 passed, or were skipped under OCLJ_LUA53=none).
#            1 = a difference, a failed check, or a crash.
#            2 = the test proved nothing (no build, no PUC unless declined,
#                a PUC run failed, too few traces, an instrument check) --
#                but a FAIL recorded anywhere keeps the run at 1.
# =====================================================================
set -u
# Neither VM may run code from the caller's environment before the scripts:
# LUA_INIT (LuaJIT, and PUC without the next) and LUA_INIT_5_3 (PUC 5.3).
unset LUA_INIT LUA_INIT_5_3
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${OCLJ_LUA53:=$OCLJ_REPO/bench/vendor/lua-5.3.6/src/lua.exe}"
: "${OCLJ_BITJIT_PARTS:=gen floor fix1 idx sel nc cse}"
: "${OCLJ_BITJIT_SEED:=1}"
: "${OCLJ_BITJIT_SEEDS:=4}"
: "${OCLJ_BITJIT_CASES:=2000}"
: "${OCLJ_BITJIT_GENMODE:=}"
: "${OCLJ_BITJIT_HOTMIN:=0.25}"
: "${OCLJ_BITJIT_OUT:=$OCLJ_BUILD/bitjit-$(date -u +%Y%m%dT%H%M%SZ)}"

fail() { echo "BITJIT SETUP FAIL: $*" >&2; exit 2; }

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
for f in gen.lua drv.lua t_rec.lua t_jit2.lua p4v.lua t_rg2.lua twin.lua t_idx.lua t_cnt33.lua t_idx2.lua phiidx.lua t_select.lua t_numconv.lua ncir.lua t_csefwd.lua cseir.lua t_cserev.lua; do
  [ -f "$B/$f" ] || fail "no $B/$f"
done
for p in $OCLJ_BITJIT_PARTS; do
  case $p in gen|floor|fix1|idx|sel|nc|cse) ;; *) fail "OCLJ_BITJIT_PARTS: '$p' is not one of gen, floor, fix1, idx, sel, nc, cse" ;; esac
done
for v in "$OCLJ_BITJIT_SEED" "$OCLJ_BITJIT_SEEDS" "$OCLJ_BITJIT_CASES"; do
  case "$v" in *[!0-9]*|'') fail "OCLJ_BITJIT_SEED, _SEEDS and _CASES must be whole numbers" ;; esac
done
# Zero seeds or zero loops would compare nothing and pass.
[ "$OCLJ_BITJIT_SEEDS" -gt 0 ] && [ "$OCLJ_BITJIT_CASES" -gt 0 ] \
  || fail "OCLJ_BITJIT_SEEDS and OCLJ_BITJIT_CASES must be at least 1 (0 would test nothing and pass)"
case "$OCLJ_BITJIT_GENMODE" in ''|phi|idx|rg2) ;; *) fail "OCLJ_BITJIT_GENMODE must be empty, phi, idx or rg2" ;; esac
case "$OCLJ_BITJIT_HOTMIN" in
  0|0.[0-9]*|1) ;;
  *) fail "OCLJ_BITJIT_HOTMIN must be a fraction from 0 to 1, not '$OCLJ_BITJIT_HOTMIN'" ;;
esac
ours_v=$("$LJEXE" -v 2>&1)
case "$ours_v" in
  LuaJIT*) ;;
  *) fail "the build's interpreter reports '$ours_v', not LuaJIT" ;;
esac
# PUC: found (its -v, and a 5.3 chunk, which luac cannot run), declined, missing.
REFV=; REFI=
if [ "$OCLJ_LUA53" = none ]; then
  HAVEPUC=0; PUCSKIP="OCLJ_LUA53=none"
else
  [ -x "$OCLJ_LUA53" ] || OCLJ_LUA53=${OCLJ_LUA53%.exe}
  [ -x "$OCLJ_LUA53" ] && REFV=$("$OCLJ_LUA53" -v 2>&1) && REFI=$("$OCLJ_LUA53" -e "io.write(_VERSION, ' ', math.type(1))" 2>&1 | head -n 1)
  case "$REFV|$REFI" in "Lua 5.3.6"*"|Lua 5.3 integer") HAVEPUC=1 ;; *) HAVEPUC=0 ;; esac
  PUCSKIP="no PUC Lua 5.3.6 at $OCLJ_LUA53; ${REFV:-not found}${REFI:+; a chunk printed: $REFI}"
fi

[ -e "$OCLJ_BITJIT_OUT" ] && fail "$OCLJ_BITJIT_OUT exists; results are never overwritten"
mkdir -p "$OCLJ_BITJIT_OUT" || fail "cannot create $OCLJ_BITJIT_OUT"
OUT=$OCLJ_BITJIT_OUT
md5sum "$LJEXE" "$B/gen.lua" "$B/drv.lua" "$B/t_rec.lua" "$B/t_jit2.lua" "$B/p4v.lua" "$B/t_rg2.lua" "$B/twin.lua" "$B/t_idx.lua" "$B/t_cnt33.lua" "$B/t_idx2.lua" "$B/phiidx.lua" "$B/t_select.lua" "$B/t_numconv.lua" "$B/ncir.lua" "$B/t_csefwd.lua" "$B/cseir.lua" "$B/t_cserev.lua" > "$OUT/inputs.md5"
[ "$HAVEPUC" = 1 ] && md5sum "$OCLJ_LUA53" >> "$OUT/inputs.md5"
# jit.vmdef and jit.util's names (p4v.lua) live beside the build's luajit.exe,
# in src/jit; the Windows exe needs a C:/ path.
LJDIR=$(dirname "$LJEXE"); command -v cygpath >/dev/null 2>&1 && LJDIR=$(cygpath -m "$LJDIR")
export LUA_PATH="$LJDIR/?.lua;;"
# A run that hangs is a failure, not a wait: 300 s is 100 times a default run.
TO=; command -v timeout >/dev/null 2>&1 && TO="timeout 300"

if [ "$HAVEPUC" = 1 ]; then pucsay=$REFV; else pucsay="none ($PUCSKIP)"; fi
echo "run-bitjit: ours $LJEXE; PUC $pucsay; parts $OCLJ_BITJIT_PARTS; results $OUT"
bad=0; nothing=0
# A PUC that is missing, not declined, proves nothing: every twin would be
# skipped and the run could pass (a git-archive scratch repo has no
# bench/vendor, verify-folda F11).
if [ "$HAVEPUC" = 0 ] && [ "$OCLJ_LUA53" != none ]; then
  echo "PROVED NOTHING PUC: $PUCSKIP -- every PUC comparison is skipped; set OCLJ_LUA53 to PUC Lua 5.3.6, or OCLJ_LUA53=none to run without it on purpose"
  nothing=1
fi
wanted() { case " $OCLJ_BITJIT_PARTS " in *" $1 "*) return 0 ;; esac; return 1; }
# run <out> <err> <cmd...>: the command's stdout, CR-stripped, into <out>
# (Windows stdout writes CRLF); returns the command's exit status.
run() {
  o=$1; e=$2; shift 2
  $TO "$@" < /dev/null > "$o.raw" 2> "$e"
  rc=$?
  tr -d '\r' < "$o.raw" > "$o"; rm -f "$o.raw"
  return $rc
}
# ndiff <got> <want>: "<differing lines> <first ids>", counted both ways: the
# number is the larger of got's lines missing from want and want's lines
# missing from got, so it is 0 only when the files are identical (a short or
# empty got that exits 0 is a difference, review of 2026-10-17), and a line
# that differs counts once.  The ids are got's, or want's as missing:<id>
# when got has none of its own.
ndiff() {
  diff "$1" "$2" | awk -F'\t' '
    /^< / { a++; if (a <= 3) { id = $1; sub(/^< /, "", id); ida = ida " " id } }
    /^> / { b++; if (b <= 3) { id = $1; sub(/^> /, "", id); idb = idb " missing:" id } }
    END { n = a + 0; if (b + 0 > n) n = b + 0; ids = idb; if (a > 0) ids = ida; print n ids }'
}
# The JIT option sets (name:options; jon is the default).
GENOPTS="jon hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0 he1:-Ohotloop=1_-Ohotexit=1 noloop:-O3_-O-loop"
RECOPTS="jon hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0"
JIT2OPTS="jon O0:-O0 O1:-O1 hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0 he1:-Ohotloop=1_-Ohotexit=1"
optname() { echo "${1%%:*}"; }
optargs() { case $1 in *:*) echo "${1#*:}" | tr '_' ' ' ;; esac; }

# ---------------------------------------------------------------- 1
echo
echo "== 1. the generator: $OCLJ_BITJIT_SEEDS seeds x $OCLJ_BITJIT_CASES loops${OCLJ_BITJIT_GENMODE:+ ($OCLJ_BITJIT_GENMODE)}, five JIT option sets x two closure modes against -joff =="
if wanted gen; then
  [ "$HAVEPUC" = 1 ] || echo "PUC twin: SKIPPED ($PUCSKIP)"
  i=0
  while [ "$i" -lt "$OCLJ_BITJIT_SEEDS" ]; do
    s=$((OCLJ_BITJIT_SEED + i)); i=$((i + 1))
    D=$OUT/gen-s$s; mkdir -p "$D"
    if ! $TO "$LJEXE" "$B/gen.lua" "$s" "$OCLJ_BITJIT_CASES" "$D" $OCLJ_BITJIT_GENMODE < /dev/null > "$D/gen.log" 2>&1; then
      echo "seed $s: PROVED NOTHING -- gen.lua failed: $(head -c 300 "$D/gen.log")"; nothing=1; continue
    fi
    line="seed $s:"; sbad=0; snothing=0; detail=
    for m in shared fresh; do
      run "$D/$m-joff.txt" "$D/$m-joff.err" "$LJEXE" -joff "$B/drv.lua" "$D/cases_lj.lua" "$m"; rc=$?
      nl=$(grep -c . "$D/$m-joff.txt")
      if [ "$rc" -ne 0 ] || [ "$nl" -ne "$OCLJ_BITJIT_CASES" ]; then
        detail="$detail $m/joff exited $rc with $nl lines: $(head -c 200 "$D/$m-joff.err");"; sbad=1; continue
      fi
      for o in $GENOPTS; do
        n=$(optname "$o")
        run "$D/$m-$n.txt" "$D/$m-$n.err" "$LJEXE" $(optargs "$o") "$B/drv.lua" "$D/cases_lj.lua" "$m"; rc=$?
        set -- $(ndiff "$D/$m-$n.txt" "$D/$m-joff.txt")
        line="$line $m/$n=$1"
        [ "$rc" -ne 0 ] && { detail="$detail $m/$n exited $rc: $(head -c 200 "$D/$m-$n.err");"; sbad=1; }
        [ "$1" -ne 0 ] && { shift; detail="$detail $m/$n differs from -joff, first cases:$*;"; sbad=1; }
      done
      if [ "$HAVEPUC" = 1 ]; then
        run "$D/$m-puc.txt" "$D/$m-puc.err" "$OCLJ_LUA53" "$B/drv.lua" "$D/cases_puc.lua" "$m"; rc=$?
        set -- $(ndiff "$D/$m-puc.txt" "$D/$m-joff.txt")
        line="$line $m/puc=$1"
        if [ "$rc" -ne 0 ]; then
          detail="$detail PUC ($m) exited $rc: $(head -c 200 "$D/$m-puc.err");"; snothing=1
        elif [ "$1" -ne 0 ]; then
          shift; detail="$detail $m/puc: -joff differs from PUC 5.3.6 with U1-B's rule, first cases:$*;"; sbad=1
        fi
      fi
    done
    # Coverage: from -joff (runs, raises, raises past iteration 60) and from
    # the JIT-on shared run (cases with a completed trace).
    cj=$(grep '^#cov' "$D/shared-joff.err" 2>/dev/null)
    cn=$(grep '^#cov' "$D/shared-jon.err" 2>/dev/null)
    starts=$(echo "$cj" | sed -n 's/.* starts \([0-9]*\).*/\1/p')
    errs=$(echo "$cj" | sed -n 's/.* errors \([0-9]*\).*/\1/p')
    e60=$(echo "$cj" | sed -n 's/.* errors-past-60 \([0-9]*\).*/\1/p')
    traced=$(echo "$cn" | sed -n 's/.* traced \([0-9]*\).*/\1/p')
    case "$cn" in *"jit on"*) jit=on ;; *) jit=off ;; esac
    echo "$line"
    echo "    coverage: $OCLJ_BITJIT_CASES loops, ${starts:-?} runs, ${errs:-?} raised, ${e60:-?} after iteration 60; a trace completed in ${traced:-?} loops (JIT-on shared run, jit $jit)"
    if [ "$sbad" = 0 ] && [ "$snothing" = 0 ]; then
      if [ "$jit" != on ] || [ -z "$traced" ] || \
         ! awk -v t="$traced" -v n="$OCLJ_BITJIT_CASES" -v h="$OCLJ_BITJIT_HOTMIN" 'BEGIN { exit !(t >= h * n) }'; then
        detail="$detail traces completed in ${traced:-no} of $OCLJ_BITJIT_CASES loops (jit $jit), under OCLJ_BITJIT_HOTMIN $OCLJ_BITJIT_HOTMIN: the JIT was barely tested;"
        snothing=1
      fi
    fi
    if [ "$sbad" = 1 ]; then echo "seed $s: FAIL --$detail"; bad=1
    elif [ "$snothing" = 1 ]; then echo "seed $s: PROVED NOTHING --$detail"; nothing=1
    else echo "seed $s: PASS"; fi
  done
else
  echo "SKIPPED (not in OCLJ_BITJIT_PARTS)"
fi

# ---------------------------------------------------------------- 2
echo
echo "== 2. the floor: t_rec.lua, t_jit2.lua and t_rg2.lua against -joff, t_jit2.lua and t_rg2.lua against PUC 5.3.6 =="
if wanted floor; then
  D=$OUT/floor; mkdir -p "$D"
  for sm in 1: 2: 3:counts 4:counts; do
    s=${sm%%:*}; md=${sm#*:}; tag=rec-s$s${md:+-$md}
    run "$D/$tag-joff.txt" "$D/$tag-joff.err" "$LJEXE" -joff "$B/t_rec.lua" 400 "$s" $md; rc=$?
    nl=$(grep -c . "$D/$tag-joff.txt")
    if [ "$rc" -ne 0 ] || [ "$nl" -ne 400 ]; then
      echo "FAIL t_rec seed $s${md:+ ($md)}: -joff exited $rc with $nl lines: $(head -c 200 "$D/$tag-joff.err")"; bad=1; continue
    fi
    line="t_rec seed $s${md:+ ($md)}:"; tbad=0
    for o in $RECOPTS; do
      n=$(optname "$o")
      run "$D/$tag-$n.txt" "$D/$tag-$n.err" "$LJEXE" $(optargs "$o") "$B/t_rec.lua" 400 "$s" $md; rc=$?
      set -- $(ndiff "$D/$tag-$n.txt" "$D/$tag-joff.txt")
      line="$line $n=$1"
      [ "$rc" -ne 0 ] && { line="$line(exit $rc)"; tbad=1; }
      [ "$1" -ne 0 ] && { shift; line="$line[first:$*]"; tbad=1; }
    done
    # t_rec's runs: 5 starts a recurrence; a raise prints ERR@<iteration>.
    cov=$(awk -F'\t' '{ n = split($4, r, " [|] "); for (k = 1; k <= n; k++) { runs++
            if (r[k] ~ /^ERR@/) { e++; it = r[k]; sub(/^ERR@/, "", it); sub(/:.*$/, "", it); if (it + 0 > 60) e60++ } } }
            END { printf "%d runs, %d raised, %d after iteration 60", runs, e, e60 }' "$D/$tag-joff.txt")
    if [ "$tbad" = 0 ]; then echo "PASS $line  ($cov)"; else echo "FAIL $line  ($cov)"; bad=1; fi
  done
  run "$D/jit2-joff.txt" "$D/jit2-joff.err" "$LJEXE" -joff "$B/t_jit2.lua"; rc=$?
  if [ "$rc" -eq 2 ] && grep -q INSTRUMENT "$D/jit2-joff.txt"; then
    echo "PROVED NOTHING t_jit2:"; sed -n '/INSTRUMENT/,$p' "$D/jit2-joff.txt" | head -6 | sed 's/^/    /'; nothing=1
  elif [ "$rc" -ne 0 ]; then
    echo "FAIL t_jit2: -joff exited $rc: $(head -c 200 "$D/jit2-joff.err")"; bad=1
  else
    nt=$(grep -c . "$D/jit2-joff.txt")
    ne=$(grep -c 'ERR@' "$D/jit2-joff.txt")
    line="t_jit2 ($nt loops, $ne of them end in a raise):"; tbad=0
    for o in $JIT2OPTS; do
      n=$(optname "$o")
      run "$D/jit2-$n.txt" "$D/jit2-$n.err" "$LJEXE" $(optargs "$o") "$B/t_jit2.lua"; rc=$?
      set -- $(ndiff "$D/jit2-$n.txt" "$D/jit2-joff.txt")
      line="$line $n=$1"
      [ "$rc" -ne 0 ] && { line="$line(exit $rc)"; tbad=1; }
      [ "$1" -ne 0 ] && { shift; line="$line[$*]"; tbad=1; }
    done
    if [ "$tbad" = 0 ]; then echo "PASS $line"; else echo "FAIL $line"; bad=1; fi
    if [ "$HAVEPUC" = 1 ]; then
      run "$D/jit2-puc.txt" "$D/jit2-puc.err" "$OCLJ_LUA53" "$B/t_jit2.lua"; rc=$?
      awk -F'\t' '$1 != "sar"' "$D/jit2-joff.txt" > "$D/jit2-joff-nosar.txt"
      set -- $(ndiff "$D/jit2-puc.txt" "$D/jit2-joff-nosar.txt")
      if [ "$rc" -ne 0 ]; then
        echo "PROVED NOTHING t_jit2 on PUC: exited $rc: $(head -c 300 "$D/jit2-puc.txt") $(head -c 200 "$D/jit2-puc.err")"; nothing=1
      elif [ "$1" -eq 0 ]; then
        echo "PASS t_jit2: PUC 5.3.6 with U1-B's rule equals -joff in all $(grep -c . "$D/jit2-puc.txt") loops it runs (all but sar)"
      else
        nd=$1; shift; echo "FAIL t_jit2: PUC 5.3.6 with U1-B's rule differs from -joff in $nd loops, first:$*"; bad=1
      fi
    else
      echo "t_jit2 on PUC: SKIPPED ($PUCSKIP)"
    fi
  fi
  # t_rg2.lua: the loops at a result guard's 2^53 boundary, run as t_jit2.lua is.
  run "$D/rg2-joff.txt" "$D/rg2-joff.err" "$LJEXE" -joff "$B/t_rg2.lua"; rc=$?
  if [ "$rc" -eq 2 ] && grep -q INSTRUMENT "$D/rg2-joff.txt"; then
    echo "PROVED NOTHING t_rg2:"; sed -n '/INSTRUMENT/,$p' "$D/rg2-joff.txt" | head -6 | sed 's/^/    /'; nothing=1
  elif [ "$rc" -ne 0 ] || [ "$(grep -c . "$D/rg2-joff.txt")" -ne 15 ]; then
    echo "FAIL t_rg2: -joff exited $rc with $(grep -c . "$D/rg2-joff.txt") loops, not 15: $(head -c 200 "$D/rg2-joff.err")"; bad=1
  else
    ne=$(grep -c 'ERR@' "$D/rg2-joff.txt")
    line="t_rg2 (15 loops, $ne of them end in a raise):"; tbad=0
    for o in $JIT2OPTS; do
      n=$(optname "$o")
      run "$D/rg2-$n.txt" "$D/rg2-$n.err" "$LJEXE" $(optargs "$o") "$B/t_rg2.lua"; rc=$?
      set -- $(ndiff "$D/rg2-$n.txt" "$D/rg2-joff.txt")
      line="$line $n=$1"
      [ "$rc" -ne 0 ] && { line="$line(exit $rc)"; tbad=1; }
      [ "$1" -ne 0 ] && { shift; line="$line[$*]"; tbad=1; }
    done
    if [ "$tbad" = 0 ]; then echo "PASS $line"; else echo "FAIL $line"; bad=1; fi
    if [ "$HAVEPUC" = 1 ]; then
      run "$D/rg2-puc.txt" "$D/rg2-puc.err" "$OCLJ_LUA53" "$B/t_rg2.lua"; rc=$?
      awk -F'\t' '$1 != "sar-edge"' "$D/rg2-joff.txt" > "$D/rg2-joff-nosar.txt"
      set -- $(ndiff "$D/rg2-puc.txt" "$D/rg2-joff-nosar.txt")
      if [ "$rc" -ne 0 ]; then
        echo "PROVED NOTHING t_rg2 on PUC: exited $rc: $(head -c 300 "$D/rg2-puc.txt") $(head -c 200 "$D/rg2-puc.err")"; nothing=1
      elif [ "$1" -eq 0 ]; then
        echo "PASS t_rg2: PUC 5.3.6 with U1-B's rule equals -joff in all $(grep -c . "$D/rg2-puc.txt") loops it runs (all but sar-edge)"
      else
        nd=$1; shift; echo "FAIL t_rg2: PUC 5.3.6 with U1-B's rule differs from -joff in $nd loops, first:$*"; bad=1
      fi
    else
      echo "t_rg2 on PUC: SKIPPED ($PUCSKIP)"
    fi
  fi
else
  echo "SKIPPED (not in OCLJ_BITJIT_PARTS)"
fi

# ---------------------------------------------------------------- 3
echo
echo "== 3. fix1: the p4 loops compile (bitop/p4v.lua) =="
if wanted fix1; then
  D=$OUT/fix1; mkdir -p "$D"
  run "$D/p4v-jon.txt" "$D/p4v-jon.err" "$LJEXE" "$B/p4v.lua"; rj=$?
  run "$D/p4v-joff.txt" "$D/p4v-joff.err" "$LJEXE" -joff "$B/p4v.lua"; rf=$?
  sed 's/^/    /' "$D/p4v-jon.txt"
  # The results (the x= y= field) against -joff's.
  cut -f1,2 "$D/p4v-jon.txt" | grep -v '^p4v:' > "$D/p4v-jon-res.txt"
  cut -f1,2 "$D/p4v-joff.txt" > "$D/p4v-joff-res.txt"
  nres=$(grep -c . "$D/p4v-joff-res.txt")
  if [ "$rj" -eq 2 ]; then
    echo "PROVED NOTHING fix1: $(grep INSTRUMENT "$D/p4v-jon.txt" | head -c 300) $(head -c 200 "$D/p4v-jon.err")"; nothing=1
  elif [ "$rf" -ne 0 ] || [ "$nres" -ne 8 ]; then
    echo "FAIL fix1: -joff exited $rf with $nres results: $(head -c 200 "$D/p4v-joff.err")"; bad=1
  elif ! cmp -s "$D/p4v-jon-res.txt" "$D/p4v-joff-res.txt"; then
    echo "FAIL fix1: compiled results differ from -joff's:"; diff "$D/p4v-jon-res.txt" "$D/p4v-joff-res.txt" | sed 's/^/    /'; bad=1
  elif [ "$rj" -ne 0 ]; then
    echo "FAIL fix1: $(grep -c FAILED "$D/p4v-jon.txt") of 8 p4 loops aborted with type instability, were blacklisted, or never compiled (exit $rj)"; bad=1
  else
    echo "PASS fix1: all 8 p4 loops compiled (no type-instability abort, none blacklisted), results equal -joff's"
  fi
else
  echo "SKIPPED (not in OCLJ_BITJIT_PARTS)"
fi

# ---------------------------------------------------------------- 4
echo
echo "== 4. the table-index fold: t_idx.lua, t_cnt33.lua and t_idx2.lua against -joff and PUC 5.3.6; phiidx.lua's traces =="
IDXOPTS="jon O0:-O0 O1:-O1 hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0 he1:-Ohotloop=1_-Ohotexit=1 noloop:-O3_-O-loop nofold:-O3_-O-fold nocse:-O3_-O-cse"
if wanted idx; then
  D=$OUT/idx; mkdir -p "$D"
  for t in t_idx t_cnt33 t_idx2; do
    run "$D/$t-joff.txt" "$D/$t-joff.err" "$LJEXE" -joff "$B/$t.lua"; rc=$?
    nc=$(grep -c . "$D/$t-joff.txt")
    if [ "$rc" -eq 2 ] && grep -q INSTRUMENT "$D/$t-joff.txt"; then
      echo "PROVED NOTHING $t:"; sed -n '/INSTRUMENT/,$p' "$D/$t-joff.txt" | head -6 | sed 's/^/    /'; nothing=1; continue
    elif [ "$rc" -ne 0 ] || [ "$nc" -eq 0 ]; then
      echo "FAIL $t: -joff exited $rc with $nc lines: $(head -c 200 "$D/$t-joff.err")"; bad=1; continue
    fi
    ne=$(grep -c 'ERR@' "$D/$t-joff.txt")
    line="$t ($nc cases, $ne of them end in a raise):"; tbad=0
    for o in $IDXOPTS; do
      n=$(optname "$o")
      run "$D/$t-$n.txt" "$D/$t-$n.err" "$LJEXE" $(optargs "$o") "$B/$t.lua"; rc=$?
      set -- $(ndiff "$D/$t-$n.txt" "$D/$t-joff.txt")
      line="$line $n=$1"
      [ "$rc" -ne 0 ] && { line="$line(exit $rc)"; tbad=1; }
      [ "$1" -ne 0 ] && { shift; line="$line[$*]"; tbad=1; }
    done
    # Coverage, from the default run: traces, and the fold itself.
    cov=$(grep '^#cov' "$D/$t-jon.err" 2>/dev/null)
    traced=$(echo "$cov" | sed -n 's/.* traced \([0-9]*\).*/\1/p')
    convs=$(echo "$cov" | sed -n 's/.* convs \([0-9]*\).*/\1/p')
    case "$cov" in *"jit on"*) jit=on ;; *) jit=off ;; esac
    covtxt="coverage: a trace completed in ${traced:-?} of $nc cases, ${convs:-?} CONV int.i64 in them (default options, jit $jit)"
    if [ "$tbad" = 1 ]; then
      echo "FAIL $line  ($covtxt)"; bad=1
    elif [ "$jit" != on ] || [ -z "$traced" ] || [ -z "$convs" ] || [ "$convs" -eq 0 ] ||
         ! awk -v t="$traced" -v n="$nc" -v h="$OCLJ_BITJIT_HOTMIN" 'BEGIN { exit !(t >= h * n) }'; then
      echo "PROVED NOTHING $line  ($covtxt; too few traces for OCLJ_BITJIT_HOTMIN $OCLJ_BITJIT_HOTMIN, or the fold never fired)"; nothing=1
    else
      echo "PASS $line  ($covtxt)"
    fi
    if [ "$HAVEPUC" = 1 ]; then
      # t_idx2's PUC twin is its "puc" part (the consumers whose meaning PUC
      # shares), against -joff's run of the same part.
      ref=$D/$t-joff.txt; pa=; what=
      if [ "$t" = t_idx2 ]; then
        pa="400 puc"; what=" of its puc part"; ref=$D/$t-joff-puc.txt
        run "$ref" "$D/$t-joff-puc.err" "$LJEXE" -joff "$B/$t.lua" $pa
      fi
      run "$D/$t-puc.txt" "$D/$t-puc.err" "$OCLJ_LUA53" "$B/$t.lua" $pa; rc=$?
      set -- $(ndiff "$D/$t-puc.txt" "$ref")
      if [ "$rc" -ne 0 ] || [ ! -s "$ref" ]; then
        echo "PROVED NOTHING $t on PUC: exited $rc: $(head -c 300 "$D/$t-puc.txt") $(head -c 200 "$D/$t-puc.err")"; nothing=1
      elif [ "$1" -eq 0 ]; then
        echo "PASS $t: PUC 5.3.6 with U1-B's rule equals -joff in all $(grep -c . "$D/$t-puc.txt") cases$what"
      else
        nd=$1; shift; echo "FAIL $t: PUC 5.3.6 with U1-B's rule differs from -joff in $nd cases$what, first:$*"; bad=1
      fi
    else
      echo "$t on PUC: SKIPPED ($PUCSKIP)"
    fi
  done
  # phiidx: where the fold folds and that it never crosses a PHI, read from
  # the compiled loops; the loops compile; their results equal -joff's.
  run "$D/phiidx-jon.txt" "$D/phiidx-jon.err" "$LJEXE" "$B/phiidx.lua"; rj=$?
  run "$D/phiidx-joff.txt" "$D/phiidx-joff.err" "$LJEXE" -joff "$B/phiidx.lua"; rf=$?
  sed 's/^/    /' "$D/phiidx-jon.txt"
  grep -v '^phiidx:' "$D/phiidx-jon.txt" | cut -f1,2 > "$D/phiidx-jon-res.txt"
  cut -f1,2 "$D/phiidx-joff.txt" > "$D/phiidx-joff-res.txt"
  nres=$(grep -c . "$D/phiidx-joff-res.txt")
  if [ "$rj" -eq 2 ]; then
    echo "PROVED NOTHING phiidx: $(grep INSTRUMENT "$D/phiidx-jon.txt" | head -c 300) $(head -c 200 "$D/phiidx-jon.err")"; nothing=1
  elif [ "$rf" -ne 0 ] || [ "$nres" -ne 7 ]; then
    echo "FAIL phiidx: -joff exited $rf with $nres results: $(head -c 200 "$D/phiidx-joff.err")"; bad=1
  elif ! cmp -s "$D/phiidx-jon-res.txt" "$D/phiidx-joff-res.txt"; then
    echo "FAIL phiidx: compiled results differ from -joff's:"; diff "$D/phiidx-jon-res.txt" "$D/phiidx-joff-res.txt" | sed 's/^/    /'; bad=1
  elif [ "$rj" -ne 0 ]; then
    echo "FAIL phiidx: $(grep -c FAILED "$D/phiidx-jon.txt") of 7 loops did not fold where they must, folded across a PHI, or did not compile (exit $rj)"; bad=1
  else
    echo "PASS phiidx: all 7 loops compiled, the fold fired where it belongs and never across a PHI, results equal -joff's"
  fi
else
  echo "SKIPPED (not in OCLJ_BITJIT_PARTS)"
fi

# ---------------------------------------------------------------- 5
echo
echo "== 5. select(k, ...): t_select.lua against -joff and PUC 5.3.6; the record-time bound =="
# The idx part's nine sets, and six for exits, side traces, ABC and
# narrowing (guide 11.3's sets for a guard and for an index).
SELOPTS="$IDXOPTS hx1:-Ohotexit=1 ts1:-Otryside=1_-Ohotexit=2 mx1:-Omaxside=1 hl1ms0:-Ohotloop=1_-Omaxside=0 noabc:-O3_-O-abc nonarrow:-O3_-O-narrow"
if wanted sel; then
  D=$OUT/sel; mkdir -p "$D"
  t=t_select
  run "$D/$t-joff.txt" "$D/$t-joff.err" "$LJEXE" -joff "$B/$t.lua"; rc=$?
  nc=$(grep -c . "$D/$t-joff.txt")
  if [ "$rc" -eq 2 ] && grep -q INSTRUMENT "$D/$t-joff.txt"; then
    echo "PROVED NOTHING $t:"; sed -n '/INSTRUMENT/,$p' "$D/$t-joff.txt" | head -6 | sed 's/^/    /'; nothing=1
  elif [ "$rc" -ne 0 ] || [ "$nc" -eq 0 ]; then
    echo "FAIL $t: -joff exited $rc with $nc lines: $(head -c 200 "$D/$t-joff.err")"; bad=1
  else
    ne=$(grep -c 'E:' "$D/$t-joff.txt")
    line="$t ($nc cases, $ne of them with a raise):"; tbad=0; kbad=; knone=
    for o in $SELOPTS; do
      n=$(optname "$o")
      run "$D/$t-$n.txt" "$D/$t-$n.err" "$LJEXE" $(optargs "$o") "$B/$t.lua"; rc=$?
      set -- $(ndiff "$D/$t-$n.txt" "$D/$t-joff.txt")
      line="$line $n=$1"
      [ "$rc" -ne 0 ] && { line="$line(exit $rc)"; tbad=1; }
      [ "$1" -ne 0 ] && { shift; line="$line[$*]"; tbad=1; }
      # The record-time bound, in every JIT run: no select trace compiled in
      # a loop recorded only with k above 2^27.
      kb=$(sed -n 's/^#cov .* kmaxbad \([0-9]*\) .*/\1/p' "$D/$t-$n.err")
      if [ -z "$kb" ]; then knone="$knone $n"
      elif [ "$kb" -gt 0 ]; then kbad="$kbad $n=$kb"; fi
    done
    # Coverage, from the default run: traces, each of rec_varg's paths, the
    # fix's guard, and the 2^27 controls (the kmax check can see a trace).
    cov=$(grep '^#cov' "$D/$t-jon.err" 2>/dev/null)
    cv() { echo "$cov" | sed -n "s/.* $1 \([0-9]*\).*/\1/p"; }
    traced=$(cv traced); sa=$(cv selA); sb=$(cv selB); sc=$(cv selC); kg=$(cv kguard); kc=$(cv kmaxctl); kn=$(cv kctl)
    case "$cov" in *"jit on"*) jit=on ;; *) jit=off ;; esac
    covtxt="coverage: a trace completed in ${traced:-?} of $nc cases; guards of select's paths A ${sa:-?}, B ${sb:-?}, C ${sc:-?}; the fix's guard ${kg:-?}; the k = 2^27 loops compiled ${kc:-?} of ${kn:-?} (default options, jit $jit)"
    if [ "$tbad" = 1 ]; then
      echo "FAIL $line  ($covtxt)"; bad=1
    elif [ "$jit" != on ] || [ -z "$traced" ] || [ "${sa:-0}" -eq 0 ] || [ "${sb:-0}" -eq 0 ] || [ "${sc:-0}" -eq 0 ] ||
         [ "${kg:-0}" -eq 0 ] || [ -z "$kn" ] || [ "$kn" -eq 0 ] || [ "${kc:-0}" -ne "$kn" ] ||
         ! awk -v t="$traced" -v n="$nc" -v h="$OCLJ_BITJIT_HOTMIN" 'BEGIN { exit !(t >= h * n) }'; then
      echo "PROVED NOTHING $line  ($covtxt; too few traces for OCLJ_BITJIT_HOTMIN $OCLJ_BITJIT_HOTMIN, a path or the fix's guard never recorded, or a k = 2^27 loop not compiled)"; nothing=1
    else
      echo "PASS $line  ($covtxt)"
    fi
    if [ -n "$kbad" ]; then
      echo "FAIL t_select-kmax: a select trace compiled in a loop recorded only with k above 2^27 (loops a set):$kbad"; bad=1
    elif [ -n "$knone" ]; then
      echo "PROVED NOTHING t_select-kmax: no #cov line in:$knone"; nothing=1
    else
      echo "PASS t_select-kmax: in no option set did a loop recorded only with k above 2^27 compile a select trace"
    fi
    if [ "$HAVEPUC" = 1 ]; then
      # The "puc" part (integral k below 2^31), on PUC and on -joff.
      run "$D/$t-joff-puc.txt" "$D/$t-joff-puc.err" "$LJEXE" -joff "$B/$t.lua" puc
      run "$D/$t-puc.txt" "$D/$t-puc.err" "$OCLJ_LUA53" "$B/$t.lua" puc; rc=$?
      set -- $(ndiff "$D/$t-puc.txt" "$D/$t-joff-puc.txt")
      if [ "$rc" -ne 0 ] || [ ! -s "$D/$t-joff-puc.txt" ]; then
        echo "PROVED NOTHING $t on PUC: exited $rc: $(head -c 300 "$D/$t-puc.txt") $(head -c 200 "$D/$t-puc.err")"; nothing=1
      elif [ "$1" -eq 0 ]; then
        echo "PASS $t: PUC 5.3.6 equals -joff in all $(grep -c . "$D/$t-puc.txt") cases of its puc part"
      else
        nd=$1; shift; echo "FAIL $t: PUC 5.3.6 differs from -joff in $nd cases of its puc part, first:$*"; bad=1
      fi
    else
      echo "$t on PUC: SKIPPED ($PUCSKIP)"
    fi
  fi
else
  echo "SKIPPED (not in OCLJ_BITJIT_PARTS)"
fi

# ---------------------------------------------------------------- 6
echo
echo "== 6. FIX-NUMCONV: t_numconv.lua against -joff and PUC 5.3.6; ncir.lua's traces =="
# t_numconv runs under the sel part's fifteen sets; ncir under the thirteen
# of them that fold (under -O0 and -O-fold no rule runs, and ncir refuses).
NCIROPTS="jon O1:-O1 hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0 he1:-Ohotloop=1_-Ohotexit=1 noloop:-O3_-O-loop nocse:-O3_-O-cse hx1:-Ohotexit=1 ts1:-Otryside=1_-Ohotexit=2 mx1:-Omaxside=1 hl1ms0:-Ohotloop=1_-Omaxside=0 noabc:-O3_-O-abc nonarrow:-O3_-O-narrow"
if wanted nc; then
  D=$OUT/nc; mkdir -p "$D"
  t=t_numconv
  run "$D/$t-joff.txt" "$D/$t-joff.err" "$LJEXE" -joff "$B/$t.lua"; rc=$?
  nc=$(grep -c . "$D/$t-joff.txt")
  if [ "$rc" -eq 2 ] && grep -q INSTRUMENT "$D/$t-joff.txt"; then
    echo "PROVED NOTHING $t:"; sed -n '/INSTRUMENT/,$p' "$D/$t-joff.txt" | head -6 | sed 's/^/    /'; nothing=1
  elif [ "$rc" -ne 0 ] || [ "$nc" -eq 0 ]; then
    echo "FAIL $t: -joff exited $rc with $nc lines: $(head -c 200 "$D/$t-joff.err")"; bad=1
  else
    ne=$(grep -c 'E:INEXACT' "$D/$t-joff.txt")
    line="$t ($nc cases, $ne of them with an inexact result's raise):"; tbad=0
    for o in $SELOPTS; do
      n=$(optname "$o")
      run "$D/$t-$n.txt" "$D/$t-$n.err" "$LJEXE" $(optargs "$o") "$B/$t.lua"; rc=$?
      set -- $(ndiff "$D/$t-$n.txt" "$D/$t-joff.txt")
      line="$line $n=$1"
      [ "$rc" -ne 0 ] && { line="$line(exit $rc)"; tbad=1; }
      [ "$1" -ne 0 ] && { shift; line="$line[$*]"; tbad=1; }
    done
    # Coverage, from the default run: traces, and the pair the rule reads.
    cov=$(grep '^#cov' "$D/$t-jon.err" 2>/dev/null)
    cv() { echo "$cov" | sed -n "s/.* $1 \([0-9]*\).*/\1/p"; }
    traced=$(cv traced); ncin=$(cv ncin); nsig=$(cv nsig)
    case "$cov" in *"jit on"*) jit=on ;; *) jit=off ;; esac
    covtxt="coverage: a trace completed in ${traced:-?} of $nc cases; ${ncin:-?} marked CONV num.i64 of a converted double, ${nsig:-?} identity result guards left (default options, jit $jit)"
    if [ "$tbad" = 1 ]; then
      echo "FAIL $line  ($covtxt)"; bad=1
    elif [ "$jit" != on ] || [ -z "$traced" ] || [ -z "$ncin" ] || [ "$ncin" -eq 0 ] ||
         ! awk -v t="$traced" -v n="$nc" -v h="$OCLJ_BITJIT_HOTMIN" 'BEGIN { exit !(t >= h * n) }'; then
      echo "PROVED NOTHING $line  ($covtxt; too few traces for OCLJ_BITJIT_HOTMIN $OCLJ_BITJIT_HOTMIN, or no bit operator on a double compiled)"; nothing=1
    else
      echo "PASS $line  ($covtxt)"
    fi
    if [ "$HAVEPUC" = 1 ]; then
      # The "puc" part (every case: with U1-B's rule at every operator, the
      # twin means what ours does), on PUC and on -joff.
      run "$D/$t-joff-puc.txt" "$D/$t-joff-puc.err" "$LJEXE" -joff "$B/$t.lua" puc
      run "$D/$t-puc.txt" "$D/$t-puc.err" "$OCLJ_LUA53" "$B/$t.lua" puc; rc=$?
      set -- $(ndiff "$D/$t-puc.txt" "$D/$t-joff-puc.txt")
      if [ "$rc" -ne 0 ] || [ ! -s "$D/$t-joff-puc.txt" ]; then
        echo "PROVED NOTHING $t on PUC: exited $rc: $(head -c 300 "$D/$t-puc.txt") $(head -c 200 "$D/$t-puc.err")"; nothing=1
      elif [ "$1" -eq 0 ]; then
        echo "PASS $t: PUC 5.3.6 with U1-B's rule equals -joff in all $(grep -c . "$D/$t-puc.txt") cases of its puc part"
      else
        nd=$1; shift; echo "FAIL $t: PUC 5.3.6 with U1-B's rule differs from -joff in $nd cases of its puc part, first:$*"; bad=1
      fi
    else
      echo "$t on PUC: SKIPPED ($PUCSKIP)"
    fi
  fi
  # ncir: the guards the rule leaves, read from the compiled loops in every
  # set that folds; the loops compile; their results equal -joff's.
  run "$D/ncir-joff.txt" "$D/ncir-joff.err" "$LJEXE" -joff "$B/ncir.lua"; rf=$?
  cut -f1,2 "$D/ncir-joff.txt" > "$D/ncir-joff-res.txt"
  nres=$(grep -c . "$D/ncir-joff-res.txt")
  if [ "$rf" -ne 0 ] || [ "$nres" -eq 0 ]; then
    echo "FAIL ncir: -joff exited $rf with $nres results: $(head -c 200 "$D/ncir-joff.err")"; bad=1
  else
    line="ncir ($nres cases):"; ibad=; inothing=; idiff=
    for o in $NCIROPTS; do
      n=$(optname "$o")
      run "$D/ncir-$n.txt" "$D/ncir-$n.err" "$LJEXE" $(optargs "$o") "$B/ncir.lua"; rj=$?
      grep -v '^ncir:' "$D/ncir-$n.txt" | cut -f1,2 > "$D/ncir-$n-res.txt"
      nf=$(grep -c 'FAILED' "$D/ncir-$n.txt")
      line="$line $n=$nf"
      if [ "$rj" -eq 2 ]; then
        inothing="$inothing $n: $(grep INSTRUMENT "$D/ncir-$n.txt" | head -c 200) $(head -c 200 "$D/ncir-$n.err");"
      elif ! cmp -s "$D/ncir-$n-res.txt" "$D/ncir-joff-res.txt"; then
        idiff="$idiff $n"
      elif [ "$rj" -ne 0 ]; then
        ibad="$ibad $n:$(grep FAILED "$D/ncir-$n.txt" | cut -f1 | head -3 | tr '\n' ',' | sed 's/,$//')"
      elif ! grep -q '^ncir: [0-9]* of [0-9]* cases compiled' "$D/ncir-$n.txt"; then
        inothing="$inothing $n: no summary line, so no trace was read (the JIT off?);"
      fi
    done
    if [ -n "$idiff" ]; then
      echo "FAIL $line  compiled results differ from -joff's under:$idiff"; bad=1
    elif [ -n "$ibad" ]; then
      echo "FAIL $line  an identity kept its result guard, a guard the rule must leave went, or a loop did not compile (first cases:$ibad)"; bad=1
    elif [ -n "$inothing" ]; then
      echo "PROVED NOTHING $line  --$inothing"; nothing=1
    else
      echo "PASS $line  every case compiled with no identity result guard, its own guards kept and its results equal -joff's, in every set that folds"
    fi
  fi
else
  echo "SKIPPED (not in OCLJ_BITJIT_PARTS)"
fi

# ---------------------------------------------------------------- 7
echo
echo "== 7. the CSE twins: t_csefwd.lua and t_cserev.lua against -joff, t_cserev.lua against PUC 5.3.6; cseir.lua's and t_cserev.lua's traces =="
# t_csefwd and t_cserev run under the sel part's fifteen sets; cseir under
# the twelve of them with fold and CSE on (under -O0 and -O-fold no pair
# forms, under -O-cse none merges, and cseir refuses all three: P61).
CSEIROPTS="jon O1:-O1 hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0 he1:-Ohotloop=1_-Ohotexit=1 noloop:-O3_-O-loop hx1:-Ohotexit=1 ts1:-Otryside=1_-Ohotexit=2 mx1:-Omaxside=1 hl1ms0:-Ohotloop=1_-Omaxside=0 noabc:-O3_-O-abc nonarrow:-O3_-O-narrow"
if wanted cse; then
  D=$OUT/cse; mkdir -p "$D"
  cv() { echo "$cov" | sed -n "s/.* $1 \([0-9]*\).*/\1/p"; }
  # t_csefwd: the forward pairs' values, against -joff and the file's own
  # plain-arithmetic reference (a mismatch exits 1, under -joff too).
  t=t_csefwd
  run "$D/$t-joff.txt" "$D/$t-joff.err" "$LJEXE" -joff "$B/$t.lua"; rc=$?
  nc=$(grep -c . "$D/$t-joff.txt")
  if [ "$rc" -eq 2 ] && grep -q INSTRUMENT "$D/$t-joff.txt"; then
    echo "PROVED NOTHING $t:"; sed -n '/INSTRUMENT/,$p' "$D/$t-joff.txt" | head -6 | sed 's/^/    /'; nothing=1
  elif [ "$rc" -ne 0 ] || [ "$nc" -eq 0 ]; then
    echo "FAIL $t: -joff exited $rc with $nc lines, $(grep -c 'bad=[1-9]' "$D/$t-joff.txt") of them with a result unlike the file's reference: $(head -c 200 "$D/$t-joff.err")"; bad=1
  else
    line="$t ($nc cases):"; tbad=0
    for o in $SELOPTS; do
      n=$(optname "$o")
      run "$D/$t-$n.txt" "$D/$t-$n.err" "$LJEXE" $(optargs "$o") "$B/$t.lua"; rc=$?
      set -- $(ndiff "$D/$t-$n.txt" "$D/$t-joff.txt")
      line="$line $n=$1"
      [ "$rc" -ne 0 ] && { line="$line(exit $rc)"; tbad=1; }
      [ "$1" -ne 0 ] && { shift; line="$line[$*]"; tbad=1; }
    done
    # Coverage, from the default run: traces, and the pairs that formed.
    cov=$(grep '^#cov' "$D/$t-jon.err" 2>/dev/null)
    traced=$(cv traced); pairs=$(cv pairs); served=$(cv served); split=$(cv split)
    pcases=$(echo "$cov" | sed -n 's/.* pairs [0-9]* of \([0-9]*\).*/\1/p')
    case "$cov" in *"jit on"*) jit=on ;; *) jit=off ;; esac
    covtxt="coverage: a trace completed in ${traced:-?} of $nc cases; ${pairs:-?} of ${pcases:-?} pairs formed, served ${served:-?}, split ${split:-?} (default options, jit $jit)"
    if [ "$tbad" = 1 ]; then
      echo "FAIL $line  ($covtxt)"; bad=1
    elif [ "$jit" != on ] || [ -z "$traced" ] || [ -z "$pairs" ] || [ "$pairs" -eq 0 ] ||
         ! awk -v t="$traced" -v n="$nc" -v h="$OCLJ_BITJIT_HOTMIN" 'BEGIN { exit !(t >= h * n) }'; then
      echo "PROVED NOTHING $line  ($covtxt; too few traces for OCLJ_BITJIT_HOTMIN $OCLJ_BITJIT_HOTMIN, or no pair formed)"; nothing=1
    else
      echo "PASS $line  ($covtxt)"
    fi
  fi
  echo "$t on PUC: not run, by design (its 32-bit halves are LuaJIT's bit library, which PUC 5.3.6 lacks; the file checks every 5.3 result against a plain-arithmetic reference under every VM, -joff included)"
  # t_cserev: the reverse order in its two no-slot shapes; fields 1-2 (the
  # values) against -joff in every set, its own IR read in every JIT run.
  t=t_cserev
  run "$D/$t-joff.txt" "$D/$t-joff.err" "$LJEXE" -joff "$B/$t.lua"; rf=$?
  nres=$(grep -c . "$D/$t-joff.txt")
  if [ "$rf" -eq 2 ] && grep -q INSTRUMENT "$D/$t-joff.txt"; then
    echo "PROVED NOTHING $t:"; sed -n '/INSTRUMENT/,$p' "$D/$t-joff.txt" | head -6 | sed 's/^/    /'; nothing=1
  elif [ "$rf" -ne 0 ] || [ "$nres" -eq 0 ]; then
    echo "FAIL $t: -joff exited $rf with $nres lines, $(grep -c 'bad=[1-9]' "$D/$t-joff.txt") of them with a value unlike the file's reference: $(head -c 200 "$D/$t-joff.err")"; bad=1
  else
    cut -f1,2 "$D/$t-joff.txt" > "$D/$t-joff-res.txt"
    line="$t ($nres cases):"; rbad=; rnothing=; rdiff=
    for o in $SELOPTS; do
      n=$(optname "$o")
      run "$D/$t-$n.txt" "$D/$t-$n.err" "$LJEXE" $(optargs "$o") "$B/$t.lua"; rj=$?
      grep -v '^t_cserev:' "$D/$t-$n.txt" | cut -f1,2 > "$D/$t-$n-res.txt"
      nf=$(grep -c 'FAILED' "$D/$t-$n.txt")
      line="$line $n=$nf"
      if [ "$rj" -eq 2 ]; then
        rnothing="$rnothing $n: $(grep INSTRUMENT "$D/$t-$n.txt" | head -c 200) $(head -c 200 "$D/$t-$n.err");"
      else
        cmp -s "$D/$t-$n-res.txt" "$D/$t-joff-res.txt" || rdiff="$rdiff $n"
        if [ "$rj" -ne 0 ]; then
          rbad="$rbad $n:$(grep FAILED "$D/$t-$n.txt" | cut -f1 | head -4 | tr '\n' ',' | sed 's/,$//')"
        elif ! grep -q '^t_cserev: [0-9]* of [0-9]* cases ok' "$D/$t-$n.txt"; then
          rnothing="$rnothing $n: no summary line, so no trace was read (the JIT off?);"
        fi
      fi
    done
    # The default run must judge every reverse case (the pairs formed).
    set -- $(sed -n 's/^t_cserev: .* reverse cases judged \([0-9]*\) of \([0-9]*\)$/\1 \2/p' "$D/$t-jon.txt")
    if [ $# -ne 2 ] || [ "$1" -eq 0 ] || [ "$1" -ne "$2" ]; then
      rnothing="$rnothing jon: reverse cases judged ${1:-?} of ${2:-?}, so a reverse pair never formed;"
    fi
    if [ -n "$rdiff" ] || [ -n "$rbad" ]; then
      msg=; [ -n "$rdiff" ] && msg=" compiled values differ from -joff's under:$rdiff;"
      [ -n "$rbad" ] && msg="$msg a 32-bit instruction consumes our int64 one, a pair is not kept apart, an int64 instruction is in a snapshot, a value is unlike the file's reference, or a loop did not compile (first cases:$rbad)"
      echo "FAIL $line $msg"; bad=1
    elif [ -n "$rnothing" ]; then
      echo "PROVED NOTHING $line  --$rnothing"; nothing=1
    else
      echo "PASS $line  every case ok in every set: values equal -joff's, each reverse pair kept apart where it forms, nothing 32-bit consumes our int64 instruction, no int64 instruction in a snapshot"
    fi
  fi
  if [ "$HAVEPUC" = 1 ]; then
    # Every case: nothing here means otherwise on PUC (the file's header).
    run "$D/$t-puc.txt" "$D/$t-puc.err" "$OCLJ_LUA53" "$B/$t.lua"; rc=$?
    set -- $(ndiff "$D/$t-puc.txt" "$D/$t-joff.txt")
    if [ "$rc" -ne 0 ] || [ ! -s "$D/$t-joff.txt" ]; then
      echo "PROVED NOTHING $t on PUC: exited $rc: $(head -c 300 "$D/$t-puc.txt") $(head -c 200 "$D/$t-puc.err")"; nothing=1
    elif [ "$1" -eq 0 ]; then
      echo "PASS $t: PUC 5.3.6 equals -joff in all $(grep -c . "$D/$t-puc.txt") cases"
    else
      nd=$1; shift; echo "FAIL $t: PUC 5.3.6 differs from -joff in $nd cases, first:$*"; bad=1
    fi
  else
    echo "$t on PUC: SKIPPED ($PUCSKIP)"
  fi
  # cseir: the forward pairs read from the compiled loops in every set with
  # fold and CSE on; the loops compile; their results equal -joff's.
  run "$D/cseir-joff.txt" "$D/cseir-joff.err" "$LJEXE" -joff "$B/cseir.lua"; rf=$?
  cut -f1,2 "$D/cseir-joff.txt" > "$D/cseir-joff-res.txt"
  nres=$(grep -c . "$D/cseir-joff-res.txt")
  if [ "$rf" -eq 2 ] && grep -q INSTRUMENT "$D/cseir-joff.txt"; then
    echo "PROVED NOTHING cseir:"; sed -n '/INSTRUMENT/,$p' "$D/cseir-joff.txt" | head -6 | sed 's/^/    /'; nothing=1
  elif [ "$rf" -ne 0 ] || [ "$nres" -eq 0 ]; then
    echo "FAIL cseir: -joff exited $rf with $nres results: $(head -c 200 "$D/cseir-joff.txt") $(head -c 200 "$D/cseir-joff.err")"; bad=1
  else
    line="cseir ($nres cases):"; ibad=; inothing=; idiff=
    for o in $CSEIROPTS; do
      n=$(optname "$o")
      run "$D/cseir-$n.txt" "$D/cseir-$n.err" "$LJEXE" $(optargs "$o") "$B/cseir.lua"; rj=$?
      grep -v '^cseir:' "$D/cseir-$n.txt" | cut -f1,2 > "$D/cseir-$n-res.txt"
      nf=$(grep -c 'FAILED' "$D/cseir-$n.txt")
      line="$line $n=$nf"
      if [ "$rj" -eq 2 ]; then
        inothing="$inothing $n: $(grep INSTRUMENT "$D/cseir-$n.txt" | head -c 200) $(head -c 200 "$D/cseir-$n.err");"
      else
        cmp -s "$D/cseir-$n-res.txt" "$D/cseir-joff-res.txt" || idiff="$idiff $n"
        if [ "$rj" -ne 0 ]; then
          ibad="$ibad $n:$(grep FAILED "$D/cseir-$n.txt" | cut -f1 | head -3 | tr '\n' ',' | sed 's/,$//')"
        elif ! grep -q '^cseir: [0-9]* of [0-9]* cases ok' "$D/cseir-$n.txt"; then
          inothing="$inothing $n: no summary line, so no trace was read (the JIT off?);"
        fi
      fi
    done
    # The default run must judge every pair (the pairs formed).
    set -- $(sed -n 's/^cseir: .* pairs judged \([0-9]*\) of \([0-9]*\)$/\1 \2/p' "$D/cseir-jon.txt")
    if [ $# -ne 2 ] || [ "$1" -eq 0 ] || [ "$1" -ne "$2" ]; then
      inothing="$inothing jon: pairs judged ${1:-?} of ${2:-?}, so a pair never formed;"
    fi
    if [ -n "$idiff" ] || [ -n "$ibad" ]; then
      msg=; [ -n "$idiff" ] && msg=" compiled results differ from -joff's under:$idiff;"
      [ -n "$ibad" ] && msg="$msg a 32-bit instruction served our operator, a pair was not kept apart, an int64 instruction is in a snapshot, or a loop did not compile (first cases:$ibad)"
      echo "FAIL $line $msg"; bad=1
    elif [ -n "$inothing" ]; then
      echo "PROVED NOTHING $line  --$inothing"; nothing=1
    else
      echo "PASS $line  every case ok in every set with fold and CSE on: no operator served by a 32-bit instruction, every pair kept apart where it forms, no int64 instruction in a snapshot, results equal -joff's"
    fi
  fi
else
  echo "SKIPPED (not in OCLJ_BITJIT_PARTS)"
fi

echo
sel=; [ "$OCLJ_BITJIT_PARTS" != "gen floor fix1 idx sel nc cse" ] && sel=" (parts run: $OCLJ_BITJIT_PARTS; the others prove nothing here)"
if [ "$bad" = 1 ]; then echo "RUN-BITJIT: FAIL$sel (results: $OUT)"; exit 1; fi
if [ "$nothing" = 1 ]; then echo "RUN-BITJIT: PROVED NOTHING$sel (results: $OUT)"; exit 2; fi
echo "RUN-BITJIT: PASS$sel (results: $OUT)"
exit 0
