#!/bin/sh
# final-check.sh <fresh outdir> -- the final check of the select fix (roadmap
# row 213, JIT guide P54) as the repo's working tree holds it:
# native/luajit/patch-bitop-record.sh's hunks 4 and 5, its tests
# (test/native/bitop/t_select.lua, run-bitjit.sh's sel part, negctl-bitop.sh's
# SELGUARD and SELRECK, 32 arms in all), and whatever else the working tree
# changes (docs/jit-guide.md, docs/roadmap.md, t_idx2.lua's header).  For the
# MAIN SESSION, from Git Bash, on a quiet machine (its last part times):
#
#   nohup sh /c/Users/astro/claude-tmp/oclj/sel/fix/final-check.sh <outdir> > <outdir>.log 2>&1 &
#
# and a monitor on <outdir>/ALL.done.  About 25-30 minutes: the negctl sweep
# about 15 [I: the CRC32 round's 30 arms took 14 min 3 s, the select arms 7-9
# s each]; measured in the fixer's smoke runs, 2026-10-21 [M]: the census
# 28-50 s each time (39450 files under build/), the Windows build 41 s,
# AlmaLinux 8 140 s, the bitjit part with three generator modes 190 s, the
# base part about 10 s, the suites 10 s, the runners 38 s, hygiene about 15
# s, timing about 27 s (7 rounds).
#
# Modelled on the CRC32 round's crc2/fix/final-check.sh (md5 recorded in
# <outdir>/model.md5 when it is there): the same refusals (by identity, before
# anything is created), census, md5s at start and end, and one PASS, FAIL or
# SKIP line per check in <outdir>/summary.txt, ALL.done last.  Written by the
# select round's fixer (claude-tmp/oclj/sel/fix), 2026-10-21.
#
# It refuses an outdir that exists or lies inside the repo, a parent that does
# not exist, an outdir not on a drive, and an FC_USE_BUILD inside the repo
# (exit 97), before it creates anything; then, when the timing part is wanted,
# a running java or javaw (exit 96, Minecraft); the timing part also stops
# between rounds if one appears (STOPPED, a FAIL line).  Without the timing
# part a running Java is recorded (jvms-start.txt) and the correctness parts
# run.  Everything it writes is under <outdir> (and, with FC_USE_BUILD, in that
# build): fresh OCLJ_BUILDs <outdir>/b/win and <outdir>/alma/b (additive, the
# variant build/native holds), every exit code in <outdir>/rc/ (and
# <outdir>/alma/rc/), the summary, and ALL.done last.  It never writes under
# the repo (the runners write into the fresh OCLJ_BUILD; the base runs write
# into <outdir>), never changes prototype/watchdog/luajit (read by the pinned
# builds), and runs its Linux parts by invoking itself in WSL
# (MSYS_NO_PATHCONV=1 wsl.exe -d AlmaLinux-8 -- env ... sh
# /mnt/c/.../final-check.sh --alma <outdir> ...), reading their exit codes from
# the files they write.
#
# SAFETY.  The base parts send select indices that wrap, and k <= 0, to
# build/native's natives, which lack the fix.  As read in lj_record.c
# rec_varg at the pin (the main session, the implementer, the sweep, both
# verifiers and the fixer, 2026-10-20/21), the path such a k reaches beyond
# the varargs loads nothing, and the only load sits behind the unsigned ABC on
# k-1 (a variable k) or a GE guard against a record-time constant (a constant
# k): a wrong value, never an address.  These are the same runs the
# implementer and the code verifier made on build/native.
#
# PARTS (FC_PARTS, default all, in this order; the census and the start and
# end md5s always run):
#   build    Windows build-native.sh into <outdir>/b/win: rc 0, the pin met,
#            the export verified, nothing ignored from the environment, the
#            record patch line (22 added, 36 removed, of 2966); 77 LuaJIT
#            objects of which only lj_record.o differs from build/native's,
#            ours (3) equal; that lj_record.o is the implementer's
#            (c536c2b9...), and the build copy's lj_record.c is d490af9b...
#   alma     AlmaLinux 8, OCLJ_GLIBC_MAX=2.28: the same against build/native's
#            Linux tree (lj_record.o a8e738ca...), GLIBC needed <= 2.28;
#            run-bitjit.sh, all five parts, with the Linux PUC; the generator
#            in its idx and phi modes (seeds 1-4 and 201-204); the sel part on
#            the base build's Linux luajit, which must fail (the fail-first);
#            sh -n of every changed shell script and this one there, and in
#            Ubuntu's dash
#   bitjit   run-bitjit.sh, all five parts (gen, floor, fix1, idx, sel), PUC
#            set, and t_select's 15 option sets at 0; the generator in its
#            idx, rg2 and phi modes (seeds 1-4, 1-4, 201-204)
#   base     the fail-firsts on the base build (build/native): the sel part
#            FAILs, t_select in every one of the 15 sets and t_select-kmax,
#            PUC passing; verify-folda's selbug.lua (fc-selbug.lua, beside
#            this script) prints n 30 E 200 there with the JIT on, and
#            E 30 E 200 on the new build with the JIT on and off
#   suites   run-bitop.sh and run-bitfuzz.sh
#   negctl   the FULL negctl-bitop.sh sweep, one call: canon, 32 arms, restore
#            (the only negctl script this round changed)
#   runners  the other native runners that link libluajit.a (its JIT and the
#            new lj_record.o): run.sh, run-mem.sh, run-vgc.sh, run-wd.sh,
#            run-penalty.sh, run-race.sh, run-security.sh, run-pack.sh and
#            run-packfuzz.sh (about 40 s together).  Not run: negctl-pack.sh
#            (its arms change oclj_strpack.c only, unchanged here, and its
#            catchers, run-pack.sh and run-packfuzz.sh, run above);
#            negative-control.sh (the shim's, memory's and collector's
#            sabotages, none in lj_record.c; it took 578 s and passed on this
#            round's build in the fixer's smoke run, sel/fix/fc-smoke-B); and
#            smoke-test.sh (it starts a JVM, which the timing part forbids)
#   hygiene  the changed files are exactly the round's seven; 0 CR bytes in
#            each; git diff --check HEAD, and its --no-index form for each new
#            file; sh -n in Git Bash (and the alma part's AlmaLinux 8 and
#            Ubuntu results); the hunk engine of all seven patch-bitop-*.sh
#            unchanged (077d1dbe...); build-native.sh unchanged (47b9c52e...);
#            patch-bitop-record.sh without tabs or backslashes, t_select.lua
#            without backslashes; the patch run on the pin's pristine blob
#            (git cat-file): 22 added, 36 removed, the build copy's bytes,
#            idempotent; the guide's line cites (fc-citecheck.py: every cite
#            holds, and every cite moved by one line fails), its anchors and
#            its tables
#   timing   LAST: base (build/native's luajit.exe, lj_record.o 81918b7d...)
#            against new (<outdir>/b/win, c536c2b9...), FC_ROUNDS rounds
#            (default 7), the order alternating, fc-bench_sel.lua (beside this
#            script, md5 checked; the implementer's five rows and vbeyond,
#            whose k changes every iteration, so the fix's guard runs in the
#            loop body) at N = 1e8 (best of 3 inside; os.clock steps by 1 ms,
#            0.01 ns of a row there), about 15 s a round; fc-summarize.py: per
#            row the medians and new/base ratios, every result of new equal to
#            base's, and at full N each row's median ratio within [0.5, 2.0]
#            (a smoke bound against a gross change, not a speed claim)
#
# KNOBS, for smoke runs and fail-firsts only (ALL.done names them):
#   FC_PARTS=<list>       the parts to run
#   FC_USE_BUILD=<dir>    skip the Windows build and use this OCLJ_BUILD
#                         (the build part's checks then judge that build;
#                         the runners and negctl write into it, so it must
#                         lie outside the repo, and is best a copy)
#   FC_BASE_BUILD=<dir>   the base build for the base and timing parts instead
#                         of build/native (and its Linux tree, if any, for the
#                         alma part's fail-first); a fail-first knob
#   FC_TASKLIST=<cmd>     the process lister instead of tasklist (a stand-in
#                         that prints a javaw.exe line proves the refusal)
#   FC_ROUNDS=<n>         timing rounds (default 7)
#   FC_NDIV=<n>           divide the bench's N (default 1; at any other value
#                         the timing part's gross-change check says SKIP)
#   FC_NEGCTL_ARMS=<list> run negctl with OCLJ_NEGCTL_ARMS=<list>: then the
#                         NEGCTL-rc and NEGCTL-32-arms checks FAIL by design
#   FC_CENSUS=stat        the census of build/ compares find's mtime and size
#                         list instead of md5s (the default, md5, took 28 s
#                         over 39450 files; stat took 197 s cold and 6 s warm,
#                         so it is no quicker: kept only for a smoke run)
# Written with a file tool; no heredocs, and no backslashes at all.
set -u
R=/c/Users/astro/Downloads/OC-LuaJIT
RW=C:/Users/astro/Downloads/OC-LuaJIT
WSL_REPO=/mnt/c/Users/astro/Downloads/OC-LuaJIT
PL=$R/prototype/watchdog/luajit
PLW=C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit
BN=$R/build/native
PUCW=C:/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/lua.exe
PUCL=/mnt/c/Users/astro/claude-tmp/oclj/puc536-alma/lua
TOOLS=/c/Users/astro/claude-tmp/oclj/bin
JNIW="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include"
JNLUAW=C:/Users/astro/Downloads/OC-JNLua
MODEL=/c/Users/astro/claude-tmp/oclj/crc2/fix/final-check.sh
REC_O_WIN=c536c2b9afd16b971de1b003ab98541b
REC_O_LINUX=a8e738ca42e88a50c227897fb5414adf
BASE_REC_O_WIN=81918b7d2a82e1988c98f05c0e0f8a7c
REC_C_MD5=d490af9bfe2ec6e67b832136b2f9b5b0
ENGINE_MD5=077d1dbebe056d59691d7f7f93307b2d
BN_SH_MD5=47b9c52eecce550b57871d8448593bc3
BENCH_MD5=70dfdac86f9658d0efafb98b8eb8a9d4
SELBUG_MD5=96ffbad1a6e0f8c0777f64f698326065
PATCHLINE="select's index is bounded in rec_varg (22 lines added, 36 removed, of 2966)"
IDEMLINE="already records the operators through oclj_rec_bitop and bounds select's index (verified) -- unchanged"
SELSETS='jon O0 O1 hl1 ms0 he1 noloop nofold nocse hx1 ts1 mx1 hl1ms0 noabc nonarrow'
ARMS32='BCDUMP ERROPERAND FIX1 INEXACT-BNOT INEXACT-FOLD INEXACT-INTERP INEXACT-JIT INEXACT-SLOW KFOLD64 NARROW NEGSHIFT NOINT-FOLD NOINT-JIT NOLOOPFOLD PHIIDX RANGE-HI SARCONST SARSHR SELFGUARD SELGUARD SELRECK SHIFTMASK STRCOERCE WADD0 WBAND WIDTH55 WIDTHIDX33 WORDTOKEN WRAP32-FOLD WRAP32-INTERP WSHL0 WSHR'
CHANGED7='docs/jit-guide.md docs/roadmap.md native/luajit/patch-bitop-record.sh test/native/bitop/t_idx2.lua test/native/bitop/t_select.lua test/native/negctl-bitop.sh test/native/run-bitjit.sh'
# Nothing from the caller's environment steers a runner.
unset LUA_INIT LUA_INIT_5_3 LUA_INIT_5_2 LUA_PATH LUA_CPATH OCLJ_REPO OCLJ_LUA53
unset OCLJ_BITJIT_PARTS OCLJ_BITJIT_SEED OCLJ_BITJIT_SEEDS OCLJ_BITJIT_CASES OCLJ_BITJIT_GENMODE OCLJ_BITJIT_HOTMIN OCLJ_BITJIT_OUT
unset OCLJ_NEGCTL_ARMS NEGCTL_GEN_SEEDS NEGCTL_FUZZ_CASES OCLJ_BITOP_OUT OCLJ_BITFUZZ_OUT OCLJ_LUAJIT_UNPINNED

