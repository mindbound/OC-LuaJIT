#!/bin/sh
# =====================================================================
# run-bitjit.sh -- the JIT against the interpreter, and both against PUC Lua
# 5.3.6, for Lua 5.3's bitwise operators (& | ~ << >> ~>> and unary ~) under
# the decided rule U1-B: an operator's 64-bit result is its double when it
# has at most 53 significant bits, and otherwise raises "result of '<op>' has
# more than 53 significant bits (mask each operand to 32 bits first)"
# (decided 2026-10-17).  The suites here classify that error by its operator
# and ignore the text after "bits"; run-bitop.sh pins the text.
#
#   OCLJ_BUILD=<build dir used by build-native.sh>  sh test/native/run-bitjit.sh
#
# Requires build-native.sh to have run first, on THIS platform: the luajit.exe
# that links the same libluajit.a the natives link, and its src/jit/vmdef.lua.
# PUC Lua 5.3.6 (bench/vendor/lua-5.3.6, git-ignored; or OCLJ_LUA53) is
# optional: without it the PUC comparisons say SKIPPED and the run can pass.
# Three parts:
#
#   1. THE GENERATOR (gen).  bitop/gen.lua, the round-3 width-fold reviewer's
#      adversarial loop generator, writes OCLJ_BITJIT_SEEDS seeds of
#      OCLJ_BITJIT_CASES loops each (carried values, branches, flipped types,
#      inner loops, helper calls, table and upvalue round trips, double
#      arithmetic, shift counts and masks at the fold engine's width bound).
#      bitop/drv.lua runs each loop from seven starts under -joff and under
#      five JIT option sets -- the default, -O3 -Ohotloop=1, -Omaxside=0,
#      -Ohotloop=1 -Ohotexit=1, -O3 -O-loop -- once with one closure per loop
#      (shared: later starts run the first start's traces and side exits) and
#      once with a fresh closure per start.  Every output must equal -joff's
#      in the same mode, line for line; errors print as ERR@<loop variable>:
#      <kind>.  With PUC, drv.lua also runs the PUC twin (the same loops with
#      U1-B's rule at every operator), which must equal -joff's too.  A
#      coverage line per seed counts the cases, the runs, the runs that
#      raised, the runs that raised after their 60th iteration (likely from
#      compiled code: the default hotloop is 56) and the cases in which a
#      trace completed; the JIT-on shared run must complete one in at least
#      OCLJ_BITJIT_HOTMIN of the cases, else the part proved nothing.
#      Measured 2026-10-17 on r3/b/bB, seeds 1-3: traced 67-70% of the cases;
#      on a copy whose recorder refuses every bit operator, 1.5-2.1%.
#   2. THE FLOOR (floor).  bitop/t_rec.lua (loop-carried recurrences; seeds 1
#      and 2, and seeds 3 and 4 with out-of-range shift counts; 400 each)
#      under the default options, -O3 -Ohotloop=1 and -Omaxside=0, and
#      bitop/t_jit2.lua (27 hand-built loops) under the default, -O0, -O1,
#      -O3 -Ohotloop=1, -Omaxside=0 and -Ohotloop=1 -Ohotexit=1: each output
#      must equal -joff's.  With PUC, t_jit2.lua's PUC text must equal
#      -joff's output too, but for its one LuaJIT-only line (sar: ~>>).
#   3. FIX1 (fix1).  bitop/p4v.lua: the eight loops that carry a value set
#      from the loop index through an identity bit operation must compile --
#      no "persistent type instability" abort, a trace attached to the loop
#      (JFORL), not blacklisted (IFORL) -- and their results must equal
#      -joff's.  Without fix1 (lj_opt_fold.c simplify_conv_i64_num's PHI
#      condition) seven of them are blacklisted; no timing is involved.
#
# Each part's catches, measured on one-line sabotages of the reference build
# (2026-10-17, role C2's report has the counts): the generator catches every
# fold-rule sabotage (SELFGUARD, WIDTH55, WSHR, WBAND, WADD0, WSHL0), the
# missing exactness guard, NARROW and KFOLD64, in every seed; the floor
# catches NARROW, KFOLD64, the missing guards (result and operand) and
# SELFGUARD, not the width rule's off-by-ones; fix1 catches FIX1, a JIT that
# records no bit operator, and (by its results) KFOLD64.  Proof that the
# checks can fail: negctl-bitop.sh.
#
# Environment:
#   OCLJ_LUA53            PUC Lua 5.3.6 (default bench/vendor/lua-5.3.6/src/lua[.exe])
#   OCLJ_BITJIT_PARTS     the parts to run, of "gen floor fix1"      (default all three)
#   OCLJ_BITJIT_SEED      the generator's first seed                  (default 1)
#   OCLJ_BITJIT_SEEDS     how many consecutive seeds                   (default 4)
#   OCLJ_BITJIT_CASES     loops per seed                               (default 2000)
#   OCLJ_BITJIT_GENMODE   empty, or "phi": half the generated statements
#                         carry a finitely-bounded value across the loop's PHI
#   OCLJ_BITJIT_HOTMIN    the generator's coverage gate, a fraction     (default 0.25)
#   OCLJ_BITJIT_OUT       results directory; must not exist
#                         (default $OCLJ_BUILD/bitjit-<UTC stamp>)
#
# Default: about 40 s (4 seeds x 2000 loops, about 7 s a seed with PUC).
# A campaign is OCLJ_BITJIT_SEED=101 OCLJ_BITJIT_SEEDS=20 (and again with
# OCLJ_BITJIT_GENMODE=phi); every seed's files are kept (about 9.6 MB a seed
# of 2000 loops; the default run writes about 42 MB: 41,580,593 bytes
# measured 2026-10-17, the four seeds 9.62-9.67 MB each and the floor 3.0 MB).
#
# Exit status 0 = every comparison equal, every check passed (PUC parts
#                 passed or were skipped).
#            1 = a difference, a failed check, or a crash.
#            2 = the test proved nothing (no build, a PUC run failed, too
#                few traces, an instrument check) -- but a FAIL recorded
#                anywhere keeps the run at 1.
# =====================================================================
set -u
# Neither VM may run code from the caller's environment before the scripts:
# LUA_INIT (LuaJIT, and PUC without the next) and LUA_INIT_5_3 (PUC 5.3).
unset LUA_INIT LUA_INIT_5_3
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${OCLJ_LUA53:=$OCLJ_REPO/bench/vendor/lua-5.3.6/src/lua.exe}"
: "${OCLJ_BITJIT_PARTS:=gen floor fix1}"
: "${OCLJ_BITJIT_SEED:=1}"
: "${OCLJ_BITJIT_SEEDS:=4}"
: "${OCLJ_BITJIT_CASES:=2000}"
: "${OCLJ_BITJIT_GENMODE:=}"
: "${OCLJ_BITJIT_HOTMIN:=0.25}"
: "${OCLJ_BITJIT_OUT:=$OCLJ_BUILD/bitjit-$(date -u +%Y%m%dT%H%M%SZ)}"

