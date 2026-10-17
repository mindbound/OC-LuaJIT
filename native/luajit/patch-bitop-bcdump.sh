#!/bin/sh
# native/luajit/patch-bitop-bcdump.sh -- the sixth of round 3's seven
# changes to LuaJIT (Lua 5.3.6's 64-bit bitwise operators), and the second
# header we change: lj_bcdump.h's BCDUMP_VERSION becomes 0x80.  (Round 3's
# others: patch-bitop-parse.sh, patch-bitop-vm.sh, patch-bitop-meta.sh,
# patch-bitop-record.sh, patch-bitop-fold.sh, patch-bitop-jitlib.sh;
# before them, patch-penalty-scrub.sh, patch-fastfunc-errmem-top.sh,
# patch-strfmt-xint-noffi.sh, patch-features-include.sh,
# patch-strpack-register.sh.)
#
#     sh native/luajit/patch-bitop-bcdump.sh <in lj_bcdump.h> <out lj_bcdump.h>
#
# <in> and <out> may name the SAME file.  build-native.sh re-copies the
# PRISTINE lj_bcdump.h over the build copy before every run, for the reason
# patch-penalty-scrub.sh's header gives, so the build always takes the patch
# path below; the "already patched" path is for hand use.
#
# WHY.  Round 3 changes what bytecode MEANS without changing its shape: the
# same BC_BNOT..BC_BSAR instructions compute Lua 5.3.6's 64-bit results
# (1 << 32 is 4294967296, upstream 1), and the parser folds constants by
# 5.3.6's rules, so `return 1 << 32` dumps the constant 4294967296 where
# upstream's dump of the same source holds 1.  A function dumped by upstream
# LuaJIT, or by an OC-LuaJIT before round 3, would compute other results
# here, and the reverse.  lj_bcdump.h:36-38 says what to do: "If you perform
# *any* kind of private modifications to the bytecode itself or to the dump
# format, you *must* set BCDUMP_VERSION to 0x80 or higher."  lj_bcwrite.c
# writes the version byte (lj_bcwrite.c:397) and lj_bcread.c refuses any
# other (lj_bcread.c:400), so each build now refuses the other's dumps --
# load() of a string.dump, and eris_lj's persisted closures, whose blob
# fingerprint also changes (native/luajit/oclj_features.h, OCLJ_OPS_BIT64,
# token bit64).  Upstream's BCDUMP_F_BITOP flag (lj_bcdump.h:46) cannot
# carry it: lj_bcwrite.c:401 sets it only for a function that contains a bit
# opcode, and a folded constant leaves none.  0x80 is the first private
# value; the next private change to the bytecode takes 0x81.
#
# Anchored, refusing otherwise, on the line `#define BCDUMP_VERSION`, two
# tabs, `2` (lj_bcdump.h:39 at 1ee778a4), which must occur exactly once; the
# line is replaced by a comment carrying the marker and the new define.
# Verified by content, by diff, and by putting the upstream line back and
# comparing with the input.  CRLF is stripped (the pinned tree checks out
# CRLF on Windows); the output is LF.  This script contains no backslashes
# and no tabs: in the hunk texts below, @T@ stands for a tab.
set -u

[ $# -eq 2 ] || { echo "usage: patch-bitop-bcdump.sh <in lj_bcdump.h> <out lj_bcdump.h>" >&2; exit 2; }
IN=$1
OUT=$2
[ -f "$IN" ] || { echo "patch-bitop-bcdump.sh: no $IN" >&2; exit 2; }

ME=patch-bitop-bcdump.sh
MARK='OC-LuaJIT (native/luajit/patch-bitop-bcdump.sh)'
NMARK=1     # the marker occurs once in a patched file
NH=1        # hunks
NADD=6      # lines diff -d reports added on the pristine file ...
NDEL=1      # ... and removed

fail() { echo "$ME: $*" >&2; exit 1; }
countsub() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }

D=${TMPDIR:-/tmp}/$ME.$$
rm -rf "$D"
mkdir -p "$D" || fail "cannot create $D"
trap 'rm -rf "$D"' EXIT

# --- the hunks: o<h> is upstream's text, n<h> ours --------------------------
cat > "$D/o1" <<'EOF'
#define BCDUMP_VERSION@T@@T@2
EOF
cat > "$D/n1" <<'EOF'
/* OC-LuaJIT (native/luajit/patch-bitop-bcdump.sh): the first private
** version.  Round 3's bitwise operators change what BC_BNOT..BC_BSAR and the
** constants the parser folds from them mean (native/luajit/oclj_features.h,
** OCLJ_OPS_BIT64), so each build must refuse the other's dumps.
*/
#define BCDUMP_VERSION@T@@T@0x80
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

# What the hunks cannot say on their own: one version define, and it is 0x80.
verify_content() {
  [ "$(grep -c '^#define BCDUMP_VERSION' "$1")" = 1 ] || fail "$1: BCDUMP_VERSION is defined $(grep -c '^#define BCDUMP_VERSION' "$1") times, expected 1"
  [ "$(awk '$1 == "#define" && $2 == "BCDUMP_VERSION" { print $3 }' "$1")" = 0x80 ] || fail "$1: BCDUMP_VERSION is not 0x80"
}

# --- already patched?  verify, copy if asked, and say so ------------------
if grep -q -F -- "$MARK" "$IN"; then
  verify_patched "$IN"
  if [ "$IN" != "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")" || exit 1
    cp "$IN" "$OUT" || fail "cannot copy $IN to $OUT"
  fi
  echo "$ME: $(basename "$OUT")  already says BCDUMP_VERSION 0x80 (verified) -- unchanged"
  exit 0
fi

# --- patch ------------------------------------------------------------------
hunks "$IN" count > "$D/counts0" || fail "the hunk engine could not count $IN"
h=0
while read -r o n s; do
  h=$((h + 1))
  [ "$o" = 1 ] || fail "refusing -- hunk $h's upstream text occurs $o times in $IN, expected exactly 1 (has lj_bcdump.h changed shape?)"
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
echo "$ME: $(basename "$OUT")  BCDUMP_VERSION 2 -> 0x80 ($NADD lines for $NDEL, of $NL_OUT); verified by content, diff and reversal"
