#!/bin/sh
# native/luajit/patch-bitop-jitlib.sh -- the seventh of round 3's seven
# changes to LuaJIT (Lua 5.3.6's 64-bit bitwise operators), and the only one
# that changes no operator: jit.util, the reflection library that LuaJIT's
# own jit/*.lua tools read, returns bytecode words and snapshot entries
# unsigned, so that those tools decode them exactly with the 64-bit
# operators.  (Round 3's others: patch-bitop-parse.sh, patch-bitop-vm.sh,
# patch-bitop-meta.sh, patch-bitop-record.sh, patch-bitop-fold.sh,
# patch-bitop-bcdump.sh.)
#
#     sh native/luajit/patch-bitop-jitlib.sh <in lib_jit.c> <out lib_jit.c>
#
# <in> and <out> may name the SAME file.  build-native.sh re-copies the
# PRISTINE lib_jit.c over the build copy before every run, for the reason
# patch-penalty-scrub.sh's header gives, so the build always takes the patch
# path below; the "already patched" path is for hand use.
#
# WHAT IS WRONG.  jit.util.funcbc returns the 32-bit bytecode word through
# setintV (lib_jit.c:220), that is as a signed int32, and jit.util.tracesnap
# returns each snapshot entry, and its SNAP(255, 0, 0) end marker, the same
# way (:359-360).  So a word whose B operand is 128 or more, or whose D
# operand is 0x8000 or more, arrives negative: every forward jump and every
# FORI (D is the offset plus BCBIAS_J, 0x8000, lj_bc.h:29), every negative
# KSHORT (D is a 16-bit two's complement).  So does the snapshot entry of a
# slot of 128 or more (the slot is the entry's top byte, SNAP, lj_jit.h:204).
# LuaJIT's jit/*.lua decode them with the native operators, assuming BitOp's
# 32 bits; under round 3's a negative int32 is a negative int64.  Every use
# of a value jit.util returns under an operator, audited at 1ee778a4:
#   - jit/bc.lua's bcline: (ins >> 8) & 0xff (:68) has 56 significant bits
#     and raises; ins >> 16 (:73) and ins >> 24 (:104) give 48- and 40-bit
#     values, wrong but exact; bctargets' ins >> 16 (:119) likewise.  So
#     `luajit -bl` stops at the first such word, and -jdump, whose default
#     modes include 'b' (jit/dump.lua:682), raises in its record handler,
#     which aborts the trace being recorded ("error thrown or hook called
#     during recording"): a bit-operator loop with a forward jump in it
#     never compiles under -jdump.  ins & 0xff (bc.lua:69), and dump.lua's
#     funcbc(func, pc) & 0xff (:618), are right either way.
#   - jit/dump.lua's printsnap: sn >> 24 == s (:368) is a 40-bit value for
#     a slot of 128 or more, so that slot prints as ----.  Its masks of sn,
#     and formatk's (:329-379), are right either way.  The end marker never
#     equals a slot number either way (LJ_MAX_JSLOTS is 250, lj_def.h:85);
#     unsigned, sn >> 24 reads it as 255, as upstream's 32-bit >> did.
#   - not changed, because no tool needs it: traceir's op1 and op2 are
#     signed on purpose (a constant's reference is negative); dump.lua only
#     compares them with 0 and hands them to tracek, and its one shift of
#     op2 (:522) is of a literal, 0..65535.  funcbc's mode, traceir's mode,
#     ot and prev, and every other number jit.util returns are small and
#     non-negative (tracek's constants are values, not bit fields).
#     jit/dis_x86.lua shifts and masks bytes of the machine code, never a
#     jit.util value; v.lua, p.lua and zone.lua use no operator on one.
#     jit/bcsave.lua's f16 (bswap(x) >> 16, :254 and :386) would be wrong
#     for a negative bswap, but only bcsave_obj reaches it, and that needs
#     FFI first ("FFI library required to write this file type", :531),
#     which this build compiles out (native/luajit/oclj_features.h).
# Unsigned, every one of those shifts is exact and computes what upstream's
# 32-bit operators computed.  The repo's own readers of funcbc (ins % 256,
# bit.band(ins, 0xff)) get the same byte either way.  None of this is
# reachable from the sandbox, which has no jit.* modules.
#
# THE CHANGE, two hunks: funcbc's setintV(L->top, ins) becomes
# setnumV(L->top, (lua_Number)(uint32_t)ins), and tracesnap's setintV of
# (int32_t)map[n] and of (int32_t)SNAP(255, 0, 0) become setnumV of the
# unsigned value.  buildvm reads lib_jit.c for its LJLIB_ lines (lj_libdef.h,
# jit/vmdef.lua); none is touched, so only lib_jit.o changes.
#
# Anchored, refusing otherwise, on funcbc's `setintV(L->top, ins);`
# (lib_jit.c:220 at 1ee778a4) and on tracesnap's loop and end marker
# (:358-360), each exactly once.  Verified by content, by diff, and by
# putting upstream's text back and comparing with the input.  CRLF is
# stripped (the pinned tree checks out CRLF on Windows); the output is LF.
# This script contains no backslashes and no tabs: in the hunk texts below,
# @T@ would stand for a tab.
set -u