fail() { echo "BITJIT SETUP FAIL: $*" >&2; exit 2; }

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) OCLJ_OS=windows ; EXE=.exe ;;
  Linux)   OCLJ_OS=linux  ; EXE= ;;
  Darwin)  OCLJ_OS=darwin ; EXE= ;;
  *) fail "unsupported host system $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  OCLJ_ARCH=x86_64  ;;
  aarch64|arm64) OCLJ_ARCH=aarch64 ;;
  *) fail "unsupported machine $(uname -m)" ;;
esac
PLATFORM="$OCLJ_OS-$OCLJ_ARCH"
LJEXE=$OCLJ_BUILD/luajit-$PLATFORM/src/luajit$EXE
B=$SELF_DIR/bitop
[ -x "$LJEXE" ] || fail "no $LJEXE -- run build-native.sh first (on THIS platform)"
for f in gen.lua drv.lua t_rec.lua t_jit2.lua p4v.lua; do
  [ -f "$B/$f" ] || fail "no $B/$f"
done
for p in $OCLJ_BITJIT_PARTS; do
  case $p in gen|floor|fix1) ;; *) fail "OCLJ_BITJIT_PARTS: '$p' is not one of gen, floor, fix1" ;; esac
done
for v in "$OCLJ_BITJIT_SEED" "$OCLJ_BITJIT_SEEDS" "$OCLJ_BITJIT_CASES"; do
  case "$v" in *[!0-9]*|'') fail "OCLJ_BITJIT_SEED, _SEEDS and _CASES must be whole numbers" ;; esac
done
# Zero seeds or zero loops would compare nothing and pass.
[ "$OCLJ_BITJIT_SEEDS" -gt 0 ] && [ "$OCLJ_BITJIT_CASES" -gt 0 ] \
  || fail "OCLJ_BITJIT_SEEDS and OCLJ_BITJIT_CASES must be at least 1 (0 would test nothing and pass)"
