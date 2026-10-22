#!/bin/sh
# native/luajit/patch-bitop-fold.sh -- the fifth of round 3's seven changes to
# LuaJIT (Lua 5.3.6's 64-bit bitwise operators): the fold engine handles the
# int64 IR that native/luajit/oclj_bitop_rec.c records.  (Round 3's others:
# patch-bitop-parse.sh, patch-bitop-vm.sh, patch-bitop-meta.sh,
# patch-bitop-record.sh, patch-bitop-bcdump.sh, patch-bitop-jitlib.sh.)
#
#     sh native/luajit/patch-bitop-fold.sh <in lj_opt_fold.c> <out lj_opt_fold.c>
#
# <in> and <out> may name the SAME file.  build-native.sh re-copies the
# PRISTINE lj_opt_fold.c over the build copy before every run, for the reason
# patch-penalty-scrub.sh's header gives, and copies oclj_bitop_fold.c,
# oclj_bitop.h and oclj_num53.h next to it; `make clean` deletes
# lj_folddef.h, and buildvm regenerates it from the patched file.  The build
# always takes the patch path below; the "already patched" path is for hand
# use.
#
# WHAT IS WRONG, for the int64 IR the recorder now emits:
#   - Without FFI, the int64 constant folds of BAND, BOR, BXOR, the shifts,
#     BNOT and the comparisons, and two int64 simplifications, are stubbed
#     out by #if LJ_HASFFI (lj_opt_fold.c:376, :432, :444, :471, :492,
#     :1746, :1794).  Most stubs fail the fold (a trace abort), but in
#     kfold_int64arith the operator falls through to the default case
#     (:376-388), so BAND/BOR/BXOR KINT64 KINT64 silently folds to its left
#     operand: a wrong value.
#   - narrow_convert (:1312-1321) narrows a CONV i64.num of an ADD or SUB
#     into int64 arithmetic, which keeps the bits the double rounded away
#     (2^53 + 1 is 2^53 as a double): a wrong value too.
#   Both were measured to miscompile in round 3's prototypes without this
#   change (2026-10-17).
#   - Speed: each operator's result is a double that the next operator
#     converts back to int64, behind a guard; each would cost a round trip.
#     And a result used as an int (a table key, a library integer argument,
#     a variable shift count) is converted from its double by a guarded
#     CONV int.num, a round trip on the loop's dependency chain in table-
#     driven CRC32 (roadmap row 209).
#
# THE CHANGE, eleven hunks.
#   1. lj_opt_fold.c includes oclj_bitop.h, for OCLJ_IRCONV_EXACT.
#   2-6, 9, 10. The seven #if LJ_HASFFI become #if 1.  kfold_int64shift
#      computes the shift itself: FFI's lj_carith_shift64 (lj_carith.c:302)
#      is not compiled without FFI.  kfold_int64arith (:368), kfold_bnot64
#      (:442), kfold_int64comp (:469), kfold_int64comp0 (:490),
#      simplify_andor_k64 (:1744) and reassoc_intarith_k64 (:1792) are
#      upstream's FFI code as it is.  What still fails without FFI is
#      harmless: kfold_int64arith2, kfold_bswap64 and simplify_intmul_k64
#      handle ops the recorder never emits.
#   7. simplify_conv_i64_num, (i64)(num)y ==> y, gains three rules before its
#      PHIBARRIER, for an int64 y:
#      - THE EXACT MARK: when the inner conversion carries OCLJ_IRCONV_EXACT
#        and the outer one does not.  oclj_bitop_rec.c emits the guard that
#        makes a marked double exact directly after it, so the guard precedes
#        every use in trace order; the loop copy keeps that order; a value a
#        PHI carries passed its guard in the pre-roll or in the previous
#        iteration; values that reach a trace from outside (stack slots,
#        tables, upvalues, a parent trace's snapshot) arrive as plain
#        doubles or ints, never as a marked conversion; and store-to-load
#        forwarding hands back the stored reference, whose guard preceded
#        the store.
#        The guard's own conversion back is marked too, so this rule never
#        folds it.
#      - THE WIDTH RULE: when y provably lies in [-2^53, 2^53), where every
#        integer is a double (oclj_bitwidth's bound of 54 or less).  This is
#        what removes the guard of a result that fits.  oclj_bitwidth and
#        its soundness argument are in native/luajit/oclj_bitop_fold.c,
#        #included above simplify_conv_int_num (hunk 11), the first of its
#        two callers: buildvm -m folddef reads the LJFOLD lines of this file
#        only, so the rules must stay here.
#      - FIX-NUMCONV (roadmap row 211 (5), 2026-10-21), on a line of its own
#        after the width rule: when y is an unguarded CONV i64.num of a
#        double (oclj_isnumconv, beside the bound in oclj_bitop_fold.c, with
#        its argument).  x64 compiles that to one cvttsd2si, whose value,
#        the double's integral part or -2^63, is always exactly a double
#        whatever its range.  That is exactness, not a range: the bound must
#        never hold it, because a bound composes (x | 1 would lose its guard).
#        An identity operation (x | 0, x & -1, x ~ 0, x << 0, x >> 0, and
#        the outer operator of ~~x) folds its result to its operand's own
#        conversion, so this removes a result guard that cannot fail.  Like
#        the width rule, it reads no guard and no exact mark.
#      Across a PHI the rules fold only to an int64-typed y: an int-typed y
#      is the int loop index after simplify_conv_sext's x64 LEFTFOLD
#      (:1242), and an int64 PHI of it makes loop_unroll raise TYPEINS and
#      blacklist the loop (found by the round-3 review, 2026-10-17).
#   8. narrow_convert returns NEXTFOLD for an int64 CONV.
#   11. The table-index fold (the CRC32 follow-up, roadmap row 209):
#      simplify_conv_int_num, the owner of LJFOLD(CONV CONV IRCONV_INT_NUM),
#      turns (int)(num)y into the unguarded CONV int.i64 y when y is an
#      int64 that oclj_bitwidth bounds at 32 bits or fewer, i.e. y lies in
#      [-2^31, 2^31).  Such a y is its double exactly and an int32 exactly,
#      so the num->int conversion gives y whatever its check mode (INDEX for
#      a table key, ANY for a library integer argument, CHECK for round 3's
#      variable shift count and narrowing's leaves) and its guard cannot
#      fail; y's low 32 bits are y.  The proof is the bound alone: no guard
#      and no exact mark is read, so no guard justifies its own removal.  The
#      new mode is exactly (IRT_INT<<IRCONV_DSH)|IRT_I64, with no check bits:
#      x64's asm_conv then emits mov r32, r32 (with IRCONV_NONE set it would
#      emit nothing and keep y's upper half).  Never across a PHI: the new
#      instruction is built on fleft->op1, which for a PHI-marked fleft is a
#      pre-roll ref (lj_opt_fold.c's requirement 2).  The bound is tight: at
#      33, y = -(2^32 - 5) truncates to 5, a different table key and a
#      variable shift count that passes its ULT 64 guard (round 3's review,
#      verify:tablefold:0).  The #include of oclj_bitop_fold.c moves from
#      hunk 7 to here, above both callers.
#
# Anchored, refusing otherwise, on the line `#include "lj_strfmt.h"`
# (lj_opt_fold.c:31 at 1ee778a4); on each of the seven #if LJ_HASFFI lines
# together with the line or lines after it that make it unique (:376-377,
# :432-436, :444-445, :471-472, :492-493, :1746-1749, :1794-1796); on
# simplify_conv_i64_num's first five lines (:1138-1142); on
# narrow_convert's comment and loop check (:1315-1317); and on
# simplify_conv_int_num whole (:1128-1136); each exactly once.
# No LJFOLD line is added or removed (checked), so buildvm's fold table
# keeps its rules.  Verified by content, by diff, and by putting upstream's
# text back and comparing with the input.  CRLF is stripped (the pinned tree
# checks out CRLF on Windows); the output is LF.  This script contains no
# backslashes and no tabs: in the hunk texts below, @T@ stands for a tab.
set -u