# objcmp <build A> <build B> <platform> <out prefix>: 0 iff both hold 77
# LuaJIT objects of the same names, only lj_record.o differs, and our 3
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
    [ "$oc_a" = 1 ] && [ "$oc_b" = 1 ] && [ "$oc_n" = "lj_record.o " ] &&
    cmp -s "$4.A-obj.md5" "$4.B-obj.md5" && [ "$(wc -l < "$4.A-obj.md5" | tr -d ' ')" = 3 ]
}
# crcount <file>: its CR bytes (od, so that no backslash is needed).
crcount() { od -An -tx1 -v "$1" | tr ' ' '|' | grep -o '|0d' | wc -l | tr -d ' '; }
bytecount() { od -An -tx1 -v "$2" | tr ' ' '|' | grep -o "|$1" | wc -l | tr -d ' '; }
engine() { sed -n '/^# --- THE HUNK ENGINE/,/^# --- end of the hunk engine/p' "$1" | md5sum | cut -c1-32; }
# glibcmax <file>: x of the highest GLIBC_2.x a build log says the library needs.
glibcmax() { awk '{ if (match($0, /highest version needed GLIBC_2[.][0-9]+/)) { print substr($0, RSTART + 31, RLENGTH - 31); exit } }' "$1" 2>/dev/null; }
# selpass <log>: the sel part passed, t_select at 0 in each of the 15 sets.
selpass() {
  sp_l=$(grep '^PASS t_select (' "$1") || return 1
  for sp_n in $SELSETS; do
    case "$sp_l " in *" $sp_n=0 "*) ;; *) echo "set $sp_n not at 0"; return 1 ;; esac
  done
  grep -q '^PASS t_select-kmax' "$1" && grep -q '^PASS t_select: PUC' "$1" &&
    grep -q -F "the k = 2^27 loops compiled 3 of 3" "$1"
}
# selfails <log>: the sel part failed as a build without the fix must: t_select
# differs in every one of the 15 sets, t_select-kmax fails, PUC passes.
selfails() {
  sf_l=$(grep '^FAIL t_select (' "$1") || { echo "no FAIL t_select line"; return 1; }
  for sf_n in $SELSETS; do
    case "$sf_l " in *" $sf_n=0 "*|*" $sf_n=0("*) echo "set $sf_n at 0"; return 1 ;; *" $sf_n="[1-9]*) ;; *) echo "set $sf_n missing"; return 1 ;; esac
  done
  grep -q '^FAIL t_select-kmax' "$1" && grep -q '^PASS t_select: PUC' "$1" && grep -q '^RUN-BITJIT: FAIL' "$1"
}
# basefails <rc file> <log>: the base run exited 1 and selfails holds.
basefails() { [ "$(cat "$1" 2>/dev/null)" = 1 ] && selfails "$2"; }

