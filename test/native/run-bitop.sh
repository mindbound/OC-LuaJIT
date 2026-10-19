#!/bin/sh
# =====================================================================
# run-bitop.sh -- Lua 5.3's bitwise operators with 64-bit results on our
# no-FFI LuaJIT fork (round 3, decided 2026-10-17): & | ~ << >> and unary ~
# compute Lua 5.3.6's int64 results, and LuaJIT's ~>> a 64-bit arithmetic
# shift, in the parser's folding, the interpreter and the JIT
# (native/luajit/patch-bitop-*.sh, oclj_bitop*.{h,c}).  U1-B: a result with
# more than 53 significant bits has no double and raises "result of '<op>'
# has more than 53 significant bits (mask each operand to 32 bits first)"
# (the hint decided 2026-10-17); every result that does not raise is 5.3.6's
# exactly.  This script pins that text: the .expect files hold it, part 1
# requires every inexact line of them to carry the hint, and part 2's
# xrule.lua requires it of X.
#
#   OCLJ_BUILD=<build dir used by build-native.sh>  sh test/native/run-bitop.sh
#
# Requires build-native.sh to have run first, on THIS platform.  Three parts:
#
#   1. MATRIX.  On the build's luajit.exe, which links the same libluajit.a
#      the natives link, JIT on and -joff:
#        bitop/t_ops.lua   the operators on runtime operands: 7440 cases over
#                          numbers, strings and other types, string-operand
#                          extras, and the operand naming of the errors
#        bitop/t_fold.lua  literal operands, and whether the parser folded
#                          each case (an inexact result is not folded)
#        bitop/t_sar.lua   ~>> on 437 cases, each folded, interpreted and
#                          compiled with a variable and a constant count
#        bitop/t_bit.lua   LuaJIT's own bit library, unchanged (U10)
#      Each output must equal bitop/<script>.expect EXACTLY.  The first three
#      .expect files are PUC Lua 5.3.6's output under U1-B's rule, X, with
#      the decided deviations applied (bitop/deviations.txt): no reference
#      interpreter needed.  Then bitop/coerce_agree.lua: string.pack's and
#      the operators' readers of a numeric string agree on 51 strings.
#   2. PROVENANCE.  When PUC Lua 5.3.6 is available (OCLJ_LUA53, default
#      bench/vendor/lua-5.3.6/src/lua[.exe], git-ignored: build it there),
#      t_ops, t_fold and t_sar run on it twice:
#        (1) with X: each operator's result is its double if that double
#            equals it (math.tointeger(r + 0.0) == r), else the error.
#            Reworded to LuaJIT's word order (bitop/reword.lua), the lines in
#            which PUC differs from the .expect files (the case and its
#            result) must be EXACTLY the ones deviations.txt lists for this
#            platform -- so no .expect line can drift from 5.3.6 unnoticed.
#            An integer that no operator made (a bare literal) prints with %d
#            here too, so a literal our lexer rounds is a visible difference
#            (LEX), not two equal %.17g texts;
#        (2) raw, every integer printed with %d and every operator's integer
#            traced: bitop/xrule.lua requires the X run to raise exactly where
#            an operator's exact 64-bit integer has more than 53 significant
#            bits (counted with integer shifts), and to return that integer
#            otherwise -- X checked against 5.3.6's own integers, which %.17g
#            would have hidden.
#      And coerce_agree.lua on PUC, where both readers are 5.3.6's own.
#      Without PUC this part says SKIPPED; the run can still pass.
#   3. THE SHIM PATH.  bitop_test.c, compiled -include lj52shim.h and linked
#      with the SAME lj52shim.o, eris_lj.o and libluajit.a the DLL links:
#      results through lua_tonumber and lua_tointeger, the new error through
#      lua_pcall (a compiled loop's included), the RAM cap's charge for the
#      C path (none), the count hook inside a compiled bit loop, bit32.
#
# The JIT's own suites and the generator are run-bitjit.sh, the differential
# fuzzer run-bitfuzz.sh; the proof that these checks can fail is
# negctl-bitop.sh.  Results go to a fresh $OCLJ_BUILD/bitop-<UTC stamp> (or
# OCLJ_BITOP_OUT, which must not exist): never overwritten.
#
# Exit status 0 = every part passed (part 2 passed or was skipped).
#            1 = a check FAILED -- including the 32-bit operators of every
#                build before round 3.
#            2 = the test proved nothing (no build, a link problem) -- but a
#                FAIL that part 1 or 2 has already recorded stays 1 when
#                part 3 then cannot run.
# =====================================================================
set -u
# Neither VM may run code from the caller's environment before the scripts:
# LUA_INIT (LuaJIT, and PUC without the next) and LUA_INIT_5_3 (PUC 5.3).
unset LUA_INIT LUA_INIT_5_3
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
: "${OCLJ_SHIM:=$OCLJ_REPO/native}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${OCLJ_JNI:=}"
: "${CC:=gcc}"
: "${OCLJ_LUA53:=$OCLJ_REPO/bench/vendor/lua-5.3.6/src/lua.exe}"
: "${OCLJ_BITOP_OUT:=$OCLJ_BUILD/bitop-$(date -u +%Y%m%dT%H%M%SZ)}"