[ $# -eq 2 ] || { echo "usage: patch-bitop-fold.sh <in lj_opt_fold.c> <out lj_opt_fold.c>" >&2; exit 2; }
IN=$1
OUT=$2
[ -f "$IN" ] || { echo "patch-bitop-fold.sh: no $IN" >&2; exit 2; }

ME=patch-bitop-fold.sh
MARK='OC-LuaJIT (native/luajit/patch-bitop-fold.sh)'
NMARK=1     # the marker occurs once in a patched file
NH=11       # hunks
NADD=70     # lines diff -d reports added on the pristine file ...
NDEL=8      # ... and removed
NOFFI='#if 1  /* OC-LuaJIT: the 64-bit bit operators, without FFI. */'

fail() { echo "$ME: $*" >&2; exit 1; }
countsub() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }
countx() { grep -c -x -F -- "$1" "$2" 2>/dev/null || true; }

D=${TMPDIR:-/tmp}/$ME.$$
rm -rf "$D"
mkdir -p "$D" || fail "cannot create $D"
trap 'rm -rf "$D"' EXIT

# --- the hunks: o<h> is upstream's text, n<h> ours --------------------------
# 1. OCLJ_IRCONV_EXACT.
cat > "$D/o1" <<'EOF'
#include "lj_strfmt.h"
EOF
cat > "$D/n1" <<'EOF'
#include "lj_strfmt.h"
#include "oclj_bitop.h"  /* OC-LuaJIT (native/luajit/patch-bitop-fold.sh) */
EOF
# 2. kfold_int64arith: the bit operators.
cat > "$D/o2" <<'EOF'
#if LJ_HASFFI
  case IR_BAND: k1 &= k2; break;
