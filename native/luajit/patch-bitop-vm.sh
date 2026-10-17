#!/bin/sh
# native/luajit/patch-bitop-vm.sh -- the second of round 3's seven changes to
# LuaJIT (Lua 5.3.6's 64-bit bitwise operators): the interpreter's fast path
# for BC_BNOT..BC_BSAR in vm_x64.dasc computes on int64 and returns only
# exact results.  (Round 3's others: patch-bitop-parse.sh,
# patch-bitop-meta.sh, patch-bitop-record.sh, patch-bitop-fold.sh,
# patch-bitop-bcdump.sh, patch-bitop-jitlib.sh.)
#
#     sh native/luajit/patch-bitop-vm.sh <in vm_x64.dasc> <out vm_x64.dasc>
#
# <in> and <out> may name the SAME file.  build-native.sh re-copies the
# PRISTINE vm_x64.dasc over the build copy before every run, for the reason
# patch-penalty-scrub.sh's header gives -- and here for one more: `make
# clean` deletes host/buildvm_arch.h, and make regenerates it with DynASM
# from whatever vm_x64.dasc the copy holds, so a stale copy would ship
# silently.  The build always takes the patch path below; the "already
# patched" path is for hand use.
#
# WHAT IS WRONG.  BC_BNOT (vm_x64.dasc:3531-3541) and the non-DUALNUM half
# of the ins_bitop macro (:3562-3579) take the low 32 bits of each operand
# after adding 2^52 + 2^51 (sseconst_tobit) and compute in 32 bits: BitOp's
# semantics, so 1 << 32 is 1.  A non-number goes to ->vmeta_bnot or
# ->vmeta_bitop (:1098-1135) and on to lj_meta_bitop.
#
# THE CHANGE, three hunks; only the non-DUALNUM halves (.else) change.
#   - Each operand is converted to int64 (cvttsd2si) and back (cvtsi2sd);
#     if the double differs (ucomisd: not integral, or outside
#     [-2^63, 2^63), where cvttsd2si gives INT64_MIN, whose round trip
#     differs) or is NaN (unordered, jp), the C path takes it: lj_meta_bitop
#     (patch-bitop-meta.sh) raises 5.3.6's error or coerces a string.
#     -2^63 itself round-trips and is accepted, as 5.3.6 accepts it.
#   - A shift count must be in [0, 63] (an unsigned compare); any other
#     count is 5.3.6's luaV_shiftl rule, computed in C.
#   - The operation is the 64-bit not/and/or/xor/shl/shr/sar.
#   - The result is converted to a double and back; if the int64 differs,
#     the result has more than 53 significant bits (or rounded to 2^63), and
#     the C path recomputes it from the untouched operand slots and raises
#     "result of '<op>' has more than 53 significant bits (mask each
#     operand to 32 bits first)".
#   BC_BNOT checks its result in TMPR, because ->vmeta_bnot needs RA and RD.
#   ins_bitop clobbers RA and RC, so its exits go to a new label,
#   ->vmeta_bitop_pc, which reloads both from the instruction (PC_RB, PC_RC,
#   as ->vmeta_bitop's DUALNUM path does, :1106-1109) and falls into
#   ->vmeta_bitop.  Nothing calls out, so the code is the same on Windows
#   and SysV.  DynASM sees only the Makefile's -D flags, never
#   oclj_features.h; oclj_features.h refuses LUAJIT_NUMMODE, so the DUALNUM
#   halves, which this patch leaves alone, are never assembled.
#
# Anchored, refusing otherwise, on the two lines `|// Caveat: ra=RB rb=RC
# rc=RA.` and `|->vmeta_bitop:` (vm_x64.dasc:1104-1105 at 1ee778a4), on
# BC_BNOT's non-DUALNUM half from its `|.else` to its `|.endif`
# (:3531-3541), and on ins_bitop's (:3562-3579), each exactly once.
# Verified by content, by diff, and by putting upstream's text back and
# comparing with the input.  build-native.sh checks, after make, that
# host/buildvm_arch.h was regenerated and echoes this file's OC-LuaJIT
# comment lines.  CRLF is stripped (the pinned tree checks out CRLF on
# Windows); the output is LF.  This script contains no backslashes and no
# tabs: in the hunk texts below, @T@ stands for a tab.
set -u

