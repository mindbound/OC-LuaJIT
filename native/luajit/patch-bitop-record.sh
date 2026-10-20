#!/bin/sh
# native/luajit/patch-bitop-record.sh -- the fourth of round 3's seven changes
# to LuaJIT (Lua 5.3.6's 64-bit bitwise operators): the trace recorder
# records BC_BNOT..BC_BSAR as int64 IR with exactness guards, through
# native/luajit/oclj_bitop_rec.c.  (Round 3's others: patch-bitop-parse.sh,
# patch-bitop-vm.sh, patch-bitop-meta.sh, patch-bitop-fold.sh,
# patch-bitop-bcdump.sh, patch-bitop-jitlib.sh.)  Since 2026-10-20 it also
# bounds select's index in rec_varg (THE SELECT FIX, below).
#
#     sh native/luajit/patch-bitop-record.sh <in lj_record.c> <out lj_record.c>
#
# <in> and <out> may name the SAME file.  build-native.sh re-copies the
# PRISTINE lj_record.c over the build copy before every run, for the reason
# patch-penalty-scrub.sh's header gives, and copies oclj_bitop_rec.c,
# oclj_bitop.h and oclj_num53.h next to it; the build always takes the patch
# path below, and the "already patched" path is for hand use.
#
# WHAT IS WRONG.  lj_record_ins records the seven bit operators
# (lj_record.c:2511-2546) as int32 IR on lj_opt_narrow_tobit's 32-bit
# reading of each operand: BitOp's semantics, which round 3 replaces.  And
# BitOp leaves operands beyond +-2^51 unspecified, which LuaJIT's narrowing
# exploits, so before round 3 compiled and interpreted code disagreed there:
# `(i * 2^45 - i) | 0` in a loop gave -66 compiled and -33 interpreted at
# i = 66 (measured 2026-10-17, on the round-2 build).
#
# THE CHANGE, three hunks.  lj_record.c includes oclj_bitop.h after its
# other headers; it includes oclj_bitop_rec.c right after its emitir macros
# (lj_record.c:43-46), which that file's code uses; and the seven cases
# become one call, rc = oclj_rec_bitop(J, op, rb, rc, rbv, rcv).  The FFI
# branches of the old cases (recff_bit64_bitop, recff_bit64_shift) go with
# them: they are compiled out of this build, and oclj_bitop_rec.c refuses to
# compile with FFI.  oclj_bitop_rec.c's header describes the IR.
#
# THE SELECT FIX, hunks 4 and 5 (roadmap row 213, 2026-10-20; JIT guide
# P54).  Not a bit operator; it is here because this is the script that
# patches lj_record.c, and build-native.sh and negctl-bitop.sh patch each
# file with one script (JIT guide 8.2).  rec_varg records y = select(k, ...)
# in a vararg function on one of three paths, chosen by the k it records: a
# constant k; a k within the varargs (their count from the frame's size
# word fr, an unsigned ABC on k-1, then the load); and a k beyond them,
# which loads nothing, guards fr < 8*k+frofs (frofs: fr with no varargs)
# and gives nil.  That guard computes 8*k+frofs in 32 bits.  So a k <= 0
# whose 8*k wraps past the frame passed it (select(-2147483628, ...) with 7
# varargs, verify-folda's probes/selbug.lua, 2026-10-20, on the shipped
# build and the 2026-09-01 upstream binary alike), and so did a k from m+1
# to 0 in a call that passed m < 0 varargs, fewer arguments than the
# function's fixed parameters (fr is then below frofs): select gave nil
# where the interpreter raises "index out of range".  And so did a k that
# narrowing wrapped: for select(x + c, ...), x a double and c an int16
# constant, the outermost ADD or SUB is left unchecked (lj_opt_narrow.c
# narrow_conv_backprop, narrow_conv_emit), so an x + c out of int32, which
# the interpreter's lj_num2int reads as -2^31 and raises on, wraps to
# within 2^15 of -2^31 (it passed when 8*k wrapped past the frame) or of
# 2^31 (it passed in such a short call).  Each was measured with
# test/native/bitop/t_select.lua on the shipped build.  Hunk 4 defines
# OCLJ_SELECT_KMAX, 2^27, above rec_varg.  Hunk 5 makes the recorder abort
# when the k it records is above it, as it already does for k < 0, which
# also keeps the constant path's frofs+8*(int32_t)k below 2^31 (as int
# arithmetic it overflows in C, undefined, for k > (2^31-1-frofs)/8, near
# 2^28; the shipped build wraps it, and t_select's constant loops still
# gave the interpreter's values); and on the path beyond the varargs it
# guards k-1 < 2^27, unsigned, before the shift: 1 <= k <= 2^27, or the
# trace exits and the interpreter computes select, raising or returning.
# After that guard 8*k+frofs <= 2^30 + 8*(2+LJ_MAX_SLOTS)+3 cannot wrap.
# A guard k >= 1 alone would not do: t_select's am source, a k wrapped to
# 2^31 - 1 in a call with 2 fewer arguments than parameters, still gave
# nil (2026-10-20).  The guard exits through the snapshot the path's own
# guards use.  No k within the varargs is refused: their count is at most
# LUAI_MAXSTACK, 65500.
#
# Anchored, refusing otherwise, on the line `#include "lj_prng.h"`
# (lj_record.c:37 at 1ee778a4), on the emitir_raw macro's line (:46), on
# the seven cases' 36 lines, from `case BC_BNOT:` to `goto recbit;`
# (:2511-2546), on the comment and signature that begin rec_varg
# (:1988-1989), and on rec_varg's select path from `ptrdiff_t idx =
# lj_ffrecord_select_mode(` to the shift beyond the varargs (:2041-2065),
# each exactly once.  Verified by content, by diff, and by
# putting upstream's text back and comparing with the input.  CRLF is
# stripped (the pinned tree checks out CRLF on Windows); the output is LF.
# This script contains no backslashes and no tabs: in the hunk texts below,
# @T@ stands for a tab.
set -u

