#!/bin/sh
# run.sh -- runs the shift-exactness checks, model.py and jitcheck.lua, into a
# fresh results directory.  Written 2026-10-23 under
# claude-tmp/oclj/shiftexact/checks/ (the checks part of the shift-exactness
# round); revised the same day for the refute part's findings F4 (an exit
# status 1 was read as a counterexample without reading the verdict line)
# and F5 (the documented launch line could not start: its log's directory
# did not exist).  Revised again the same day (revision 3) for the review of
# the revised checks, its findings 2 (a JIT set's stdout was compared with
# -joff's whatever either run's exit, so a timeout, a crash or an
# incomplete reference read FAIL), 7 (git status took the repo's optional
# index lock) and 8 (the header understated the refusals that write no done,
# and a failed cd into R left OUT empty, so no done was written though R
# existed).  NOT RUN when written or revised.
#
# WHO RUNS IT, AND WHEN: the main session, from Git Bash, and only when no
# timed benchmark runs on this machine (at the round's start the user was
# timing in Minecraft here).  It is value-level only and times nothing, so
# load changes its duration, not its verdict; it may take a few minutes [I],
# so run it detached (CLAUDE.md: chains longer than a minute run from the
# main session, nohup plus a monitor), naming a results directory that does
# not exist yet:
#   R=/c/Users/astro/claude-tmp/oclj/shiftexact/checks/runs/run-1
#   [ -e "$R" ] && echo "$R exists: name another"      (must print nothing)
#   nohup sh /c/Users/astro/claude-tmp/oclj/shiftexact/checks/run.sh "$R" > /dev/null 2>&1 &
# then wait until "$R/done" exists (Git Bash has no pgrep, P58), with a time
# bound on the wait; done holds the exit status.  run.sh creates R's parent
# (checks/runs/ above) and R itself, refuses an R that exists (it never
# writes into one), and writes its own log, everything it prints, into
# "$R/run.log".
# THE REFUSALS THAT WRITE NO DONE AND NO LOG, all six before this run has
# made R: (1) the script's own directory cannot be found; (2) more than one
# argument; (3) an empty results directory name (such as "/", which loses
# its slash); (4) R exists, made by anyone (run.sh never writes into an R it
# did not make); (5) R's parent cannot be made; (6) R cannot be made, or
# appeared meanwhile.  Their message goes to the caller's stderr, which the
# launch above discards: hence the check before it, and the time bound on
# the wait.  Once run.sh has made R, every refusal writes 2 into done and
# its message into summary.txt, as far as R can be written: when R cannot
# be entered, or run.log cannot be created in it, done may be unwritable
# too, and the wait's time bound is what ends the wait.
# Without an argument the results go to
# checks/runs/run-<UTC date-time>-<pid>.  Results are never overwritten,
# reused or cleared.  model.py, jitcheck.lua and this script are copied
# into <results>/inputs/ first and the copies of the first two run; never
# edit this script while it runs (P17).
#
# WHAT IT RUNS, from <results> as the working directory, each command's
# stdout and stderr CR-stripped (P18) into files of their own (P57), the raw
# bytes kept beside them as *.raw:
#   model.out, model.err    python -I model.py <model nrand> <seed>
#   jc-<set>.out, .err, .rc luajit <options> jitcheck.lua <jit nrand> <seed>
#                           for each option set (SE_SETS, name:options with _
#                           for a space; P35: levels before flags):
#                             joff    -joff, the reference
#                             jon     the defaults
#                             hl1     -O3 -Ohotloop=1
#                             ms0     -Omaxside=0
#                             he1     -Ohotloop=1 -Ohotexit=1
#                             noloop  -O3 -O-loop
#                             nofold  -O3 -O-fold (no fold rule runs)
#   run.log       everything run.sh prints, the summary at its end
#   env.txt       date, host, repo HEAD, the repo's status line count (git
#                 status run with GIT_OPTIONAL_LOCKS=0, so that it never
#                 takes the index lock in the user's repo), luajit -v,
#                 python -V, knobs, LUA_PATH
#   inputs.md5    the copies of the three scripts, luajit.exe, the python
#                 executable, and beside luajit.exe: jit/vmdef.lua,
#                 lj_opt_fold.o, lj_record.o, lj_asm.o, lj_vm.o, libluajit.a
#                 (the JIT guide names builds by lj_opt_fold.o's md5)
#   summary.txt   the verdicts and each run's summary lines, among them each
#                 JIT set's "#cov probe", "#cov part" and "#cov measured"
#                 lines
#   done          the exit status
# THE VERDICT (summary.txt's last line; done's number; the exit status):
#   PASS (0): model.py exits 0 with VERDICT PASS; jc-joff exits 0 with
#     "verdict PASS" and "#cov verdict jit off"; every other set exits 0
#     with stdout byte-identical to jc-joff's, "#cov verdict ok" (the JIT on,
#     each part traced in at least half its cases, the sguard gates met,
#     the controls' result guards seen leaving through attributable
#     snapshots, no lemma part's result guard leaving, the probe untraced)
#     and "#cov measured result guards never failed in the lemma parts:
#     YES".
#   FAIL (1): model.py exits 1 AND its last line is "VERDICT FAIL" (a
#     counterexample to L1, L2, L3 BSHL10 or L4 BAND); a jitcheck run exits
#     1 AND its stdout's last line is "verdict FAIL" (a lemma part, the
#     probe or a control failed by value) or its stderr's "#cov verdict"
#     line is "#cov verdict FAIL" (a lemma part's result guard left); or a
#     JIT set's stdout differs from -joff's, which is compared only when
#     both are complete value verdicts: jc-joff exited 0 with "verdict PASS"
#     as its last line, and the set's last line is "verdict PASS" or
#     "verdict FAIL ...".  A set whose stdout ends otherwise (a timeout, a
#     crash, an uncaught error: no verdict line; or an instrument's early
#     stop such as "verdict INSTRUMENT no jit.vmdef ..."), or a reference
#     that is not a clean PASS, is not compared: PROVED NOTHING, never FAIL.
#   PROVED NOTHING (2): anything else: an instrument, a control that found
#     nothing, coverage, an exit 1 without a FAIL verdict line (an uncaught
#     error: Python and luajit exit 1 on one), a timeout, a missing input,
#     a stdout not compared.
# KNOBS (environment, each optional): SE_LJEXE (default the build's
# luajit.exe), SE_PY (python), SE_MODEL_NRAND (200), SE_JIT_NRAND (24),
# SE_SEED (20261023, for both scripts), SE_SETS (the list above).
# It unsets LUA_INIT and its versioned names (P22) and sets LUA_PATH to the
# build's src/?.lua, as run-bitjit.sh does, so that jit.vmdef loads.
set -u

