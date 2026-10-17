#!/bin/sh
# native/luajit/patch-bitop-parse.sh -- the first of round 3's seven changes
# to LuaJIT (Lua 5.3.6's 64-bit bitwise operators): the parser folds
# constant bitwise expressions by 5.3.6's rules, through
# native/luajit/oclj_bitop.h.  (Round 3's others: patch-bitop-vm.sh,
# patch-bitop-meta.sh, patch-bitop-record.sh, patch-bitop-fold.sh,
# patch-bitop-bcdump.sh, patch-bitop-jitlib.sh.)
#
#     sh native/luajit/patch-bitop-parse.sh <in lj_parse.c> <out lj_parse.c>
#
# <in> and <out> may name the SAME file.  build-native.sh re-copies the
# PRISTINE lj_parse.c over the build copy before every run, for the reason
# patch-penalty-scrub.sh's header gives, and copies oclj_bitop.h and
# oclj_num53.h next to it; the build always takes the patch path below, and
# the "already patched" path is for hand use.
#
# WHAT IS WRONG.  foldbitop (lj_parse.c:818-835) and the unary ~ fold
# (:1050-1054) fold every pair of numeric constants to an int32 through
# expr_bitV (:89-93, BitOp's lj_num2bit), with shift counts masked to 31:
# `1 << 32` folds to 1 and `1.5 | 0` to 2, where 5.3.6 gives 4294967296 and
# raises "number has no integer representation".
#
# THE CHANGE, four hunks.  lj_parse.c includes oclj_bitop.h; expr_bitV, the
# 32-bit reader, is removed (a comment says where it went); and both folds
# compute oclj_bitop.h's oclj_bitop64, the function the interpreter's slow
# path uses (oclj_bitop_meta.c), and store a number (setnumV), where
# upstream stored an int.  A fold happens only when both constants have an
# integer representation (oclj_flt2int) and the result has a double that
# equals it (oclj_bit2num); otherwise the operator is left to the run time,
# which raises the error -- as 5.3.6's lcode.c validop leaves an operand
# without an integer representation to the run time (lcode.c:960-971).
# PROTO_BITOP is still set as before (:956, :1056).
#
# Anchored, refusing otherwise, on the line `#include "lj_vmevent.h"`
# (lj_parse.c:29 at 1ee778a4), on expr_bitV's five lines (:89-93), on
# foldbitop's body from its `if` to its `return 0;` (:820-834), and on the
# ~ fold's five lines (:1050-1054), each exactly once.  Verified by content,
# by diff, and by putting upstream's text back and comparing with the input.
# CRLF is stripped (the pinned tree checks out CRLF on Windows); the output
# is LF.  This script contains no backslashes and no tabs: in the hunk texts
# below, @T@ stands for a tab.
set -u

[ $# -eq 2 ] || { echo "usage: patch-bitop-parse.sh <in lj_parse.c> <out lj_parse.c>" >&2; exit 2; }
IN=$1
OUT=$2
[ -f "$IN" ] || { echo "patch-bitop-parse.sh: no $IN" >&2; exit 2; }

ME=patch-bitop-parse.sh
MARK='OC-LuaJIT (native/luajit/patch-bitop-parse.sh)'
NMARK=1     # the marker occurs once in a patched file
NH=4        # hunks
NADD=24     # lines diff -d reports added on the pristine file ...
NDEL=18     # ... and removed

fail() { echo "$ME: $*" >&2; exit 1; }
countsub() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }

D=${TMPDIR:-/tmp}/$ME.$$
rm -rf "$D"
mkdir -p "$D" || fail "cannot create $D"
trap 'rm -rf "$D"' EXIT

# --- the hunks: o<h> is upstream's text, n<h> ours --------------------------
# 1. The rules.
cat > "$D/o1" <<'EOF'
#include "lj_vmevent.h"
EOF
cat > "$D/n1" <<'EOF'
#include "lj_vmevent.h"
#include "oclj_bitop.h"  /* OC-LuaJIT (native/luajit/patch-bitop-parse.sh) */
EOF
# 2. expr_bitV, the 32-bit reader of a constant, which nothing uses after 3, 4.
cat > "$D/o2" <<'EOF'
static LJ_AINLINE int32_t expr_bitV(ExpDesc *e)
{
  TValue *o = expr_numtv(e);
  return tvisint(o) ? intV(o) : lj_num2bit(numV(o));
}
EOF
cat > "$D/n2" <<'EOF'
/* OC-LuaJIT: expr_bitV, BitOp's 32-bit reading of a numeric constant, is
** gone: foldbitop and the unary ~ fold read constants by 5.3.6's rules. */
EOF
# 3. foldbitop.
cat > "$D/o3" <<'EOF'
  if (expr_isnumk_nojump(e1) && expr_isnumk_nojump(e2)) {
    int32_t k1 = expr_bitV(e1), k2 = expr_bitV(e2);
    switch (opr) {
    case OPR_BAND: k1 &= k2; break;
    case OPR_BOR: k1 |= k2; break;
    case OPR_BXOR: k1 ^= k2; break;
    case OPR_BSHL: k1 <<= (k2 & 31); break;
    case OPR_BSHR: k1 = (int32_t)((uint32_t)k1 >> (k2 & 31)); break;
    case OPR_BSAR: k1 >>= (k2 & 31); break;
    default: lj_assertX(0, "bad OPR %d", opr); break;
    }
    setintV(&e1->u.nval, k1);
    return 1;
  }
  return 0;
