#!/bin/sh
# native/luajit/patch-bitop-meta.sh -- the third of round 3's seven changes to
# LuaJIT (Lua 5.3.6's 64-bit bitwise operators): lj_meta_bitop, the
# interpreter's slow path for BC_BNOT..BC_BSAR, computes 5.3.6's results and
# raises 5.3.6's errors, through native/luajit/oclj_bitop_meta.c.  (Round
# 3's others: patch-bitop-parse.sh, patch-bitop-vm.sh,
# patch-bitop-record.sh, patch-bitop-fold.sh, patch-bitop-bcdump.sh,
# patch-bitop-jitlib.sh.)
#
#     sh native/luajit/patch-bitop-meta.sh <in lj_meta.c> <out lj_meta.c>
#
# <in> and <out> may name the SAME file.  build-native.sh re-copies the
# PRISTINE lj_meta.c over the build copy before every run, for the reason
# patch-penalty-scrub.sh's header gives, and copies oclj_bitop_meta.c,
# oclj_bitop.h and oclj_num53.h next to it; the build always takes the patch
# path below, and the "already patched" path is for hand use.
#
# WHAT IS WRONG.  Without FFI, lj_meta_bitop (lj_meta.c:242-310) can only
# raise "attempt to perform arithmetic on" (:307-308): upstream's fast path
# computes every bit operator on two numbers, in 32 bits, so the slow path
# only ever saw a non-number.  Round 3's fast path (patch-bitop-vm.sh) sends
# here everything it cannot compute exactly: a string operand (5.3.6
# coerces it), a shift count outside [0, 63], a number with no integer
# representation, and a result with more than 53 significant bits.
#
# THE CHANGE, two hunks.  oclj_bitop_meta.c is #included directly above
# lj_meta_bitop, under #if !LJ_HASFFI like the code it replaces.  The
# function's no-FFI tail (:282-310), a DUALNUM 32-bit block and the
# arithmetic error, becomes one call, oclj_meta_bitop(L, ra, rb, rc, op).
# The DUALNUM block can go: oclj_bitop.h refuses to compile under
# LJ_DUALNUM, and native/luajit/oclj_features.h refuses LUAJIT_NUMMODE.  The
# FFI branch above the tail stays as it is, compiled out.  lj_err.c and
# lj_errmsg.h are not touched; oclj_bitop_meta.c's header says how it
# raises.
#
# Anchored, refusing otherwise, on the comment line above lj_meta_bitop
# (lj_meta.c:242 at 1ee778a4) and on the tail's 29 lines from its #else to
# the function's closing brace (:282-310), each exactly once.  Verified by
# content, by diff, and by putting upstream's text back and comparing with
# the input.  CRLF is stripped (the pinned tree checks out CRLF on Windows);
# the output is LF.  This script contains no backslashes and no tabs: in the
# hunk texts below, @T@ would stand for a tab.
set -u

[ $# -eq 2 ] || { echo "usage: patch-bitop-meta.sh <in lj_meta.c> <out lj_meta.c>" >&2; exit 2; }
IN=$1
OUT=$2
[ -f "$IN" ] || { echo "patch-bitop-meta.sh: no $IN" >&2; exit 2; }

ME=patch-bitop-meta.sh
MARK='OC-LuaJIT (native/luajit/patch-bitop-meta.sh)'
NMARK=1     # the marker occurs once in a patched file
NH=2        # hunks
NADD=8      # lines diff -d reports added on the pristine file ...
NDEL=26     # ... and removed

fail() { echo "$ME: $*" >&2; exit 1; }
countsub() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }

D=${TMPDIR:-/tmp}/$ME.$$
rm -rf "$D"
mkdir -p "$D" || fail "cannot create $D"
trap 'rm -rf "$D"' EXIT

# --- the hunks: o<h> is upstream's text, n<h> ours --------------------------
# 1. The slow path's code, directly above lj_meta_bitop.
cat > "$D/o1" <<'EOF'
/* Helper for bit operators. No bitop metamethods in v2.1. */
EOF
cat > "$D/n1" <<'EOF'
/* OC-LuaJIT (native/luajit/patch-bitop-meta.sh): Lua 5.3.6's bitwise
** operators' slow path, oclj_meta_bitop (native/luajit/oclj_bitop_meta.c). */
#if !LJ_HASFFI
#include "oclj_bitop_meta.c"
#endif