case "$OCLJ_BITJIT_GENMODE" in ''|phi) ;; *) fail "OCLJ_BITJIT_GENMODE must be empty or phi" ;; esac
case "$OCLJ_BITJIT_HOTMIN" in
  0|0.[0-9]*|1) ;;
  *) fail "OCLJ_BITJIT_HOTMIN must be a fraction from 0 to 1, not '$OCLJ_BITJIT_HOTMIN'" ;;
esac
ours_v=$("$LJEXE" -v 2>&1)
case "$ours_v" in
  LuaJIT*) ;;
  *) fail "the build's interpreter reports '$ours_v', not LuaJIT" ;;
esac
[ -x "$OCLJ_LUA53" ] || OCLJ_LUA53=${OCLJ_LUA53%.exe}
REFV=
[ -x "$OCLJ_LUA53" ] && REFV=$("$OCLJ_LUA53" -v 2>&1)
case "$REFV" in "Lua 5.3.6"*) HAVEPUC=1 ;; *) HAVEPUC=0 ;; esac

[ -e "$OCLJ_BITJIT_OUT" ] && fail "$OCLJ_BITJIT_OUT exists; results are never overwritten"
mkdir -p "$OCLJ_BITJIT_OUT" || fail "cannot create $OCLJ_BITJIT_OUT"
OUT=$OCLJ_BITJIT_OUT
md5sum "$LJEXE" "$B/gen.lua" "$B/drv.lua" "$B/t_rec.lua" "$B/t_jit2.lua" "$B/p4v.lua" > "$OUT/inputs.md5"
[ "$HAVEPUC" = 1 ] && md5sum "$OCLJ_LUA53" >> "$OUT/inputs.md5"
# jit.vmdef and jit.util's names (p4v.lua) live beside the build's luajit.exe,
# in src/jit; the Windows exe needs a C:/ path.
LJDIR=$(dirname "$LJEXE"); command -v cygpath >/dev/null 2>&1 && LJDIR=$(cygpath -m "$LJDIR")
export LUA_PATH="$LJDIR/?.lua;;"
# A run that hangs is a failure, not a wait: 300 s is 100 times a default run.
TO=; command -v timeout >/dev/null 2>&1 && TO="timeout 300"

echo "run-bitjit: ours $LJEXE; PUC ${REFV:-not found}; parts $OCLJ_BITJIT_PARTS; results $OUT"
bad=0; nothing=0
wanted() { case " $OCLJ_BITJIT_PARTS " in *" $1 "*) return 0 ;; esac; return 1; }
# run <out> <err> <cmd...>: the command's stdout, CR-stripped, into <out>
# (Windows stdout writes CRLF); returns the command's exit status.
run() {
  o=$1; e=$2; shift 2
  $TO "$@" < /dev/null > "$o.raw" 2> "$e"
  rc=$?
  tr -d '\r' < "$o.raw" > "$o"; rm -f "$o.raw"
  return $rc
}
# ndiff <got> <want>: "<differing lines> <first ids>", counted both ways: the
# number is the larger of got's lines missing from want and want's lines
# missing from got, so it is 0 only when the files are identical (a short or
# empty got that exits 0 is a difference, review of 2026-10-17), and a line
# that differs counts once.  The ids are got's, or want's as missing:<id>
# when got has none of its own.
ndiff() {
  diff "$1" "$2" | awk -F'\t' '
    /^< / { a++; if (a <= 3) { id = $1; sub(/^< /, "", id); ida = ida " " id } }
    /^> / { b++; if (b <= 3) { id = $1; sub(/^> /, "", id); idb = idb " missing:" id } }
    END { n = a + 0; if (b + 0 > n) n = b + 0; ids = idb; if (a > 0) ids = ida; print n ids }'
}
# The JIT option sets (name:options; jon is the default).
GENOPTS="jon hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0 he1:-Ohotloop=1_-Ohotexit=1 noloop:-O3_-O-loop"
RECOPTS="jon hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0"
JIT2OPTS="jon O0:-O0 O1:-O1 hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0 he1:-Ohotloop=1_-Ohotexit=1"
optname() { echo "${1%%:*}"; }
optargs() { case $1 in *:*) echo "${1#*:}" | tr '_' ' ' ;; esac; }