[ $# -eq 2 ] || { echo "usage: patch-bitop-record.sh <in lj_record.c> <out lj_record.c>" >&2; exit 2; }
IN=$1
OUT=$2
[ -f "$IN" ] || { echo "patch-bitop-record.sh: no $IN" >&2; exit 2; }

ME=patch-bitop-record.sh
MARK='OC-LuaJIT (native/luajit/patch-bitop-record.sh)'
NMARK=1     # the marker occurs once in a patched file
NH=5        # hunks
NADD=22     # lines diff -d reports added on the pristine file (7 the
            # operators', 15 the select fix's: 11 in hunk 4, 4 in hunk 5) ...
NDEL=36     # ... and removed (35 the operators', 1 the select fix's)

fail() { echo "$ME: $*" >&2; exit 1; }
countsub() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }

D=${TMPDIR:-/tmp}/$ME.$$
rm -rf "$D"
mkdir -p "$D" || fail "cannot create $D"
trap 'rm -rf "$D"' EXIT

# --- the hunks: o<h> is upstream's text, n<h> ours --------------------------
# 1. The rules.
cat > "$D/o1" <<'EOF'
#include "lj_prng.h"
EOF
cat > "$D/n1" <<'EOF'
#include "lj_prng.h"
#include "oclj_bitop.h"  /* OC-LuaJIT (native/luajit/patch-bitop-record.sh) */
EOF
# 2. The recorder's code, after the emitir macros it uses.
cat > "$D/o2" <<'EOF'
#define emitir_raw(ot, a, b)@T@(lj_ir_set(J, (ot), (a), (b)), lj_ir_emit(J))
EOF
cat > "$D/n2" <<'EOF'
#define emitir_raw(ot, a, b)@T@(lj_ir_set(J, (ot), (a), (b)), lj_ir_emit(J))

#include "oclj_bitop_rec.c"  /* OC-LuaJIT: Lua 5.3.6's bit operators. */
EOF
# 3. The seven cases of lj_record_ins.
cat > "$D/o3" <<'EOF'
  case BC_BNOT:
#if LJ_HASFFI
    if (tref_iscdata(rc)) {
      rc = recff_bit64_bitop(J, rc, 0, rcv, NULL, IR_BNOT);
      break;
    }