EOF
cat > "$D/n2" <<'EOF'
#if 1  /* OC-LuaJIT: the 64-bit bit operators, without FFI. */
  case IR_BAND: k1 &= k2; break;
EOF
# 3. kfold_int64shift, without FFI's lj_carith_shift64.
cat > "$D/o3" <<'EOF'
#if LJ_HASFFI
  uint64_t k = ir_k64(fleft)->u64;
  int32_t sh = (fright->i & 63);
  return INT64FOLD(lj_carith_shift64(k, sh, fins->o - IR_BSHL));
#else
EOF
cat > "$D/n3" <<'EOF'
#if 1  /* OC-LuaJIT: the 64-bit bit operators, without FFI. */
  uint64_t k = ir_k64(fleft)->u64;
  int32_t sh = (fright->i & 63);
  switch (fins->o) {
  case IR_BSHL: k <<= sh; break;
  case IR_BSHR: k >>= sh; break;
  case IR_BSAR: k = (uint64_t)((int64_t)k >> sh); break;
  case IR_BROL: k = lj_rol(k, sh); break;
  default: k = lj_ror(k, sh); break;
  }
  return INT64FOLD(k);
#else
EOF
# 4. kfold_bnot64.
cat > "$D/o4" <<'EOF'
#if LJ_HASFFI
  return INT64FOLD(~ir_k64(fleft)->u64);
EOF
cat > "$D/n4" <<'EOF'
#if 1  /* OC-LuaJIT: the 64-bit bit operators, without FFI. */
  return INT64FOLD(~ir_k64(fleft)->u64);
EOF
# 5. kfold_int64comp.
cat > "$D/o5" <<'EOF'
#if LJ_HASFFI
  uint64_t a = ir_k64(fleft)->u64, b = ir_k64(fright)->u64;
EOF
cat > "$D/n5" <<'EOF'
#if 1  /* OC-LuaJIT: the 64-bit bit operators, without FFI. */
  uint64_t a = ir_k64(fleft)->u64, b = ir_k64(fright)->u64;
EOF
# 6. kfold_int64comp0.
cat > "$D/o6" <<'EOF'
#if LJ_HASFFI
  if (ir_k64(fright)->u64 == 0)
EOF
cat > "$D/n6" <<'EOF'
#if 1  /* OC-LuaJIT: the 64-bit bit operators, without FFI. */
  if (ir_k64(fright)->u64 == 0)
