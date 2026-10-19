#!/bin/sh
# =====================================================================
# run-pack.sh -- string.pack, string.unpack and string.packsize: our fork's
# Lua 5.3.6 port (native/luajit/oclj_strpack.c, registered in LuaJIT's
# lib_string.c by native/luajit/patch-strpack-register.sh).
#
#   OCLJ_BUILD=<build dir used by build-native.sh>  sh test/native/run-pack.sh
#
# Requires build-native.sh to have run first, on THIS platform.  Three parts:
#
#   1. CONFORMANCE.  pack/conformance.lua (308 cases) and pack/conf-extra.lua
#      (411) on the build's luajit.exe, which links the same libluajit.a the
#      natives link.  Each output must equal pack/<script>.expect EXACTLY.  The
#      .expect files are PUC Lua 5.3.6's output with the decided deviations
#      applied (pack/deviations.txt) -- no reference interpreter needed.
#   2. PROVENANCE.  When PUC Lua 5.3.6 is available (OCLJ_LUA53, default
#      bench/vendor/lua-5.3.6/src/lua[.exe], git-ignored: build it there), the
#      same scripts run on it twice.  As they are: the lines in which PUC
#      differs from the .expect files must be EXACTLY the ones deviations.txt
#      lists for this platform.  With the decided deviations applied to the
#      listed lines (each script's header says how): PUC's output must equal
#      the .expect file in every line but the listed RESID/RESID-scan ones,
#      and those must still differ -- so no .expect line but a listed RESID one
#      can drift from 5.3.6 unnoticed, a listed DEV line included, and no line
#      D1 or D2 explains can be filed as RESID (a RESID class needs a RESID id).
#      Without PUC this part says SKIPPED; the run can still pass.
#   3. THE SHIM PATH.  pack_test.c, compiled -include lj52shim.h and linked
#      with the SAME lj52shim.o, eris_lj.o and libluajit.a the DLL links: the
#      functions through jnlua's opener, Plan9k's GPT header on a text
#      sector, the RAM cap's charge and refusal, unpack's C-stack limit.
#
# The differential fuzzer is run-packfuzz.sh; the proof that these checks can
# fail is negctl-pack.sh.  Results go to a fresh $OCLJ_BUILD/pack-<UTC stamp>
# (or OCLJ_PACK_OUT, which must not exist): never overwritten.
#
# Exit status 0 = every part passed (part 2 passed or was skipped).
#            1 = a check FAILED -- including string.pack missing, which is
#                every build before 2026-10-17.
#            2 = the test proved nothing (no build, a link problem) -- but a
#                FAIL that part 1 or 2 has already recorded stays 1 when
#                part 3 then cannot run.
# =====================================================================
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
: "${OCLJ_SHIM:=$OCLJ_REPO/native}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${OCLJ_JNI:=}"
: "${CC:=gcc}"
: "${OCLJ_LUA53:=$OCLJ_REPO/bench/vendor/lua-5.3.6/src/lua.exe}"
: "${OCLJ_PACK_OUT:=$OCLJ_BUILD/pack-$(date -u +%Y%m%dT%H%M%SZ)}"

fail() { echo "PACK TEST SETUP FAIL: $*" >&2; exit 2; }

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
LJEXE=$LJ/luajit$EXE
P=$SELF_DIR/pack

if [ -z "$OCLJ_JNI" ]; then
  for c in "${JAVA_HOME:-}/include" /usr/lib/jvm/*/include /c/Program\ Files/Java/*/include; do
    [ -f "$c/jni.h" ] && OCLJ_JNI="$c" && break
  done
fi
[ -n "$OCLJ_JNI" ] && [ -f "$OCLJ_JNI/jni.h" ] || fail "OCLJ_JNI must name a JDK include dir containing jni.h
       (pack_test.c force-includes lj52shim.h, which includes <jni.h>)."
[ -x "$LJEXE" ] || fail "no $LJEXE -- run build-native.sh first (on THIS platform)"
[ -f "$LJ/libluajit.a" ] || fail "no $LJ/libluajit.a -- run build-native.sh first"
[ -f "$OBJ/lj52shim.o" ] || fail "no $OBJ/lj52shim.o -- run build-native.sh first (on THIS platform)"
[ -f "$OBJ/eris_lj.o" ]  || fail "no $OBJ/eris_lj.o -- run build-native.sh first (on THIS platform)"
for f in conformance.lua conf-extra.lua conformance.expect conf-extra.expect deviations.txt; do
  [ -f "$P/$f" ] || fail "no $P/$f"
done
[ -e "$OCLJ_PACK_OUT" ] && fail "$OCLJ_PACK_OUT exists; results are never overwritten"
mkdir -p "$OCLJ_PACK_OUT" || fail "cannot create $OCLJ_PACK_OUT"
OUT=$OCLJ_PACK_OUT
echo "run-pack: build $OCLJ_BUILD ($PLATFORM); results $OUT"