fail() {
  echo "run.sh: $*" >&2
  if [ -n "${OUT:-}" ] && [ -d "$OUT" ]; then
    echo "run.sh: $*" >> "$OUT/summary.txt"
    echo 2 > "$OUT/done"
  fi
  exit 2
}

OUT=
HERE=$(cd "$(dirname "$0")" && pwd -P) || fail "cannot find the script's directory"
[ $# -le 1 ] || fail "usage: run.sh [results-directory]"

# 1. The results directory, before anything else that can fail, so that
# every later failure writes done and its message into summary.txt (and
# into run.log once it is open).  Until mkdir "$RES" succeeds OUT stays
# empty, so fail() writes nothing into an R this run did not make
# (refusals 1 to 6 of the header).
if [ $# -ge 1 ]; then RES=${1%/}; else RES=$HERE/runs/run-$(date -u +%Y%m%d-%H%M%S)-$$; fi
[ -n "$RES" ] || fail "an empty results directory"
[ -e "$RES" ] && fail "$RES exists; results are never overwritten or reused"
PARENT=$(dirname "$RES")
mkdir -p "$PARENT" || fail "cannot create $PARENT"
mkdir "$RES" || fail "cannot create $RES (or it appeared meanwhile)"
# R is this run's own from here: fail() writes done into it.  OUT holds R as
# given (relative to the unchanged working directory) until its physical
# path is known; a failed command substitution would assign OUT an empty
# string, so the path goes through OUTP.
OUT=$RES
OUTP=$(cd "$RES" && pwd -P) || fail "cannot enter $RES"
OUT=$OUTP
# The log is created by a subshell first: a failed redirection on exec
# would end a POSIX-mode shell (Git Bash's sh is bash in POSIX mode [I])
# before fail() could run.
( : > "$OUT/run.log" ) 2>/dev/null || fail "cannot create $OUT/run.log"
exec > "$OUT/run.log" 2>&1
echo "run.sh: results $OUT; pid $$; started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir "$OUT/inputs" || fail "cannot create $OUT/inputs"
IN=$OUT/inputs

# 2. The knobs and the inputs.
REPO=/c/Users/astro/Downloads/OC-LuaJIT
LJEXE=${SE_LJEXE:-$REPO/build/native/luajit-windows-x86_64/src/luajit.exe}
PY=${SE_PY:-python}
MNRAND=${SE_MODEL_NRAND:-200}
JNRAND=${SE_JIT_NRAND:-24}
SEED=${SE_SEED:-20261023}
SETS=${SE_SETS:-"joff:-joff jon hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0 he1:-Ohotloop=1_-Ohotexit=1 noloop:-O3_-O-loop nofold:-O3_-O-fold"}

for v in "$MNRAND" "$JNRAND" "$SEED"; do
  case "$v" in *[!0-9]*|'') fail "SE_MODEL_NRAND, SE_JIT_NRAND and SE_SEED must be whole numbers" ;; esac
done
[ "$SEED" -ge 1 ] && [ "$SEED" -le 2147483646 ] || fail "SE_SEED must be from 1 to 2147483646 (jitcheck.lua's generator)"
[ "$JNRAND" -le 10000 ] || fail "SE_JIT_NRAND must be at most 10000"
[ "$MNRAND" -le 100000 ] || fail "SE_MODEL_NRAND must be at most 100000"
case " $SETS " in *" joff:-joff "*) ;; *) fail "SE_SETS must hold joff:-joff, the reference" ;; esac
[ -f "$LJEXE" ] || fail "no luajit at $LJEXE"
for f in model.py jitcheck.lua run.sh; do
  [ -f "$HERE/$f" ] || fail "no $HERE/$f"