# --------------------------------------------------------------- the Linux parts (in WSL)
alma_part() {  # alma_part <outdir, WSL form> <this script, WSL form> <base build, WSL form>
  A=$1/alma
  mkdir "$A" || exit 98
  mkdir -p "$A/rc" || exit 98
  { uname -a; gcc --version | head -1; readlink -f /bin/sh; ldd --version 2>&1 | head -1; } > "$A/host.txt" 2>&1
  : > "$A/shn.txt"
  while read -r f; do
    case $f in *.sh) sh -n "$WSL_REPO/$f" > /dev/null 2>&1; echo "$? $f" >> "$A/shn.txt" ;; esac
  done < "$1/changed-files.txt"
  sh -n "$2" > /dev/null 2>&1; echo "$? final-check.sh" >> "$A/shn.txt"
  env OCLJ_JNI=/usr/lib/jvm/java-1.8.0-openjdk/include OCLJ_JNLUA=/mnt/c/Users/astro/Downloads/OC-JNLua CC=gcc OCLJ_LUAJIT="$WSL_REPO/prototype/watchdog/luajit" OCLJ_BUILD="$A/b" OCLJ_VARIANT=additive OCLJ_GLIBC_MAX=2.28 sh "$WSL_REPO/native/build-native.sh" > "$A/build.log" 2>&1
  echo $? > "$A/rc/build.rc"
  if [ "$(cat "$A/rc/build.rc")" = 0 ]; then
    objcmp "$A/b" "$WSL_REPO/build/native" linux-x86_64 "$A/cmp-vs-buildnative"; echo $? > "$A/rc/objcmp.rc"
    md5sum < "$A/b/luajit-linux-x86_64/src/lj_record.o" | cut -c1-32 > "$A/record-o.md5"
    grep -h 'glibc: highest version needed' "$A/build.log" > "$A/glibc.txt"
    env OCLJ_BUILD="$A/b" OCLJ_LUA53="$PUCL" OCLJ_BITJIT_OUT="$A/bitjit-all" sh "$WSL_REPO/test/native/run-bitjit.sh" > "$A/bitjit-all.log" 2>&1
    echo $? > "$A/rc/bitjit-all.rc"
    for ms in idx:1 phi:201; do
      m=${ms%%:*}; s=${ms#*:}
      env OCLJ_BUILD="$A/b" OCLJ_LUA53="$PUCL" OCLJ_BITJIT_PARTS=gen OCLJ_BITJIT_GENMODE=$m OCLJ_BITJIT_SEED=$s OCLJ_BITJIT_SEEDS=4 OCLJ_BITJIT_OUT="$A/gen-$m" sh "$WSL_REPO/test/native/run-bitjit.sh" > "$A/gen-$m.log" 2>&1
      echo $? > "$A/rc/gen-$m.rc"
    done
  fi
  # The fail-first: the sel part on the base build's Linux luajit (read only;
  # its results go to the outdir).
  if [ -x "$3/luajit-linux-x86_64/src/luajit" ]; then
    md5sum "$3/luajit-linux-x86_64/src/luajit" "$3/luajit-linux-x86_64/src/lj_record.o" > "$A/base.md5" 2>&1
    env OCLJ_BUILD="$3" OCLJ_LUA53="$PUCL" OCLJ_BITJIT_PARTS=sel OCLJ_BITJIT_OUT="$A/base-sel" sh "$WSL_REPO/test/native/run-bitjit.sh" > "$A/base-sel.log" 2>&1
    echo $? > "$A/rc/base-sel.rc"
  else
    echo "no $3/luajit-linux-x86_64/src/luajit" > "$A/base-sel.skip"
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
  --alma) alma_part "$2" "$3" "$4"; exit 0 ;;
  --ubuntu) ubuntu_part "$2" "$3"; exit 0 ;;