EOF
# 7. simplify_conv_i64_num: the exact mark, the width rule and FIX-NUMCONV.
cat > "$D/o7" <<'EOF'
LJFOLD(CONV CONV IRCONV_I64_NUM)  /* _INT or _U32 */
LJFOLD(CONV CONV IRCONV_U64_NUM)  /* _INT or _U32 */
LJFOLDF(simplify_conv_i64_num)
{
  PHIBARRIER(fleft);
EOF
cat > "$D/n7" <<'EOF'
LJFOLD(CONV CONV IRCONV_I64_NUM)  /* _INT or _U32 */
LJFOLD(CONV CONV IRCONV_U64_NUM)  /* _INT or _U32 */
LJFOLDF(simplify_conv_i64_num)
{
  /* OC-LuaJIT: (i64)(num)y ==> y for an int64 y, by any rule below.
  ** Across a PHI, only to an int64-typed y: an int-typed y is the int loop
  ** index after simplify_conv_sext's x64 LEFTFOLD, and an int64 PHI of it
  ** makes loop_unroll raise TYPEINS and blacklist the loop. */
  if ((fleft->op2 & IRCONV_SRCMASK) == IRT_I64 && irt_isi64(fins->t) &&
      (irt_isi64(IR(fleft->op1)->t) || !irt_isphi(fleft->t))) {
    /* The exact mark: a double marked exact equals its int64 wherever it is
    ** used (its guard comes right after it, and every value a PHI carries
    ** passed one), except in that guard's own check, which is marked too
    ** (oclj_bitop_rec.c, oclj_bitop.h's OCLJ_IRCONV_EXACT). */
    if ((fleft->op2 & OCLJ_IRCONV_EXACT) &&
@T@!(fins->op2 & OCLJ_IRCONV_EXACT))
      return fleft->op1;
    /* The width rule: y is in [-2^53, 2^53), where every integer is a
    ** double, in every iteration (oclj_bitwidth).  This is what removes the
    ** guard of a result that fits. */
    if (oclj_bitwidth(J, fleft->op1, 0) <= 54)
    if (oclj_isnumconv(J, fleft->op1))
      return fleft->op1;
    /* FIX-NUMCONV: y is an unguarded CONV i64.num of a double, x64's
    ** cvttsd2si, whose value (the double's integral part, or -2^63) is
    ** exactly a double whatever its range (oclj_isnumconv: exactness, not
    ** a bound).  This removes the guard of an identity operation, x | 0
    ** and the like, whose result folds to its operand's own conversion. */
      return fleft->op1;
  }
  PHIBARRIER(fleft);
EOF
# 8. narrow_convert.
cat > "$D/o8" <<'EOF'
  /* Narrowing ignores PHIs and repeating it inside the loop is not useful. */
  if (J->chain[IR_LOOP])
    return NEXTFOLD;
EOF
cat > "$D/n8" <<'EOF'
  /* Narrowing ignores PHIs and repeating it inside the loop is not useful. */
  if (J->chain[IR_LOOP])
    return NEXTFOLD;
  /* OC-LuaJIT: a bit operator's CONV i64.num converts the double the
  ** interpreter sees; narrowing it to int64 arithmetic would keep bits the
  ** double rounded away (2^53 + 1 is 2^53 as a double). */
  if (fins->o == IR_CONV && irt_is64(fins->t))
    return NEXTFOLD;
EOF
# 9. simplify_andor_k64.
cat > "$D/o9" <<'EOF'
#if LJ_HASFFI
  IRIns *irk = IR(fleft->op2);
  PHIBARRIER(fleft);
  if (irk->o == IR_KINT64) {
EOF
cat > "$D/n9" <<'EOF'
#if 1  /* OC-LuaJIT: the 64-bit bit operators, without FFI. */
  IRIns *irk = IR(fleft->op2);
  PHIBARRIER(fleft);
  if (irk->o == IR_KINT64) {
EOF
# 10. reassoc_intarith_k64.
cat > "$D/o10" <<'EOF'
#if LJ_HASFFI
  IRIns *irk = IR(fleft->op2);
  if (irk->o == IR_KINT64) {
EOF
cat > "$D/n10" <<'EOF'
#if 1  /* OC-LuaJIT: the 64-bit bit operators, without FFI. */
  IRIns *irk = IR(fleft->op2);
  if (irk->o == IR_KINT64) {
EOF
# 11. simplify_conv_int_num: the table-index fold; the bound's #include.
cat > "$D/o11" <<'EOF'
LJFOLD(CONV CONV IRCONV_INT_NUM)  /* _INT */
LJFOLDF(simplify_conv_int_num)
{
  /* Fold even across PHI to avoid expensive num->int conversions in loop. */
  if ((fleft->op2 & IRCONV_SRCMASK) ==
      ((fins->op2 & IRCONV_DSTMASK) >> IRCONV_DSH))
    return fleft->op1;
  return NEXTFOLD;
}
EOF
cat > "$D/n11" <<'EOF'
/* OC-LuaJIT: oclj_bitwidth, the bound that the table-index fold below and
** simplify_conv_i64_num's width rule read, is in native/luajit/
** oclj_bitop_fold.c; buildvm reads LJFOLD lines from this file only, so the
** rules stay here. */
#include "oclj_bitop_fold.c"

LJFOLD(CONV CONV IRCONV_INT_NUM)  /* _INT */
LJFOLDF(simplify_conv_int_num)
{
  /* Fold even across PHI to avoid expensive num->int conversions in loop. */
  if ((fleft->op2 & IRCONV_SRCMASK) ==
      ((fins->op2 & IRCONV_DSTMASK) >> IRCONV_DSH))
    return fleft->op1;
  /* OC-LuaJIT, the table-index fold: (int)(num)y ==> the unguarded CONV
  ** int.i64 y, for an int64 y in [-2^31, 2^31) (oclj_bitwidth's bound of 32
  ** or less): a bit result used as a table key (INDEX), a library integer
  ** argument (ANY) or a variable shift count (CHECK).  Such a y is its
  ** double exactly and an int32 exactly, so this conversion, checked or
  ** not, gives y, and its check cannot fail; y's low 32 bits are y.  The
  ** proof is the bound alone, which reads no guard and no exact mark.  The
  ** mode has no check bits, so x64's asm_conv emits mov r32, r32, which
  ** zero-extends as every int does.  Not across a PHI: the new instruction
  ** would take fleft->op1, a pre-roll ref, into the loop body. */
  if ((fleft->op2 & IRCONV_SRCMASK) == IRT_I64 && !irt_isphi(fleft->t) &&
      oclj_bitwidth(J, fleft->op1, 0) <= 32) {
    fins->ot = IRTI(IR_CONV);
    fins->op1 = fleft->op1;
    fins->op2 = (IRT_INT<<IRCONV_DSH)|IRT_I64;
    return RETRYFOLD;
  }
  return NEXTFOLD;
}
EOF

# --- THE HUNK ENGINE (the same text in all seven patch-bitop-*.sh) ---------
# hunks <file> <mode> reads <file> with each line's trailing CR removed, and
# the hunk files $D/o<h> (upstream's text) and $D/n<h> (ours), h = 1..$NH,
# in which @T@ stands for a tab.  A text matches only as a run of
# consecutive whole lines, compared exactly.
#   count   prints one line per hunk: how often upstream's text occurs, how
#           often ours occurs, and 1 if upstream's text is a run inside ours
#           (an insertion keeps it), else 0;
#   apply   replaces each upstream text by ours, in order, refusing unless it
#           occurs exactly once at that point, and prints the result (LF);
#   revert  the inverse: each of ours by upstream's text, in reverse order.
hunks() {
  HD=$D HN=$NH HM=$2 awk '
    function rd(f, a,    n, l) {
      n = 0
      while ((getline l < f) > 0) { gsub(/@T@/, TAB, l); a[++n] = l }
      close(f)
      return n
    }
    function at(a, n, from,    i, j) {
      for (i = from; i + n - 1 <= nl; i++) {
        for (j = 1; j <= n; j++) if (L[i + j - 1] != a[j]) break
        if (j > n) return i
      }
      return 0
    }
    function times(a, n,    c, i) {
      c = 0
      for (i = at(a, n, 1); i > 0; i = at(a, n, i + 1)) c++
      return c
    }
    function inside(a, n, b, m,    i, j) {
      for (i = 1; i + n - 1 <= m; i++) {
        for (j = 1; j <= n; j++) if (b[i + j - 1] != a[j]) break
        if (j > n) return 1
      }
      return 0
    }
    function die(msg) { print "hunk engine: " msg > "/dev/stderr"; exit 1 }
    BEGIN {
      TAB = sprintf("%c", 9); CR = sprintf("%c", 13)
      d = ENVIRON["HD"]; nh = ENVIRON["HN"] + 0; mode = ENVIRON["HM"]
    }
    {
      if (substr($0, length($0)) == CR) $0 = substr($0, 1, length($0) - 1)
      L[++nl] = $0
    }
    END {
      if (nh < 1 || (mode != "count" && mode != "apply" && mode != "revert"))
        die("bad call")
      for (k = 1; k <= nh; k++) {
        h = (mode == "revert") ? nh + 1 - k : k
        split("", O); split("", N)
        if (mode == "revert") { no = rd(d "/n" h, O); nn = rd(d "/o" h, N) }
        else { no = rd(d "/o" h, O); nn = rd(d "/n" h, N) }
        if (no == 0 || nn == 0) die("hunk " h ": a side is empty or missing")
        if (mode == "count") {
          print times(O, no), times(N, nn), inside(O, no, N, nn)
          continue
        }
        c = times(O, no)
        if (c != 1) die("hunk " h ": the text to replace occurs " c " times, expected 1")
        i = at(O, no, 1)
        split("", M); m = 0
        for (j = 1; j < i; j++) M[++m] = L[j]
        for (j = 1; j <= nn; j++) M[++m] = N[j]
        for (j = i + no; j <= nl; j++) M[++m] = L[j]
        split("", L); nl = m
        for (j = 1; j <= m; j++) L[j] = M[j]
      }
      if (mode != "count") for (j = 1; j <= nl; j++) print L[j]
    }' "$1"
}
# lf <file>: the file with each line's trailing CR removed.  ncr <file>: how
# many lines still carry a CR.
lf() {
  awk 'BEGIN { CR = sprintf("%c", 13) }
    { if (substr($0, length($0)) == CR) $0 = substr($0, 1, length($0) - 1); print }' "$1"
}
ncr() {
  awk 'BEGIN { CR = sprintf("%c", 13) } index($0, CR) { n++ } END { print n + 0 }' "$1"
}
# A patched file: the marker NMARK times; every hunk's text exactly once,
# and upstream's text gone unless ours keeps it (an insertion).  Used for the
# idempotent path and for the output.
verify_patched() {
  f=$1
  [ "$(countsub "$MARK" "$f")" = "$NMARK" ] || fail "$f: marker present $(countsub "$MARK" "$f") times, expected $NMARK"
  hunks "$f" count > "$D/counts" || fail "$f: the hunk engine could not count"
  h=0
  while read -r o n s; do
    h=$((h + 1))
    [ "$n" = 1 ] || fail "$f: hunk $h's patched text occurs $n times, expected 1"
    [ "$s" = 1 ] || [ "$o" = 0 ] || fail "$f: hunk $h's upstream text still occurs $o times"
  done < "$D/counts"
  [ "$h" = "$NH" ] || fail "$f: counted $h hunks, expected $NH"
  verify_content "$f"
}
# --- end of the hunk engine ----------------------------------------------

# What the hunks cannot say on their own: seven #if 1 lines; the bound is
# included once, before the two rules that call it, each rule calling it
# once inside its own function (the table-index fold with 32, the width rule
# with 54); and the include is not itself a line buildvm would read (it does
# not start with LJFOLD).  Which checks fail alone (every check run on ten
# mutations, 2026-10-20): when every hunk's text matched, the #if 1 count,
# the oclj_bitwidth( count (a stray line), and the link "the 32 call above
# simplify_conv_i64_num" (hunk 11 above hunk 7: the pristine file's order);
# on an edit of this script's n11 or n7, the order links inside that hunk.
# Implied, and kept for their messages: the include count and both calls'
# counts (an extra one also fails an order link, and none the missing check).
# FIX-NUMCONV's predicate is named on one line, its call on fleft->op1, which
# lies inside the rules' block, below the width rule's call and above the
# line '  }' that ends that block directly above simplify_conv_i64_num's
# PHIBARRIER: there fleft is a CONV num.i64 and the folded conversion's type
# is int64.  Each was run on its own mutation of a patched file with a fail()
# that does not exit (2026-10-21): when every hunk's text matched, the
# oclj_isnumconv( count fails alone on a stray line; on an edit of this
# script's n7, the order fails alone on the call above the width rule,
# between the block's '  }' and the PHIBARRIER, or below the PHIBARRIER, and
# the call's text (another operand) and the count (a second call, or none)
# fail first, the order failing with them.  The width rule's call and
# FIX-NUMCONV's are each followed directly by their own return line, so
# neither call sits nested in the other's unbraced if, which every check
# above passes (the code verifier's m11, 2026-10-21); on that edit of n7
# this check fails alone.
verify_content() {
  [ "$(countx "$NOFFI" "$1")" = 7 ] || fail "$1: '$NOFFI' occurs $(countx "$NOFFI" "$1") times, expected 7"
  [ "$(countx '#include "oclj_bitop_fold.c"' "$1")" = 1 ] || fail "$1: oclj_bitop_fold.c is included $(countx '#include "oclj_bitop_fold.c"' "$1") times, expected 1"
  [ "$(countsub 'oclj_bitwidth(' "$1")" = 2 ] || fail "$1: oclj_bitwidth is named on $(countsub 'oclj_bitwidth(' "$1") lines, expected 2 (the two rules' calls; the definition is in oclj_bitop_fold.c)"
  [ "$(countsub 'oclj_bitwidth(J, fleft->op1, 0) <= 32)' "$1")" = 1 ] || fail "$1: the table-index fold's call (32) does not occur exactly once"
  [ "$(countsub 'oclj_bitwidth(J, fleft->op1, 0) <= 54)' "$1")" = 1 ] || fail "$1: the width rule's call (54) does not occur exactly once"
  LI=$(grep -n -x -F '#include "oclj_bitop_fold.c"' "$1" | cut -d: -f1)
  LR1=$(grep -n -x -F 'LJFOLDF(simplify_conv_int_num)' "$1" | cut -d: -f1)
  LC1=$(grep -n -F 'oclj_bitwidth(J, fleft->op1, 0) <= 32)' "$1" | cut -d: -f1)
  LR2=$(grep -n -x -F 'LJFOLDF(simplify_conv_i64_num)' "$1" | cut -d: -f1)
  LC2=$(grep -n -F 'oclj_bitwidth(J, fleft->op1, 0) <= 54)' "$1" | cut -d: -f1)
  [ -n "$LI" ] && [ -n "$LR1" ] && [ -n "$LC1" ] && [ -n "$LR2" ] && [ -n "$LC2" ] || fail "$1: missing the include, a rule or its call"
  if [ "$LI" -lt "$LR1" ] && [ "$LR1" -lt "$LC1" ] && [ "$LC1" -lt "$LR2" ] && [ "$LR2" -lt "$LC2" ]; then :; else
    fail "$1: out of order (include $LI, simplify_conv_int_num $LR1, its call $LC1, simplify_conv_i64_num $LR2, its call $LC2)"
  fi
  [ "$(countsub 'oclj_isnumconv(' "$1")" = 1 ] || fail "$1: oclj_isnumconv is named on $(countsub 'oclj_isnumconv(' "$1") lines, expected 1 (FIX-NUMCONV's call; the definition is in oclj_bitop_fold.c)"
  LN=$(grep -n -F 'if (oclj_isnumconv(J, fleft->op1))' "$1" | cut -d: -f1)
  LP=$(awk -v s="$LR2" 'NR > s + 0 && $0 == "  PHIBARRIER(fleft);" { print NR; exit }' "$1")
  [ -n "$LN" ] && [ -n "$LP" ] || fail "$1: missing FIX-NUMCONV's call on fleft->op1, or simplify_conv_i64_num's PHIBARRIER"
  LE=$(awk -v p="$LP" 'NR == p - 1 { print; exit }' "$1")
  if [ "$LC2" -lt "$LN" ] && [ "$LN" -lt "$((LP - 1))" ] && [ "$LE" = "  }" ]; then :; else
    fail "$1: FIX-NUMCONV's call (line $LN) is not inside the rules' block below the width rule's call ($LC2), which ends with '  }' directly above simplify_conv_i64_num's PHIBARRIER ($LP)"
  fi
  RL='      return fleft->op1;'
  if [ "$(awk -v n="$LC2" 'NR == n + 1 { print; exit }' "$1")" = "$RL" ] && [ "$(awk -v n="$LN" 'NR == n + 1 { print; exit }' "$1")" = "$RL" ]; then :; else
    fail "$1: the width rule's call (line $LC2) or FIX-NUMCONV's (line $LN) is not followed directly by its own '$RL': a call nested in another rule's if"
  fi
}

# --- already patched?  verify, copy if asked, and say so ------------------
if grep -q -F -- "$MARK" "$IN"; then
  verify_patched "$IN"
  if [ "$IN" != "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")" || exit 1
    cp "$IN" "$OUT" || fail "cannot copy $IN to $OUT"
  fi
  echo "$ME: $(basename "$OUT")  already folds the 64-bit bit operators without FFI (verified) -- unchanged"
  exit 0
fi

# --- patch ------------------------------------------------------------------
hunks "$IN" count > "$D/counts0" || fail "the hunk engine could not count $IN"
h=0
while read -r o n s; do
  h=$((h + 1))
  [ "$o" = 1 ] || fail "refusing -- hunk $h's upstream text occurs $o times in $IN, expected exactly 1 (has lj_opt_fold.c changed shape?)"
  [ "$n" = 0 ] || fail "refusing -- hunk $h's patched text already occurs in $IN"
done < "$D/counts0"
[ "$h" = "$NH" ] || fail "counted $h hunks, expected $NH"

mkdir -p "$(dirname "$OUT")" || exit 1
TMP=$OUT.tmp.$$
trap 'rm -rf "$D"; rm -f "$TMP"' EXIT
hunks "$IN" apply > "$TMP" || fail "the hunk engine refused $IN (above)"

# VERIFY, RATHER THAN TRUST THE AWK.
verify_patched "$TMP"
[ "$(ncr "$TMP")" = 0 ] || fail "the output carries CR characters"
# Exactly seven #if LJ_HASFFI are gone; buildvm's fold table keeps every
# rule (the same LJFOLD lines, in the same order).
[ "$(countx '#if LJ_HASFFI' "$TMP")" = "$(( $(lf "$IN" | grep -c -x -F '#if LJ_HASFFI') - 7 ))" ] || fail "#if LJ_HASFFI: $(lf "$IN" | grep -c -x -F '#if LJ_HASFFI') lines in, $(countx '#if LJ_HASFFI' "$TMP") out, expected 7 fewer"
lf "$IN" | grep '^LJFOLD' > "$D/rules.in"
grep '^LJFOLD' "$TMP" > "$D/rules.out"
cmp -s "$D/rules.in" "$D/rules.out" || fail "the LJFOLD lines differ between $IN and the output: buildvm's fold table would change"
NL_IN=$(wc -l < "$IN" | tr -d ' ')
NL_OUT=$(wc -l < "$TMP" | tr -d ' ')
[ "$NL_OUT" = "$((NL_IN + NADD - NDEL))" ] || fail "line count: $NL_IN in + $NADD - $NDEL != $NL_OUT out"
diff -d --strip-trailing-cr "$IN" "$TMP" > "$D/diff"
ADDED=$(grep -c '^>' "$D/diff" || true)
REMOVED=$(grep -c '^<' "$D/diff" || true)
if [ "$ADDED" != "$NADD" ] || [ "$REMOVED" != "$NDEL" ]; then
  head -60 "$D/diff" >&2
  fail "expected exactly $NADD added and $NDEL removed lines, got $ADDED added / $REMOVED removed"
fi
# The change is exactly the hunks: put each upstream text back and the input
# comes out, CR stripped, byte for byte.
hunks "$TMP" revert > "$D/back" || fail "could not put the upstream text back (above)"
lf "$IN" > "$D/in"
cmp -s "$D/back" "$D/in" || fail "putting each hunk's upstream text back does not give $IN: the output differs from it by more than the hunks"

mv -f "$TMP" "$OUT" || fail "cannot write $OUT"
trap 'rm -rf "$D"' EXIT
echo "$ME: $(basename "$OUT")  int64 bit folds without FFI, no int64 narrowing, the exact-mark, width and FIX-NUMCONV rules, the table-index fold ($NADD lines added, $NDEL removed, of $NL_OUT); verified by content, diff and reversal"