fail() { echo "BITOP TEST SETUP FAIL: $*" >&2; exit 2; }

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) OCLJ_OS=windows ;;
  Linux)   OCLJ_OS=linux   ;;
  Darwin)  OCLJ_OS=darwin  ;;
  *) fail "unsupported host system $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  OCLJ_ARCH=x86_64  ;;
  aarch64|arm64) OCLJ_ARCH=aarch64 ;;
  *) fail "unsupported machine $(uname -m)" ;;
esac
PLATFORM="$OCLJ_OS-$OCLJ_ARCH"
case $OCLJ_OS in
  windows) JNI_MD=win32 ; EXE=.exe ; TEST_EXTRA= ;;
  darwin)  JNI_MD=darwin ; EXE= ; TEST_EXTRA= ;;
  # One Linux tail for every test link.  -pthread, not -lpthread: it sets the
  # preprocessor defines too.  -ldl: luaL_openlibs pulls LuaJIT's lib_package,
  # which calls dlopen.  Before glibc 2.34 (AlmaLinux 8, the release build's
  # host) both are outside libc and a link that needs one fails without it.
  *)       JNI_MD=$OCLJ_OS ; EXE= ; TEST_EXTRA="-pthread -ldl" ;;
esac
LJ=$OCLJ_BUILD/luajit-$PLATFORM/src
OBJ=$OCLJ_BUILD/obj-$PLATFORM
P=$SELF_DIR/bitop

if [ -z "$OCLJ_JNI" ]; then
  for c in "${JAVA_HOME:-}/include" /usr/lib/jvm/*/include /c/Program\ Files/Java/*/include; do
    [ -f "$c/jni.h" ] && OCLJ_JNI="$c" && break
  done
fi
[ -n "$OCLJ_JNI" ] && [ -f "$OCLJ_JNI/jni.h" ] || fail "OCLJ_JNI must name a JDK include dir containing jni.h
       (bitop_test.c force-includes lj52shim.h, which includes <jni.h>)."
[ -x "$LJ/luajit$EXE" ] || fail "no $LJ/luajit$EXE -- run build-native.sh first (on THIS platform)"
[ -f "$LJ/libluajit.a" ] || fail "no $LJ/libluajit.a -- run build-native.sh first"
[ -f "$LJ/jit/vmdef.lua" ] || fail "no $LJ/jit/vmdef.lua (t_fold.lua reads the bytecode names from it)"
[ -f "$OBJ/lj52shim.o" ] || fail "no $OBJ/lj52shim.o -- run build-native.sh first (on THIS platform)"
[ -f "$OBJ/eris_lj.o" ]  || fail "no $OBJ/eris_lj.o -- run build-native.sh first (on THIS platform)"
for f in t_ops.lua t_fold.lua t_sar.lua t_bit.lua t_ops.expect t_fold.expect t_sar.expect t_bit.expect \
         deviations.txt reword.lua xrule.lua coerce_agree.lua; do
  [ -f "$P/$f" ] || fail "no $P/$f"
done
[ -e "$OCLJ_BITOP_OUT" ] && fail "$OCLJ_BITOP_OUT exists; results are never overwritten"
mkdir -p "$OCLJ_BITOP_OUT" || fail "cannot create $OCLJ_BITOP_OUT"
# Absolute paths: the matrix runs luajit from its own directory (below).
OUT=$(CDPATH= cd -- "$OCLJ_BITOP_OUT" && pwd)
LJ=$(CDPATH= cd -- "$LJ" && pwd)
LJEXE=$LJ/luajit$EXE
echo "run-bitop: build $OCLJ_BUILD ($PLATFORM); results $OUT"