esac

# --------------------------------------------------------------- Windows: setup
O=${1:-}
[ -n "$O" ] || { echo "usage: sh final-check.sh <fresh outdir>"; exit 2; }
[ -e "$O" ] && { echo "REFUSING: $O exists (never reuse a results directory)"; exit 97; }
OP=$(CDPATH= cd -P -- "$(dirname -- "$O")" 2>/dev/null && pwd -P) || { echo "REFUSING: the parent of $O does not exist; make it first"; exit 97; }
O=$OP/$(basename -- "$O")
# inrepo <existing dir>: 0 when it is the repo or lies under it.  Windows
# ignores case, and Git Bash's pwd -P keeps the case it was given, so every
# ancestor is compared with the repo by identity ([ -ef ], which also sees
# through an 8.3 name or a junction), and the lower-cased spellings are
# compared too (the CRC32 round's verify-code F1).
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
# run-pack's pack-*, negctl's work directory), so never one in the repo;
# checked before anything is created.
WB=$O/b/win
if [ -n "${FC_USE_BUILD:-}" ]; then
  WB=$(CDPATH= cd -P -- "$FC_USE_BUILD" 2>/dev/null && pwd -P) || { echo "no FC_USE_BUILD $FC_USE_BUILD"; exit 2; }
  inrepo "$WB" && { echo "REFUSING: FC_USE_BUILD $WB is inside the repo (the runners and negctl write into it; build/ is never written)"; exit 97; }
fi
# The base build is only read (its luajit runs; every result goes to the outdir).
BASEB=$BN
if [ -n "${FC_BASE_BUILD:-}" ]; then
  BASEB=$(CDPATH= cd -P -- "$FC_BASE_BUILD" 2>/dev/null && pwd -P) || { echo "no FC_BASE_BUILD $FC_BASE_BUILD"; exit 2; }
fi
case $BASEB in /[A-Za-z]/?*) ;; *) echo "REFUSING: the base build $BASEB is not on a drive (/<letter>/...)"; exit 97 ;; esac
FC_PARTS=${FC_PARTS:-build alma bitjit base suites negctl runners hygiene timing}
FC_ROUNDS=${FC_ROUNDS:-7}
FC_NDIV=${FC_NDIV:-1}
FC_CENSUS=${FC_CENSUS:-md5}
case "$FC_ROUNDS$FC_NDIV" in *[!0-9]*) echo "FC_ROUNDS and FC_NDIV are whole numbers"; exit 2 ;; esac
case $FC_CENSUS in md5|stat) ;; *) echo "FC_CENSUS is md5 or stat"; exit 2 ;; esac
for p in $FC_PARTS; do
  case " build alma bitjit base suites negctl runners hygiene timing " in *" $p "*) ;; *) echo "unknown part $p"; exit 2 ;; esac
done
wanted() { case " $FC_PARTS " in *" $1 "*) return 0 ;; esac; return 1; }
SELF=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd -P)/$(basename -- "$0")
HERE=$(dirname -- "$SELF")
for h in fc-summarize.py fc-bench_sel.lua fc-selbug.lua fc-citecheck.py fc-anchorcheck.py fc-tablecheck.py; do
  [ -f "$HERE/$h" ] || { echo "no $HERE/$h (it lives beside this script)"; exit 2; }
done
mkdir "$O" || exit 98
TASKLIST=${FC_TASKLIST:-tasklist}
javacheck() {  # 0 when a java or javaw process runs; writes <file>
  $TASKLIST > "$1.all" 2>/dev/null
  grep -iE '^(java|javaw)[.]exe' "$1.all" > "$1"
  [ -s "$1" ]
}
if javacheck "$O/jvms-start.txt"; then
  if wanted timing; then
    echo "REFUSING: a Java process is running (Minecraft?); close it and start again:"
    cat "$O/jvms-start.txt"
    exit 96
  fi
  echo "NOTE: a Java process is running; no timing part was asked for, so the correctness parts run (jvms-start.txt)"
