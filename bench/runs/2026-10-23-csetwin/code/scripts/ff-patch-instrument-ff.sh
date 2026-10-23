#!/bin/sh
# ff-patch.sh <fresh outdir> -- the CSE type twin round, impl-code: the
# fail-first of hunk 12 of the scratch repo's native/luajit/patch-bitop-fold.sh
# (round/repo), modelled on numconv/impl-code/scripts/ff-patch.sh.
# Part A: the script (S), mutated copies of it, and S0 = S with only hunk 12's
#   verify_content block removed (the script "before the check"), on the pin's
#   lj_opt_fold.c, on mutated inputs and on mutated patched files (the
#   already-patched path).  Each case must exit with the wanted rc and print
#   the wanted message.  Controls: HEAD's script (70/8), S (76/9),
#   idempotence, in == out, the tip a4c0645's lj_opt_fold.c, and S0 passing
#   every content mutation S refuses.
# Part B: every check of S's verify_content, evaluated on mutated PATCHED
#   files with a fail() that does not exit, so that which checks fail on each
#   mutation can be seen, against a stated expectation.
# Mutations: mut <in> <out> <old> <new>: <old> is a run of whole lines that
# must occur exactly once; @N@ separates lines; with TABS=1, @T@ is a tab
# (for C files; the script's own text holds a literal @T@).
# Written with a file tool; no backslashes in this file.
set -u
OUT=${1:?usage: ff-patch.sh <fresh outdir>}
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT/tmp" || exit 98
I=/c/Users/astro/claude-tmp/oclj/csetwin/round/impl-code
SRC=/c/Users/astro/claude-tmp/oclj/csetwin/round/repo/native/luajit/patch-bitop-fold.sh
HEADS=$I/head-patch-bitop-fold.sh
IN=$I/pristine/lj_opt_fold.c
TIP=$I/tip/lj_opt_fold.c
TMPDIR=$OUT/tmp
export TMPDIR
cp "$SRC" "$OUT/S.sh" || exit 98
S=$OUT/S.sh
md5sum "$SRC" "$S" "$HEADS" "$IN" "$TIP" > "$OUT/inputs.md5"
# S0: S without hunk 12's verify_content block (from its comment line to the
# function's closing brace, which stays).
awk '$0 == "  # Hunk 12, the CSE type test." { skip = 1 }
  skip && $0 == "}" { skip = 0 }
  !skip { print }' "$S" > "$OUT/S0.sh"