done
PYP=$(command -v "$PY") || fail "no python ($PY)"
cp "$HERE/model.py" "$HERE/jitcheck.lua" "$HERE/run.sh" "$IN/" || fail "cannot copy the inputs into $IN"

unset LUA_INIT LUA_INIT_5_1 LUA_INIT_5_2 LUA_INIT_5_3 LUA_PATH_5_3 LUA_CPATH LUA_CPATH_5_3
LJDIR=$(dirname "$LJEXE")
LJDIRW=$LJDIR
command -v cygpath >/dev/null 2>&1 && LJDIRW=$(cygpath -m "$LJDIR")
LUA_PATH="$LJDIRW/?.lua;;"
export LUA_PATH
TO=
command -v timeout >/dev/null 2>&1 && TO="timeout 1800"
cd "$OUT" || fail "cannot enter $OUT"

{
  md5sum "$IN/model.py" "$IN/jitcheck.lua" "$IN/run.sh" "$LJEXE" "$PYP"
  for f in "$LJDIR/jit/vmdef.lua" "$LJDIR/lj_opt_fold.o" "$LJDIR/lj_record.o" "$LJDIR/lj_asm.o" "$LJDIR/lj_vm.o" "$LJDIR/libluajit.a"; do
    if [ -f "$f" ]; then md5sum "$f"; else echo "absent $f"; fi
  done
} > inputs.md5 2>&1
{
  echo "date $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host $(uname -a)"
  echo "repo HEAD $(git -C "$REPO" rev-parse HEAD 2>&1)"
  # git is an external command, so the one-command assignment stays with
  # it (CLAUDE.md's rule is about shell functions); it keeps git status from
  # taking the index lock in the user's repo.
  echo "repo status lines $(GIT_OPTIONAL_LOCKS=0 git -C "$REPO" status --porcelain 2>/dev/null | wc -l)"
  echo "luajit $LJEXE: $("$LJEXE" -v 2>&1 | tr -d '\r')"
  echo "python $PYP: $("$PY" -V 2>&1 | tr -d '\r')"
  echo "knobs model_nrand $MNRAND jit_nrand $JNRAND seed $SEED"
  echo "sets $SETS"
  echo "LUA_PATH $LUA_PATH"
  echo "timeout ${TO:-none}"
} > env.txt