#endif
    rc = lj_opt_narrow_tobit(J, rc);
    rc = emitir(IRTI(IR_BNOT), rc, 0);
    break;

  case BC_BAND: case BC_BOR: case BC_BXOR:
#if LJ_HASFFI
    if (tref_iscdata(rb) || tref_iscdata(rc)) {
      rc = recff_bit64_bitop(J, rb, rc, rbv, rcv, (int)op - (int)BC_BAND + (int)IR_BAND);
      break;
    }
#endif
  recbit:
    rb = lj_opt_narrow_tobit(J, rb);
    rc = lj_opt_narrow_tobit(J, rc);
    rc = emitir(IRTI((int)op - (int)BC_BAND + (int)IR_BAND), rb, rc);
    break;

  case BC_BSHL: case BC_BSHR: case BC_BSAR:
#if LJ_HASFFI
    {
      TRef xrb = rb, xrc = rc;
      if (recff_bit64_shift(J, &xrb, &xrc, rbv, rcv, (int)op - (int)BC_BSHL + (int)IR_BSHL)) {
@T@rc = xrb;
@T@break;
      }
      rc = xrc;  /* Shift amount may have been converted. */
    }
#endif
    goto recbit;
EOF
cat > "$D/n3" <<'EOF'
  case BC_BNOT: case BC_BAND: case BC_BOR: case BC_BXOR:
  case BC_BSHL: case BC_BSHR: case BC_BSAR:
    /* OC-LuaJIT: Lua 5.3.6's operators as int64 IR (oclj_bitop_rec.c). */
    rc = oclj_rec_bitop(J, op, rb, rc, rbv, rcv);
    break;
EOF
# 4. The bound on select's index, above rec_varg.
cat > "$D/o4" <<'EOF'
/* Record vararg instruction. */
static void rec_varg(jit_State *J, BCReg dst, ptrdiff_t nresults)
EOF
cat > "$D/n4" <<'EOF'
/* OC-LuaJIT: the largest index k that rec_varg compiles select(k, ...)
** with (roadmap row 213, JIT guide P54).  The recorder aborts above it, as
** for k < 0; where k is beyond the varargs, a guard exits unless k is
** from 1 to this bound before 8*k+frofs is computed in 32 bits, which
** then cannot wrap (frofs <= 8*(2+LJ_MAX_SLOTS)+3).  Upstream's
** wrapped: a k <= 0 could pass, and select gave nil where the interpreter
** raises "index out of range".  A k that narrowing's unchecked ADD or SUB
** wrapped (lj_opt_narrow.c narrow_conv_emit) is 2^30 or more in magnitude,
** so it exits too.  The varargs number at most LUAI_MAXSTACK, below it. */
#define OCLJ_SELECT_KMAX@T@0x08000000@T@/* 2^27 */

