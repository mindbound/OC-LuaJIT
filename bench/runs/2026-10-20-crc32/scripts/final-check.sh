#!/bin/sh
# final-check.sh <fresh outdir> -- the final check of the CRC32 follow-up
# (roadmap row 209) as the repo's working tree holds it: fold a, the
# table-index fold (native/luajit/patch-bitop-fold.sh hunk 11), its tests
# (test/native/bitop/twin.lua, t_idx.lua, t_cnt33.lua, t_idx2.lua,
# phiidx.lua, t_rg2.lua, gen.lua's idx and rg2 modes, run-bitjit.sh's idx
# part, negctl-bitop.sh's 30 arms), and whatever else the working tree
# changes (the docs).  rg2, the range guard, does not ship.  For the MAIN
# SESSION, from Git Bash, on a quiet machine (its last part times):
#
#   nohup sh /c/Users/astro/claude-tmp/oclj/crc2/fix/final-check.sh <outdir> > <outdir>.log 2>&1 &
#
# and a monitor on <outdir>/ALL.done.  About 35 minutes (estimated from
# the parts' smoke and single runs, 2026-10-20: the negctl sweep about 12,
# timing about 6, census twice 2-4, AlmaLinux 8 about 4, the rest about 6).
#
# The fixer's version (crc2/fix, 2026-10-20) of crc2/impl/final-check.sh
# (md5 41d1c407): the inside-repo refusal compares directories by identity
# ([ -ef ] on every ancestor) and lower-cased spellings, where the first
# compared spellings and let /c/users/.../oc-luajit/x through (verify-code
# F1); FC_USE_BUILD inside the repo is refused (F2: the runners and negctl
# write into it); the WSL drive letter is lower-cased (F2: /mnt/C is not
# mounted); git diff --check runs against HEAD, so staged changes count;
# fc-summarize.py fails a PUC difference it does not expect.
#
# It refuses an outdir that exists or lies inside the repo, and an
# FC_USE_BUILD inside the repo (exit 97), before it creates anything; then a
# running java or javaw (exit 96, Minecraft); the timing part also stops
# between rounds if one appears (STOPPED, a FAIL line).  Everything it
# writes is under <outdir> (and, with FC_USE_BUILD, in that build): fresh
# OCLJ_BUILDs <outdir>/b/win and
# <outdir>/alma/b (additive, the variant build/native holds), every exit
# code in <outdir>/rc/ (and <outdir>/alma/rc/), one PASS, FAIL or SKIP line
# per check in <outdir>/summary.txt, and <outdir>/ALL.done last.  It never
# writes under the repo (the runners write into the fresh OCLJ_BUILD), never
# changes prototype/watchdog/luajit (read by the pinned builds), and runs its
# Linux parts by invoking itself in WSL (MSYS_NO_PATHCONV=1 wsl.exe -d
# AlmaLinux-8 -- env ... sh /mnt/c/.../final-check.sh --alma <outdir>),
# reading their exit codes from the files they write.
#
# PARTS (FC_PARTS, default all, in this order; the census and the start and
# end md5s always run):
#   build    Windows build-native.sh into <outdir>/b/win: rc 0, the pin met,
#            the export verified, nothing ignored from the environment, the
#            patch line (63 added, 8 removed); 77 LuaJIT objects of which only
#            lj_opt_fold.o differs from build/native's, ours (3) equal; that
#            lj_opt_fold.o is the implementer's (1d018acc...)
#   alma     AlmaLinux 8, OCLJ_GLIBC_MAX=2.28: the same against build/native's
#            Linux tree (lj_opt_fold.o 33a2cc50...), GLIBC needed <= 2.28;
#            run-bitjit.sh, all four parts, with the Linux PUC; the generator
#            in its idx and rg2 modes (seeds 1-4); sh -n of every changed
#            shell script and this one there, and in Ubuntu's dash
#   bitjit   run-bitjit.sh, all four parts, PUC set; the generator in its idx
#            and rg2 modes (seeds 1-4) and phi mode (seeds 201-204)
#   suites   run-bitop.sh and run-bitfuzz.sh
#   negctl   the FULL negctl-bitop.sh sweep, one call: canon, 30 arms, restore
#   runners  the other native runners that link libluajit.a (its JIT and the
#            new lj_opt_fold.o): run.sh, run-mem.sh, run-vgc.sh, run-wd.sh,
#            run-penalty.sh, run-race.sh, run-security.sh, run-pack.sh,
#            run-packfuzz.sh (about 40 s together).  Not run: negctl-pack.sh
#            (its arms change oclj_strpack.c only, its objects are unchanged
#            here, and its catchers, run-pack.sh and run-packfuzz.sh, run
#            above on this build), negative-control.sh (the shim's
#            security_test teeth: no object it rebuilds changed), and
#            smoke-test.sh (it starts a JVM, which the timing part forbids)
#   gen      the generator's identity: the working tree's gen.lua writes, byte
#            for byte, what HEAD's wrote (default and phi modes),
#            proto-folda's (idx) and proto-rg2's (rg2), several seeds each
#   hygiene  0 CR bytes in every changed file; git diff --check HEAD, and
#            its --no-index form for each new file; sh -n in Git Bash (and the
#            alma part's AlmaLinux 8 and Ubuntu results); the hunk engine of
#            all seven patch-bitop-*.sh unchanged (077d1dbe...);
#            build-native.sh unchanged (47b9c52e...); patch-bitop-fold.sh
#            without tabs or backslashes, and run on the pin's pristine blob
#            (git cat-file): 63 added, 8 removed, the build copy's bytes,
#            idempotent
#   timing   LAST: base (crc/combine/b-base, HEAD eb47daf's tree), new
#            (<outdir>/b/win), round 2's b0 (times only: its results differ
#            by design) and PUC 5.3.6, FC_ROUNDS rounds (default 7), the
#            order rotated by one each round; crc/combine/timing-chain.sh's
#            benches (copied into <outdir>/timing/bench, md5s checked against
#            the main session's chain-1 inputs), b0 running bench_bit.lua and
#            bench_bit2.lua only; fc-summarize.py (beside this script, copied
#            in): ratios to base in the same round, every result of new equal
#            to base's
#
# KNOBS, for smoke runs and fail-firsts only (ALL.done names them):
#   FC_PARTS=<list>       the parts to run
#   FC_USE_BUILD=<dir>    skip the Windows build and use this OCLJ_BUILD
#                         (the build part's checks then judge that build;
#                         the runners and negctl write into it, so it must
#                         lie outside the repo, and is best a copy)
#   FC_TASKLIST=<cmd>     the process lister instead of tasklist (a stand-in
#                         that prints a javaw.exe line proves the refusal)
#   FC_ROUNDS=<n>         timing rounds (default 7)
#   FC_NDIV=<n>           divide every bench's N (default 1; at any other
#                         value the timing part's fold check says SKIP)
# Written with a file tool; no heredocs, and no backslashes at all.
set -u
R=/c/Users/astro/Downloads/OC-LuaJIT
WSL_REPO=/mnt/c/Users/astro/Downloads/OC-LuaJIT
PL=$R/prototype/watchdog/luajit
PLW=C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit
BN=$R/build/native
BASE=/c/Users/astro/claude-tmp/oclj/crc/combine/b-base
B0=/c/Users/astro/claude-tmp/oclj/r3/synth/b0/build/native/luajit-windows-x86_64/src/luajit.exe
BENCH_SRC=/c/Users/astro/claude-tmp/oclj/crc/combine/bench
CHAIN_INPUTS=/c/Users/astro/claude-tmp/oclj/crc/main/chain-1/inputs.md5
GEN_FOLDA=/c/Users/astro/claude-tmp/oclj/crc/folda/repo/test/native/bitop/gen.lua
GEN_RG2=/c/Users/astro/claude-tmp/oclj/crc/rg2/repo/test/native/bitop/gen.lua
PUCW=C:/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/lua.exe
PUCL=/mnt/c/Users/astro/claude-tmp/oclj/puc536-alma/lua
TOOLS=/c/Users/astro/claude-tmp/oclj/bin
JNIW="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include"
JNLUAW=C:/Users/astro/Downloads/OC-JNLua
FOLD_O_WIN=1d018acc8b2ce53076dfbb2e63aa5cdd
FOLD_O_LINUX=33a2cc50e40803c75555753124faa06f
ENGINE_MD5=077d1dbebe056d59691d7f7f93307b2d
BN_SH_MD5=47b9c52eecce550b57871d8448593bc3
PATCHLINE='the table-index fold (63 lines added, 8 removed, of 2708)'
ARMS30='BCDUMP ERROPERAND FIX1 INEXACT-BNOT INEXACT-FOLD INEXACT-INTERP INEXACT-JIT INEXACT-SLOW KFOLD64 NARROW NEGSHIFT NOINT-FOLD NOINT-JIT NOLOOPFOLD PHIIDX RANGE-HI SARCONST SARSHR SELFGUARD SHIFTMASK STRCOERCE WADD0 WBAND WIDTH55 WIDTHIDX33 WORDTOKEN WRAP32-FOLD WRAP32-INTERP WSHL0 WSHR'
# Nothing from the caller's environment steers a runner.
unset LUA_INIT LUA_INIT_5_3 LUA_INIT_5_2 LUA_PATH LUA_CPATH OCLJ_REPO OCLJ_LUA53
unset OCLJ_BITJIT_PARTS OCLJ_BITJIT_SEED OCLJ_BITJIT_SEEDS OCLJ_BITJIT_CASES OCLJ_BITJIT_GENMODE OCLJ_BITJIT_HOTMIN OCLJ_BITJIT_OUT
unset OCLJ_NEGCTL_ARMS NEGCTL_GEN_SEEDS NEGCTL_FUZZ_CASES OCLJ_BITOP_OUT OCLJ_BITFUZZ_OUT OCLJ_LUAJIT_UNPINNED