bad=0
# A matrix line is "<id> TAB <result>" (t_fold.expect: and TAB <fold
# decision>).  ids_differing <a> <b> -> the ids of the line pairs that differ.
ids_differing() {
  awk -F'\t' 'NR == FNR { a[FNR] = $0; n = FNR; next }
       { if (a[FNR] != $0) { i = a[FNR]; sub(/\t.*$/, "", i); print i } m = FNR }
       END { if (n != m) print "<line count " n " vs " m ">" }' "$1" "$2"
}
# luajit, run from its own directory: t_fold.lua requires jit.vmdef, which
# lives beside the binary (jit/vmdef.lua) and is found through "./?.lua".
lj() { ( cd "$LJ" && "./luajit$EXE" "$@" ); }
# The inexact error: INEXACT finds it, HINT is its whole decided text.
INEXACT="has more than 53 significant bits"
HINT="has more than 53 significant bits (mask each operand to 32 bits first)"

# ---------------------------------------------------------------- 1
echo
echo "== 1. matrix on $LJEXE, JIT on and -joff =="
for s in t_ops t_fold t_sar t_bit; do
  n=$(grep -c . "$P/$s.expect")
  ni=$(grep -c -F "$INEXACT" "$P/$s.expect")
  nh=$(grep -c -F "$HINT" "$P/$s.expect")
  # The .expect file itself: every inexact line carries the hint, with or
  # without PUC (an old .expect and an old build would agree).
  if [ "$ni" -ne "$nh" ]; then
    echo "FAIL $s.expect: $((ni - nh)) of its $ni inexact-error lines lack the decided text '... $HINT'"
    bad=1
  fi
  for m in jit joff; do
    flag=; [ "$m" = joff ] && flag=-joff
    lj $flag "$P/$s.lua" > "$OUT/$s.$m.raw" 2> "$OUT/$s.$m.err"
    rc=$?
    tr -d '\r' < "$OUT/$s.$m.raw" > "$OUT/$s.$m.txt"
    if [ "$rc" -ne 0 ]; then
      echo "FAIL $s ($m): luajit raised (exit $rc): $(head -c 300 "$OUT/$s.$m.err")"
      bad=1
    elif cmp -s "$OUT/$s.$m.txt" "$P/$s.expect"; then
      echo "PASS $s ($m): $n cases, every line as $s.expect says ($ni of them raise the inexact error)"
    else
      nd=$(ids_differing "$P/$s.expect" "$OUT/$s.$m.txt" | grep -c .)
      echo "FAIL $s ($m): $nd of $n lines differ from $s.expect (want, then got):"
      diff "$P/$s.expect" "$OUT/$s.$m.txt" | grep '^[<>]' | head -40 | sed 's/^/    /'
      bad=1
    fi
  done
done
"$LJEXE" "$P/coerce_agree.lua" > "$OUT/coerce.raw" 2> "$OUT/coerce.err"
rc=$?
tr -d '\r' < "$OUT/coerce.raw" > "$OUT/coerce.txt"
CL=$(tail -n 1 "$OUT/coerce.txt")
case "$rc|$CL" in
  "0|coerce-agree: 51 strings, 0 disagreements")
    echo "PASS coerce_agree: string.pack and the operators read all 51 strings alike" ;;
  *)
    echo "FAIL coerce_agree (exit $rc): ${CL:-no summary line} $(head -c 200 "$OUT/coerce.err")"
    grep '^DISAGREE' "$OUT/coerce.txt" | head -20 | sed 's/^/    /'
    bad=1 ;;
esac