/* Helper for bit operators. No bitop metamethods in v2.1. */
EOF
# 2. lj_meta_bitop's no-FFI tail.
cat > "$D/o2" <<'EOF'
#else
#if LJ_DUALNUM
  uint32_t b = 0, c = 0;
  if (tvisint(rb)) b = (uint32_t)intV(rb);
  else if (tvisnum(rb)) b = (uint32_t)lj_num2bit(numV(rb));
  else goto err;
  if (tvisint(rc)) c = (uint32_t)intV(rc);
  else if (tvisnum(rc)) c = (uint32_t)lj_num2bit(numV(rc));
  else goto err;
  switch (op) {
  case BC_BNOT: b = ~b; break;
  case BC_BAND: b &= c; break;
  case BC_BOR: b |= c; break;
  case BC_BXOR: b ^= c; break;
  case BC_BSHL: b <<= (c & 31); break;
  case BC_BSHR: b >>= (c & 31); break;
  case BC_BSAR: b = (uint32_t)((int32_t)b >> (c & 31)); break;
  default:
    lj_assertL(0, "bad bytecode op %d", op);
    break;
  }
  setintV(ra, (int32_t)b);
  return;
err:
#endif
  UNUSED(ra); UNUSED(op);
  lj_err_optype(L, tvisnumber(rb) ? rc : rb, LJ_ERR_OPARITH);
#endif
}
EOF
cat > "$D/n2" <<'EOF'
#else
  /* OC-LuaJIT: Lua 5.3.6's operators (oclj_bitop_meta.c). */
  oclj_meta_bitop(L, ra, rb, rc, op);
#endif
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

# What the hunks cannot say on their own: lj_meta_bitop is still defined
# once, and the code it calls is included above it, not elsewhere.
verify_content() {
  [ "$(grep -c '^void lj_meta_bitop(' "$1")" = 1 ] || fail "$1: lj_meta_bitop is defined $(grep -c '^void lj_meta_bitop(' "$1") times, expected 1"
  [ "$(grep -c -x -F '#include "oclj_bitop_meta.c"' "$1")" = 1 ] || fail "$1: oclj_bitop_meta.c is included $(grep -c -x -F '#include "oclj_bitop_meta.c"' "$1") times, expected 1"
  LI=$(grep -n -x -F '#include "oclj_bitop_meta.c"' "$1" | cut -d: -f1)
  LF=$(grep -n '^void lj_meta_bitop(' "$1" | cut -d: -f1)
  LC=$(grep -n -F 'oclj_meta_bitop(L, ra, rb, rc, op);' "$1" | cut -d: -f1)
  if [ "$LI" -lt "$LF" ] && [ "$LF" -lt "$LC" ]; then :; else
    fail "$1: out of order (include $LI, lj_meta_bitop $LF, the call $LC)"
  fi
}

# --- already patched?  verify, copy if asked, and say so ------------------
if grep -q -F -- "$MARK" "$IN"; then
  verify_patched "$IN"
  if [ "$IN" != "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")" || exit 1
    cp "$IN" "$OUT" || fail "cannot copy $IN to $OUT"
  fi
  echo "$ME: $(basename "$OUT")  already calls oclj_meta_bitop (verified) -- unchanged"
  exit 0
fi

# --- patch ------------------------------------------------------------------
hunks "$IN" count > "$D/counts0" || fail "the hunk engine could not count $IN"
h=0
while read -r o n s; do
  h=$((h + 1))
  [ "$o" = 1 ] || fail "refusing -- hunk $h's upstream text occurs $o times in $IN, expected exactly 1 (has lj_meta.c changed shape?)"
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
# The arithmetic error the tail raised is gone, and only it.
[ "$(countsub 'LJ_ERR_OPARITH' "$TMP")" = "$(( $(countsub 'LJ_ERR_OPARITH' "$IN") - 1 ))" ] || fail "LJ_ERR_OPARITH: $(countsub 'LJ_ERR_OPARITH' "$IN") uses in, $(countsub 'LJ_ERR_OPARITH' "$TMP") out, expected one fewer"
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
echo "$ME: $(basename "$OUT")  lj_meta_bitop's no-FFI path calls oclj_meta_bitop ($NADD lines added, $NDEL removed, of $NL_OUT); verified by content, diff and reversal"