# objcmp <build A> <build B> <platform> <out prefix>: 0 iff both hold 77
# LuaJIT objects of the same names, only lj_opt_fold.o differs, and our 3
# objects (obj-<platform>) are equal.
objcmp() {
  ( cd "$1/luajit-$3/src" && md5sum *.o host/*.o ) | tr -d '*' | LC_ALL=C sort -k2 > "$4.A-lj.md5"
  ( cd "$2/luajit-$3/src" && md5sum *.o host/*.o ) | tr -d '*' | LC_ALL=C sort -k2 > "$4.B-lj.md5"
  ( cd "$1/obj-$3" && md5sum *.o ) | tr -d '*' | LC_ALL=C sort -k2 > "$4.A-obj.md5"
  ( cd "$2/obj-$3" && md5sum *.o ) | tr -d '*' | LC_ALL=C sort -k2 > "$4.B-obj.md5"
  diff "$4.A-lj.md5" "$4.B-lj.md5" > "$4.lj.diff"
  oc_a=$(grep -c '^<' "$4.lj.diff"); oc_b=$(grep -c '^>' "$4.lj.diff")
  oc_n=$(grep '^[<>]' "$4.lj.diff" | awk '{ print $3 }' | LC_ALL=C sort -u | awk '{ printf "%s ", $0 }')
  echo "LuaJIT objects $(wc -l < "$4.A-lj.md5" | tr -d ' ')/$(wc -l < "$4.B-lj.md5" | tr -d ' '); differing: $oc_n($oc_a/$oc_b lines); ours $(wc -l < "$4.A-obj.md5" | tr -d ' ')" > "$4.txt"
  [ "$(wc -l < "$4.A-lj.md5" | tr -d ' ')" = 77 ] && [ "$(wc -l < "$4.B-lj.md5" | tr -d ' ')" = 77 ] &&
    [ "$oc_a" = 1 ] && [ "$oc_b" = 1 ] && [ "$oc_n" = "lj_opt_fold.o " ] &&
    cmp -s "$4.A-obj.md5" "$4.B-obj.md5" && [ "$(wc -l < "$4.A-obj.md5" | tr -d ' ')" = 3 ]
}
# crcount <file>: its CR bytes (od, so that no backslash is needed).
crcount() { od -An -tx1 -v "$1" | tr ' ' '|' | grep -o '|0d' | wc -l | tr -d ' '; }
bytecount() { od -An -tx1 -v "$2" | tr ' ' '|' | grep -o "|$1" | wc -l | tr -d ' '; }
engine() { sed -n '/^# --- THE HUNK ENGINE/,/^# --- end of the hunk engine/p' "$1" | md5sum | cut -c1-32; }
# glibcmax <file>: x of the highest GLIBC_2.x a build log says the library needs.
glibcmax() { awk '{ if (match($0, /highest version needed GLIBC_2[.][0-9]+/)) { print substr($0, RSTART + 31, RLENGTH - 31); exit } }' "$1" 2>/dev/null; }

# --------------------------------------------------------------- the Linux parts (in WSL)
alma_part() {  # alma_part <outdir, WSL form>
  A=$1/alma
  mkdir "$A" || exit 98
  mkdir -p "$A/rc" || exit 98
  { uname -a; gcc --version | head -1; readlink -f /bin/sh; } > "$A/host.txt" 2>&1
  : > "$A/shn.txt"
  while read -r f; do
    case $f in *.sh) sh -n "$WSL_REPO/$f" > /dev/null 2>&1; echo "$? $f" >> "$A/shn.txt" ;; esac
  done < "$1/changed-files.txt"
  sh -n "$2" > /dev/null 2>&1; echo "$? final-check.sh" >> "$A/shn.txt"
  env OCLJ_JNI=/usr/lib/jvm/java-1.8.0-openjdk/include OCLJ_JNLUA=/mnt/c/Users/astro/Downloads/OC-JNLua CC=gcc OCLJ_LUAJIT="$WSL_REPO/prototype/watchdog/luajit" OCLJ_BUILD="$A/b" OCLJ_VARIANT=additive OCLJ_GLIBC_MAX=2.28 sh "$WSL_REPO/native/build-native.sh" > "$A/build.log" 2>&1
  echo $? > "$A/rc/build.rc"
  if [ "$(cat "$A/rc/build.rc")" = 0 ]; then
    objcmp "$A/b" "$WSL_REPO/build/native" linux-x86_64 "$A/cmp-vs-buildnative"; echo $? > "$A/rc/objcmp.rc"
    md5sum < "$A/b/luajit-linux-x86_64/src/lj_opt_fold.o" | cut -c1-32 > "$A/fold-o.md5"
    grep -h 'glibc: highest version needed' "$A/build.log" > "$A/glibc.txt"
    env OCLJ_BUILD="$A/b" OCLJ_LUA53="$PUCL" OCLJ_BITJIT_OUT="$A/bitjit-all" sh "$WSL_REPO/test/native/run-bitjit.sh" > "$A/bitjit-all.log" 2>&1
    echo $? > "$A/rc/bitjit-all.rc"
    for m in idx rg2; do
      env OCLJ_BUILD="$A/b" OCLJ_LUA53="$PUCL" OCLJ_BITJIT_PARTS=gen OCLJ_BITJIT_GENMODE=$m OCLJ_BITJIT_SEED=1 OCLJ_BITJIT_SEEDS=4 OCLJ_BITJIT_OUT="$A/gen-$m" sh "$WSL_REPO/test/native/run-bitjit.sh" > "$A/gen-$m.log" 2>&1
      echo $? > "$A/rc/gen-$m.rc"
    done
  fi
  echo done > "$A/part.done"
}
ubuntu_part() {  # ubuntu_part <outdir, WSL form> <this script, WSL form>
  U=$1/ubuntu
  mkdir "$U" || exit 98
  { readlink -f /bin/sh; uname -a; } > "$U/host.txt" 2>&1
  : > "$U/shn.txt"
  while read -r f; do
    case $f in *.sh) sh -n "$WSL_REPO/$f" > /dev/null 2>&1; echo "$? $f" >> "$U/shn.txt" ;; esac
  done < "$1/changed-files.txt"
  sh -n "$2" > /dev/null 2>&1; echo "$? final-check.sh" >> "$U/shn.txt"
  echo done > "$U/part.done"
}
case ${1:-} in
  --alma) alma_part "$2" "$3"; exit 0 ;;
  --ubuntu) ubuntu_part "$2" "$3"; exit 0 ;;
esac

# --------------------------------------------------------------- Windows: setup
O=${1:-}
[ -n "$O" ] || { echo "usage: sh final-check.sh <fresh outdir>"; exit 2; }
[ -e "$O" ] && { echo "REFUSING: $O exists (never reuse a results directory)"; exit 97; }
OP=$(CDPATH= cd -P -- "$(dirname -- "$O")" 2>/dev/null && pwd -P) || { echo "REFUSING: the parent of $O does not exist; make it first"; exit 97; }
O=$OP/$(basename -- "$O")
# inrepo <existing dir>: 0 when it is the repo or lies under it.  Windows
# ignores case, and Git Bash's pwd -P keeps the case it was given, so a
# spelling comparison alone let /c/users/.../oc-luajit/x through (verify-code
# F1).  Every ancestor is compared with the repo by identity ([ -ef ], which
# also sees through an 8.3 name or a junction), and the lower-cased
# spellings are compared too.
lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
inrepo() {
  ir_d=$1
  case $(lc "$ir_d") in "$(lc "$R")"|"$(lc "$R")"/*) return 0 ;; esac
  while :; do
    [ "$ir_d" -ef "$R" ] && return 0
    ir_n=$(dirname -- "$ir_d")
    [ "$ir_n" = "$ir_d" ] && return 1
    ir_d=$ir_n
  done
}
inrepo "$OP" && { echo "REFUSING: $O is inside the repo"; exit 97; }
case $O in "$R"|"$R"/*) echo "REFUSING: $O is inside the repo"; exit 97 ;; esac
case $O in /[A-Za-z]/?*) ;; *) echo "REFUSING: $O is not on a drive (/<letter>/...), which the WSL parts need"; exit 97 ;; esac
# FC_USE_BUILD: the runners and negctl write into it (run.sh's shim_test,
# run-pack's pack-*, negctl's work directory), so never one in the repo
# (verify-code F2); checked before anything is created.
WB=$O/b/win
if [ -n "${FC_USE_BUILD:-}" ]; then
  WB=$(CDPATH= cd -P -- "$FC_USE_BUILD" 2>/dev/null && pwd -P) || { echo "no FC_USE_BUILD $FC_USE_BUILD"; exit 2; }
  inrepo "$WB" && { echo "REFUSING: FC_USE_BUILD $WB is inside the repo (the runners and negctl write into it; build/ is never written)"; exit 97; }
fi
mkdir "$O" || exit 98
TASKLIST=${FC_TASKLIST:-tasklist}
javacheck() {  # 0 when a java or javaw process runs; writes <file>
  $TASKLIST > "$1.all" 2>/dev/null
  grep -iE '^(java|javaw)[.]exe' "$1.all" > "$1"
  [ -s "$1" ]
}
if javacheck "$O/jvms-start.txt"; then
  echo "REFUSING: a Java process is running (Minecraft?); close it and start again:"
  cat "$O/jvms-start.txt"
  exit 96
fi
SELF=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd -P)/$(basename -- "$0")
SUMPY=$(dirname -- "$SELF")/fc-summarize.py
[ -f "$SUMPY" ] || { echo "no $SUMPY (it lives beside this script)"; exit 2; }
# WSL mounts drives lower-case (/mnt/c); Git Bash may spell one /C/ (F2).
WD=$(echo "$O" | cut -c2 | tr 'A-Z' 'a-z'); WO=/mnt/$WD$(echo "$O" | cut -c3-)
SD=$(echo "$SELF" | cut -c2 | tr 'A-Z' 'a-z'); SELF_L=/mnt/$SD$(echo "$SELF" | cut -c3-)
FC_PARTS=${FC_PARTS:-build alma bitjit suites negctl runners gen hygiene timing}
FC_ROUNDS=${FC_ROUNDS:-7}
FC_NDIV=${FC_NDIV:-1}
case "$FC_ROUNDS$FC_NDIV" in *[!0-9]*) echo "FC_ROUNDS and FC_NDIV are whole numbers"; exit 2 ;; esac
mkdir -p "$O/logs" "$O/rc" "$O/b" "$O/cmp" "$O/census" "$O/runs" || exit 98
SUM=$O/summary.txt
: > "$SUM"
T0=$(date +%s)
date -u +%Y-%m-%dT%H:%M:%SZ > "$O/start-time.txt"
echo "FC_PARTS=$FC_PARTS FC_USE_BUILD=${FC_USE_BUILD:-unset} FC_TASKLIST=${FC_TASKLIST:-unset} FC_ROUNDS=$FC_ROUNDS FC_NDIV=$FC_NDIV" > "$O/knobs.txt"
wanted() { case " $FC_PARTS " in *" $1 "*) return 0 ;; esac; return 1; }
res() { echo "$1 $2: $3" >> "$SUM"; echo "$1 $2: $3"; }
check() {  # check <id> <text> <command...>: PASS when the command succeeds
  ck_i=$1; ck_t=$2; shift 2
  echo "== $ck_i: $*" >> "$O/logs/checks.log"
  if "$@" >> "$O/logs/checks.log" 2>&1; then res PASS "$ck_i" "$ck_t"; else res FAIL "$ck_i" "$ck_t"; fi
}
skip() { res SKIP "$1" "$2"; }
rcis() { [ "$(cat "$O/rc/$1.rc" 2>/dev/null)" = "$2" ]; }
stamp() { echo "$1 secs=$(( $(date +%s) - $2 ))" >> "$O/logs/timing.txt"; }
census() {  # census <prefix>
  ( cd "$R" && find build -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ) > "$1-build.md5"
  ( cd "$PL" && find . -print0 | LC_ALL=C sort -z | xargs -0 stat -c '%Y %s %n' ) > "$1-pristine-stat.txt"
  ( cd "$PL" && find .git -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ) > "$1-pristine-git.md5"
  git -C "$PL" rev-parse HEAD > "$1-pristine-head.txt" 2>&1
}
# The working tree's changed files (tracked and modified, or new), repo-relative.
( cd "$R" && { git diff --name-only HEAD; git ls-files --others --exclude-standard; } | LC_ALL=C sort -u ) > "$O/changed-files.txt"
( cd "$R" && git ls-files --others --exclude-standard | LC_ALL=C sort -u ) > "$O/new-files.txt"
mdstate() {  # mdstate <out>: md5 of every changed file, this script and the summarizer
  { while read -r f; do md5sum "$R/$f"; done < "$O/changed-files.txt"; md5sum "$SELF" "$SUMPY"; } > "$1" 2>&1
}
mdstate "$O/md5-start.txt"
git -C "$R" rev-parse HEAD > "$O/repo-head.txt"
echo "== census before"
t=$(date +%s); census "$O/census/before"; stamp census-before "$t"

# --------------------------------------------------------------- build (Windows)
# WB was set, and an FC_USE_BUILD checked, before the outdir was made.
LJW=$WB/luajit-windows-x86_64/src/luajit.exe
if wanted build; then
  echo "== build"
  if [ -n "${FC_USE_BUILD:-}" ]; then
    skip W-rc "the Windows build (FC_USE_BUILD=$WB: not built here)"
  else
    t=$(date +%s)
    env PATH="$TOOLS:$PATH" OCLJ_JNI="$JNIW" OCLJ_JNLUA="$JNLUAW" OCLJ_LUAJIT="$PLW" OCLJ_VARIANT=additive OCLJ_BUILD="$WB" sh "$R/native/build-native.sh" > "$O/logs/build-win.log" 2>&1
    echo $? > "$O/rc/build-win.rc"; stamp build-win "$t"
    check W-rc "build-native.sh (additive) into a fresh OCLJ_BUILD succeeds" rcis build-win 0
    check W-pin "the pin is met and the export verified (8 trees, 232 files)" sh -c 'grep -q "pin     = met" "$1" && grep -q -F "8 trees to their names, 232 files to the pin" "$1"' x "$O/logs/build-win.log"
    check W-ignored-none "nothing ignored from the environment" grep -q "ignored from the environment: none " "$O/logs/build-win.log"
    check W-patch "patch-bitop-fold.sh reports the table-index fold, 63 added and 8 removed" grep -q -F "$PATCHLINE" "$O/logs/build-win.log"
  fi
  check W-objects "77 LuaJIT objects, only lj_opt_fold.o differs from build/native's; our 3 objects equal" objcmp "$WB" "$BN" windows-x86_64 "$O/cmp/win-vs-buildnative"
  check W-fold-object "lj_opt_fold.o is the implementer's ($FOLD_O_WIN)" sh -c '[ "$(md5sum < "$1" | cut -c1-32)" = "$2" ]' x "$WB/luajit-windows-x86_64/src/lj_opt_fold.o" "$FOLD_O_WIN"
fi
[ -x "$LJW" ] || { res FAIL W-exists "no $LJW: nothing below can run"; }

# --------------------------------------------------------------- alma (AlmaLinux 8 and Ubuntu, in WSL)
if wanted alma; then
  echo "== AlmaLinux 8 (WSL)"
  t=$(date +%s)
  MSYS_NO_PATHCONV=1 wsl.exe -d AlmaLinux-8 -- env FC_MODE=alma sh "$SELF_L" --alma "$WO" "$SELF_L" > "$O/logs/wsl-alma.log" 2>&1
  stamp wsl-alma "$t"
  MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu -- env FC_MODE=ubuntu sh "$SELF_L" --ubuntu "$WO" "$SELF_L" > "$O/logs/wsl-ubuntu.log" 2>&1
  A=$O/alma
  check ALMA-ran "the AlmaLinux 8 part ran to its end" [ -f "$A/part.done" ]
  check ALMA-rc "build-native.sh (additive, OCLJ_GLIBC_MAX=2.28) succeeds" [ "$(cat "$A/rc/build.rc" 2>/dev/null)" = 0 ]
  check ALMA-ignored-none "nothing ignored from the environment" grep -q "ignored from the environment: none " "$A/build.log"
  check ALMA-patch "patch-bitop-fold.sh reports the table-index fold, 63 added and 8 removed" grep -q -F "$PATCHLINE" "$A/build.log"
  check ALMA-glibc "the library needs GLIBC 2.28 at most (needs 2.$(glibcmax "$A/glibc.txt"))" sh -c '[ -n "$1" ] && [ "$1" -le 28 ]' x "$(glibcmax "$A/glibc.txt")"
  check ALMA-objects "77 LuaJIT objects, only lj_opt_fold.o differs from build/native's Linux tree; our 3 objects equal" [ "$(cat "$A/rc/objcmp.rc" 2>/dev/null)" = 0 ]
  check ALMA-fold-object "lj_opt_fold.o is the implementer's AlmaLinux 8 one ($FOLD_O_LINUX)" [ "$(cat "$A/fold-o.md5" 2>/dev/null)" = "$FOLD_O_LINUX" ]
  check ALMA-bitjit "run-bitjit.sh, all four parts, the Linux PUC: PASS" sh -c '[ "$(cat "$1/rc/bitjit-all.rc")" = 0 ] && grep -q "^RUN-BITJIT: PASS (results" "$1/bitjit-all.log" && grep -q "^PASS phiidx" "$1/bitjit-all.log" && grep -q "^PASS t_idx2: PUC" "$1/bitjit-all.log"' x "$A"
  for m in idx rg2; do
    check ALMA-gen-$m "the generator in its $m mode, seeds 1-4: PASS" sh -c '[ "$(cat "$1/rc/gen-$2.rc")" = 0 ] && [ "$(grep -c "^seed [0-9]*: PASS" "$1/gen-$2.log")" = 4 ]' x "$A" "$m"
  done
fi

# --------------------------------------------------------------- bitjit (Windows)
if wanted bitjit; then
  echo "== bitjit"
  t=$(date +%s)
  env OCLJ_BUILD="$WB" OCLJ_LUA53="$PUCW" OCLJ_BITJIT_OUT="$O/runs/bitjit-all" sh "$R/test/native/run-bitjit.sh" > "$O/logs/bitjit-all.log" 2>&1
  echo $? > "$O/rc/bitjit-all.rc"; stamp bitjit-all "$t"
  check BITJIT-all "run-bitjit.sh, all four parts (gen, floor with t_rg2, fix1, idx), PUC set: PASS" sh -c '[ "$(cat "$1/rc/bitjit-all.rc")" = 0 ] && grep -q "^RUN-BITJIT: PASS (results" "$2" && [ "$(grep -c "^seed [0-9]*: PASS" "$2")" = 4 ] && grep -q "^PASS t_rg2 (" "$2" && grep -q "^PASS t_rg2: PUC" "$2" && grep -q "^PASS fix1" "$2" && grep -q "^PASS t_idx (" "$2" && grep -q "^PASS t_cnt33 (" "$2" && grep -q "^PASS t_idx2 (" "$2" && grep -q "^PASS t_idx2: PUC" "$2" && grep -q "^PASS phiidx" "$2"' x "$O" "$O/logs/bitjit-all.log"
  for ms in idx:1 rg2:1 phi:201; do
    m=${ms%%:*}; s=${ms#*:}
    t=$(date +%s)
    env OCLJ_BUILD="$WB" OCLJ_LUA53="$PUCW" OCLJ_BITJIT_PARTS=gen OCLJ_BITJIT_GENMODE=$m OCLJ_BITJIT_SEED=$s OCLJ_BITJIT_SEEDS=4 OCLJ_BITJIT_OUT="$O/runs/gen-$m" sh "$R/test/native/run-bitjit.sh" > "$O/logs/gen-$m.log" 2>&1
    echo $? > "$O/rc/gen-$m.rc"; stamp "gen-$m" "$t"
    check BITJIT-gen-$m "the generator in its $m mode, seeds $s-$((s + 3)), PUC set: PASS" sh -c '[ "$(cat "$1/rc/gen-$2.rc")" = 0 ] && [ "$(grep -c "^seed [0-9]*: PASS" "$1/logs/gen-$2.log")" = 4 ]' x "$O" "$m"
  done
fi

# --------------------------------------------------------------- suites
if wanted suites; then
  echo "== suites"
  t=$(date +%s)
  env PATH="$TOOLS:$PATH" OCLJ_BUILD="$WB" OCLJ_LUA53="$PUCW" OCLJ_JNI="$JNIW" OCLJ_BITOP_OUT="$O/runs/bitop" sh "$R/test/native/run-bitop.sh" > "$O/logs/bitop.log" 2>&1
  echo $? > "$O/rc/bitop.rc"; stamp bitop "$t"
  check BITOP "run-bitop.sh: PASS" sh -c '[ "$(cat "$1/rc/bitop.rc")" = 0 ] && grep -q "^RUN-BITOP: PASS" "$1/logs/bitop.log"' x "$O"
  t=$(date +%s)
  env OCLJ_BUILD="$WB" OCLJ_LUA53="$PUCW" OCLJ_BITFUZZ_OUT="$O/runs/bitfuzz" sh "$R/test/native/run-bitfuzz.sh" > "$O/logs/bitfuzz.log" 2>&1
  echo $? > "$O/rc/bitfuzz.rc"; stamp bitfuzz "$t"
  check BITFUZZ "run-bitfuzz.sh: PASS" sh -c '[ "$(cat "$1/rc/bitfuzz.rc")" = 0 ] && grep -q "^BITFUZZ PASS" "$1/logs/bitfuzz.log"' x "$O"
fi

# --------------------------------------------------------------- negctl (the full sweep, one call)
if wanted negctl; then
  echo "== negctl-bitop (full sweep)"
  t=$(date +%s)
  env PATH="$TOOLS:$PATH" OCLJ_BUILD="$WB" OCLJ_LUAJIT="$PLW" OCLJ_LUA53="$PUCW" OCLJ_JNI="$JNIW" CC=gcc sh "$R/test/native/negctl-bitop.sh" > "$O/logs/negctl-bitop.log" 2>&1
  echo $? > "$O/rc/negctl-bitop.rc"; stamp negctl-bitop "$t"
  NL=$O/logs/negctl-bitop.log
  grep -E '^.negctl-bitop. [A-Z0-9-]+ [(].*: PASS [(]caught by' "$NL" | awk '{ print $2 }' | LC_ALL=C sort > "$O/cmp/negctl-caught.txt"
  for a in $ARMS30; do echo "$a"; done | LC_ALL=C sort > "$O/cmp/negctl-want.txt"
  check NEGCTL-rc "negctl-bitop.sh, every arm: exit 0 and the full-sweep PASS line" sh -c '[ "$(cat "$1/rc/negctl-bitop.rc")" = 0 ] && grep -q "^NEGCTL-BITOP: PASS (canon passes; every sabotage is caught" "$2"' x "$O" "$NL"
  check NEGCTL-canon "canon passes, every object reproduced, pristine files from the build's export" sh -c 'grep -q "^.negctl-bitop. canon (-, .*: PASS (every catcher passes; every object reproduced)" "$1" && grep -q "pristine files from .*luajit-export-windows-x86_64/src" "$1"' x "$NL"
  check NEGCTL-30-arms "exactly the 30 arms, each caught by its catchers" cmp -s "$O/cmp/negctl-caught.txt" "$O/cmp/negctl-want.txt"
  check NEGCTL-restore "restore: every file put back, every object as shipped" grep -q "^.negctl-bitop. restore: PASS" "$NL"
fi

# --------------------------------------------------------------- runners
if wanted runners; then
  echo "== runners"
  for r in run.sh run-mem.sh run-vgc.sh run-wd.sh run-penalty.sh run-race.sh run-security.sh run-pack.sh run-packfuzz.sh; do
    t=$(date +%s)
    env PATH="$TOOLS:$PATH" OCLJ_BUILD="$WB" OCLJ_JNI="$JNIW" OCLJ_LUA53="$PUCW" CC=gcc sh "$R/test/native/$r" > "$O/logs/runner-$r.log" 2>&1
    echo $? > "$O/rc/runner-$r.rc"; stamp "runner-$r" "$t"
    check "RUNNER-$r" "$r on the new build: exit 0" rcis "runner-$r" 0
  done
fi

# --------------------------------------------------------------- gen (the generator's identity)
if wanted gen; then
  echo "== generator identity"
  G=$O/gen; mkdir -p "$G/refs"
  git -C "$R" show HEAD:test/native/bitop/gen.lua > "$G/refs/gen-head.lua"
  cp "$GEN_FOLDA" "$G/refs/gen-folda.lua"; cp "$GEN_RG2" "$G/refs/gen-rg2.lua"
  md5sum "$LJW" "$R/test/native/bitop/gen.lua" "$G"/refs/*.lua "$GEN_FOLDA" "$GEN_RG2" > "$G/inputs.md5"
  gbad=0; gn=0
  for t3 in :1:head :2:head :3:head :4:head :57:head :301:head phi:1:head phi:2:head phi:3:head phi:4:head phi:57:head phi:301:head idx:1:folda idx:2:folda idx:3:folda idx:4:folda idx:5:folda idx:777:folda rg2:1:rg2 rg2:2:rg2 rg2:3:rg2 rg2:4:rg2 rg2:501:rg2 rg2:777:rg2; do
    m=$(echo "$t3" | cut -d: -f1); s=$(echo "$t3" | cut -d: -f2); rn=$(echo "$t3" | cut -d: -f3)
    tag=${m:-default}-$s-$rn
    mkdir -p "$G/$tag/ref" "$G/$tag/new"
    "$LJW" -joff "$G/refs/gen-$rn.lua" "$s" 500 "$G/$tag/ref" $m > "$G/$tag/ref.log" 2>&1; r1=$?
    "$LJW" -joff "$R/test/native/bitop/gen.lua" "$s" 500 "$G/$tag/new" $m > "$G/$tag/new.log" 2>&1; r2=$?
    v=same
    for f in cases_lj.lua cases_puc.lua; do
      [ -s "$G/$tag/ref/$f" ] && [ -s "$G/$tag/new/$f" ] || v=missing
      cmp -s "$G/$tag/ref/$f" "$G/$tag/new/$f" || { [ "$v" = same ] && v=DIFFER; }
    done
    [ "$r1" = 0 ] && [ "$r2" = 0 ] || v="$v(exit $r1/$r2)"
    echo "$tag: $v" >> "$G/pairs.txt"
    gn=$((gn + 1)); [ "$v" = same ] || gbad=1
  done
  # The control: a mode flag that read nothing would make its mode equal the default.
  for tg in phi-1-head idx-1-folda rg2-1-rg2; do
    cmp -s "$G/default-1-head/new/cases_lj.lua" "$G/$tg/new/cases_lj.lua" && { echo "CONTROL: $tg equals default-1" >> "$G/pairs.txt"; gbad=1; }
  done
  check GEN-identity "gen.lua writes what each mode's reference wrote: $gn mode-seed pairs byte-identical, and phi, idx and rg2 differ from default" [ "$gbad" = 0 ]
fi

# --------------------------------------------------------------- hygiene
if wanted hygiene; then
  echo "== hygiene"
  : > "$O/cmp/cr.txt"; crbad=0
  while read -r f; do
    n=$(crcount "$R/$f"); echo "$n $f" >> "$O/cmp/cr.txt"; [ "$n" = 0 ] || crbad=1
  done < "$O/changed-files.txt"
  check CR0 "0 CR bytes in each of the $(wc -l < "$O/changed-files.txt" | tr -d ' ') changed files (cmp/cr.txt)" [ "$crbad" = 0 ]
  ( cd "$R" && git diff --check HEAD ) > "$O/logs/git-diff-check.log" 2>&1; echo $? > "$O/rc/git-diff-check.rc"
  check GIT-DIFF-CHECK "git diff --check HEAD is clean (staged and unstaged changes)" rcis git-diff-check 0
  : > "$O/logs/git-diff-check-new.log"; nbad=0
  while read -r f; do
    ( cd "$R" && git diff --no-index --check /dev/null "$f" ) >> "$O/logs/git-diff-check-new.log" 2>&1; rc=$?
    echo "rc=$rc $f" >> "$O/logs/git-diff-check-new.log"
    [ "$rc" -le 1 ] || nbad=1
  done < "$O/new-files.txt"
  check GIT-DIFF-CHECK-NEW "git diff --no-index --check finds nothing in each of the $(wc -l < "$O/new-files.txt" | tr -d ' ') new files" [ "$nbad" = 0 ]
  : > "$O/cmp/shn-gitbash.txt"; sbad=0
  while read -r f; do
    case $f in *.sh) sh -n "$R/$f" > /dev/null 2>&1; rc=$?; echo "$rc $f" >> "$O/cmp/shn-gitbash.txt"; [ "$rc" = 0 ] || sbad=1 ;; esac
  done < "$O/changed-files.txt"
  sh -n "$SELF" > /dev/null 2>&1; rc=$?; echo "$rc final-check.sh" >> "$O/cmp/shn-gitbash.txt"; [ "$rc" = 0 ] || sbad=1
  check SHN-gitbash "sh -n of every changed shell script and this one (Git Bash)" [ "$sbad" = 0 ]
  if wanted alma; then
    check SHN-alma "sh -n of the same (AlmaLinux 8's sh)" sh -c '[ -s "$1" ] && ! grep -v "^0 " "$1"' x "$O/alma/shn.txt"
    check SHN-ubuntu "sh -n of the same (Ubuntu's dash)" sh -c '[ -s "$1" ] && ! grep -v "^0 " "$1"' x "$O/ubuntu/shn.txt"
  else
    skip SHN-alma "the alma part did not run"
    skip SHN-ubuntu "the alma part did not run"
  fi
  : > "$O/cmp/engine.txt"; ebad=0
  for s in "$R"/native/luajit/patch-bitop-*.sh; do
    e=$(engine "$s"); echo "$e $s" >> "$O/cmp/engine.txt"; [ "$e" = "$ENGINE_MD5" ] || ebad=1
  done
  check ENGINE "the hunk engine of all seven patch-bitop-*.sh is unchanged ($ENGINE_MD5)" sh -c '[ "$1" = 0 ] && [ "$(wc -l < "$2" | tr -d " ")" = 7 ]' x "$ebad" "$O/cmp/engine.txt"
  check BUILD-NATIVE-UNCHANGED "native/build-native.sh is HEAD's ($BN_SH_MD5)" sh -c 'git -C "$1" diff --quiet HEAD -- native/build-native.sh && [ "$(md5sum < "$1/native/build-native.sh" | cut -c1-32)" = "$2" ]' x "$R" "$BN_SH_MD5"
  P=$R/native/luajit/patch-bitop-fold.sh
  check PATCH-NO-TAB-BS "patch-bitop-fold.sh holds no tab and no backslash" sh -c '[ "$1" = 0 ] && [ "$2" = 0 ]' x "$(bytecount 09 "$P")" "$(bytecount 5c "$P")"
  PS=$O/ps; mkdir -p "$PS"
  git -C "$PL" cat-file blob "$(cat "$R/native/luajit/upstream.commit"):src/lj_opt_fold.c" > "$PS/pristine.c"
  TMPDIR=$PS sh "$P" "$PS/pristine.c" "$PS/out1.c" > "$PS/run1.log" 2>&1; echo $? > "$O/rc/ps-run1.rc"
  TMPDIR=$PS sh "$P" "$PS/out1.c" "$PS/out2.c" > "$PS/run2.log" 2>&1; echo $? > "$O/rc/ps-run2.rc"
  check PATCH-PRISTINE "on the pin's pristine blob: 63 added, 8 removed, verified by content, diff and reversal" sh -c '[ "$(cat "$1/rc/ps-run1.rc")" = 0 ] && grep -q -F "$2" "$1/ps/run1.log"' x "$O" "$PATCHLINE"
  check PATCH-IDEMPOTENT "on its own output: verified, unchanged, the same bytes" sh -c '[ "$(cat "$1/rc/ps-run2.rc")" = 0 ] && grep -q "already folds the 64-bit bit operators without FFI (verified) -- unchanged" "$1/ps/run2.log" && cmp -s "$1/ps/out1.c" "$1/ps/out2.c"' x "$O"
  check PATCH-IS-BUILD-COPY "its output is the build copy's lj_opt_fold.c, byte for byte" cmp -s "$PS/out1.c" "$WB/luajit-windows-x86_64/src/lj_opt_fold.c"
fi

# --------------------------------------------------------------- timing (last)
if wanted timing; then
  echo "== timing"
  T=$O/timing; mkdir -p "$T/bench"
  cp "$BENCH_SRC"/*.lua "$T/bench/" && cp "$SUMPY" "$T/fc-summarize.py"
  ( cd "$T/bench" && md5sum *.lua ) | tr -d '*' > "$T/bench.md5"
  grep -E 'bench/(bench_bit|bench_bit2|bench_crcx|bench_idx|bench_spec|ident)[.]lua$' "$CHAIN_INPUTS" | awk '{ n = $2; sub(/^.*[/]/, "", n); print $1 " " n }' | LC_ALL=C sort -k2 > "$T/bench-chain1.md5"
  LC_ALL=C sort -k2 "$T/bench.md5" | awk '{ print $1 " " $2 }' > "$T/bench-now.md5"
  check TIMING-benches "the six benches are the main session's chain-1 inputs, byte for byte" sh -c '[ "$(wc -l < "$1" | tr -d " ")" = 6 ] && cmp -s "$1" "$2"' x "$T/bench-chain1.md5" "$T/bench-now.md5"
  exe() { case $1 in base) echo "$BASE/luajit-windows-x86_64/src/luajit.exe" ;; new) echo "$LJW" ;; b0) echo "$B0" ;; puc) echo "$PUCW" ;; esac; }
  for v in base new b0 puc; do md5sum "$(exe $v)"; done > "$T/vms.md5" 2>&1
  md5sum "$BASE/luajit-windows-x86_64/src/lj_opt_fold.o" "$WB/luajit-windows-x86_64/src/lj_opt_fold.o" >> "$T/vms.md5" 2>&1
  check TIMING-base "base is the chain-1 base: its luajit.exe and lj_opt_fold.o have the md5s chain-1 recorded" sh -c 'for f in luajit.exe lj_opt_fold.o; do m=$(md5sum < "$1/luajit-windows-x86_64/src/$f" | cut -c1-32); grep -q "^$m .*/b-base/luajit-windows-x86_64/src/$f$" "$2" || exit 1; done' x "$BASE" "$CHAIN_INPUTS"
  nn() { awk -v n="$1" -v d="$FC_NDIV" 'BEGIN { printf "%d", n / d }'; }
  powershell -NoProfile -Command "(Get-CimInstance Win32_Processor).LoadPercentage" > "$T/cpuload-before.txt" 2>/dev/null
  $TASKLIST > "$T/procs-before.txt" 2>/dev/null
  r=1; stopped=0
  while [ "$r" -le "$FC_ROUNDS" ]; do
    if javacheck "$T/jvms-round-$r.txt"; then
      { echo "STOPPED before round $r: a Java process started"; cat "$T/jvms-round-$r.txt"; } > "$T/STOPPED"
      stopped=1; break
    fi
    k=$(( (r - 1) % 4 ))
    set -- base new b0 puc
    i=0
    while [ "$i" -lt "$k" ]; do f=$1; shift; set -- "$@" "$f"; i=$((i + 1)); done
    ORDER="$*"; p=1
    for v in $ORDER; do
      E=$(exe "$v")
      if [ "$v" = b0 ]; then BL="bench_bit.lua:2e7 bench_bit2.lua:1e7"; else BL="bench_bit.lua:2e7 bench_bit2.lua:1e7 bench_crcx.lua:1e7 bench_idx.lua:1e7 bench_spec.lua:2e7 ident.lua:1e7:time"; fi
      for bb in $BL; do
        bf=$(echo "$bb" | cut -d: -f1); bn=$(echo "$bb" | cut -d: -f2); bx=$(echo "$bb" | cut -d: -f3)
        line=$( cd "$T/bench" && "$E" "$bf" "$(nn "$bn")" $bx 2>&1 | tr '[:cntrl:]' ' ' )
        echo "round=$r pos=$p vm=$v bench=${bf%.lua}: $line" >> "$T/raw.txt"
      done
      p=$((p + 1))
    done
    echo "round $r done $(date -u +%H:%M:%SZ) order: $ORDER" >> "$T/progress.txt"
    r=$((r + 1))
  done
  powershell -NoProfile -Command "(Get-CimInstance Win32_Processor).LoadPercentage" > "$T/cpuload-after.txt" 2>/dev/null
  $TASKLIST > "$T/procs-after.txt" 2>/dev/null
  python -I "$T/fc-summarize.py" "$T/raw.txt" > "$T/summary.txt" 2>&1; echo $? > "$O/rc/timing-summary.rc"
  check TIMING-complete "all $FC_ROUNDS rounds ran (no Java process appeared)" sh -c '[ "$1" = 0 ] && [ "$(grep -c "^round [0-9]* done" "$2")" = "$3" ]' x "$stopped" "$T/progress.txt" "$FC_ROUNDS"
  check TIMING-results-equal "every result of the new build equals base's, in every round (timing/summary.txt)" sh -c 'grep -q "^RESULTS: EQUAL" "$1" && grep -q "^SUMMARY: OK" "$1"' x "$T/summary.txt"
  if [ "$FC_NDIV" = 1 ]; then
    check TIMING-fold-active "crc-table: new/base median below 0.75 (the fold is in the timed build; the main session read 0.51)" sh -c 'v=$(sed -n "s/^CRCTABLE_NEW_OVER_BASE //p" "$1"); [ -n "$v" ] && awk -v v="$v" "BEGIN { exit !(v + 0 > 0 && v + 0 < 0.75) }"' x "$T/summary.txt"
  else
    skip TIMING-fold-active "FC_NDIV=$FC_NDIV: a smoke reading, too short to time"
  fi
fi

# --------------------------------------------------------------- census and md5s after
echo "== census after"
t=$(date +%s); census "$O/census/after"; stamp census-after "$t"
check CENSUS-build "every file under build/ has its md5 of the start, none added or removed ($(wc -l < "$O/census/before-build.md5" | tr -d ' ') files)" cmp -s "$O/census/before-build.md5" "$O/census/after-build.md5"
check CENSUS-pristine-stat "the pristine checkout's stat list (mtimes included) is unchanged" cmp -s "$O/census/before-pristine-stat.txt" "$O/census/after-pristine-stat.txt"
check CENSUS-pristine-git "the pristine checkout's .git md5 list and HEAD are unchanged" sh -c 'cmp -s "$1-pristine-git.md5" "$2-pristine-git.md5" && cmp -s "$1-pristine-head.txt" "$2-pristine-head.txt"' x "$O/census/before" "$O/census/after"
( cd "$R" && { git diff --name-only HEAD; git ls-files --others --exclude-standard; } | LC_ALL=C sort -u ) > "$O/changed-files-end.txt"
mdstate "$O/md5-end.txt"
check FILES-unchanged "the changed files (the same list), this script and fc-summarize.py are unchanged since the start; the repo's HEAD too" sh -c 'cmp -s "$1/changed-files.txt" "$1/changed-files-end.txt" && cmp -s "$1/md5-start.txt" "$1/md5-end.txt" && [ "$(git -C "$2" rev-parse HEAD)" = "$(cat "$1/repo-head.txt")" ]' x "$O" "$R"
NF=$(grep -c '^FAIL ' "$SUM"); NP=$(grep -c '^PASS ' "$SUM"); NS=$(grep -c '^SKIP ' "$SUM")
echo "PASS $NP FAIL $NF SKIP $NS secs $(( $(date +%s) - T0 )) parts [$FC_PARTS] FC_USE_BUILD=${FC_USE_BUILD:-unset} FC_ROUNDS=$FC_ROUNDS FC_NDIV=$FC_NDIV final-check.sh $(md5sum < "$SELF" | cut -c1-32)" > "$O/ALL.done"
cat "$O/ALL.done"