/* Record vararg instruction. */
static void rec_varg(jit_State *J, BCReg dst, ptrdiff_t nresults)
EOF
# 5. select's index: the record-time bound, and the guard before the shift.
cat > "$D/o5" <<'EOF'
      ptrdiff_t idx = lj_ffrecord_select_mode(J, tridx, &J->L->base[dst-1]);
      if (idx < 0) goto nyivarg;
      if (idx != 0 && !tref_isinteger(tridx)) {
@T@if (tref_isstr(tridx))
@T@  tridx = emitir(IRTG(IR_STRTO, IRT_NUM), tridx, 0);
@T@tridx = emitir(IRTGI(IR_CONV), tridx, IRCONV_INT_NUM|IRCONV_INDEX);
      }
      if (idx != 0 && tref_isk(tridx)) {
@T@emitir(IRTGI(idx <= nvararg ? IR_GE : IR_LT),
@T@       fr, lj_ir_kint(J, frofs+8*(int32_t)idx));
@T@frofs -= 8;  /* Bias for 1-based index. */
      } else if (idx <= nvararg) {  /* Compute size. */
@T@TRef tmp = emitir(IRTI(IR_ADD), fr, lj_ir_kint(J, -frofs));
@T@if (numparams)
@T@  emitir(IRTGI(IR_GE), tmp, lj_ir_kint(J, 0));
@T@tr = emitir(IRTI(IR_BSHR), tmp, lj_ir_kint(J, 3));
@T@if (idx != 0) {
@T@  tridx = emitir(IRTI(IR_ADD), tridx, lj_ir_kint(J, -1));
@T@  rec_idx_abc(J, tr, tridx, (uint32_t)nvararg);
@T@}
      } else {
@T@TRef tmp = lj_ir_kint(J, frofs);
@T@if (idx != 0) {
@T@  TRef tmp2 = emitir(IRTI(IR_BSHL), tridx, lj_ir_kint(J, 3));
@T@  tmp = emitir(IRTI(IR_ADD), tmp2, tmp);
EOF
cat > "$D/n5" <<'EOF'
      ptrdiff_t idx = lj_ffrecord_select_mode(J, tridx, &J->L->base[dst-1]);
      if (idx < 0) goto nyivarg;
      if (idx > OCLJ_SELECT_KMAX) goto nyivarg;  /* OC-LuaJIT: as for k < 0. */
      if (idx != 0 && !tref_isinteger(tridx)) {
@T@if (tref_isstr(tridx))
@T@  tridx = emitir(IRTG(IR_STRTO, IRT_NUM), tridx, 0);
@T@tridx = emitir(IRTGI(IR_CONV), tridx, IRCONV_INT_NUM|IRCONV_INDEX);
      }
      if (idx != 0 && tref_isk(tridx)) {
@T@emitir(IRTGI(idx <= nvararg ? IR_GE : IR_LT),
@T@       fr, lj_ir_kint(J, frofs+8*(int32_t)idx));
@T@frofs -= 8;  /* Bias for 1-based index. */
      } else if (idx <= nvararg) {  /* Compute size. */
@T@TRef tmp = emitir(IRTI(IR_ADD), fr, lj_ir_kint(J, -frofs));
@T@if (numparams)
@T@  emitir(IRTGI(IR_GE), tmp, lj_ir_kint(J, 0));
@T@tr = emitir(IRTI(IR_BSHR), tmp, lj_ir_kint(J, 3));
@T@if (idx != 0) {
@T@  tridx = emitir(IRTI(IR_ADD), tridx, lj_ir_kint(J, -1));
@T@  rec_idx_abc(J, tr, tridx, (uint32_t)nvararg);
@T@}
      } else {
@T@TRef tmp = lj_ir_kint(J, frofs);
@T@if (idx != 0) {
@T@  TRef tmp2 = emitir(IRTI(IR_ADD), tridx, lj_ir_kint(J, -1));
@T@  emitir(IRTGI(IR_ULT), tmp2, lj_ir_kint(J, OCLJ_SELECT_KMAX));  /* OC-LuaJIT: 1 <= k <= 2^27, or exit. */
@T@  tmp2 = emitir(IRTI(IR_BSHL), tridx, lj_ir_kint(J, 3));
@T@  tmp = emitir(IRTI(IR_ADD), tmp2, tmp);
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

# What the hunks cannot say on their own: the recorder's code is included
# after all three emitir macros it uses and before lj_record_ins, whose one
# call is the only one; no case label of a bit opcode is left elsewhere.
verify_content() {
  LE=$(grep -n '^#define emitir_raw(' "$1" | head -1 | cut -d: -f1)
  LI=$(grep -n -F '#include "oclj_bitop_rec.c"' "$1" | head -1 | cut -d: -f1)
  LR=$(grep -n '^void lj_record_ins(' "$1" | head -1 | cut -d: -f1)
  LC=$(grep -n -F 'rc = oclj_rec_bitop(J, op, rb, rc, rbv, rcv);' "$1" | head -1 | cut -d: -f1)
  [ -n "$LE" ] && [ -n "$LI" ] && [ -n "$LR" ] && [ -n "$LC" ] || fail "$1: missing the emitir_raw macro, the include, lj_record_ins or the call"
  if [ "$LE" -lt "$LI" ] && [ "$LI" -lt "$LR" ] && [ "$LR" -lt "$LC" ]; then :; else
    fail "$1: out of order (emitir_raw $LE, include $LI, lj_record_ins $LR, the call $LC)"
  fi
  [ "$(countsub 'oclj_rec_bitop(J, op' "$1")" = 1 ] || fail "$1: oclj_rec_bitop is called $(countsub 'oclj_rec_bitop(J, op' "$1") times, expected 1"
  for b in BNOT BAND BOR BXOR BSHL BSHR BSAR; do
    [ "$(countsub "case BC_$b:" "$1")" = 1 ] || fail "$1: 'case BC_$b:' occurs $(countsub "case BC_$b:" "$1") times, expected 1"
  done
  [ "$(countsub 'recbit' "$1")" = 0 ] || fail "$1: the old cases' recbit label or goto is still there"
  # The select fix (hunks 4 and 5).  OCLJ_SELECT_KMAX on exactly three
  # lines, its definition, the record-time bound and the guard: one more,
  # anywhere, could redefine or misuse the bound.  Then, in this order: the
  # definition, rec_varg's signature, the bound, the guard, and the next
  # function, rec_tnew, so both checks sit inside rec_varg.  With every
  # hunk's text matched, the count fails alone (a stray line naming the
  # macro), and so do two links of the order, rec_varg's signature before
  # the bound (hunk 4 before hunk 5) and the guard before rec_tnew (a line
  # no hunk holds); the definition before the signature and the bound
  # before the guard lie inside one hunk each, and are implied.
  [ "$(countsub 'OCLJ_SELECT_KMAX' "$1")" = 3 ] || fail "$1: OCLJ_SELECT_KMAX is named on $(countsub 'OCLJ_SELECT_KMAX' "$1") lines, expected 3"
  LD=$(grep -n '^#define OCLJ_SELECT_KMAX' "$1" | head -1 | cut -d: -f1)
  LV=$(grep -n '^static void rec_varg(' "$1" | head -1 | cut -d: -f1)
  LB=$(grep -n -F 'if (idx > OCLJ_SELECT_KMAX) goto nyivarg;' "$1" | head -1 | cut -d: -f1)
  LG=$(grep -n -F 'emitir(IRTGI(IR_ULT), tmp2, lj_ir_kint(J, OCLJ_SELECT_KMAX));' "$1" | head -1 | cut -d: -f1)
  LT=$(grep -n '^static TRef rec_tnew(' "$1" | head -1 | cut -d: -f1)
  [ -n "$LD" ] && [ -n "$LV" ] && [ -n "$LB" ] && [ -n "$LG" ] && [ -n "$LT" ] || fail "$1: missing OCLJ_SELECT_KMAX's definition, rec_varg, the record-time bound, the guard or rec_tnew"
  if [ "$LD" -lt "$LV" ] && [ "$LV" -lt "$LB" ] && [ "$LB" -lt "$LG" ] && [ "$LG" -lt "$LT" ]; then :; else
    fail "$1: out of order (OCLJ_SELECT_KMAX $LD, rec_varg $LV, the bound $LB, the guard $LG, rec_tnew $LT)"
  fi
}

# --- already patched?  verify, copy if asked, and say so ------------------
if grep -q -F -- "$MARK" "$IN"; then
  verify_patched "$IN"
  if [ "$IN" != "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")" || exit 1
    cp "$IN" "$OUT" || fail "cannot copy $IN to $OUT"
  fi
  echo "$ME: $(basename "$OUT")  already records the operators through oclj_rec_bitop and bounds select's index (verified) -- unchanged"
  exit 0
fi

# --- patch ------------------------------------------------------------------
hunks "$IN" count > "$D/counts0" || fail "the hunk engine could not count $IN"
h=0
while read -r o n s; do
  h=$((h + 1))
  [ "$o" = 1 ] || fail "refusing -- hunk $h's upstream text occurs $o times in $IN, expected exactly 1 (has lj_record.c changed shape?)"
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
echo "$ME: $(basename "$OUT")  the seven bit-operator cases call oclj_rec_bitop, and select's index is bounded in rec_varg ($NADD lines added, $NDEL removed, of $NL_OUT); verified by content, diff and reversal"