# ---------------------------------------------------------------- 1
echo
echo "== 1. the generator: $OCLJ_BITJIT_SEEDS seeds x $OCLJ_BITJIT_CASES loops${OCLJ_BITJIT_GENMODE:+ ($OCLJ_BITJIT_GENMODE)}, five JIT option sets x two closure modes against -joff =="
if wanted gen; then
  [ "$HAVEPUC" = 1 ] || echo "PUC twin: SKIPPED (no PUC Lua 5.3.6 at $OCLJ_LUA53; ${REFV:-not found})"
  i=0
  while [ "$i" -lt "$OCLJ_BITJIT_SEEDS" ]; do
    s=$((OCLJ_BITJIT_SEED + i)); i=$((i + 1))
    D=$OUT/gen-s$s; mkdir -p "$D"
    if ! $TO "$LJEXE" "$B/gen.lua" "$s" "$OCLJ_BITJIT_CASES" "$D" $OCLJ_BITJIT_GENMODE < /dev/null > "$D/gen.log" 2>&1; then
      echo "seed $s: PROVED NOTHING -- gen.lua failed: $(head -c 300 "$D/gen.log")"; nothing=1; continue
    fi
    line="seed $s:"; sbad=0; snothing=0; detail=
    for m in shared fresh; do
      run "$D/$m-joff.txt" "$D/$m-joff.err" "$LJEXE" -joff "$B/drv.lua" "$D/cases_lj.lua" "$m"; rc=$?
      nl=$(grep -c . "$D/$m-joff.txt")
      if [ "$rc" -ne 0 ] || [ "$nl" -ne "$OCLJ_BITJIT_CASES" ]; then
        detail="$detail $m/joff exited $rc with $nl lines: $(head -c 200 "$D/$m-joff.err");"; sbad=1; continue
      fi
      for o in $GENOPTS; do
        n=$(optname "$o")
        run "$D/$m-$n.txt" "$D/$m-$n.err" "$LJEXE" $(optargs "$o") "$B/drv.lua" "$D/cases_lj.lua" "$m"; rc=$?
        set -- $(ndiff "$D/$m-$n.txt" "$D/$m-joff.txt")
        line="$line $m/$n=$1"
        [ "$rc" -ne 0 ] && { detail="$detail $m/$n exited $rc: $(head -c 200 "$D/$m-$n.err");"; sbad=1; }
        [ "$1" -ne 0 ] && { shift; detail="$detail $m/$n differs from -joff, first cases:$*;"; sbad=1; }
      done
      if [ "$HAVEPUC" = 1 ]; then
        run "$D/$m-puc.txt" "$D/$m-puc.err" "$OCLJ_LUA53" "$B/drv.lua" "$D/cases_puc.lua" "$m"; rc=$?
        set -- $(ndiff "$D/$m-puc.txt" "$D/$m-joff.txt")
        line="$line $m/puc=$1"
        if [ "$rc" -ne 0 ]; then
          detail="$detail PUC ($m) exited $rc: $(head -c 200 "$D/$m-puc.err");"; snothing=1
        elif [ "$1" -ne 0 ]; then
          shift; detail="$detail $m/puc: -joff differs from PUC 5.3.6 with U1-B's rule, first cases:$*;"; sbad=1
        fi
      fi
    done
    # Coverage: from -joff (runs, raises, raises past iteration 60) and from
    # the JIT-on shared run (cases with a completed trace).
    cj=$(grep '^#cov' "$D/shared-joff.err" 2>/dev/null)
    cn=$(grep '^#cov' "$D/shared-jon.err" 2>/dev/null)
    starts=$(echo "$cj" | sed -n 's/.* starts \([0-9]*\).*/\1/p')
    errs=$(echo "$cj" | sed -n 's/.* errors \([0-9]*\).*/\1/p')
    e60=$(echo "$cj" | sed -n 's/.* errors-past-60 \([0-9]*\).*/\1/p')
    traced=$(echo "$cn" | sed -n 's/.* traced \([0-9]*\).*/\1/p')
    case "$cn" in *"jit on"*) jit=on ;; *) jit=off ;; esac
    echo "$line"
    echo "    coverage: $OCLJ_BITJIT_CASES loops, ${starts:-?} runs, ${errs:-?} raised, ${e60:-?} after iteration 60; a trace completed in ${traced:-?} loops (JIT-on shared run, jit $jit)"
    if [ "$sbad" = 0 ] && [ "$snothing" = 0 ]; then
      if [ "$jit" != on ] || [ -z "$traced" ] || \
         ! awk -v t="$traced" -v n="$OCLJ_BITJIT_CASES" -v h="$OCLJ_BITJIT_HOTMIN" 'BEGIN { exit !(t >= h * n) }'; then
        detail="$detail traces completed in ${traced:-no} of $OCLJ_BITJIT_CASES loops (jit $jit), under OCLJ_BITJIT_HOTMIN $OCLJ_BITJIT_HOTMIN: the JIT was barely tested;"
        snothing=1
      fi
    fi
    if [ "$sbad" = 1 ]; then echo "seed $s: FAIL --$detail"; bad=1
    elif [ "$snothing" = 1 ]; then echo "seed $s: PROVED NOTHING --$detail"; nothing=1
    else echo "seed $s: PASS"; fi
  done