bad=0
# The id of each line: the text before " | ".
ids_differing() {  # ids_differing <a> <b> -> the ids of the line pairs that differ
  awk 'NR == FNR { a[FNR] = $0; n = FNR; next }
       { if (a[FNR] != $0) { i = a[FNR]; sub(/ [|] .*$/, "", i); print i } m = FNR }
       END { if (n != m) print "<line count " n " vs " m ">" }' "$1" "$2"
}

# ---------------------------------------------------------------- 1
echo
echo "== 1. conformance on $LJEXE =="
for s in conformance conf-extra; do
  "$LJEXE" "$P/$s.lua" > "$OUT/$s.ours.raw" 2> "$OUT/$s.ours.err"
  rc=$?
  tr -d '\r' < "$OUT/$s.ours.raw" > "$OUT/$s.ours.txt"
  n=$(grep -c . "$P/$s.expect")
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $s: luajit.exe raised (exit $rc): $(head -c 300 "$OUT/$s.ours.err")"
    bad=1
  elif cmp -s "$OUT/$s.ours.txt" "$P/$s.expect"; then
    echo "PASS $s: $n cases, every line as $s.expect says"
  else
    nd=$(ids_differing "$P/$s.expect" "$OUT/$s.ours.txt" | grep -c .)
    echo "FAIL $s: $nd of $n lines differ from $s.expect (want, then got):"
    diff "$P/$s.expect" "$OUT/$s.ours.txt" | grep '^[<>]' | head -40 | sed 's/^/    /'
    bad=1
  fi
done

# ---------------------------------------------------------------- 2
echo
echo "== 2. provenance: the .expect files against PUC Lua 5.3.6 =="
# deviations.txt: <script>|<platform: any, windows or linux>|<id>|<class>, the
# class DEV1, DEV2, RESID or RESID-scan; an id that starts "DEV1 ", "DEV2 " or
# "RESID" must carry that class, and a RESID class needs an id that starts
# "RESID".  Checked with or without PUC.
devbad=$(awk -F'|' '/^#/ || /^[ \t]*$/ { next }
  { why = "" }
  NF != 4 { why = "not 4 fields" }
  why == "" && $1 != "conformance" && $1 != "conf-extra" { why = "unknown script" }
  why == "" && $2 != "any" && $2 != "windows" && $2 != "linux" { why = "unknown platform" }
  why == "" && $4 != "DEV1" && $4 != "DEV2" && $4 != "RESID" && $4 != "RESID-scan" { why = "unknown class" }
  why == "" && (($3 ~ /^DEV1 / && $4 != "DEV1") || ($3 ~ /^DEV2 / && $4 != "DEV2") ||
                ($3 ~ /^RESID/ && $4 !~ /^RESID/) || ($4 ~ /^RESID/ && $3 !~ /^RESID/)) { why = "the id and the class disagree" }
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
    for s in conformance conf-extra; do
      "$OCLJ_LUA53" "$P/$s.lua" 2> "$OUT/$s.puc.err" | tr -d '\r' > "$OUT/$s.puc.txt"
      ids_differing "$P/$s.expect" "$OUT/$s.puc.txt" | sort > "$OUT/$s.diff-ids.txt"
      awk -F'|' -v s="$s" -v o="$OCLJ_OS" '$1 == s && ($2 == "any" || $2 == o) { print $3 }' \
        "$P/deviations.txt" | sort > "$OUT/$s.want-ids.txt"
      nw=$(grep -c . "$OUT/$s.want-ids.txt")
      if cmp -s "$OUT/$s.diff-ids.txt" "$OUT/$s.want-ids.txt"; then
        echo "PASS $s: PUC 5.3.6 differs from $s.expect in exactly the $nw lines deviations.txt lists for $OCLJ_OS"
      else
        echo "FAIL $s: PUC 5.3.6 and $s.expect differ in lines deviations.txt does not list, or agree where it does"
        echo "    differ but not listed:"; comm -23 "$OUT/$s.diff-ids.txt" "$OUT/$s.want-ids.txt" | head -20 | sed 's/^/      /'
        echo "    listed but agree:";      comm -13 "$OUT/$s.diff-ids.txt" "$OUT/$s.want-ids.txt" | head -20 | sed 's/^/      /'
        bad=1
      fi
      # The content of the listed lines: run again with the decided deviations
      # applied to them (the script reads "<class>|<id>" lines: DEV1 gets D1,
      # DEV2 gets D2, a RESID class both); every line but the RESID ones must
      # then be the .expect line itself, and the RESID ones must still differ.
      awk -F'|' -v s="$s" -v o="$OCLJ_OS" '$1 == s && ($2 == "any" || $2 == o) { print $4 "|" $3 }' \
        "$P/deviations.txt" > "$OUT/$s.dev-classes.txt"
      awk -F'|' -v s="$s" -v o="$OCLJ_OS" '$1 == s && ($2 == "any" || $2 == o) && $4 ~ /^RESID/ { print $3 }' \
        "$P/deviations.txt" | sort > "$OUT/$s.resid-ids.txt"
      "$OCLJ_LUA53" "$P/$s.lua" "$OUT/$s.dev-classes.txt" 2> "$OUT/$s.puc-dev.err" | tr -d '\r' > "$OUT/$s.puc-dev.txt"
      ids_differing "$P/$s.expect" "$OUT/$s.puc-dev.txt" | sort > "$OUT/$s.dev-diff-ids.txt"
      n1=$(grep -c '^DEV1|' "$OUT/$s.dev-classes.txt")
      n2=$(grep -c '^DEV2|' "$OUT/$s.dev-classes.txt")
      nr=$(grep -c . "$OUT/$s.resid-ids.txt")
      if cmp -s "$OUT/$s.dev-diff-ids.txt" "$OUT/$s.resid-ids.txt"; then
        echo "PASS $s: with D1/D2 applied ($n1 DEV1 and $n2 DEV2 lines), PUC 5.3.6 equals $s.expect in every line but the $nr RESID lines, which D1/D2 do not explain"
      else
        echo "FAIL $s: with D1/D2 applied, PUC 5.3.6 differs from $s.expect outside the RESID lines, or D1/D2 explain a RESID line"
        echo "    differ, not RESID:";         comm -23 "$OUT/$s.dev-diff-ids.txt" "$OUT/$s.resid-ids.txt" | head -20 | sed 's/^/      /'
        echo "    RESID, but D1/D2 explain:";  comm -13 "$OUT/$s.dev-diff-ids.txt" "$OUT/$s.resid-ids.txt" | head -20 | sed 's/^/      /'
        awk -v r="$OUT/$s.resid-ids.txt" 'BEGIN { while ((getline l < r) > 0) resid[l] = 1 }
          NR == FNR { a[FNR] = $0; next }
          a[FNR] != $0 { i = a[FNR]; sub(/ [|] .*$/, "", i)
                         if (!(i in resid)) { print "    want: " a[FNR]; print "    PUC:  " $0 } }' \
          "$P/$s.expect" "$OUT/$s.puc-dev.txt" | head -20
        [ -s "$OUT/$s.puc-dev.err" ] && echo "    PUC's stderr: $(head -c 300 "$OUT/$s.puc-dev.err")"
        bad=1
      fi
    done ;;
  *)
    echo "SKIPPED: no PUC Lua 5.3.6 at $OCLJ_LUA53 (${REFV:-not found}); build bench/vendor/lua-5.3.6 or set OCLJ_LUA53" ;;