[ $# -eq 2 ] || { echo "usage: patch-bitop-vm.sh <in vm_x64.dasc> <out vm_x64.dasc>" >&2; exit 2; }
IN=$1
OUT=$2
[ -f "$IN" ] || { echo "patch-bitop-vm.sh: no $IN" >&2; exit 2; }

ME=patch-bitop-vm.sh
MARK='OC-LuaJIT (native/luajit/patch-bitop-vm.sh)'
NMARK=1     # the marker occurs once in a patched file
NH=3        # hunks
NADD=40     # lines diff -d reports added on the pristine file ...
NDEL=15     # ... and removed

fail() { echo "$ME: $*" >&2; exit 1; }
countsub() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }

D=${TMPDIR:-/tmp}/$ME.$$
rm -rf "$D"
mkdir -p "$D" || fail "cannot create $D"
trap 'rm -rf "$D"' EXIT

# --- the hunks: o<h> is upstream's text, n<h> ours --------------------------
# 1. ->vmeta_bitop_pc, ahead of ->vmeta_bitop.
cat > "$D/o1" <<'EOF'
  |// Caveat: ra=RB rb=RC rc=RA.
  |->vmeta_bitop:
EOF
cat > "$D/n1" <<'EOF'
  |// OC-LuaJIT (native/luajit/patch-bitop-vm.sh): the 64-bit fast path
  |// clobbered RC and RA: reload them.
  |->vmeta_bitop_pc:
  |  movzx RCd, PC_RB
  |  movzx RAd, PC_RC
  |// Caveat: ra=RB rb=RC rc=RA.
  |->vmeta_bitop:
EOF
# 2. BC_BNOT, the non-DUALNUM half.
cat > "$D/o2" <<'EOF'
    |.else
    |  checknumtp [BASE+RD*8], ->vmeta_bnot
    |  movsd xmm0, qword [BASE+RD*8]
    |  sseconst_tobit xmm1, RB
    |  addsd xmm0, xmm1
    |  movd RBd, xmm0
    |  not RBd
    |  cvtsi2sd xmm0, RBd
    |  movsd qword [BASE+RA*8], xmm0
    |  ins_next
    |.endif
EOF
cat > "$D/n2" <<'EOF'
    |.else
    |  // OC-LuaJIT: Lua 5.3's ~ on int64.  An operand that is not exactly an
    |  // integer in [-2^63, 2^63) (the round trip through int64 differs, or
    |  // NaN), or a result with more than 53 significant bits (the round
    |  // trip back differs), goes to lj_meta_bitop, which raises the error.
    |  checknumtp [BASE+RD*8], ->vmeta_bnot
    |  movsd xmm0, qword [BASE+RD*8]
    |  cvttsd2si RB, xmm0
    |  cvtsi2sd xmm1, RB
    |  ucomisd xmm0, xmm1
    |  jne ->vmeta_bnot
    |  jp ->vmeta_bnot
    |  not RB
    |  cvtsi2sd xmm0, RB
    |  cvttsd2si TMPR, xmm0@T@@T@// Exact, or the error in C.
    |  cmp TMPR, RB
    |  jne ->vmeta_bnot
    |  movsd qword [BASE+RA*8], xmm0
    |  ins_next
    |.endif
EOF
# 3. The ins_bitop macro, the non-DUALNUM half.
cat > "$D/o3" <<'EOF'
    |.else
    |  checknumtp [BASE+RA*8], ->vmeta_bitop
    |  checknumtp [BASE+RC*8], ->vmeta_bitop
    |  movsd xmm0, qword [BASE+RA*8]
    |  movsd xmm1, qword [BASE+RC*8]
    |  sseconst_tobit xmm2, RC
    |  addsd xmm0, xmm2
    |  addsd xmm1, xmm2
    |  movd RAd, xmm0
    |  movd RCd, xmm1
    |.if shift == 1
    |  ins RCd, cl@T@@T@// Assumes RA is ecx.
    |.else
    |  ins RCd, RAd
    |.endif
    |  cvtsi2sd xmm0, RCd
    |  movsd qword [BASE+RB*8], xmm0
    |.endif