mut() {
  OLD=$3 NEW=$4 awk '
    BEGIN {
      T = sprintf("%c", 9); o = ENVIRON["OLD"]; n = ENVIRON["NEW"]
      if (ENVIRON["TABS"] == "1") { gsub(/@T@/, T, o); gsub(/@T@/, T, n) }
      no = split(o, O, "@N@"); nn = split(n, N, "@N@")
    }
    { L[++nl] = $0 }
    END {
      c = 0
      for (i = 1; i + no - 1 <= nl; i++) {
        for (j = 1; j <= no; j++) if (L[i + j - 1] != O[j]) break
        if (j > no) { c++; at = i }
      }
      if (no < 1 || c != 1) { print "mut: old text occurs " c " times" > "/dev/stderr"; exit 1 }
      for (i = 1; i < at; i++) print L[i]
      for (k = 1; k <= nn; k++) print N[k]
      for (i = at + no; i <= nl; i++) print L[i]
    }' "$1" > "$2"
}
mutt() { TABS=1 mut "$@"; }
PASS=0; FAIL=0
note() { echo "$*" >> "$OUT/results.txt"; }
# run <case> <script> <input> <want rc> <want message substring or ->
run() {
  sh "$2" "$3" "$OUT/$1.out.c" > "$OUT/$1.log" 2>&1
  rc=$?
  if [ "$rc" = "$4" ] && { [ "$5" = - ] || grep -q -F -- "$5" "$OUT/$1.log"; }; then
    v=ok; PASS=$((PASS + 1))
  else
    v=WRONG; FAIL=$((FAIL + 1))
  fi
  note "$v $1 rc=$rc (want $4) :: $(tr '|' '!' < "$OUT/$1.log" | awk '{ printf "%s ", $0 }' | cut -c1-300)"
}
check() {  # check <name> <command...>: a control that must hold
  n=$1; shift
  if "$@"; then note "ok $n"; PASS=$((PASS + 1)); else note "WRONG $n"; FAIL=$((FAIL + 1)); fi
}
mkcase() {  # mkcase <name> <old> <new> [<old2> <new2>]: S and S0 mutated alike
  mut "$S" "$OUT/$1.S.sh" "$2" "$3" || return 1
  mut "$OUT/S0.sh" "$OUT/$1.S0.sh" "$2" "$3" || return 1
  if [ $# -ge 5 ]; then
    mv "$OUT/$1.S.sh" "$OUT/$1.S.tmp" && mut "$OUT/$1.S.tmp" "$OUT/$1.S.sh" "$4" "$5" || return 1
    mv "$OUT/$1.S0.sh" "$OUT/$1.S0.tmp" && mut "$OUT/$1.S0.tmp" "$OUT/$1.S0.sh" "$4" "$5" || return 1
    rm -f "$OUT/$1.S.tmp" "$OUT/$1.S0.tmp"
  fi
}
IFL='      if (IR(ref)->op12 == op12)'
IFN='      if (IR(ref)->op12 == op12 &&'
PRL='@T@  irt_isi64(IR(ref)->t) == irt_isi64(fins->t))'
RET='@T@return TREF(ref, irt_t(IR(ref)->t));  /* Common subexpression found. */'
FWD='@T@  (irt_isi64(IR(ref)->t) == irt_isi64(fins->t) || irt_isi64(fins->t)))  /* SABOTAGE CSEFWD: an int64 instruction may common with a narrower one (the forward order); the reverse stays refused */'
REV='@T@  (irt_isi64(IR(ref)->t) == irt_isi64(fins->t) || irt_isi64(IR(ref)->t)))'
WHT='@T@  IR(ref)->t.irt == fins->t.irt)'
CMT1='      /* OC-LuaJIT: an int64 instruction never commons with one of another'
CSLI='    if (IR(ref)->op12 == op12)'
CSLR='      return ref;'
ONEL='    if (IR(ref)->op12 == op12 && irt_isi64(IR(ref)->t) == irt_isi64(fins->t))'
NEXT='      ref = IR(ref)->prev;'
NADDL='NADD=76     # lines diff -d reports added on the pristine file ...'
NDELL='NDEL=9      # ... and removed'
nadd() { echo "NADD=$1     # lines diff -d reports added on the pristine file ..."; }
ndel() { echo "NDEL=$1      # ... and removed"; }
# ---------------------------------------------------------------- Part A
note "== Part A: the script on the pin's file, on mutations of itself and of its input"
check S0-differs-only-by-the-block [ "$(diff "$S" "$OUT/S0.sh" | grep -c '^<')" -gt 20 ]
check S0-adds-nothing [ "$(diff "$S" "$OUT/S0.sh" | grep -c '^>')" = 0 ]
note "info S0 drops $(diff "$S" "$OUT/S0.sh" | grep -c '^<') lines of S"
run C0-head "$HEADS" "$IN" 0 "the table-index fold (70 lines added, 8 removed, of 2715)"
run C1-new "$S" "$IN" 0 "the table-index fold, no CSE of int64 with another type (76 lines added, 9 removed, of 2721); verified by content, diff and reversal"
run C1b-S0 "$OUT/S0.sh" "$IN" 0 "(76 lines added, 9 removed, of 2720)"
check C1-S0-same-output cmp -s "$OUT/C1-new.out.c" "$OUT/C1b-S0.out.c"
diff "$OUT/C0-head.out.c" "$OUT/C1-new.out.c" > "$OUT/C1-vs-head.diff"
note "info C1-new against HEAD's output: $(grep -c '^<' "$OUT/C1-vs-head.diff") lines out, $(grep -c '^>' "$OUT/C1-vs-head.diff") in (expected 1/6: lj_opt_cse's if, and the comment, if and test)"
check C1-vs-head-1-6 [ "$(grep -c '^<' "$OUT/C1-vs-head.diff")/$(grep -c '^>' "$OUT/C1-vs-head.diff")" = 1/6 ]
run C3-idem "$S" "$OUT/C1-new.out.c" 0 "already folds the 64-bit bit operators without FFI (verified) -- unchanged"
check C3-idem-identical cmp -s "$OUT/C1-new.out.c" "$OUT/C3-idem.out.c"
cp "$IN" "$OUT/C4-same.c"
sh "$S" "$OUT/C4-same.c" "$OUT/C4-same.c" > "$OUT/C4-same.log" 2>&1
check C4-same-rc [ "$?" = 0 ]
check C4-same-identical cmp -s "$OUT/C1-new.out.c" "$OUT/C4-same.c"
cp "$OUT/C1-new.out.c" "$OUT/C5-same-idem.c"
sh "$S" "$OUT/C5-same-idem.c" "$OUT/C5-same-idem.c" > "$OUT/C5-same-idem.log" 2>&1
check C5-same-idem-rc [ "$?" = 0 ]
check C5-same-idem-identical cmp -s "$OUT/C1-new.out.c" "$OUT/C5-same-idem.c"
CRS=$(od -An -tx1 -v "$OUT/C1-new.out.c" | tr ' ' '|' | grep -o '|0d' | wc -l | tr -d ' ')
check C1-no-CR [ "$CRS" = 0 ]
check C1-marker-once [ "$(grep -c -F 'OC-LuaJIT (native/luajit/patch-bitop-fold.sh)' "$OUT/C1-new.out.c")" = 1 ]
check C1-no-other-round3-marker [ "$(grep -c -F 'OC-LuaJIT (native/luajit/patch-bitop-' "$OUT/C1-new.out.c")" = 1 ]
grep '^LJFOLD' "$IN" > "$OUT/rules.in"
grep '^LJFOLD' "$OUT/C1-new.out.c" > "$OUT/rules.out"
check C1-LJFOLD-unchanged cmp -s "$OUT/rules.in" "$OUT/rules.out"
# The hunk engine block, byte-identical to HEAD's.
awk '/^# --- THE HUNK ENGINE/ { on = 1 } on { print } /^# --- end of the hunk engine/ { exit }' "$S" > "$OUT/engine.S"
awk '/^# --- THE HUNK ENGINE/ { on = 1 } on { print } /^# --- end of the hunk engine/ { exit }' "$HEADS" > "$OUT/engine.head"
check engine-identical-to-head cmp -s "$OUT/engine.S" "$OUT/engine.head"
note "info engine block: $(wc -l < "$OUT/engine.S" | tr -d ' ') lines, md5 $(md5sum < "$OUT/engine.S" | cut -c1-12)"
# The anchor: o12's two lines, as a run, in the pin's file and the tip's.
cnt2() {
  A=$IFL B=$RET awk 'BEGIN { T = sprintf("%c", 9); CR = sprintf("%c", 13); a = ENVIRON["A"]; b = ENVIRON["B"]; gsub(/@T@/, T, b) }
    { if (substr($0, length($0)) == CR) $0 = substr($0, 1, length($0) - 1); L[++n] = $0 }
    END { c = 0; for (i = 1; i < n; i++) if (L[i] == a && L[i + 1] == b) c++; print c }' "$1"
}
note "info hunk 12's anchor (o12) occurs $(cnt2 "$IN") time(s) in the pin's lj_opt_fold.c and $(cnt2 "$TIP") in a4c0645's"
check anchor-once-pin [ "$(cnt2 "$IN")" = 1 ]
check anchor-once-tip [ "$(cnt2 "$TIP")" = 1 ]
run T1-tip-new "$S" "$TIP" 0 "no CSE of int64 with another type (76 lines added, 9 removed, of"
run T2-tip-head "$HEADS" "$TIP" 0 "(70 lines added, 8 removed, of"
# M: script mutations.  Each: S refuses with its message, S0 takes it (rc 0).
mkcase M1-stray-n12 "$PRL@N@$RET" "$PRL@N@$RET@N@$PRL" "$NADDL" "$(nadd 77)"
run M1-stray-n12 "$OUT/M1-stray-n12.S.sh" "$IN" 1 "is a line of its own 2 times, expected 1"
run M1-stray-n12.S0 "$OUT/M1-stray-n12.S0.sh" "$IN" 0 "(77 lines added, 9 removed, of 2721)"
mkcase M2-in-cselim "$IFL@N@$RET" "$CSLI@N@$CSLR" "$NADDL@N@$NDELL" "$(nadd 77)@N@$(ndel 10)"
run M2-in-cselim "$OUT/M2-in-cselim.S.sh" "$IN" 1 "is not inside lj_opt_cse"
run M2-in-cselim.S0 "$OUT/M2-in-cselim.S0.sh" "$IN" 0 "(77 lines added, 10 removed, of 2720)"
mkcase M3-csefwd "$PRL" "$FWD"
run M3-csefwd "$OUT/M3-csefwd.S.sh" "$IN" 1 "is a line of its own 0 times, expected 1"
run M3-csefwd.S0 "$OUT/M3-csefwd.S0.sh" "$IN" 0 "(76 lines added, 9 removed, of 2720)"
mkcase M4-reverse "$PRL" "$REV"
run M4-reverse "$OUT/M4-reverse.S.sh" "$IN" 1 "is a line of its own 0 times, expected 1"
run M4-reverse.S0 "$OUT/M4-reverse.S0.sh" "$IN" 0 "(76 lines added, 9 removed, of 2720)"
mkcase M5-dropped "$IFN@N@$PRL" "$IFL" "$NADDL" "$(nadd 74)"
mut "$OUT/M5-dropped.S.sh" "$OUT/M5-dropped.S.tmp" "$NDELL" "$(ndel 8)" && mv "$OUT/M5-dropped.S.tmp" "$OUT/M5-dropped.S.sh"
mut "$OUT/M5-dropped.S0.sh" "$OUT/M5-dropped.S0.tmp" "$NDELL" "$(ndel 8)" && mv "$OUT/M5-dropped.S0.tmp" "$OUT/M5-dropped.S0.sh"
run M5-dropped "$OUT/M5-dropped.S.sh" "$IN" 1 "is a line of its own 0 times, expected 1"
run M5-dropped.S0 "$OUT/M5-dropped.S0.sh" "$IN" 0 "(74 lines added, 8 removed, of 2719)"
mkcase M6-whole-t "$PRL" "$WHT"
run M6-whole-t "$OUT/M6-whole-t.S.sh" "$IN" 1 "is a line of its own 0 times, expected 1"
run M6-whole-t.S0 "$OUT/M6-whole-t.S0.sh" "$IN" 0 "(76 lines added, 9 removed, of 2720)"
mkcase M7-after-return "$PRL@N@$RET" "$RET@N@$PRL"
run M7-after-return "$OUT/M7-after-return.S.sh" "$IN" 1 "(below/above: no/no)"
run M7-after-return.S0 "$OUT/M7-after-return.S0.sh" "$IN" 0 "(76 lines added, 9 removed, of 2720)"
mkcase M8-or "$IFN" '      if (IR(ref)->op12 == op12 ||'
run M8-or "$OUT/M8-or.S.sh" "$IN" 1 "(below/above: no/yes)"
run M8-or.S0 "$OUT/M8-or.S0.sh" "$IN" 0 "(76 lines added, 9 removed, of 2720)"
mkcase M9-marker "$CMT1" '      /* OC-LuaJIT (native/luajit/patch-bitop-fold.sh): an int64 instruction never commons with one of another'
run M9-marker "$OUT/M9-marker.S.sh" "$IN" 1 "marker present 2 times, expected 1"
mkcase M10-old-nadd "$NADDL@N@$NDELL" "$(nadd 70)@N@$(ndel 8)"
run M10-old-nadd "$OUT/M10-old-nadd.S.sh" "$IN" 1 "line count: 2653 in + 70 - 8 != 2720 out"
mkcase M11-nh11 'NH=12       # hunks' 'NH=11       # hunks'
run M11-nh11 "$OUT/M11-nh11.S.sh" "$IN" 1 "is a line of its own 0 times, expected 1"
# I: input mutations.
{ cat "$IN"; echo '      irt_isi64(IR(ref)->t) == irt_isi64(fins->t))'; } > "$OUT/I1.c"
run I1-stray-input "$S" "$OUT/I1.c" 1 "is a line of its own 2 times, expected 1"
run I1-stray-input.head "$HEADS" "$OUT/I1.c" 0 "(70 lines added, 8 removed, of 2716)"
run I1-stray-input.S0 "$OUT/S0.sh" "$OUT/I1.c" 0 "(76 lines added, 9 removed, of 2721)"
mutt "$IN" "$OUT/I2.c" "$CSLI@N@$CSLR" "$ONEL@N@$CSLR"
run I2-oneline-in-cselim "$S" "$OUT/I2.c" 1 "irt_isi64(IR(ref)->t) is named on 2 lines, expected 1"
run I2-oneline-in-cselim.head "$HEADS" "$OUT/I2.c" 0 "(70 lines added, 8 removed, of 2715)"
run I2-oneline-in-cselim.S0 "$OUT/S0.sh" "$OUT/I2.c" 0 "(76 lines added, 9 removed, of 2720)"
{ cat "$IN"; echo "$IFL"; echo "$RET" | awk '{ gsub(/@T@/, sprintf("%c", 9)); print }'; } > "$OUT/I3.c"
run I3-anchor-twice "$S" "$OUT/I3.c" 1 "hunk 12's upstream text occurs 2 times"
mutt "$IN" "$OUT/I4.c" "$IFL@N@$RET" "$IFL@N@@T@return TREF(ref, irt_t(IR(ref)->t));"
run I4-anchor-missing "$S" "$OUT/I4.c" 1 "hunk 12's upstream text occurs 0 times"
# P: the already-patched path (build-native.sh never takes it; the cserev
# gate of the design's 4.4 does, on the build copy).
G=$OUT/C1-new.out.c
mutt "$G" "$OUT/P1.c" "$PRL" "$FWD"
run P1-patched-csefwd "$S" "$OUT/P1.c" 1 "hunk 12's patched text occurs 0 times, expected 1"
mutt "$G" "$OUT/P2.c" "$PRL" "$REV"
run P2-patched-reverse "$S" "$OUT/P2.c" 1 "hunk 12's patched text occurs 0 times, expected 1"
mutt "$G" "$OUT/P3.c" "$CSLI@N@$CSLR" "$ONEL@N@$CSLR"
run P3-patched-oneline-in-cselim "$S" "$OUT/P3.c" 1 "irt_isi64(IR(ref)->t) is named on 2 lines, expected 1"
run P3-patched-oneline-in-cselim.S0 "$OUT/S0.sh" "$OUT/P3.c" 0 "(verified) -- unchanged"
# ---------------------------------------------------------------- Part B
note "== Part B: verify_content's checks on mutated patched files, fail() not exiting"
awk 'index($0, "verify_content() {") == 1 { on = 1 } on { print } on && $0 == "}" { exit }' "$S" > "$OUT/vc.sh"
{ echo "NOFFI='#if 1  /* OC-LuaJIT: the 64-bit bit operators, without FFI. */'"
  echo 'countsub() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }'
  echo 'countx() { grep -c -x -F -- "$1" "$2" 2>/dev/null || true; }'
  echo 'fail() { echo "CHECK FAILED: $*"; }'
  cat "$OUT/vc.sh"
  echo 'verify_content "$1"'
} > "$OUT/vc-harness.sh"
cp "$G" "$OUT/v0.c"
{ cat "$G"; echo '      irt_isi64(IR(ref)->t) == irt_isi64(fins->t))'; } > "$OUT/v1.c"
mutt "$G" "$OUT/v2.c" "$CSLI@N@$CSLR" "$ONEL@N@$CSLR"
mutt "$G" "$OUT/v3a.c" "$IFN@N@$PRL@N@$RET@N@$NEXT" "$NEXT" && mutt "$OUT/v3a.c" "$OUT/v3.c" "$CSLI@N@$CSLR" "$IFN@N@$PRL@N@$RET"
mutt "$G" "$OUT/v4.c" "$PRL" "$FWD"
mutt "$G" "$OUT/v5.c" "$PRL" "$REV"
mutt "$G" "$OUT/v6.c" "$IFN@N@$PRL" "$IFL"
mutt "$G" "$OUT/v7.c" "$PRL" "$WHT"
mutt "$G" "$OUT/v8.c" "$PRL@N@$RET" "$RET@N@$PRL"
mutt "$G" "$OUT/v9.c" "$IFN" '      if (IR(ref)->op12 == op12 ||'
mutt "$G" "$OUT/v10.c" 'TRef LJ_FASTCALL lj_opt_cse(jit_State *J)' 'TRef LJ_FASTCALL lj_opt_cse(jit_State *J)  /* moved */'
mutt "$G" "$OUT/v11.c" "$PRL" '          irt_isi64(IR(ref)->t) == irt_isi64(fins->t))'
# classify: C1 the line count; C2 the irt_isi64(IR(ref)->t) count; MISS the
# missing check; ORD the order; ADJ the neighbours; OTHER any earlier check.
classify() {
  awk '/^CHECK FAILED/ {
      if (index($0, "is a line of its own")) k = "C1"
      else if (index($0, "irt_isi64(IR(ref)->t) is named on")) k = "C2"
      else if (index($0, "missing lj_opt_cse")) k = "MISS"
      else if (index($0, "is not inside lj_opt_cse")) k = "ORD"
      else if (index($0, "is not directly below")) k = "ADJ"
      else k = "OTHER"
      s = s (s == "" ? "" : ",") k
    }
    END { print (s == "" ? "none" : s) }' "$1"
}
for pair in v0:C1 v1:C1,C2 v2:C2 v3:ORD v4:C1,MISS,ORD,ADJ v5:C1,MISS,ORD,ADJ v6:C1,C2,MISS,ORD,ADJ v7:C1,C2,MISS,ORD,ADJ v8:ADJ v9:ADJ v10:MISS,ORD v11:none; do
  v=${pair%%:*}; want=${pair#*:}
  sh "$OUT/vc-harness.sh" "$OUT/$v.c" > "$OUT/$v.vc" 2> "$OUT/$v.vc-err"
  got=$(classify "$OUT/$v.vc")
  if [ "$got" = "$want" ]; then k=ok; PASS=$((PASS + 1)); else k=WRONG; FAIL=$((FAIL + 1)); fi
  note "$k $v: failed [$got] want [$want]; stderr $(wc -c < "$OUT/$v.vc-err" | tr -d ' ') bytes :: $(grep 'CHECK FAILED' "$OUT/$v.vc" | sed 's|^CHECK FAILED: [^:]*: ||' | cut -c1-110 | awk '{ printf "%s|", $0 }')"
done
note "PASS=$PASS FAIL=$FAIL"
rmdir "$OUT/tmp" 2>/dev/null
cat "$OUT/results.txt"
[ "$FAIL" = 0 ]