EOF
cat > "$D/n3" <<'EOF'
  /* OC-LuaJIT: Lua 5.3.6's rules (oclj_bitop.h), the function the
  ** interpreter's slow path uses.  An operand without an integer
  ** representation is not folded: the run time raises the error, as 5.3.6's
  ** lcode.c validop leaves it to (lcode.c:960-971). */
  if (expr_isnumk_nojump(e1) && expr_isnumk_nojump(e2)) {
    int64_t k1, k2;
    if (!oclj_flt2int(expr_numberV(e1), &k1) ||
@T@!oclj_flt2int(expr_numberV(e2), &k2))
      return 0;
    {
      double d;  /* Nor is a result of more than 53 significant bits. */
      if (!oclj_bit2num(oclj_bitop64((int)opr-OPR_BAND+BC_BAND, k1, k2), &d))
@T@return 0;
      setnumV(&e1->u.nval, d);
    }
    return 1;
  }
  return 0;
EOF
# 4. The unary ~ fold.
cat > "$D/o4" <<'EOF'
      } else if (op == BC_BNOT && expr_isnumk(e)) {
@T@/* Constant-fold bitwise not. */
@T@setintV(&e->u.nval, (int32_t)~(uint32_t)expr_bitV(e));
@T@return;
      }
EOF
cat > "$D/n4" <<'EOF'
      } else if (op == BC_BNOT && expr_isnumk(e)) {
@T@/* Constant-fold bitwise not.  OC-LuaJIT: 5.3.6's rules. */
@T@int64_t k;
@T@double d;
@T@if (oclj_flt2int(expr_numberV(e), &k) &&
@T@    oclj_bit2num(~(uint64_t)k, &d)) {
@T@  setnumV(&e->u.nval, d);
@T@  return;
@T@}
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

# What the hunks cannot say on their own: no use of the 32-bit reader is
# left anywhere in the file, and both folds call the shared rules.
verify_content() {
  [ "$(countsub 'expr_bitV(' "$1")" = 0 ] || fail "$1: expr_bitV is still used $(countsub 'expr_bitV(' "$1") times"
  [ "$(countsub 'oclj_bit2num(' "$1")" = 2 ] || fail "$1: oclj_bit2num is called $(countsub 'oclj_bit2num(' "$1") times, expected 2 (foldbitop, the ~ fold)"
  [ "$(countsub 'oclj_flt2int(' "$1")" = 3 ] || fail "$1: oclj_flt2int is called $(countsub 'oclj_flt2int(' "$1") times, expected 3"
}

# --- already patched?  verify, copy if asked, and say so ------------------
if grep -q -F -- "$MARK" "$IN"; then
  verify_patched "$IN"
  if [ "$IN" != "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")" || exit 1
    cp "$IN" "$OUT" || fail "cannot copy $IN to $OUT"
  fi
  echo "$ME: $(basename "$OUT")  already folds by 5.3.6's rules (verified) -- unchanged"
  exit 0
fi

# --- patch ------------------------------------------------------------------
hunks "$IN" count > "$D/counts0" || fail "the hunk engine could not count $IN"
h=0
while read -r o n s; do
  h=$((h + 1))
  [ "$o" = 1 ] || fail "refusing -- hunk $h's upstream text occurs $o times in $IN, expected exactly 1 (has lj_parse.c changed shape?)"
  [ "$n" = 0 ] || fail "refusing -- hunk $h's patched text already occurs in $IN"
done < "$D/counts0"
[ "$h" = "$NH" ] || fail "counted $h hunks, expected $NH"
# expr_bitV must be named only where the hunks replace it, or removing it
# would break a use this script does not know: three lines (its definition,
# foldbitop's line with two calls, the ~ fold's call).
[ "$(countsub 'expr_bitV(' "$IN")" = 3 ] || fail "refusing -- $IN names expr_bitV on $(countsub 'expr_bitV(' "$IN") lines, expected 3 (its definition, foldbitop's two calls on one line, the ~ fold's one)"

mkdir -p "$(dirname "$OUT")" || exit 1
TMP=$OUT.tmp.$$
trap 'rm -rf "$D"; rm -f "$TMP"' EXIT
hunks "$IN" apply > "$TMP" || fail "the hunk engine refused $IN (above)"

# VERIFY, RATHER THAN TRUST THE AWK.
verify_patched "$TMP"
[ "$(ncr "$TMP")" = 0 ] || fail "the output carries CR characters"
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
echo "$ME: $(basename "$OUT")  foldbitop and the ~ fold use oclj_bitop.h ($NADD lines added, $NDEL removed, of $NL_OUT); verified by content, diff and reversal"
