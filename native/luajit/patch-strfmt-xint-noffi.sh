#!/bin/sh
# native/luajit/patch-strfmt-xint-noffi.sh -- the third place in LuaJIT we
# change (after patch-penalty-scrub.sh and patch-fastfunc-errmem-top.sh): one
# NYI in the trace recorder's string.format, recff_format in lj_ffrecord.c.
#
#     sh native/luajit/patch-strfmt-xint-noffi.sh <in lj_ffrecord.c> <out lj_ffrecord.c>
#
# <in> and <out> may name the SAME file: build-native.sh patches the build
# copy in place, after re-copying the PRISTINE lj_ffrecord.c over it, exactly
# as it does for native/luajit/patch-penalty-scrub.sh (whose header explains
# why the build never relies on the "already patched" path below).
#
# WHAT IS WRONG.  The native is built with LUAJIT_DISABLE_FFI.  recff_format
# (lj_ffrecord.c:1067) records an integer conversion -- %d %i %u %x %X %o
# with any flag, width or precision -- whose operand the recorder has
# narrowed to an int (a numeric for-loop index, a bit.* result, string.byte,
# #s, a small constant) through 64-bit FFI IR: a CONV to U64 and a call of
# lj_strfmt_putfxint (:1104-1108).  Without FFI that branch is
# "recff_nyiu(J, rd); return;" (:1109-1111) for every such conversion except
# plain %d and %i, which have their own shortcut (:1100-1102).  recff_nyi
# (:162-189) then stitches the trace around the call, or stops it, and the
# call runs in the interpreter: a hot loop formatting "%02x" of an int runs
# 1.6-2.1x slower than with this patch when the strings repeat, 1.2x when
# every result is a new string (measured 2026-10-16, unpinned; the patched
# loop is within 2-12% of the same loop with FFI compiled in).
#
# THE FIX.  "goto handle_num;" -- the path the same switch already takes for
# an operand that is not an integer (:1098).  lj_ir_tonum turns the int into
# a double, which is exact for every int32, and the trace calls the function
# id names: lj_strfmt_putfnum_int for %d %i (set at :1088) or
# lj_strfmt_putfnum_uint for %u %x %X %o (set at :1116).  Those are the very
# functions the interpreter calls for EVERY number on a build without
# DUALNUM (lj_strfmt_putarg, lj_strfmt.c:404 and :420; tvisint is constant
# false there, lj_obj.h:806), with the same double, so the compiled result is
# the interpreter's by construction.  A constant operand is folded at compile
# time by bufput_kfold_fmt (lj_opt_fold.c:722-762), which calls the same
# function.  In a build WITH FFI the patched line is inside the #else and
# changes nothing.
#
# Anchored, refusing otherwise, on the nine lines from "#if LJ_HASFFI" to
# "#endif" (:1104-1112) -- consecutive, exactly once, compared with leading
# blanks removed because the file indents with tabs and this script contains
# none.  The two lines between "#else" and "#endif" are replaced by the
# block; the result is verified by content and by diff rather than trusted.
# The other "Don't bother working around this NYI" line (bit.tohex, :830) is
# preceded by different lines and is left alone.  The block contains NO
# backslashes and NO tabs on purpose, and neither does this script.
set -u

[ $# -eq 2 ] || { echo "usage: patch-strfmt-xint-noffi.sh <in lj_ffrecord.c> <out lj_ffrecord.c>" >&2; exit 2; }
IN=$1
OUT=$2
[ -f "$IN" ] || { echo "patch-strfmt-xint-noffi.sh: no $IN" >&2; exit 2; }

MARK='OC-LuaJIT (native/luajit/patch-strfmt-xint-noffi.sh)'
GOTO='goto handle_num;'
# The anchor, leading blanks removed.  A7 and A8 are the two replaced lines.
A1='#if LJ_HASFFI'
A2='tra = emitir(IRT(IR_CONV, IRT_U64), tra,'
A3='(IRT_INT|(IRT_U64<<5)|IRCONV_SEXT));'
A4='tr = lj_ir_call(J, IRCALL_lj_strfmt_putfxint, tr, trsf, tra);'
A5='lj_needsplit(J);'
A6='#else'
A7="recff_nyiu(J, rd);  /* Don't bother working around this NYI. */"
A8='return;'
A9='#endif'

fail() { echo "patch-strfmt-xint-noffi.sh: $*" >&2; exit 1; }
count() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }

BLOCK=${TMPDIR:-/tmp}/strfmt-xint-noffi-block.$$
trap 'rm -f "$BLOCK"' EXIT
cat > "$BLOCK" <<'EOF'
        /* OC-LuaJIT (native/luajit/patch-strfmt-xint-noffi.sh): without FFI,
        ** format an int-typed operand the way the interpreter formats every
        ** number on a non-DUALNUM build: as a double, through
        ** lj_strfmt_putfnum_int or lj_strfmt_putfnum_uint (id, set above).
        ** Upstream stitches or stops the trace here instead.
        */
        goto handle_num;
EOF
NBLOCK=$(wc -l < "$BLOCK" | tr -d ' ')
[ "$(count "$MARK" "$BLOCK")" = 1 ] && [ "$(count "$GOTO" "$BLOCK")" = 1 ] ||
  fail "internal: the block does not carry its own markers exactly once"