# run <out> <err> <cmd...>: stdout and stderr CR-stripped into their files,
# the raw bytes kept; returns the command's exit status.
run() {
  o=$1; e=$2; shift 2
  $TO "$@" < /dev/null > "$o.raw" 2> "$e.raw"
  rc=$?
  tr -d '\r' < "$o.raw" > "$o"
  tr -d '\r' < "$e.raw" > "$e"
  return $rc
}
say() { echo "$*" >> summary.txt; }
# jcfail <set>: true when jitcheck run <set>'s exit 1 carries a FAIL verdict,
# on stdout's last line or on stderr's "#cov verdict" line (F4).
jcfail() {
  jl=$(tail -n 1 "jc-$1.out")
  jv=$(grep '^#cov verdict' "jc-$1.err" | tail -n 1)
  case "$jl" in "verdict FAIL"*) return 0 ;; esac
  case "$jv" in "#cov verdict FAIL"*) return 0 ;; esac
  return 1
}

say "run.sh: results $OUT; started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
fails=
nothing=

# 3. model.py
run model.out model.err "$PY" -I "$IN/model.py" "$MNRAND" "$SEED"
mrc=$?
mlast=$(tail -n 1 model.out)
say "model.py: exit $mrc; $mlast"
grep -E '^(model total|sweep64|instrument|LEMMA|control)' model.out >> summary.txt
case "$mrc" in
  0) case "$mlast" in "VERDICT PASS"*) ;; *) nothing="$nothing model.py(exit 0 without VERDICT PASS)" ;; esac ;;
  1) case "$mlast" in
       "VERDICT FAIL"*) fails="$fails model.py" ;;
       *) nothing="$nothing model.py(exit 1 without VERDICT FAIL: an uncaught error? see model.err)" ;;
     esac ;;
  *) nothing="$nothing model.py(exit $mrc)" ;;
esac

# 4. jitcheck.lua under each option set
nsets=0
for s in $SETS; do
  n=${s%%:*}
  a=
  case "$s" in *:*) a=$(echo "${s#*:}" | tr '_' ' ') ;; esac
  run "jc-$n.out" "jc-$n.err" "$LJEXE" $a "$IN/jitcheck.lua" "$JNRAND" "$SEED"
  echo $? > "jc-$n.rc"
  nsets=$((nsets + 1))
done

# 5. the verdicts: -joff first, then every JIT set against it
jrc=$(cat jc-joff.rc)
jlast=$(tail -n 1 jc-joff.out)
jcov=$(grep '^#cov verdict' jc-joff.err | tail -n 1)
say "jitcheck joff: exit $jrc; $jlast; $jcov"
grep -E '^(jitcheck|instrument|selftest|probe|part) ' jc-joff.out >> summary.txt
case "$jrc" in
  0) case "$jlast|$jcov" in
       "verdict PASS|#cov verdict jit off") ;;
       *) nothing="$nothing joff($jlast; $jcov)" ;;
     esac ;;
  1) if jcfail joff; then
       fails="$fails joff"
     else
       nothing="$nothing joff(exit 1 without a FAIL verdict: an uncaught error? see jc-joff.err)"
     fi ;;
  *) nothing="$nothing joff(exit $jrc)" ;;