[ $# -eq 2 ] || { echo "usage: patch-bitop-jitlib.sh <in lib_jit.c> <out lib_jit.c>" >&2; exit 2; }
IN=$1
OUT=$2
[ -f "$IN" ] || { echo "patch-bitop-jitlib.sh: no $IN" >&2; exit 2; }

ME=patch-bitop-jitlib.sh
MARK='OC-LuaJIT (native/luajit/patch-bitop-jitlib.sh)'
NMARK=1     # the marker occurs once in a patched file
NH=2        # hunks
NADD=7      # lines diff -d reports added on the pristine file ...
NDEL=3      # ... and removed

fail() { echo "$ME: $*" >&2; exit 1; }
countsub() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }

D=${TMPDIR:-/tmp}/$ME.$$
rm -rf "$D"
mkdir -p "$D" || fail "cannot create $D"
trap 'rm -rf "$D"' EXIT

# --- the hunks: o<h> is upstream's text, n<h> ours --------------------------
# 1. jit.util.funcbc's word.
cat > "$D/o1" <<'EOF'
    setintV(L->top, ins);
EOF
cat > "$D/n1" <<'EOF'
    /* OC-LuaJIT (native/luajit/patch-bitop-jitlib.sh): the word unsigned, so
    ** that jit/bc.lua decodes it exactly with Lua 5.3.6's 64-bit operators. */
    setnumV(L->top, (lua_Number)(uint32_t)ins);
EOF
# 2. jit.util.tracesnap's entries and end marker.
cat > "$D/o2" <<'EOF'
    for (n = 0; n < nent; n++)
      setintV(lj_tab_setint(L, t, (int32_t)(n+2)), (int32_t)map[n]);
    setintV(lj_tab_setint(L, t, (int32_t)(nent+2)), (int32_t)SNAP(255, 0, 0));
EOF
cat > "$D/n2" <<'EOF'
    /* OC-LuaJIT: each entry and the end marker unsigned, like funcbc's word
    ** (jit/dump.lua reads an entry's slot as sn >> 24). */
    for (n = 0; n < nent; n++)
      setnumV(lj_tab_setint(L, t, (int32_t)(n+2)), (lua_Number)(uint32_t)map[n]);
    setnumV(lj_tab_setint(L, t, (int32_t)(nent+2)), (lua_Number)(uint32_t)SNAP(255, 0, 0));
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

# What the hunks cannot say on their own: each changed line sits in its own
# function (funcbc's between LJLIB_CF(jit_util_funcbc) and the next
# LJLIB_CF, tracesnap's two between LJLIB_CF(jit_util_tracesnap) and the
# next), each of those functions is defined once, and no signed snapshot
# entry is left.
verify_content() {
  for fn in jit_util_funcbc jit_util_tracesnap; do
    [ "$(grep -c "^LJLIB_CF($fn)" "$1")" = 1 ] || fail "$1: LJLIB_CF($fn) occurs $(grep -c "^LJLIB_CF($fn)" "$1") times, expected 1"
  done
  [ "$(countsub '(int32_t)map[n]' "$1")" = 0 ] || fail "$1: a snapshot entry is still returned as (int32_t)map[n]"
  W='setnumV(L->top, (lua_Number)(uint32_t)ins);'
  E='(lua_Number)(uint32_t)map[n]);'
  K='(lua_Number)(uint32_t)SNAP(255, 0, 0));'
  awk -v w="$W" -v e="$E" -v k="$K" '
    /^LJLIB_CF[(]/ { fn = $0 }
    index($0, w) { nw++; if (fn != "LJLIB_CF(jit_util_funcbc)") bad = bad " funcbc-word" }
    index($0, e) { ne++; if (fn != "LJLIB_CF(jit_util_tracesnap)") bad = bad " snap-entry" }
    index($0, k) { nk++; if (fn != "LJLIB_CF(jit_util_tracesnap)") bad = bad " snap-end" }
    END { print nw + 0, ne + 0, nk + 0, (bad == "" ? "-" : bad) }' "$1" > "$D/where"
  [ "$(cat "$D/where")" = "1 1 1 -" ] || fail "$1: the unsigned lines (counts, misplacements): $(cat "$D/where"), expected 1 1 1 -"
}

# --- already patched?  verify, copy if asked, and say so ------------------
if grep -q -F -- "$MARK" "$IN"; then
  verify_patched "$IN"
  if [ "$IN" != "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")" || exit 1
    cp "$IN" "$OUT" || fail "cannot copy $IN to $OUT"
  fi
  echo "$ME: $(basename "$OUT")  already returns jit.util's words unsigned (verified) -- unchanged"
  exit 0
fi

# --- patch ------------------------------------------------------------------
hunks "$IN" count > "$D/counts0" || fail "the hunk engine could not count $IN"
h=0
while read -r o n s; do
  h=$((h + 1))
  [ "$o" = 1 ] || fail "refusing -- hunk $h's upstream text occurs $o times in $IN, expected exactly 1 (has lib_jit.c changed shape?)"
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
# Three setintV became setnumV, and nothing else did.
[ "$(countsub 'setintV(' "$TMP")" = "$(( $(countsub 'setintV(' "$IN") - 3 ))" ] || fail "setintV: $(countsub 'setintV(' "$IN") lines in, $(countsub 'setintV(' "$TMP") out, expected three fewer"
[ "$(countsub 'setnumV(' "$TMP")" = "$(( $(countsub 'setnumV(' "$IN") + 3 ))" ] || fail "setnumV: $(countsub 'setnumV(' "$IN") lines in, $(countsub 'setnumV(' "$TMP") out, expected three more"
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
echo "$ME: $(basename "$OUT")  jit.util.funcbc's word and tracesnap's entries unsigned ($NADD lines added, $NDEL removed, of $NL_OUT); verified by content, diff and reversal"