fi
# WSL mounts drives lower-case (/mnt/c); Git Bash may spell one /C/.
wslpath_of() { printf '/mnt/%s%s' "$(printf '%s' "$1" | cut -c2 | tr 'A-Z' 'a-z')" "$(printf '%s' "$1" | cut -c3-)"; }
winpath_of() { printf '%s:%s' "$(printf '%s' "$1" | cut -c2 | tr 'a-z' 'A-Z')" "$(printf '%s' "$1" | cut -c3-)"; }
WO=$(wslpath_of "$O"); SELF_L=$(wslpath_of "$SELF"); WBASE=$(wslpath_of "$BASEB")
mkdir -p "$O/logs" "$O/rc" "$O/b" "$O/cmp" "$O/census" "$O/runs" || exit 98
SUM=$O/summary.txt
: > "$SUM"
T0=$(date +%s)
date -u +%Y-%m-%dT%H:%M:%SZ > "$O/start-time.txt"
echo "FC_PARTS=$FC_PARTS FC_USE_BUILD=${FC_USE_BUILD:-unset} FC_BASE_BUILD=${FC_BASE_BUILD:-unset} FC_TASKLIST=${FC_TASKLIST:-unset} FC_ROUNDS=$FC_ROUNDS FC_NDIV=$FC_NDIV FC_NEGCTL_ARMS=${FC_NEGCTL_ARMS:-unset} FC_CENSUS=$FC_CENSUS" > "$O/knobs.txt"
[ -f "$MODEL" ] && md5sum "$MODEL" > "$O/model.md5"
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
  if [ "$FC_CENSUS" = stat ]; then
    ( cd "$R" && find build -type f -print0 | LC_ALL=C sort -z | xargs -0 stat -c '%Y %s %n' ) > "$1-build.md5"
  else
    ( cd "$R" && find build -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ) > "$1-build.md5"
  fi
  ( cd "$PL" && find . -print0 | LC_ALL=C sort -z | xargs -0 stat -c '%Y %s %n' ) > "$1-pristine-stat.txt"
  ( cd "$PL" && find .git -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ) > "$1-pristine-git.md5"
  git -C "$PL" rev-parse HEAD > "$1-pristine-head.txt" 2>&1
}
# The working tree's changed files (tracked and modified, or new), repo-relative.
( cd "$R" && { git diff --name-only HEAD; git ls-files --others --exclude-standard; } | LC_ALL=C sort -u ) > "$O/changed-files.txt"
( cd "$R" && git ls-files --others --exclude-standard | LC_ALL=C sort -u ) > "$O/new-files.txt"
mdstate() {  # mdstate <out>: md5 of every changed file, this script and its helpers
  { while read -r f; do md5sum "$R/$f"; done < "$O/changed-files.txt"
    md5sum "$SELF" "$HERE/fc-summarize.py" "$HERE/fc-bench_sel.lua" "$HERE/fc-selbug.lua" "$HERE/fc-citecheck.py" "$HERE/fc-anchorcheck.py" "$HERE/fc-tablecheck.py"; } > "$1" 2>&1
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
    check W-patch "patch-bitop-record.sh reports the select fix, 22 added and 36 removed of 2966" grep -q -F "$PATCHLINE" "$O/logs/build-win.log"
  fi
  check W-objects "77 LuaJIT objects, only lj_record.o differs from build/native's; our 3 objects equal" objcmp "$WB" "$BN" windows-x86_64 "$O/cmp/win-vs-buildnative"
  check W-record-object "lj_record.o is the implementer's ($REC_O_WIN)" sh -c '[ "$(md5sum < "$1" | cut -c1-32)" = "$2" ]' x "$WB/luajit-windows-x86_64/src/lj_record.o" "$REC_O_WIN"
  check W-build-copy "the build copy's lj_record.c is the patched one ($REC_C_MD5)" sh -c '[ "$(md5sum < "$1" | cut -c1-32)" = "$2" ]' x "$WB/luajit-windows-x86_64/src/lj_record.c" "$REC_C_MD5"
fi
[ -x "$LJW" ] || { res FAIL W-exists "no $LJW: nothing below can run"; }

# --------------------------------------------------------------- alma (AlmaLinux 8 and Ubuntu, in WSL)
if wanted alma; then
  echo "== AlmaLinux 8 (WSL)"
  t=$(date +%s)
  MSYS_NO_PATHCONV=1 wsl.exe -d AlmaLinux-8 -- env FC_MODE=alma sh "$SELF_L" --alma "$WO" "$SELF_L" "$WBASE" > "$O/logs/wsl-alma.log" 2>&1
  stamp wsl-alma "$t"
  MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu -- env FC_MODE=ubuntu sh "$SELF_L" --ubuntu "$WO" "$SELF_L" > "$O/logs/wsl-ubuntu.log" 2>&1
  A=$O/alma
  check ALMA-ran "the AlmaLinux 8 part ran to its end" [ -f "$A/part.done" ]
  check ALMA-rc "build-native.sh (additive, OCLJ_GLIBC_MAX=2.28) succeeds" [ "$(cat "$A/rc/build.rc" 2>/dev/null)" = 0 ]
  check ALMA-ignored-none "nothing ignored from the environment" grep -q "ignored from the environment: none " "$A/build.log"
  check ALMA-patch "patch-bitop-record.sh reports the select fix, 22 added and 36 removed of 2966" grep -q -F "$PATCHLINE" "$A/build.log"
  check ALMA-glibc "the library needs GLIBC 2.28 at most (needs 2.$(glibcmax "$A/glibc.txt"))" sh -c '[ -n "$1" ] && [ "$1" -le 28 ]' x "$(glibcmax "$A/glibc.txt")"
  check ALMA-objects "77 LuaJIT objects, only lj_record.o differs from build/native's Linux tree; our 3 objects equal" [ "$(cat "$A/rc/objcmp.rc" 2>/dev/null)" = 0 ]
  check ALMA-record-object "lj_record.o is the implementer's AlmaLinux 8 one ($REC_O_LINUX)" [ "$(cat "$A/record-o.md5" 2>/dev/null)" = "$REC_O_LINUX" ]
  check ALMA-bitjit "run-bitjit.sh, all five parts, the Linux PUC: PASS, t_select at 0 in all 15 sets" sh -c '[ "$(cat "$1/rc/bitjit-all.rc")" = 0 ] && grep -q "^RUN-BITJIT: PASS (results" "$1/bitjit-all.log" && grep -q "^PASS phiidx" "$1/bitjit-all.log" && grep -q "^PASS t_idx2: PUC" "$1/bitjit-all.log" && grep -q "^PASS t_rg2: PUC" "$1/bitjit-all.log"' x "$A"
  check ALMA-sel "the sel part: t_select 0 in all 15 sets, t_select-kmax and PUC pass, the 2^27 controls 3 of 3" selpass "$A/bitjit-all.log"
  for m in idx phi; do
    check ALMA-gen-$m "the generator in its $m mode, 4 seeds: PASS" sh -c '[ "$(cat "$1/rc/gen-$2.rc")" = 0 ] && [ "$(grep -c "^seed [0-9]*: PASS" "$1/gen-$2.log")" = 4 ]' x "$A" "$m"
  done
  if [ -f "$A/base-sel.skip" ]; then
    skip ALMA-base-sel "the base build has no Linux luajit ($(cat "$A/base-sel.skip"))"
  else
    check ALMA-base-sel "fail-first: the sel part on the base build's Linux luajit FAILs, t_select in every one of the 15 sets and t_select-kmax" basefails "$A/rc/base-sel.rc" "$A/base-sel.log"
  fi
fi

# --------------------------------------------------------------- bitjit (Windows)
if wanted bitjit; then
  echo "== bitjit"
  t=$(date +%s)
  env OCLJ_BUILD="$WB" OCLJ_LUA53="$PUCW" OCLJ_BITJIT_OUT="$O/runs/bitjit-all" sh "$R/test/native/run-bitjit.sh" > "$O/logs/bitjit-all.log" 2>&1
  echo $? > "$O/rc/bitjit-all.rc"; stamp bitjit-all "$t"
  check BITJIT-all "run-bitjit.sh, all five parts (gen, floor with t_rg2, fix1, idx, sel), PUC set: PASS" sh -c '[ "$(cat "$1/rc/bitjit-all.rc")" = 0 ] && grep -q "^RUN-BITJIT: PASS (results" "$2" && [ "$(grep -c "^seed [0-9]*: PASS" "$2")" = 4 ] && grep -q "^PASS t_rg2 (" "$2" && grep -q "^PASS t_rg2: PUC" "$2" && grep -q "^PASS fix1" "$2" && grep -q "^PASS t_idx (" "$2" && grep -q "^PASS t_cnt33 (" "$2" && grep -q "^PASS t_idx2 (" "$2" && grep -q "^PASS t_idx2: PUC" "$2" && grep -q "^PASS phiidx" "$2"' x "$O" "$O/logs/bitjit-all.log"
  check BITJIT-sel "the sel part: t_select 0 in all 15 sets, t_select-kmax and PUC pass, the 2^27 controls 3 of 3" selpass "$O/logs/bitjit-all.log"
  for ms in idx:1 rg2:1 phi:201; do
    m=${ms%%:*}; s=${ms#*:}
    t=$(date +%s)
    env OCLJ_BUILD="$WB" OCLJ_LUA53="$PUCW" OCLJ_BITJIT_PARTS=gen OCLJ_BITJIT_GENMODE=$m OCLJ_BITJIT_SEED=$s OCLJ_BITJIT_SEEDS=4 OCLJ_BITJIT_OUT="$O/runs/gen-$m" sh "$R/test/native/run-bitjit.sh" > "$O/logs/gen-$m.log" 2>&1
    echo $? > "$O/rc/gen-$m.rc"; stamp "gen-$m" "$t"
    check BITJIT-gen-$m "the generator in its $m mode, seeds $s-$((s + 3)), PUC set: PASS" sh -c '[ "$(cat "$1/rc/gen-$2.rc")" = 0 ] && [ "$(grep -c "^seed [0-9]*: PASS" "$1/logs/gen-$2.log")" = 4 ]' x "$O" "$m"
  done
fi

# --------------------------------------------------------------- base (the fail-firsts on the base build)
BLJ=$BASEB/luajit-windows-x86_64/src/luajit.exe
if wanted base; then
  echo "== base"
  md5sum "$BLJ" "$BASEB/luajit-windows-x86_64/src/lj_record.o" > "$O/cmp/base.md5" 2>&1
  t=$(date +%s)
  env OCLJ_BUILD="$BASEB" OCLJ_LUA53="$PUCW" OCLJ_BITJIT_PARTS=sel OCLJ_BITJIT_OUT="$O/runs/base-sel" sh "$R/test/native/run-bitjit.sh" > "$O/logs/base-sel.log" 2>&1
  echo $? > "$O/rc/base-sel.rc"; stamp base-sel "$t"
  check BASE-sel "fail-first: the sel part on the base build FAILs, t_select in every one of the 15 sets and t_select-kmax (PUC passes)" basefails "$O/rc/base-sel.rc" "$O/logs/base-sel.log"
  SB=$O/runs/selbug; mkdir -p "$SB"
  cp "$HERE/fc-selbug.lua" "$SB/selbug.lua"
  md5sum "$SB/selbug.lua" > "$SB/selbug.md5"
  for v in new:"$LJW" base:"$BLJ"; do
    vn=${v%%:*}; ve=${v#*:}
    for j in jon joff; do
      if [ "$j" = joff ]; then "$ve" -joff "$SB/selbug.lua" > "$SB/$vn-$j.txt" 2>&1; else "$ve" "$SB/selbug.lua" > "$SB/$vn-$j.txt" 2>&1; fi
      echo $? > "$SB/$vn-$j.rc"
      tr -d '[:cntrl:]' < "$SB/$vn-$j.txt" > "$SB/$vn-$j.flat"
    done
  done
  check SELBUG-input "fc-selbug.lua is verify-folda's probes/selbug.lua ($SELBUG_MD5)" sh -c '[ "$(md5sum < "$1" | cut -c1-32)" = "$2" ]' x "$SB/selbug.lua" "$SELBUG_MD5"
  check SELBUG-new "selbug.lua on the new build prints E 30 E 200 with the JIT on and off" sh -c '[ "$(cat "$1/new-jon.flat")" = E30E200 ] && [ "$(cat "$1/new-joff.flat")" = E30E200 ] && [ "$(cat "$1/new-jon.rc")" = 0 ]' x "$SB"
  check SELBUG-base "fail-first: on the base build selbug.lua prints n 30 E 200 with the JIT on, E 30 E 200 with it off (P54's symptom)" sh -c '[ "$(cat "$1/base-jon.flat")" = n30E200 ] && [ "$(cat "$1/base-joff.flat")" = E30E200 ]' x "$SB"
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
  grep -E '^arm [A-Z0-9-]+ ' "$R/test/native/negctl-bitop.sh" | awk '{ print $2 }' | LC_ALL=C sort > "$O/cmp/negctl-script-arms.txt"
  for a in $ARMS32; do echo "$a"; done | LC_ALL=C sort > "$O/cmp/negctl-want.txt"
  check NEGCTL-arm-list "negctl-bitop.sh's arm calls are exactly the 32 arms this check expects" cmp -s "$O/cmp/negctl-script-arms.txt" "$O/cmp/negctl-want.txt"
  t=$(date +%s)
  if [ -n "${FC_NEGCTL_ARMS:-}" ]; then
    env PATH="$TOOLS:$PATH" OCLJ_BUILD="$WB" OCLJ_LUAJIT="$PLW" OCLJ_LUA53="$PUCW" OCLJ_JNI="$JNIW" CC=gcc OCLJ_NEGCTL_ARMS="$FC_NEGCTL_ARMS" sh "$R/test/native/negctl-bitop.sh" > "$O/logs/negctl-bitop.log" 2>&1
  else
    env PATH="$TOOLS:$PATH" OCLJ_BUILD="$WB" OCLJ_LUAJIT="$PLW" OCLJ_LUA53="$PUCW" OCLJ_JNI="$JNIW" CC=gcc sh "$R/test/native/negctl-bitop.sh" > "$O/logs/negctl-bitop.log" 2>&1
  fi
  echo $? > "$O/rc/negctl-bitop.rc"; stamp negctl-bitop "$t"
  NL=$O/logs/negctl-bitop.log
  grep -E '^.negctl-bitop. [A-Z0-9-]+ [(].*: PASS [(]caught by' "$NL" | awk '{ print $2 }' | LC_ALL=C sort > "$O/cmp/negctl-caught.txt"
  check NEGCTL-rc "negctl-bitop.sh, every arm: exit 0 and the full-sweep PASS line" sh -c '[ "$(cat "$1/rc/negctl-bitop.rc")" = 0 ] && grep -q "^NEGCTL-BITOP: PASS (canon passes; every sabotage is caught" "$2"' x "$O" "$NL"
  check NEGCTL-canon "canon passes, every object reproduced, pristine files from the build's export" sh -c 'grep -q "^.negctl-bitop. canon (-, .*: PASS (every catcher passes; every object reproduced)" "$1" && grep -q "pristine files from .*luajit-export-windows-x86_64/src" "$1"' x "$NL"
  check NEGCTL-32-arms "exactly the 32 arms, each caught by its catchers (SELGUARD by sel:t_select, SELRECK by sel:kmax among them)" sh -c 'cmp -s "$1" "$2" && grep -q "^.negctl-bitop. SELGUARD (.*: PASS (caught by sel:t_select)" "$3" && grep -q "^.negctl-bitop. SELRECK (.*: PASS (caught by sel:kmax)" "$3"' x "$O/cmp/negctl-caught.txt" "$O/cmp/negctl-want.txt" "$NL"
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

# --------------------------------------------------------------- hygiene
if wanted hygiene; then
  echo "== hygiene"
  for f in $CHANGED7; do echo "$f"; done | LC_ALL=C sort > "$O/cmp/changed-want.txt"
  check CHANGED-SET "the working tree changes exactly the round's seven files (cmp/changed-want.txt)" cmp -s "$O/changed-files.txt" "$O/cmp/changed-want.txt"
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
  P=$R/native/luajit/patch-bitop-record.sh
  check PATCH-NO-TAB-BS "patch-bitop-record.sh holds no tab and no backslash" sh -c '[ "$1" = 0 ] && [ "$2" = 0 ]' x "$(bytecount 09 "$P")" "$(bytecount 5c "$P")"
  check TSELECT-NO-BS "t_select.lua holds no backslash, as its header says" [ "$(bytecount 5c "$R/test/native/bitop/t_select.lua")" = 0 ]
  PS=$O/ps; mkdir -p "$PS"
  PIN=$(cat "$R/native/luajit/upstream.commit")
  for f in lj_record.c lj_opt_narrow.c lj_trace.c lj_ffrecord.c; do
    git --no-replace-objects -C "$PL" cat-file blob "$PIN:src/$f" > "$PS/pristine-$f"
  done
  cp "$PS/pristine-lj_record.c" "$PS/pristine.c"
  TMPDIR=$PS sh "$P" "$PS/pristine.c" "$PS/out1.c" > "$PS/run1.log" 2>&1; echo $? > "$O/rc/ps-run1.rc"
  TMPDIR=$PS sh "$P" "$PS/out1.c" "$PS/out2.c" > "$PS/run2.log" 2>&1; echo $? > "$O/rc/ps-run2.rc"
  check PATCH-PRISTINE "on the pin's pristine blob: 22 added, 36 removed of 2966, verified by content, diff and reversal" sh -c '[ "$(cat "$1/rc/ps-run1.rc")" = 0 ] && grep -q -F "$2" "$1/ps/run1.log"' x "$O" "$PATCHLINE"
  check PATCH-IDEMPOTENT "on its own output: verified, unchanged, the same bytes" sh -c '[ "$(cat "$1/rc/ps-run2.rc")" = 0 ] && grep -q -F "$2" "$1/ps/run2.log" && cmp -s "$1/ps/out1.c" "$1/ps/out2.c"' x "$O" "$IDEMLINE"
  check PATCH-IS-BUILD-COPY "its output is the build copy's lj_record.c, byte for byte ($REC_C_MD5)" sh -c 'cmp -s "$1" "$2" && [ "$(md5sum < "$1" | cut -c1-32)" = "$3" ]' x "$PS/out1.c" "$WB/luajit-windows-x86_64/src/lj_record.c" "$REC_C_MD5"
  cp "$PS/out1.c" "$PS/patched-lj_record.c"
  PSW=$(winpath_of "$PS")
  python -I "$HERE/fc-citecheck.py" "$RW" "$PSW/patched-lj_record.c" > "$O/cmp/cites.txt" 2>&1; echo $? > "$O/rc/cites.rc"
  python -I "$HERE/fc-citecheck.py" "$RW" "$PSW/patched-lj_record.c" 1 > "$O/cmp/cites-shift1.txt" 2>&1; echo $? > "$O/rc/cites-shift1.rc"
  check DOCS-CITES "the guide's line cites into the round's files hold, and every cite moved down one line fails ($(tail -1 "$O/cmp/cites.txt"); moved: $(tail -1 "$O/cmp/cites-shift1.txt"))" sh -c '[ "$(cat "$1/rc/cites.rc")" = 0 ] && [ "$(cat "$1/rc/cites-shift1.rc")" = 1 ] && grep -q "bad=0 shift=0" "$1/cmp/cites.txt" && ! grep -q "bad=0 shift=1" "$1/cmp/cites-shift1.txt"' x "$O"
  python -I "$HERE/fc-anchorcheck.py" "$RW/docs/jit-guide.md" > "$O/cmp/anchors.txt" 2>&1; echo $? > "$O/rc/anchors.rc"
  check DOCS-ANCHORS "every in-page link of the guide names a heading ($(tail -1 "$O/cmp/anchors.txt"))" rcis anchors 0
  python -I "$HERE/fc-tablecheck.py" "$RW/docs/jit-guide.md" > "$O/cmp/tables.txt" 2>&1; echo $? > "$O/rc/tables.rc"
  check DOCS-TABLES "every table row of the guide has its header's cell count ($(tail -1 "$O/cmp/tables.txt"))" rcis tables 0
fi

# --------------------------------------------------------------- timing (last)
if wanted timing; then
  echo "== timing"
  T=$O/timing; mkdir -p "$T"
  cp "$HERE/fc-bench_sel.lua" "$T/bench_sel.lua" && cp "$HERE/fc-summarize.py" "$T/fc-summarize.py"
  md5sum "$T/bench_sel.lua" "$BLJ" "$LJW" "$BASEB/luajit-windows-x86_64/src/lj_record.o" "$WB/luajit-windows-x86_64/src/lj_record.o" > "$T/inputs.md5" 2>&1
  check TIMING-inputs "the bench is fc-bench_sel.lua ($BENCH_MD5); base's lj_record.o is build/native's ($BASE_REC_O_WIN), new's the fix's ($REC_O_WIN)" sh -c '[ "$(md5sum < "$1" | cut -c1-32)" = "$2" ] && [ "$(md5sum < "$3" | cut -c1-32)" = "$4" ] && [ "$(md5sum < "$5" | cut -c1-32)" = "$6" ]' x "$T/bench_sel.lua" "$BENCH_MD5" "$BASEB/luajit-windows-x86_64/src/lj_record.o" "$BASE_REC_O_WIN" "$WB/luajit-windows-x86_64/src/lj_record.o" "$REC_O_WIN"
  NB=$(awk -v n=1e8 -v d="$FC_NDIV" 'BEGIN { printf "%d", n / d }')
  powershell -NoProfile -Command "(Get-CimInstance Win32_Processor).LoadPercentage" > "$T/cpuload-before.txt" 2>/dev/null
  $TASKLIST > "$T/procs-before.txt" 2>/dev/null
  r=1; stopped=0
  while [ "$r" -le "$FC_ROUNDS" ]; do
    if javacheck "$T/jvms-round-$r.txt"; then
      { echo "STOPPED before round $r: a Java process started"; cat "$T/jvms-round-$r.txt"; } > "$T/STOPPED"
      stopped=1; break
    fi
    if [ $((r % 2)) = 1 ]; then ORDER="base new"; else ORDER="new base"; fi
    p=1
    for v in $ORDER; do
      if [ "$v" = base ]; then E=$BLJ; else E=$LJW; fi
      ( cd "$T" && "$E" bench_sel.lua "$NB" 2>&1 ) | awk -v r="$r" -v p="$p" -v v="$v" '{ sub(/[[:cntrl:]]+$/, ""); print "round=" r " pos=" p " vm=" v " " $0 }' >> "$T/raw.txt"
      p=$((p + 1))
    done
    echo "round $r done $(date -u +%H:%M:%SZ) order: $ORDER" >> "$T/progress.txt"
    r=$((r + 1))
  done
  powershell -NoProfile -Command "(Get-CimInstance Win32_Processor).LoadPercentage" > "$T/cpuload-after.txt" 2>/dev/null
  $TASKLIST > "$T/procs-after.txt" 2>/dev/null
  python -I "$T/fc-summarize.py" "$T/raw.txt" > "$T/summary.txt" 2>&1; echo $? > "$O/rc/timing-summary.rc"
  check TIMING-complete "all $FC_ROUNDS rounds ran (no Java process appeared)" sh -c '[ "$1" = 0 ] && [ "$(grep -c "^round [0-9]* done" "$2")" = "$3" ]' x "$stopped" "$T/progress.txt" "$FC_ROUNDS"
  check TIMING-results-equal "every result of the new build equals base's, in every round, six rows (timing/summary.txt)" sh -c 'grep -q "^RESULTS: EQUAL" "$1" && grep -q "^SUMMARY: OK" "$1"' x "$T/summary.txt"
  if [ "$FC_NDIV" = 1 ]; then
    check TIMING-no-gross-change "each row's median new/base within [0.5, 2.0] (a smoke bound; the ratios are in timing/summary.txt)" grep -q "^GROSS: OK" "$T/summary.txt"
  else
    skip TIMING-no-gross-change "FC_NDIV=$FC_NDIV: a smoke reading, too short to time"
  fi
fi

# --------------------------------------------------------------- census and md5s after
echo "== census after"
t=$(date +%s); census "$O/census/after"; stamp census-after "$t"
check CENSUS-build "every file under build/ has its $FC_CENSUS entry of the start, none added or removed ($(wc -l < "$O/census/before-build.md5" | tr -d ' ') files)" cmp -s "$O/census/before-build.md5" "$O/census/after-build.md5"
check CENSUS-pristine-stat "the pristine checkout's stat list (mtimes included) is unchanged" cmp -s "$O/census/before-pristine-stat.txt" "$O/census/after-pristine-stat.txt"
check CENSUS-pristine-git "the pristine checkout's .git md5 list and HEAD are unchanged" sh -c 'cmp -s "$1-pristine-git.md5" "$2-pristine-git.md5" && cmp -s "$1-pristine-head.txt" "$2-pristine-head.txt"' x "$O/census/before" "$O/census/after"
( cd "$R" && { git diff --name-only HEAD; git ls-files --others --exclude-standard; } | LC_ALL=C sort -u ) > "$O/changed-files-end.txt"
mdstate "$O/md5-end.txt"
check FILES-unchanged "the changed files (the same list), this script and its helpers are unchanged since the start; the repo's HEAD too" sh -c 'cmp -s "$1/changed-files.txt" "$1/changed-files-end.txt" && cmp -s "$1/md5-start.txt" "$1/md5-end.txt" && [ "$(git -C "$2" rev-parse HEAD)" = "$(cat "$1/repo-head.txt")" ]' x "$O" "$R"
NF=$(grep -c '^FAIL ' "$SUM"); NP=$(grep -c '^PASS ' "$SUM"); NS=$(grep -c '^SKIP ' "$SUM")
echo "PASS $NP FAIL $NF SKIP $NS secs $(( $(date +%s) - T0 )) parts [$FC_PARTS] FC_USE_BUILD=${FC_USE_BUILD:-unset} FC_BASE_BUILD=${FC_BASE_BUILD:-unset} FC_ROUNDS=$FC_ROUNDS FC_NDIV=$FC_NDIV FC_NEGCTL_ARMS=${FC_NEGCTL_ARMS:-unset} FC_CENSUS=$FC_CENSUS final-check.sh $(md5sum < "$SELF" | cut -c1-32)" > "$O/ALL.done"
cat "$O/ALL.done"