esac
# The reference for the stdout comparison: jc-joff's stdout, only when it
# exited 0 with "verdict PASS" as its last line (review finding 2).
refok=no
if [ "$jrc" = 0 ] && [ "$jlast" = "verdict PASS" ]; then refok=yes; fi
for s in $SETS; do
  n=${s%%:*}
  [ "$n" = joff ] && continue
  rc=$(cat "jc-$n.rc")
  cv=$(grep '^#cov verdict' "jc-$n.err" | tail -n 1)
  ms=$(grep '^#cov measured' "jc-$n.err" | tail -n 1)
  last=$(tail -n 1 "jc-$n.out")
  # Compared only when the set's stdout is complete: it passed every early
  # stop (it holds the "selftest comparator" line) and ends with a verdict
  # line, PASS, FAIL or a final INSTRUMENT (re-review finding 4).  No verdict
  # line (a timeout, a crash, an uncaught error) or an early INSTRUMENT stop
  # (such as no jit.vmdef) is not compared.
  setok=no
  case "$last" in
    "verdict "*) if grep -q '^selftest comparator' "jc-$n.out"; then setok=yes; fi ;;
  esac
  if [ "$refok" = yes ] && [ "$setok" = yes ]; then
    if cmp -s "jc-$n.out" jc-joff.out; then same=same; else same=DIFFERS; fi
    say "jitcheck $n: exit $rc; stdout $same as -joff's; $cv"
  else
    same=uncompared
    why=
    [ "$refok" = yes ] || why="-joff's stdout is not a clean PASS"
    [ "$setok" = yes ] || why="${why:+$why; }its stdout is incomplete (no selftest line, or no final verdict line; last line: ${last:-none})"
    say "jitcheck $n: exit $rc; stdout not compared with -joff's ($why); $cv"
    nothing="$nothing $n(stdout not compared: $why)"
  fi
  grep -E '^#cov (probe|part|measured)' "jc-$n.err" | sed "s/^/    $n /" >> summary.txt
  if [ "$same" = DIFFERS ]; then
    fails="$fails $n(differs from -joff)"
    diff jc-joff.out "jc-$n.out" | head -n 20 >> summary.txt
  fi
  case "$rc" in
    0) if [ "$cv" != "#cov verdict ok" ]; then
         nothing="$nothing $n($cv)"
       else
         case "$ms" in
           "#cov measured result guards never failed in the lemma parts: YES"*) ;;
           *) nothing="$nothing $n(#cov verdict ok without the measured line's YES)" ;;
         esac
       fi ;;
    1) if jcfail "$n"; then
         fails="$fails $n"
       else
         nothing="$nothing $n(exit 1 without a FAIL verdict: an uncaught error? see jc-$n.err)"
       fi ;;
    *) nothing="$nothing $n(exit $rc; $cv)" ;;
  esac
done

if [ -n "$fails" ]; then
  V="FAIL:$fails"
  [ -n "$nothing" ] && V="$V (and proved nothing:$nothing)"
  code=1
elif [ -n "$nothing" ]; then
  V="PROVED NOTHING:$nothing"
  code=2
else
  V="PASS: model.py's lemmas (L1 shl, L2 sar, L3 BSHL10, L4 BAND) hold and its controls fail where they must; jitcheck passes under every one of the $nsets option sets, -joff among them, each compiled run's stdout identical to -joff's, and in each compiled run no result guard of a lemma part left (the controls' did, through snapshots holding only result and operand guards) and the jit.off'd probe read untraced"
  code=0
fi
say "finished $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "VERDICT $V"
echo "$code" > done
cat summary.txt
exit $code