esac

# ---------------------------------------------------------------- 3
echo
echo "== 3. the shim path: pack_test.c =="
# A part-3 setup problem proves nothing about part 3, but it does not undo a
# FAIL that part 1 or 2 has recorded: that run still ends FAIL, exit 1.
fail3() {
  echo "PACK TEST SETUP FAIL: $*" >&2
  if [ "$bad" != 0 ]; then
    echo
    echo "RUN-PACK: FAIL (part 3 could not run: $*; results: $OUT)"
    exit 1
  fi
  exit 2
}
# -include lj52shim.h, exactly as build-native.sh compiles jnlua.c.
"$CC" -O2 -Wall -Wextra -I"$LJ" -I"$OCLJ_SHIM" -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" \
  -include "$OCLJ_SHIM/lj52shim.h" \
  "$SELF_DIR/pack_test.c" \
  "$OBJ/lj52shim.o" "$OBJ/eris_lj.o" \
  "$LJ/libluajit.a" -lm $TEST_EXTRA -o "$OUT/pack_test$EXE" 2> "$OUT/pack_test.build.err" \
  || { cat "$OUT/pack_test.build.err"; fail3 "pack_test.c did not build"; }
if grep -q 'warning:' "$OUT/pack_test.build.err"; then
  cat "$OUT/pack_test.build.err"
  fail3 "pack_test.c must compile warning-clean"
fi
"$OUT/pack_test$EXE" > "$OUT/pack_test.log" 2>&1
rc=$?
cat "$OUT/pack_test.log"
case $rc in
  0) : ;;
  2) echo "PACK TEST PROVED NOTHING: pack_test exited 2 (results: $OUT)"
     fail3 "pack_test exited 2" ;;
  *) bad=1 ;;
esac

echo
if [ "$bad" = 0 ]; then
  echo "RUN-PACK: PASS (results: $OUT)"
  exit 0
fi
echo "RUN-PACK: FAIL (results: $OUT)"
exit 1