# ---------------------------------------------------------------- 2
echo
echo "== 2. provenance: the .expect files against PUC Lua 5.3.6 =="
# deviations.txt: "<script> <platform: any, windows or linux> <class> <id>",
# the id to the end of the line.  Classes: LEX (the id holds a hex literal,
# or a decimal integer literal of 16 or more digits: 2^53 has 16), IDIV (it
# holds "//"), RESID-varinfo (a naming case, "name: ...").  Each id must be
# exactly one line of its script's .expect.  Checked with or without PUC.
devbad=$(awk -v P="$P" 'function maxdigits(s,   k, r, m) { r = 0; m = 0
    for (k = 1; k <= length(s); k++) if (substr(s, k, 1) ~ /[0-9]/) { r++; if (r > m) m = r } else r = 0
    return m }
  /^#/ || /^[ \t]*$/ { next }
  { why = ""; id = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ /, "", id) }
  NF < 4 { why = "fewer than 4 fields" }
  why == "" && $1 != "t_ops" && $1 != "t_fold" && $1 != "t_sar" { why = "unknown script" }
  why == "" && $2 != "any" && $2 != "windows" && $2 != "linux" { why = "unknown platform" }
  why == "" && $3 != "LEX" && $3 != "IDIV" && $3 != "RESID-varinfo" { why = "unknown class" }
  why == "" && (($3 == "LEX" && !index(id, "0x") && maxdigits(id) < 16) || ($3 == "IDIV" && !index(id, "//")) ||
                ($3 == "RESID-varinfo" && index(id, "name: ") != 1)) { why = "the id and the class disagree" }
  why == "" { k = 0; f = P "/" $1 ".expect"
              while ((getline l < f) > 0) { sub(/\t.*$/, "", l); if (l == id) k++ }
              close(f)
              if (k != 1) why = "the id is " k " lines of " $1 ".expect, not 1" }
  why != "" { print "line " NR ", " why ": " $0 }' "$P/deviations.txt")
if [ -n "$devbad" ]; then
  echo "FAIL deviations: lines of deviations.txt that part 2 cannot use:"
  echo "$devbad" | head -20 | sed 's/^/    /'
  bad=1
fi
[ -x "$OCLJ_LUA53" ] || OCLJ_LUA53=${OCLJ_LUA53%.exe}
REFV=
[ -x "$OCLJ_LUA53" ] && REFV=$("$OCLJ_LUA53" -v 2>&1)
case "$REFV" in
  "Lua 5.3.6"*)
    for s in t_ops t_fold t_sar; do
      # (1) X, reworded, against the .expect file's case and result.
      "$OCLJ_LUA53" "$P/$s.lua" X > "$OUT/$s.pucx.raw" 2> "$OUT/$s.pucx.err"
      rc=$?
      tr -d '\r' < "$OUT/$s.pucx.raw" > "$OUT/$s.pucx.txt"
      "$LJEXE" "$P/reword.lua" < "$OUT/$s.pucx.txt" 2> "$OUT/$s.reword.err" | tr -d '\r' > "$OUT/$s.pucx-rw.txt"
      cut -f1-2 "$P/$s.expect" > "$OUT/$s.expect12.txt"
      ids_differing "$OUT/$s.expect12.txt" "$OUT/$s.pucx-rw.txt" | sort > "$OUT/$s.diff-ids.txt"
      awk -v s="$s" -v o="$OCLJ_OS" '/^#/ || /^[ \t]*$/ { next }
        $1 == s && ($2 == "any" || $2 == o) { id = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ /, "", id); print id }' \
        "$P/deviations.txt" | sort > "$OUT/$s.want-ids.txt"
      nw=$(grep -c . "$OUT/$s.want-ids.txt")
      if [ "$rc" -ne 0 ]; then
        echo "FAIL $s (1): PUC 5.3.6 raised running it with X (exit $rc): $(head -c 300 "$OUT/$s.pucx.err")"
        bad=1
      elif cmp -s "$OUT/$s.diff-ids.txt" "$OUT/$s.want-ids.txt"; then
        echo "PASS $s (1): PUC 5.3.6 with X ($(cat "$OUT/$s.reword.err")) differs from $s.expect in exactly the $nw lines deviations.txt lists for $OCLJ_OS"
      else
        echo "FAIL $s (1): PUC 5.3.6 with X and $s.expect differ in lines deviations.txt does not list, or agree where it does"
        echo "    differ but not listed:"; comm -23 "$OUT/$s.diff-ids.txt" "$OUT/$s.want-ids.txt" | head -20 | sed 's/^/      /'
        echo "    listed but agree:";      comm -13 "$OUT/$s.diff-ids.txt" "$OUT/$s.want-ids.txt" | head -20 | sed 's/^/      /'
        awk -F'\t' -v w="$OUT/$s.want-ids.txt" 'BEGIN { while ((getline l < w) > 0) want[l] = 1 }
          NR == FNR { a[FNR] = $0; next }
          a[FNR] != $0 { i = a[FNR]; sub(/\t.*$/, "", i)
                         if (!(i in want)) { print "    want: " a[FNR]; print "    PUC:  " $0 } }' \
          "$OUT/$s.expect12.txt" "$OUT/$s.pucx-rw.txt" | head -20
        bad=1
      fi
      # (2) raw, traced: X against 5.3.6's own integers.  Exit 3 is the
      # script's own check that its X rewrite changed no case.
      "$OCLJ_LUA53" "$P/$s.lua" raw > "$OUT/$s.pucraw.raw" 2> "$OUT/$s.pucraw.err"
      rc=$?
      tr -d '\r' < "$OUT/$s.pucraw.raw" > "$OUT/$s.pucraw.txt"
      "$OCLJ_LUA53" "$P/xrule.lua" "$OUT/$s.pucx.txt" "$OUT/$s.pucraw.txt" > "$OUT/$s.xrule.raw" 2>&1
      xrc=$?
      tr -d '\r' < "$OUT/$s.xrule.raw" > "$OUT/$s.xrule.txt"
      if [ "$rc" -ne 0 ]; then
        echo "FAIL $s (2): PUC 5.3.6 raw run exited $rc: $(head -c 300 "$OUT/$s.pucraw.err")"
        bad=1
      elif [ "$xrc" -eq 0 ]; then
        echo "PASS $s (2): $(tail -n 1 "$OUT/$s.xrule.txt")"
      else
        echo "FAIL $s (2): X disagrees with PUC 5.3.6's integers (xrule.lua exit $xrc):"
        head -22 "$OUT/$s.xrule.txt" | sed 's/^/    /'
        bad=1
      fi
    done
    "$OCLJ_LUA53" "$P/coerce_agree.lua" > "$OUT/coerce.puc.raw" 2> "$OUT/coerce.puc.err"
    rc=$?
    CL=$(tr -d '\r' < "$OUT/coerce.puc.raw" | tail -n 1)
    case "$rc|$CL" in
      "0|coerce-agree: 51 strings, 0 disagreements")
        echo "PASS coerce_agree on PUC 5.3.6: its own two readers agree on the same 51 strings" ;;
      *)
        echo "FAIL coerce_agree on PUC 5.3.6 (exit $rc): ${CL:-no summary line}"
        bad=1 ;;
    esac ;;
  *)
    echo "SKIPPED: no PUC Lua 5.3.6 at $OCLJ_LUA53 (${REFV:-not found}); build bench/vendor/lua-5.3.6 or set OCLJ_LUA53" ;;