# Find a window of consecutive lines (leading blanks and a trailing CR
# removed) in a file.  Pattern lines come from the -v anchors; when blockf is
# set, the block's lines stand in for A7 and A8.  Prints "<hits> <first line>".
window() {
  awk -v a1="$A1" -v a2="$A2" -v a3="$A3" -v a4="$A4" -v a5="$A5" -v a6="$A6" -v a7="$A7" -v a8="$A8" -v a9="$A9" -v blockf="$2" '
    function strip(s) { sub(/^[[:blank:]]+/, "", s); return s }
    BEGIN {
      CR = sprintf("%c", 13)
      p[1] = a1; p[2] = a2; p[3] = a3; p[4] = a4; p[5] = a5; p[6] = a6; np = 6
      if (blockf != "") {
        while ((getline l < blockf) > 0) p[++np] = strip(l)
        close(blockf)
      } else {
        p[++np] = a7; p[++np] = a8
      }
      p[++np] = a9
    }
    {
      if (substr($0, length($0)) == CR) $0 = substr($0, 1, length($0) - 1)
      L[NR] = strip($0)
    }
    END {
      for (i = 1; i + np - 1 <= NR; i++) {
        ok = 1
        for (j = 1; j <= np; j++) if (L[i + j - 1] != p[j]) { ok = 0; break }
        if (ok) { hits++; at = i }
      }
      print (hits + 0) " " (at + 0)
    }' "$1"
}

# A patched file: marker once, the patched window once, the unpatched window
# never.  Used for the idempotent path and for the output.
verify_patched() {
  f=$1
  [ "$(count "$MARK" "$f")" = 1 ] || fail "$f: marker present $(count "$MARK" "$f") times, expected 1"
  set -- $(window "$f" "$BLOCK")
  [ "$1" = 1 ] || fail "$f: the patched recff_format window occurs $1 times, expected 1"
  set -- $(window "$f" "")
  [ "$1" = 0 ] || fail "$f: the UNPATCHED recff_format window still occurs $1 times"
}

# --- already patched?  verify, copy if asked, and say so ------------------
if grep -q -F -- "$MARK" "$IN"; then
  verify_patched "$IN"
  if [ "$IN" != "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")" || exit 1
    cp "$IN" "$OUT" || fail "cannot copy $IN to $OUT"
  fi
  echo "patch-strfmt-xint-noffi.sh: $(basename "$OUT")  already carries the no-FFI integer-format fallback (verified: marker once, patched window once, unpatched window absent) -- unchanged"
  exit 0
fi

# --- patch ------------------------------------------------------------------
set -- $(window "$IN" "")
[ "$1" = 1 ] || fail "refusing -- expected the 9-line FFI/no-FFI integer-format branch of recff_format exactly once, matched $1 (has lj_ffrecord.c changed shape?)"
AT=$2
R1=$((AT + 6))
R2=$((AT + 7))

mkdir -p "$(dirname "$OUT")" || exit 1
TMP=$OUT.tmp.$$
trap 'rm -f "$BLOCK" "$TMP"' EXIT

# CRLF stripped (the pinned tree checks out CRLF on Windows); the output is
# LF.  Lines R1 and R2 are replaced by the block; every other line is copied.
awk -v r1="$R1" -v r2="$R2" -v blockf="$BLOCK" '
  BEGIN { CR = sprintf("%c", 13) }
  { if (substr($0, length($0)) == CR) $0 = substr($0, 1, length($0) - 1) }
  NR == r1 { while ((getline l < blockf) > 0) print l; close(blockf); next }
  NR == r2 { next }
  { print }
' "$IN" > "$TMP" || fail "awk failed writing $TMP"

# VERIFY, RATHER THAN TRUST THE AWK.
verify_patched "$TMP"
NL_IN=$(wc -l < "$IN" | tr -d ' ')
NL_OUT=$(wc -l < "$TMP" | tr -d ' ')
[ "$NL_OUT" = "$((NL_IN - 2 + NBLOCK))" ] || fail "line count: $NL_IN in - 2 + $NBLOCK block != $NL_OUT out"
DIFFF=$OUT.diff.$$
trap 'rm -f "$BLOCK" "$TMP" "$DIFFF"' EXIT
diff --strip-trailing-cr "$IN" "$TMP" > "$DIFFF"
HUNKS=$(grep -c '^[0-9]' "$DIFFF" || true)
ADDED=$(grep -c '^>' "$DIFFF" || true)
REMOVED=$(grep -c '^<' "$DIFFF" || true)
if [ "$HUNKS" != 1 ] || [ "$ADDED" != "$NBLOCK" ] || [ "$REMOVED" != 2 ]; then
  head -40 "$DIFFF" >&2
  fail "expected one hunk, $NBLOCK added and 2 removed lines, got $HUNKS hunks, $ADDED added / $REMOVED removed"
fi
# The two removed lines must be exactly the NYI call and its return.
GONE=$(awk -v a7="$A7" -v a8="$A8" '
  /^< / { s = substr($0, 3); sub(/^[[:blank:]]+/, "", s); o = o ((s == a7) ? "N" : (s == a8) ? "R" : "?") }
  END { print o }' "$DIFFF")
[ "$GONE" = "NR" ] || fail "the removed lines are not the NYI call and its return (saw $GONE, want NR)"

mv -f "$TMP" "$OUT" || fail "cannot write $OUT"
rm -f "$DIFFF"
trap 'rm -f "$BLOCK"' EXIT
echo "patch-strfmt-xint-noffi.sh: $(basename "$OUT")  2 lines (recff_nyiu + return, line $R1) replaced by $NBLOCK (of $NL_OUT); no-FFI integer-format fallback verified by content and diff"