else
  echo "SKIPPED (not in OCLJ_BITJIT_PARTS)"
fi

# ---------------------------------------------------------------- 2
echo
echo "== 2. the floor: t_rec.lua and t_jit2.lua against -joff, t_jit2.lua against PUC 5.3.6 =="
if wanted floor; then
  D=$OUT/floor; mkdir -p "$D"
  for sm in 1: 2: 3:counts 4:counts; do
    s=${sm%%:*}; md=${sm#*:}; tag=rec-s$s${md:+-$md}
    run "$D/$tag-joff.txt" "$D/$tag-joff.err" "$LJEXE" -joff "$B/t_rec.lua" 400 "$s" $md; rc=$?
    nl=$(grep -c . "$D/$tag-joff.txt")
    if [ "$rc" -ne 0 ] || [ "$nl" -ne 400 ]; then
      echo "FAIL t_rec seed $s${md:+ ($md)}: -joff exited $rc with $nl lines: $(head -c 200 "$D/$tag-joff.err")"; bad=1; continue
    fi
    line="t_rec seed $s${md:+ ($md)}:"; tbad=0
    for o in $RECOPTS; do
      n=$(optname "$o")
      run "$D/$tag-$n.txt" "$D/$tag-$n.err" "$LJEXE" $(optargs "$o") "$B/t_rec.lua" 400 "$s" $md; rc=$?
      set -- $(ndiff "$D/$tag-$n.txt" "$D/$tag-joff.txt")
      line="$line $n=$1"
      [ "$rc" -ne 0 ] && { line="$line(exit $rc)"; tbad=1; }
      [ "$1" -ne 0 ] && { shift; line="$line[first:$*]"; tbad=1; }
    done
    # t_rec's runs: 5 starts a recurrence; a raise prints ERR@<iteration>.
    cov=$(awk -F'\t' '{ n = split($4, r, " [|] "); for (k = 1; k <= n; k++) { runs++
            if (r[k] ~ /^ERR@/) { e++; it = r[k]; sub(/^ERR@/, "", it); sub(/:.*$/, "", it); if (it + 0 > 60) e60++ } } }
            END { printf "%d runs, %d raised, %d after iteration 60", runs, e, e60 }' "$D/$tag-joff.txt")
    if [ "$tbad" = 0 ]; then echo "PASS $line  ($cov)"; else echo "FAIL $line  ($cov)"; bad=1; fi
  done
  run "$D/jit2-joff.txt" "$D/jit2-joff.err" "$LJEXE" -joff "$B/t_jit2.lua"; rc=$?
  if [ "$rc" -eq 2 ] && grep -q INSTRUMENT "$D/jit2-joff.txt"; then
    echo "PROVED NOTHING t_jit2:"; sed -n '/INSTRUMENT/,$p' "$D/jit2-joff.txt" | head -6 | sed 's/^/    /'; nothing=1
  elif [ "$rc" -ne 0 ]; then
    echo "FAIL t_jit2: -joff exited $rc: $(head -c 200 "$D/jit2-joff.err")"; bad=1
  else
    nt=$(grep -c . "$D/jit2-joff.txt")
    ne=$(grep -c 'ERR@' "$D/jit2-joff.txt")
    line="t_jit2 ($nt loops, $ne of them end in a raise):"; tbad=0
    for o in $JIT2OPTS; do
      n=$(optname "$o")
      run "$D/jit2-$n.txt" "$D/jit2-$n.err" "$LJEXE" $(optargs "$o") "$B/t_jit2.lua"; rc=$?
      set -- $(ndiff "$D/jit2-$n.txt" "$D/jit2-joff.txt")
      line="$line $n=$1"
      [ "$rc" -ne 0 ] && { line="$line(exit $rc)"; tbad=1; }
      [ "$1" -ne 0 ] && { shift; line="$line[$*]"; tbad=1; }
    done
    if [ "$tbad" = 0 ]; then echo "PASS $line"; else echo "FAIL $line"; bad=1; fi
    if [ "$HAVEPUC" = 1 ]; then
      run "$D/jit2-puc.txt" "$D/jit2-puc.err" "$OCLJ_LUA53" "$B/t_jit2.lua"; rc=$?
      awk -F'\t' '$1 != "sar"' "$D/jit2-joff.txt" > "$D/jit2-joff-nosar.txt"
      set -- $(ndiff "$D/jit2-puc.txt" "$D/jit2-joff-nosar.txt")
      if [ "$rc" -ne 0 ]; then
        echo "PROVED NOTHING t_jit2 on PUC: exited $rc: $(head -c 300 "$D/jit2-puc.txt") $(head -c 200 "$D/jit2-puc.err")"; nothing=1
      elif [ "$1" -eq 0 ]; then
        echo "PASS t_jit2: PUC 5.3.6 with U1-B's rule equals -joff in all $(grep -c . "$D/jit2-puc.txt") loops it runs (all but sar)"
      else
        nd=$1; shift; echo "FAIL t_jit2: PUC 5.3.6 with U1-B's rule differs from -joff in $nd loops, first:$*"; bad=1
      fi
    else
      echo "t_jit2 on PUC: SKIPPED (no PUC Lua 5.3.6 at $OCLJ_LUA53; ${REFV:-not found})"
    fi
  fi