esac

# ---------------------------------------------------------------- 3
echo
echo "== 3. the shim path: bitop_test.c =="
# A part-3 setup problem proves nothing about part 3, but it does not undo a
# FAIL that part 1 or 2 has recorded: that run still ends FAIL, exit 1.
fail3() {
  echo "BITOP TEST SETUP FAIL: $*" >&2
  if [ "$bad" != 0 ]; then
    echo
    echo "RUN-BITOP: FAIL (part 3 could not run: $*; results: $OUT)"
    exit 1
  fi
  exit 2
}
# -include lj52shim.h, exactly as build-native.sh compiles jnlua.c.
"$CC" -O2 -Wall -Wextra -I"$LJ" -I"$OCLJ_SHIM" -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" \
  -include "$OCLJ_SHIM/lj52shim.h" \
  "$SELF_DIR/bitop_test.c" \
  "$OBJ/lj52shim.o" "$OBJ/eris_lj.o" \
  "$LJ/libluajit.a" -lm $TEST_EXTRA -o "$OUT/bitop_test$EXE" 2> "$OUT/bitop_test.build.err" \
  || { cat "$OUT/bitop_test.build.err"; fail3 "bitop_test.c did not build"; }
if grep -q 'warning:' "$OUT/bitop_test.build.err"; then
  cat "$OUT/bitop_test.build.err"
  fail3 "bitop_test.c must compile warning-clean"
fi
"$OUT/bitop_test$EXE" > "$OUT/bitop_test.log" 2>&1
rc=$?
cat "$OUT/bitop_test.log"
case $rc in
  0) : ;;
  2) echo "BITOP TEST PROVED NOTHING: bitop_test exited 2 (results: $OUT)"
     fail3 "bitop_test exited 2" ;;
  *) bad=1 ;;
esac

echo
if [ "$bad" = 0 ]; then
  echo "RUN-BITOP: PASS (results: $OUT)"
  exit 0
fi
echo "RUN-BITOP: FAIL (results: $OUT)"
exit 1