EOF
cat > "$D/n3" <<'EOF'
    |.else
    |  // OC-LuaJIT: Lua 5.3's operators on int64 (see BC_BNOT).
    |  checknumtp [BASE+RA*8], ->vmeta_bitop
    |  checknumtp [BASE+RC*8], ->vmeta_bitop
    |  movsd xmm0, qword [BASE+RA*8]@T@// src2
    |  movsd xmm1, qword [BASE+RC*8]@T@// src1
    |  cvttsd2si RA, xmm0
    |  cvttsd2si RC, xmm1
    |  cvtsi2sd xmm2, RA
    |  ucomisd xmm0, xmm2
    |  jne ->vmeta_bitop_pc
    |  jp ->vmeta_bitop_pc
    |  cvtsi2sd xmm2, RC
    |  ucomisd xmm1, xmm2
    |  jne ->vmeta_bitop_pc
    |  jp ->vmeta_bitop_pc
    |.if shift == 1
    |  cmp RA, 63
    |  ja ->vmeta_bitop_pc@T@@T@// Count < 0 or > 63: 5.3's rules, in C.
    |  ins RC, cl@T@@T@@T@// Assumes RA is ecx.
    |.else
    |  ins RC, RA
    |.endif
    |  cvtsi2sd xmm0, RC
    |  cvttsd2si RA, xmm0@T@@T@// Exact, or the error in C.
    |  cmp RA, RC
    |  jne ->vmeta_bitop_pc
    |  movsd qword [BASE+RB*8], xmm0
    |.endif
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

# What the hunks cannot say on their own: the new label is defined once and
# reached only from ins_bitop's six exits; three OC-LuaJIT comment lines,
# the ones build-native.sh finds echoed in host/buildvm_arch.h.
verify_content() {
  [ "$(grep -c -F -x '  |->vmeta_bitop_pc:' "$1")" = 1 ] || fail "$1: the ->vmeta_bitop_pc label occurs $(grep -c -F -x '  |->vmeta_bitop_pc:' "$1") times, expected 1"
  [ "$(countsub '->vmeta_bitop_pc' "$1")" = 7 ] || fail "$1: ->vmeta_bitop_pc is named on $(countsub '->vmeta_bitop_pc' "$1") lines, expected 7 (the label and ins_bitop's six exits)"
  [ "$(countsub 'OC-LuaJIT' "$1")" = 3 ] || fail "$1: $(countsub 'OC-LuaJIT' "$1") lines carry OC-LuaJIT, expected 3 (one per hunk)"
}

# --- already patched?  verify, copy if asked, and say so ------------------
if grep -q -F -- "$MARK" "$IN"; then
  verify_patched "$IN"
  if [ "$IN" != "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")" || exit 1
    cp "$IN" "$OUT" || fail "cannot copy $IN to $OUT"
  fi
  echo "$ME: $(basename "$OUT")  already carries the 64-bit fast path (verified) -- unchanged"
  exit 0
fi

# --- patch ------------------------------------------------------------------
hunks "$IN" count > "$D/counts0" || fail "the hunk engine could not count $IN"
h=0
while read -r o n s; do
  h=$((h + 1))
  [ "$o" = 1 ] || fail "refusing -- hunk $h's upstream text occurs $o times in $IN, expected exactly 1 (has vm_x64.dasc changed shape?)"
  [ "$n" = 0 ] || fail "refusing -- hunk $h's patched text already occurs in $IN"
done < "$D/counts0"
[ "$h" = "$NH" ] || fail "counted $h hunks, expected $NH"
[ "$(countsub 'OC-LuaJIT' "$IN")" = 0 ] || fail "refusing -- $IN already carries OC-LuaJIT lines: not a pristine vm_x64.dasc"

mkdir -p "$(dirname "$OUT")" || exit 1
TMP=$OUT.tmp.$$
trap 'rm -rf "$D"; rm -f "$TMP"' EXIT
hunks "$IN" apply > "$TMP" || fail "the hunk engine refused $IN (above)"

# VERIFY, RATHER THAN TRUST THE AWK.
verify_patched "$TMP"
[ "$(ncr "$TMP")" = 0 ] || fail "the output carries CR characters"
# The two 32-bit conversions are gone, and only they; five conversions back
# to int64 are new (two in BC_BNOT, three in ins_bitop).
[ "$(countsub 'sseconst_tobit' "$TMP")" = "$(( $(countsub 'sseconst_tobit' "$IN") - 2 ))" ] || fail "sseconst_tobit: $(countsub 'sseconst_tobit' "$IN") lines in, $(countsub 'sseconst_tobit' "$TMP") out, expected 2 fewer"
[ "$(countsub 'cvttsd2si' "$TMP")" = "$(( $(countsub 'cvttsd2si' "$IN") + 5 ))" ] || fail "cvttsd2si: $(countsub 'cvttsd2si' "$IN") lines in, $(countsub 'cvttsd2si' "$TMP") out, expected 5 more"
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
echo "$ME: $(basename "$OUT")  BC_BNOT and ins_bitop compute on int64, exact results only ($NADD lines added, $NDEL removed, of $NL_OUT); verified by content, diff and reversal"