else
  echo "SKIPPED (not in OCLJ_BITJIT_PARTS)"
fi

# ---------------------------------------------------------------- 3
echo
echo "== 3. fix1: the p4 loops compile (bitop/p4v.lua) =="
if wanted fix1; then
  D=$OUT/fix1; mkdir -p "$D"
  run "$D/p4v-jon.txt" "$D/p4v-jon.err" "$LJEXE" "$B/p4v.lua"; rj=$?
  run "$D/p4v-joff.txt" "$D/p4v-joff.err" "$LJEXE" -joff "$B/p4v.lua"; rf=$?
  sed 's/^/    /' "$D/p4v-jon.txt"
  # The results (the x= y= field) against -joff's.
  cut -f1,2 "$D/p4v-jon.txt" | grep -v '^p4v:' > "$D/p4v-jon-res.txt"
  cut -f1,2 "$D/p4v-joff.txt" > "$D/p4v-joff-res.txt"
  nres=$(grep -c . "$D/p4v-joff-res.txt")
  if [ "$rj" -eq 2 ]; then
    echo "PROVED NOTHING fix1: $(grep INSTRUMENT "$D/p4v-jon.txt" | head -c 300) $(head -c 200 "$D/p4v-jon.err")"; nothing=1
  elif [ "$rf" -ne 0 ] || [ "$nres" -ne 8 ]; then
    echo "FAIL fix1: -joff exited $rf with $nres results: $(head -c 200 "$D/p4v-joff.err")"; bad=1
  elif ! cmp -s "$D/p4v-jon-res.txt" "$D/p4v-joff-res.txt"; then
    echo "FAIL fix1: compiled results differ from -joff's:"; diff "$D/p4v-jon-res.txt" "$D/p4v-joff-res.txt" | sed 's/^/    /'; bad=1
  elif [ "$rj" -ne 0 ]; then
    echo "FAIL fix1: $(grep -c FAILED "$D/p4v-jon.txt") of 8 p4 loops aborted with type instability, were blacklisted, or never compiled (exit $rj)"; bad=1
  else
    echo "PASS fix1: all 8 p4 loops compiled (no type-instability abort, none blacklisted), results equal -joff's"
  fi
else
  echo "SKIPPED (not in OCLJ_BITJIT_PARTS)"
fi

echo
sel=; [ "$OCLJ_BITJIT_PARTS" != "gen floor fix1" ] && sel=" (parts run: $OCLJ_BITJIT_PARTS; the others prove nothing here)"
if [ "$bad" = 1 ]; then echo "RUN-BITJIT: FAIL$sel (results: $OUT)"; exit 1; fi
if [ "$nothing" = 1 ]; then echo "RUN-BITJIT: PROVED NOTHING$sel (results: $OUT)"; exit 2; fi
echo "RUN-BITJIT: PASS$sel (results: $OUT)"
exit 0
