#!/bin/sh
# final-check2.sh <outdir> -- the pin round 5 verification chain: everything pin4/final/final-check.sh
# checks, plus the cases round 4's review found, on the repo's build-native.sh as it stands.
# Run from Git Bash:   sh final-check2.sh <fresh outdir>   (well under 30 minutes)
#
# It refuses an outdir that exists, writes everything under it, reads every exit code into a
# file (<outdir>/rc/, <outdir>/alma/rc/), never writes under the repo's build/ (fresh
# OCLJ_BUILDs under <outdir>/b and <outdir>/t; gradle only as ./gradlew --offline --no-daemon
# verifyModAssets on scratch natives dirs), never touches prototype/watchdog/luajit (it is read
# by the pinned builds) nor round 3's scratch clones (read only; U2L clones one with
# git clone --no-hardlinks into <outdir>), and runs its Linux parts by invoking itself in WSL
# (MSYS_NO_PATHCONV=1 wsl.exe -d <distro> -- env ... sh /mnt/c/.../final-check2.sh --alma ...),
# whose exit codes it reads from the files that part writes.  <outdir>/summary.txt gets one PASS
# or FAIL line per check; <outdir>/ALL.done is written last, with the counts, the elapsed
# seconds and the md5 of the build-native.sh it ran.
#
# FC_SCRIPT=<copy>/native/build-native.sh runs every build, Windows and AlmaLinux 8, with that
# copy instead (a fail-first run on an older text); its builds then get OCLJ_REPO=<the repo>.
# Keep the copy in a directory of its own (<copy>/native/): since round 5 a script guards its
# own parent repository, <copy>, as it guards OCLJ_REPO.
#
# Checks (round 4's chain, then round 5's):
#   W1  canonical pinned builds: Windows additive and dropin into fresh OCLJ_BUILDs, objects
#       against build/native's (additive) and round 2's dropin reference; the additive's dist
#       copy byte-equal to its own libdir-additive output; AlmaLinux 8 with
#       OCLJ_GLIBC_MAX=2.28, additive and dropin, .so md5s against the release's; each log's
#       "ignored from the environment: none".
#   G2  CFLAGS='-include <inject.h>', cpath (lower case) naming a directory whose stdint.h adds a
#       marker, and MAKEFLAGS='TARGET_CFLAGS=-O0': objects equal W1's, no marker, the names
#       in the "ignored" line.
#   MO  MAKEOVERRIDES=CFLAGS=-O0: objects equal W1's, no -O0 line, the "ignored" line names it.
#   R1-R3, F2, F7, export-ignore: round 3's scratch clones in claude-tmp/oclj/pin3/impl/clones.
#   U2, U3  round 4's directory-guard refusals (junction/.., non-ASCII other case).
#   U2L OCLJ_BUILD=<x>/<junction>/.. with a throwaway clone at the lexical <x>/luajit-<platform>:
#       the clone's files and .git unchanged; the build lands in the junction's target.
#   T1  OCLJ_OUT=<B>/dist. (a trailing dot): refused, dist intact.
#   T2  OCLJ_OUT=<B>/j/../dist, j a junction to else/sub: dist intact, the library in else/dist.
#   T4  OCLJ_BUILD=<E>/Bäu, OCLJ_OUT=<E>/BÄU/dist, neither made: refused, nothing created.
#   SHIM-dot  OCLJ_SHIM=<E>/shim. beside a decoy <E>/shim: refused, nothing built.
#   SER-dot   OCLJ_SER=<E>/ser.: refused, nothing created.
#   G3  OCLJ_BUILD inside a scratch OCLJ_REPO outside its build/ (directly, other ASCII case,
#       through a junction): refused before anything is created; under its build/: allowed.
#   H2  the script itself in a scratch repository, OCLJ_REPO the real one: OCLJ_BUILD in the
#       scratch repository's serializer/tests refused, the scratch repository unchanged;
#       OCLJ_OUT in its build/native/dist refused, that dist intact.
#   ALMA  AlmaLinux 8 replays of U2, U3 and G3 (symlink/.., non-ASCII other case on /mnt/c,
#       G3 in, case, symlink, under build/) and T4, end to end, each refused in the preflight.
#   gradle accepts W1's pinned DLL and refuses an unpinned build's DLL.
#   negctl-bitop.sh with OCLJ_NEGCTL_ARMS=SARCONST on W1's additive build.
#   hygiene: sh -n in Git Bash, AlmaLinux 8 and Ubuntu (dash); CR bytes 0 in the five files
#   the pin rounds own; git diff --check; build/ md5 census and the pristine checkout's stat list
#   and .git md5 list identical before and after; this script and build-native.sh unchanged.
# Written with a file tool: no heredocs; its only backslashes end continued lines.
set -u
DRIVE_REPO=/c/Users/astro/Downloads/OC-LuaJIT
WSL_REPO=/mnt/c/Users/astro/Downloads/OC-LuaJIT
SELF_W=/c/Users/astro/claude-tmp/oclj/pin5/final/final-check2.sh
SELF_L=/mnt/c/Users/astro/claude-tmp/oclj/pin5/final/final-check2.sh
SO_ADD=6c88805001bae0cd2b385803f5d857c7
SO_DROP=6c0715d11344c5fe075cd33f4f93cdbc
STAMP_WANT='1ee778a4|LuaJIT 2.1.ROLLING|412be694'
CL=/c/Users/astro/claude-tmp/oclj/pin3/impl/clones
CLL=/mnt/c/Users/astro/claude-tmp/oclj/pin3/impl/clones

# cmpobj <build A> <build B> <platform> <out prefix>: md5 of the 77 LuaJIT objects and
# obj-<platform>'s .o files in A against B; 0 iff equal and 77 LuaJIT objects and 3 of ours.
cmpobj() {
  ( cd "$1/luajit-$3/src" && md5sum *.o host/*.o ) | tr -d '*' | sort -k2 > "$4.A-lj.md5"
  ( cd "$2/luajit-$3/src" && md5sum *.o host/*.o ) | tr -d '*' | sort -k2 > "$4.B-lj.md5"
  ( cd "$1/obj-$3" && md5sum *.o ) | tr -d '*' | sort -k2 > "$4.A-obj.md5"
  ( cd "$2/obj-$3" && md5sum *.o ) | tr -d '*' | sort -k2 > "$4.B-obj.md5"
  co_n=$(wc -l < "$4.A-lj.md5" | tr -d ' ')
  co_o=$(wc -l < "$4.A-obj.md5" | tr -d ' ')
  diff "$4.A-lj.md5" "$4.B-lj.md5" > "$4.diff" && diff "$4.A-obj.md5" "$4.B-obj.md5" >> "$4.diff" \
    && [ "$co_n" = 77 ] && [ "$co_o" = 3 ]
}
treemd5() { if [ -d "$1" ]; then ( cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ); else echo "ABSENT $1"; fi; }
treels() { if [ -d "$1" ]; then ( cd "$1" && find . | LC_ALL=C sort ); else echo "ABSENT $1"; fi; }
mkthrow() {
  mkdir -p "$1/.git" "$1/src" || return 1
  echo 'ref: refs/heads/master' > "$1/.git/HEAD"
  echo "throwaway marker: must survive" > "$1/MARKER.txt"
  echo '/* LUAJIT_ENABLE_CHECKHOOK */' > "$1/src/lj_record.c"
}

# --------------------------------------------------------------- the Linux parts (in WSL)
# alma_part <outdir, WSL form> <script, WSL form> <1: pass OCLJ_REPO=the repo>
alma_part() {
  A=$1/alma
  AS=$2
  FCR=
  [ "$3" = 1 ] && FCR=OCLJ_REPO=$WSL_REPO
  mkdir "$A" || exit 98
  mkdir -p "$A/rc" "$A/logs" "$A/t" || exit 98
  { uname -a; gcc --version | head -1; git --version; md5sum "$AS"; readlink -f /bin/sh; } > "$A/host.txt" 2>&1
  sh -n "$AS" > "$A/shn.log" 2>&1; echo $? > "$A/shn.rc"
  for v in add drop; do
    case $v in add) var=additive ;; drop) var=dropin ;; esac
    env OCLJ_JNI=/usr/lib/jvm/java-1.8.0-openjdk/include OCLJ_JNLUA=/mnt/c/Users/astro/Downloads/OC-JNLua \
      CC=gcc $FCR OCLJ_BUILD="$A/b-$v" OCLJ_VARIANT=$var OCLJ_GLIBC_MAX=2.28 sh "$AS" > "$A/build-$v.log" 2>&1
    echo $? > "$A/build-$v.rc"
  done
  md5sum < "$A/b-add/libdir-additive/libjnluajit52-linux-x86_64.so" | cut -c1-32 > "$A/so-add.md5" 2>/dev/null
  md5sum < "$A/b-drop/libdir/libjnlua52-linux-x86_64.so" | cut -c1-32 > "$A/so-drop.md5" 2>/dev/null
  cmpobj "$A/b-add" "$WSL_REPO/build/native" linux-x86_64 "$A/cmp-add-vs-buildnative"; echo $? > "$A/cmp-add.rc"
  grep -h 'ignored from the environment:' "$A/build-add.log" "$A/build-drop.log" > "$A/ignored.txt"
  grep -h -E 'glibc: highest|export verified' "$A/build-add.log" "$A/build-drop.log" > "$A/gates.txt"
  # ab <label> <OCLJ_BUILD> [VAR=value...]: one AlmaLinux 8 run; later VAR=value override.
  ab() {
    ab_l=$1; ab_b=$2; shift 2
    env OCLJ_JNI=/usr/lib/jvm/java-1.8.0-openjdk/include OCLJ_JNLUA=/mnt/c/Users/astro/Downloads/OC-JNLua \
      CC=gcc $FCR OCLJ_BUILD="$ab_b" "$@" sh "$AS" > "$A/logs/$ab_l.log" 2>&1
    echo $? > "$A/rc/$ab_l.rc"
  }
  T=$A/t
  # U2 symlink/..: OCLJ_BUILD=<E>/x/link/.., link -> y/sub, so physically <E>/y; the throwaway at
  # <E>/y/luajit-linux-x86_64.
  E=$T/u2dd; mkdir -p "$E/y/sub" "$E/x"; ln -s "$E/y/sub" "$E/x/link"
  TW=$E/y/luajit-linux-x86_64; mkthrow "$TW"; treemd5 "$TW" > "$T/u2dd.before.md5"
  ab u2-dd "$E/x/link/.." OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT="$TW"
  treemd5 "$TW" > "$T/u2dd.after.md5"
  # U2 case on /mnt/c (NTFS): OCLJ_BUILD <E>/Bäu, the throwaway named through <E>/BÄU.
  E=$T/u2case; mkdir -p "$E/Bäu"
  TW=$E/Bäu/luajit-linux-x86_64; mkthrow "$TW"; treemd5 "$TW" > "$T/u2case.before.md5"
  ab u2-case "$E/Bäu" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT="$E/BÄU/luajit-linux-x86_64"
  treemd5 "$TW" > "$T/u2case.after.md5"
  # U3 symlink/..: OCLJ_BUILD <E>/B, OCLJ_OUT <E>/q/l/../dist, q/l -> B/sub: physically B/dist.
  E=$T/u3dd; mkdir -p "$E/B/sub" "$E/B/dist" "$E/q/dist"; ln -s "$E/B/sub" "$E/q/l"
  echo 'the release library: must survive' > "$E/B/dist/libjnluajit52-linux-x86_64.so"
  treemd5 "$E/B/dist" > "$T/u3dd.before.md5"
  ab u3-dd "$E/B" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT="$CLL/lj-clean" OCLJ_OUT="$E/q/l/../dist"
  treemd5 "$E/B/dist" > "$T/u3dd.after.md5"
  # U3 case: OCLJ_BUILD <E>/Bäu holding dist, OCLJ_OUT <E>/BÄU/dist.
  E=$T/u3case; mkdir -p "$E/Bäu/dist"
  echo 'the release library: must survive' > "$E/Bäu/dist/libjnluajit52-linux-x86_64.so"
  treemd5 "$E/Bäu/dist" > "$T/u3case.before.md5"
  ab u3-case "$E/Bäu" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT="$CLL/lj-clean" OCLJ_OUT="$E/BÄU/dist"
  treemd5 "$E/Bäu/dist" > "$T/u3case.after.md5"
  # T4: neither made.
  E=$T/t4; mkdir -p "$E"
  ab t4 "$E/Bäu" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT="$CLL/lj-clean" OCLJ_OUT="$E/BÄU/dist"
  ls -A "$E" > "$T/t4.ls"
  # G3: a scratch OCLJ_REPO.
  FR=$T/g3repo
  mkdir -p "$FR/native/luajit" "$FR/serializer/tests"
  cp "$WSL_REPO/native/luajit/upstream.commit" "$WSL_REPO/native/luajit/oclj_features.h" "$FR/native/luajit/"
  echo '-- a tracked file of the scratch repository: must survive' > "$FR/serializer/tests/strpack.lua"
  treemd5 "$FR" > "$T/g3repo.before.md5"; treels "$FR" > "$T/g3repo.before.ls"
  ab g3-in "$FR/serializer/tests" OCLJ_REPO="$FR" OCLJ_SHIM=$WSL_REPO/native OCLJ_SER=$WSL_REPO/serializer OCLJ_LUAJIT=$CLL/lj-clean OCLJ_VARIANT=additive
  ab g3-case "$FR/SERIALIZER/newdir" OCLJ_REPO="$FR" OCLJ_SHIM=$WSL_REPO/native OCLJ_SER=$WSL_REPO/serializer OCLJ_LUAJIT=$CLL/lj-clean OCLJ_VARIANT=additive
  ln -s "$FR/serializer" "$T/g3link"
  ab g3-symlink "$T/g3link/tests" OCLJ_REPO="$FR" OCLJ_SHIM=$WSL_REPO/native OCLJ_SER=$WSL_REPO/serializer OCLJ_LUAJIT=$CLL/lj-clean OCLJ_VARIANT=additive
  treemd5 "$FR" > "$T/g3repo.after.md5"; treels "$FR" > "$T/g3repo.after.ls"
  ab g3-build "$FR/build/native" OCLJ_REPO="$FR" OCLJ_SHIM=$WSL_REPO/native OCLJ_SER=$WSL_REPO/serializer OCLJ_LUAJIT=$CLL/lj-clean OCLJ_VARIANT=additive OCLJ_JNLUA="$T/no-jnlua-here"
  echo done > "$A/part.done"
}
ubuntu_part() {
  U=$1/ubuntu
  mkdir "$U" || exit 98
  { readlink -f /bin/sh; uname -a; } > "$U/host.txt" 2>&1
  sh -n "$2" > "$U/shn.log" 2>&1; echo $? > "$U/shn.rc"
  echo done > "$U/part.done"
}
case ${1:-} in
  --alma) alma_part "$2" "$3" "$4"; exit 0 ;;
  --ubuntu) ubuntu_part "$2" "$3"; exit 0 ;;
esac

# --------------------------------------------------------------- Windows: setup
O=${1:-}
[ -n "$O" ] || { echo "usage: sh final-check2.sh <fresh outdir>"; exit 2; }
[ -e "$O" ] && { echo "refusing: $O exists (never reuse a results directory)"; exit 97; }
mkdir -p "$O" || exit 98
O=$(CDPATH= cd -P -- "$O" && pwd -P)
case $O in "$DRIVE_REPO"|"$DRIVE_REPO"/*) echo "refusing: $O is inside the repo"; exit 97 ;; esac
R=$DRIVE_REPO
S=${FC_SCRIPT:-$R/native/build-native.sh}
S=$(CDPATH= cd -P -- "$(dirname -- "$S")" && pwd -P)/$(basename -- "$S")
[ -f "$S" ] || { echo "no script $S"; exit 2; }
FCREPO=${FC_SCRIPT:+OCLJ_REPO=$R}
FCFLAG=0; [ -n "${FC_SCRIPT:-}" ] && FCFLAG=1
BN=$R/build/native
C=$CL
E3=/c/Users/astro/claude-tmp/oclj/pin3/impl/exp
DROPREF=/c/Users/astro/claude-tmp/oclj/pin2/impl/win-v1/canon-dropin
INJ_SRC=/c/Users/astro/claude-tmp/oclj/pin3/verify/exp/inject.h
TOOLS=/c/Users/astro/claude-tmp/oclj/bin
JNIW="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include"
JNLUAW=C:/Users/astro/Downloads/OC-JNLua
PL=$R/prototype/watchdog/luajit
DLLA=libjnluajit52-windows-x86_64.dll
WD=$(echo "$O" | cut -c2)
WO=/mnt/$WD$(echo "$O" | cut -c3-)
SD=$(echo "$S" | cut -c2)
SL=/mnt/$SD$(echo "$S" | cut -c3-)
mkdir -p "$O/logs" "$O/rc" "$O/b" "$O/cmp" "$O/t" "$O/census" || exit 98
SUM=$O/summary.txt
: > "$SUM"
T0=$(date +%s)
date -u +%Y-%m-%dT%H:%M:%SZ > "$O/start-time.txt"
md5sum "$S" "$SELF_W" > "$O/md5-start.txt"
echo "script $S (WSL $SL) FC_SCRIPT=${FC_SCRIPT:-unset}" > "$O/script.txt"

res() { echo "$1 $2: $3" >> "$SUM"; echo "$1 $2: $3"; }
# check <id> <text> <command...>: PASS when the command succeeds
check() {
  ck_i=$1; ck_t=$2; shift 2
  if "$@" >> "$O/logs/checks.log" 2>&1; then res PASS "$ck_i" "$ck_t"; else res FAIL "$ck_i" "$ck_t"; fi
}
rcis() { [ "$(cat "$O/rc/$1.rc" 2>/dev/null)" = "$2" ]; }
# wbs <label> <script> <OCLJ_BUILD> [VAR=value...]: one Windows run of <script>; rc into rc/<label>.rc
wbs() {
  wb_l=$1; wb_s=$2; wb_b=$3; shift 3
  wb_t=$(date +%s)
  env PATH="$TOOLS:$PATH" OCLJ_JNI="$JNIW" OCLJ_JNLUA="$JNLUAW" OCLJ_BUILD="$wb_b" "$@" sh "$wb_s" > "$O/logs/$wb_l.log" 2>&1
  wb_r=$?
  echo "$wb_r" > "$O/rc/$wb_l.rc"
  echo "build $wb_l rc=$wb_r secs=$(( $(date +%s) - wb_t ))" >> "$O/logs/timing.txt"
  return 0
}
# wb <label> <OCLJ_BUILD> [VAR=value...]: one Windows build with the script under test
wb() { wb_l0=$1; wb_b0=$2; shift 2; wbs "$wb_l0" "$S" "$wb_b0" $FCREPO "$@"; }
stampof() { grep -a -o -m1 '[0-9a-z]*|LuaJIT 2[.]1[.][A-Z0-9]*|[0-9a-f]*' "$1/obj-windows-x86_64/eris_lj.o" 2>/dev/null | head -1; }
junction() { MSYS_NO_PATHCONV=1 cmd.exe /c mklink /J "$(cygpath -w "$1")" "$(cygpath -w "$2")" > /dev/null; }
census() { # census <prefix>
  ( cd "$R" && find build -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ) > "$1-build.md5"
  ( cd "$PL" && find . -print0 | LC_ALL=C sort -z | xargs -0 stat -c '%Y %s %n' ) > "$1-pristine-stat.txt"
  ( cd "$PL" && find .git -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ) > "$1-pristine-git.md5"
}
# guardfail <label> <text>: the run failed, and its log carries <text>
guardfail() { [ "$(cat "$O/rc/$1.rc" 2>/dev/null)" != 0 ] && [ -f "$O/rc/$1.rc" ] && grep -q -F -- "$2" "$O/logs/$1.log"; }
dllst() { if [ -f "$1" ]; then echo "$(md5sum < "$1" | cut -c1-32) $(grep -a -o -m1 '[0-9a-z]*|LuaJIT 2[.]1[.][A-Z0-9]*|[0-9a-f]*' "$1" | head -1)"; else echo "ABSENT $1"; fi; }

echo "== census before"
census "$O/census/before"

# --------------------------------------------------------------- W1, Windows
echo "== W1 Windows"
wb w1-add "$O/b/w1-add" OCLJ_VARIANT=additive
wb w1-drop "$O/b/w1-drop"
check W1-win-additive-rc "the canonical additive build succeeds" rcis w1-add 0
check W1-win-dropin-rc "the canonical dropin build succeeds" rcis w1-drop 0
check W1-win-additive-objects "additive: 77 LuaJIT objects and 3 of ours equal build/native's" \
  cmpobj "$O/b/w1-add" "$BN" windows-x86_64 "$O/cmp/w1-add-vs-buildnative"
check W1-win-dropin-objects "dropin: 77 and 3 equal round 2's dropin reference (pin2/impl/win-v1/canon-dropin)" \
  cmpobj "$O/b/w1-drop" "$DROPREF" windows-x86_64 "$O/cmp/w1-drop-vs-pin2ref"
check W1-win-stamp "the additive's fingerprint is $STAMP_WANT" [ "$(stampof "$O/b/w1-add")" = "$STAMP_WANT" ]
check W1-win-ignored-none "both logs: 'ignored from the environment: none'" \
  sh -c 'grep -q "ignored from the environment: none " "$1" && grep -q "ignored from the environment: none " "$2"' x "$O/logs/w1-add.log" "$O/logs/w1-drop.log"
check W1-win-export "the export is verified (8 trees, 232 files)" grep -q -F "8 trees to their names, 232 files to the pin's blob ids" "$O/logs/w1-add.log"
dllst "$O/b/w1-add/libdir-additive/$DLLA" > "$O/cmp/w1-dist.txt"
dllst "$O/b/w1-add/dist/$DLLA" >> "$O/cmp/w1-dist.txt"
check W1-win-dist "the additive's dist copy has the md5 of its own libdir-additive output" \
  sh -c '[ -f "$1/dist/$2" ] && [ "$(md5sum < "$1/dist/$2")" = "$(md5sum < "$1/libdir-additive/$2")" ]' x "$O/b/w1-add" "$DLLA"
REL=$O/b/w1-add/libdir-additive/$DLLA

# --------------------------------------------------------------- AlmaLinux 8 (W1 and the replays); sh -n there and in Ubuntu
echo "== AlmaLinux 8 (WSL)"
t=$(date +%s)
MSYS_NO_PATHCONV=1 wsl.exe -d AlmaLinux-8 -- env FC_MODE=alma sh "$SELF_L" --alma "$WO" "$SL" "$FCFLAG" > "$O/logs/wsl-alma.log" 2>&1
echo "wsl alma secs=$(( $(date +%s) - t ))" >> "$O/logs/timing.txt"
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu -- env FC_MODE=ubuntu sh "$SELF_L" --ubuntu "$WO" "$SL" > "$O/logs/wsl-ubuntu.log" 2>&1
A=$O/alma
check W1-alma-ran "the AlmaLinux 8 part ran to its end" [ -f "$A/part.done" ]
check W1-alma-additive-rc "AlmaLinux 8 additive build (OCLJ_GLIBC_MAX=2.28) succeeds" [ "$(cat "$A/build-add.rc" 2>/dev/null)" = 0 ]
check W1-alma-dropin-rc "AlmaLinux 8 dropin build (OCLJ_GLIBC_MAX=2.28) succeeds" [ "$(cat "$A/build-drop.rc" 2>/dev/null)" = 0 ]
check W1-alma-so-additive "additive .so md5 is the release's $SO_ADD" [ "$(cat "$A/so-add.md5" 2>/dev/null)" = "$SO_ADD" ]
check W1-alma-so-dropin "dropin .so md5 is the release's $SO_DROP" [ "$(cat "$A/so-drop.md5" 2>/dev/null)" = "$SO_DROP" ]
check W1-alma-objects "AlmaLinux 8 additive: 77 and 3 objects equal build/native's Linux ones" [ "$(cat "$A/cmp-add.rc" 2>/dev/null)" = 0 ]
check W1-alma-ignored-none "both AlmaLinux 8 logs: 'ignored from the environment: none'" [ "$(grep -c 'ignored from the environment: none ' "$A/ignored.txt" 2>/dev/null)" = 2 ]
check ALMA-U2-symlink-dotdot "AlmaLinux 8: OCLJ_BUILD <symlink>/..: refused (a directory this script removes), the throwaway intact" \
  sh -c '[ -f "$1/rc/u2-dd.rc" ] && [ "$(cat "$1/rc/u2-dd.rc")" != 0 ] && grep -q "a directory this script" "$1/logs/u2-dd.log" && cmp -s "$1/t/u2dd.before.md5" "$1/t/u2dd.after.md5"' x "$A"
check ALMA-U2-nonascii-case "AlmaLinux 8, on /mnt/c: OCLJ_LUAJIT in non-ASCII other case: refused, the throwaway intact" \
  sh -c '[ -f "$1/rc/u2-case.rc" ] && [ "$(cat "$1/rc/u2-case.rc")" != 0 ] && grep -q "a directory this script" "$1/logs/u2-case.log" && cmp -s "$1/t/u2case.before.md5" "$1/t/u2case.after.md5"' x "$A"
check ALMA-U3-symlink-dotdot "AlmaLinux 8: OCLJ_OUT <symlink>/../dist: refused (the collection point), dist intact" \
  sh -c '[ -f "$1/rc/u3-dd.rc" ] && [ "$(cat "$1/rc/u3-dd.rc")" != 0 ] && grep -q "the collection point" "$1/logs/u3-dd.log" && cmp -s "$1/t/u3dd.before.md5" "$1/t/u3dd.after.md5"' x "$A"
check ALMA-U3-nonascii-case "AlmaLinux 8, on /mnt/c: OCLJ_OUT <BÄU>/dist for OCLJ_BUILD <Bäu>: refused, dist intact" \
  sh -c '[ -f "$1/rc/u3-case.rc" ] && [ "$(cat "$1/rc/u3-case.rc")" != 0 ] && grep -q "the collection point" "$1/logs/u3-case.log" && cmp -s "$1/t/u3case.before.md5" "$1/t/u3case.after.md5"' x "$A"
check ALMA-T4 "AlmaLinux 8, on /mnt/c: OCLJ_BUILD <Bäu> and OCLJ_OUT <BÄU>/dist, neither made: refused, nothing created" \
  sh -c '[ -f "$1/rc/t4.rc" ] && [ "$(cat "$1/rc/t4.rc")" != 0 ] && grep -q "the collection point" "$1/logs/t4.log" && [ ! -s "$1/t/t4.ls" ]' x "$A"
for c in in case symlink; do
  check ALMA-G3-$c "AlmaLinux 8: OCLJ_BUILD inside a scratch OCLJ_REPO outside build/ ($c): refused" \
    sh -c '[ -f "$1/rc/g3-$2.rc" ] && [ "$(cat "$1/rc/g3-$2.rc")" != 0 ] && grep -q "lies inside, the repository" "$1/logs/g3-$2.log"' x "$A" "$c"
done
check ALMA-G3-nothing-created "AlmaLinux 8: the scratch repository is unchanged" \
  sh -c 'cmp -s "$1/t/g3repo.before.md5" "$1/t/g3repo.after.md5" && cmp -s "$1/t/g3repo.before.ls" "$1/t/g3repo.after.ls"' x "$A"
check ALMA-G3-under-build-allowed "AlmaLinux 8: OCLJ_BUILD under OCLJ_REPO/build: not refused by the guard (stops at OCLJ_JNLUA), nothing created" \
  sh -c 'grep -q "no .*no-jnlua-here/native/src/jnlua.c" "$1/logs/g3-build.log" && ! grep -q "lies inside, the repository" "$1/logs/g3-build.log" && [ ! -e "$1/t/g3repo/build" ]' x "$A"

# --------------------------------------------------------------- G2 and MO, the build environment
echo "== G2 MO"
mkdir -p "$O/t/inj/cpath"
cp "$INJ_SRC" "$O/t/inj/inject.h"
{
  echo '#include_next <stdint.h>'
  echo '#ifndef OCLJ_CPATH_INJECTED'
  echo '#define OCLJ_CPATH_INJECTED 1'
  echo 'static const char oclj_cpath_injected[] __attribute__((used)) = "OCLJ-CPATH-INJECTED";'
  echo '#endif'
} > "$O/t/inj/cpath/stdint.h"
INJW=$(cygpath -m "$O/t/inj/inject.h")
CPW=$(cygpath -m "$O/t/inj/cpath")
wb g2-inject "$O/b/g2-inject" OCLJ_VARIANT=additive "CFLAGS=-include $INJW" "cpath=$CPW" "MAKEFLAGS=TARGET_CFLAGS=-O0"
check G2-rc "the build with CFLAGS, cpath and MAKEFLAGS set succeeds" rcis g2-inject 0
check G2-ignored-line "the log names them: 'ignored from the environment: CFLAGS MAKEFLAGS cpath'" \
  grep -q -F "ignored from the environment: CFLAGS MAKEFLAGS cpath (THE BUILD ENVIRONMENT)" "$O/logs/g2-inject.log"
check G2-objects "every object equals the canonical additive's (W1)" \
  cmpobj "$O/b/g2-inject" "$O/b/w1-add" windows-x86_64 "$O/cmp/g2-vs-w1"
check G2-no-marker "no injected marker in the DLL, the objects or the LuaJIT log" \
  sh -c '! grep -a -q -r -E "OCLJ-VERIFY-INJECTED|OCLJ-CPATH-INJECTED" "$1/libdir-additive" "$1/obj-windows-x86_64" "$1/luajit-windows-x86_64/src" && ! grep -q -E "[-]include|-O0" "$1/luajit_build.log"' x "$O/b/g2-inject"
wb mo "$O/b/mo" OCLJ_VARIANT=additive "MAKEOVERRIDES=CFLAGS=-O0"
check MO-rc "the build with MAKEOVERRIDES=CFLAGS=-O0 set succeeds" rcis mo 0
check MO-ignored-line "the log names it: 'ignored from the environment: MAKEOVERRIDES'" \
  grep -q -F "ignored from the environment: MAKEOVERRIDES (THE BUILD ENVIRONMENT)" "$O/logs/mo.log"
check MO-objects "every object equals the canonical additive's (W1)" \
  cmpobj "$O/b/mo" "$O/b/w1-add" windows-x86_64 "$O/cmp/mo-vs-w1"
check MO-no-O0 "no -O0 on any LuaJIT compile line" sh -c '[ -f "$1/luajit_build.log" ] && ! grep -q -- " -O0 " "$1/luajit_build.log"' x "$O/b/mo"

# --------------------------------------------------------------- R1-R3, F2, F7, export-ignore
echo "== attacks"
for c in replace envcfg forgeblob f7-8 dirty infoattr eitree; do
  B=$O/b/a-$c
  case $c in
    envcfg)
      wb a-$c "$B" OCLJ_VARIANT=additive OCLJ_LUAJIT=$C/lj-clean \
        GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.attributesFile GIT_CONFIG_VALUE_0=$E3/envattrs \
        GIT_CONFIG_KEY_1=filter.oclj.smudge "GIT_CONFIG_VALUE_1=cat >/dev/null; cat $E3/parent_lj_opt_mem.c" ;;
    eitree)
      FR=$O/t/fakerepo-eitree
      mkdir -p "$FR/native/luajit"
      git --git-dir="$C/lj-eitree/.git" rev-parse HEAD > "$FR/native/luajit/upstream.commit"
      cp "$R/native/luajit/oclj_features.h" "$FR/native/luajit/"
      wb a-$c "$B" OCLJ_REPO=$FR OCLJ_SHIM=$R/native OCLJ_SER=$R/serializer OCLJ_VARIANT=additive OCLJ_LUAJIT=$C/lj-eitree ;;
    *)
      wb a-$c "$B" OCLJ_VARIANT=additive OCLJ_LUAJIT=$C/lj-$c ;;
  esac
done
check R1-replace "replace ref: builds the pin, WARNING names lj_opt_mem.c" \
  sh -c '[ "$(cat "$1/rc/a-replace.rc")" = 0 ] && grep -q "WARNING:   .*src/lj_opt_mem.c" "$1/logs/a-replace.log"' x "$O"
check R1-replace-objects "replace ref: objects equal W1's" cmpobj "$O/b/a-replace" "$O/b/w1-add" windows-x86_64 "$O/cmp/replace-vs-w1"
check R2-envcfg "environment-config filter: BUILD FAIL naming src/lj_opt_mem.c" guardfail a-envcfg "not the pin's bytes: src/lj_opt_mem.c"
check R3-forgeblob "forged blob: BUILD FAIL naming src/lj_opt_mem.c" guardfail a-forgeblob "not the pin's bytes: src/lj_opt_mem.c"
check F7-forged-head "HEAD forged to 1ee778a4 and 32 zeros: refused" guardfail a-f7-8 "is at 1ee778a400000000000000000000000000000000"
check F2-dirty "dirty checkout: builds the pin, WARNING names lj_opt_mem.c" \
  sh -c '[ "$(cat "$1/rc/a-dirty.rc")" = 0 ] && grep -q "WARNING:   .*src/lj_opt_mem.c" "$1/logs/a-dirty.log"' x "$O"
check F2-dirty-objects "dirty checkout: objects equal W1's" cmpobj "$O/b/a-dirty" "$O/b/w1-add" windows-x86_64 "$O/cmp/dirty-vs-w1"
check EI-infoattr "export-ignore in .git/info/attributes: BUILD FAIL, 231 files against 232" guardfail a-infoattr "holds 231 files, and the pin's tree lists 232"
check EI-tree "export-ignore in the tree: BUILD FAIL, 231 files against 232" guardfail a-eitree "holds 231 files, and the pin's tree lists 232"

# --------------------------------------------------------------- U2, U3: round 4's directory guards
echo "== U2 U3"
E=$O/t/u2dd; mkdir -p "$E/y/sub" "$E/x"; junction "$E/x/link" "$E/y/sub"
TW=$E/y/luajit-windows-x86_64; mkthrow "$TW"; treemd5 "$TW" > "$O/t/u2dd.before.md5"
wb u2-dd "$E/x/link/.." OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT="$TW"
treemd5 "$TW" > "$O/t/u2dd.after.md5"
check U2-junction-dotdot "OCLJ_BUILD <junction>/..: refused (a directory this script removes), the throwaway intact" \
  sh -c '[ "$(cat "$1/rc/u2-dd.rc")" != 0 ] && grep -q "a directory this script" "$1/logs/u2-dd.log" && cmp -s "$1/t/u2dd.before.md5" "$1/t/u2dd.after.md5"' x "$O"
E=$O/t/u2case; mkdir -p "$E/Bäu"
TW=$E/Bäu/luajit-windows-x86_64; mkthrow "$TW"; treemd5 "$TW" > "$O/t/u2case.before.md5"
wb u2-case "$E/Bäu" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT="$E/BÄU/luajit-windows-x86_64"
treemd5 "$TW" > "$O/t/u2case.after.md5"
check U2-nonascii-case "OCLJ_LUAJIT in non-ASCII other case: refused, the throwaway intact" \
  sh -c '[ "$(cat "$1/rc/u2-case.rc")" != 0 ] && grep -q "a directory this script" "$1/logs/u2-case.log" && cmp -s "$1/t/u2case.before.md5" "$1/t/u2case.after.md5"' x "$O"
E=$O/t/u3case; mkdir -p "$E/Bäu/dist"; cp "$REL" "$E/Bäu/dist/"; treemd5 "$E/Bäu/dist" > "$O/t/u3case.before.md5"
wb u3-case "$E/Bäu" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT=$C/lj-clean OCLJ_OUT="$E/BÄU/dist"
treemd5 "$E/Bäu/dist" > "$O/t/u3case.after.md5"
check U3-nonascii-case "OCLJ_OUT <BÄU>/dist for OCLJ_BUILD <Bäu>: refused (the collection point), dist intact, nothing built" \
  sh -c '[ "$(cat "$1/rc/u3-case.rc")" != 0 ] && grep -q "the collection point" "$1/logs/u3-case.log" && cmp -s "$1/t/u3case.before.md5" "$1/t/u3case.after.md5" && [ ! -e "$1/t/u3case/Bäu/obj-windows-x86_64" ]' x "$O"
E=$O/t/u3new; mkdir -p "$E/BÄU"
wb u3-new "$E/BÄU" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT=$C/lj-clean OCLJ_OUT="$E/Bäu/dist"
check U3-nonascii-case-nodist "OCLJ_OUT <Bäu>/dist, dist not made yet, OCLJ_BUILD <BÄU>: refused, nothing created" \
  sh -c '[ "$(cat "$1/rc/u3-new.rc")" != 0 ] && grep -q "the collection point" "$1/logs/u3-new.log" && [ -z "$(ls -A "$1/t/u3new/BÄU")" ]' x "$O"
E=$O/t/u3dd; mkdir -p "$E/B/sub" "$E/B/dist" "$E/q/dist"; junction "$E/q/l" "$E/B/sub"
cp "$REL" "$E/B/dist/"; treemd5 "$E/B/dist" > "$O/t/u3dd.before.md5"
wb u3-dd "$E/B" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT=$C/lj-clean OCLJ_OUT="$E/q/l/../dist"
treemd5 "$E/B/dist" > "$O/t/u3dd.after.md5"
check U3-junction-dotdot "OCLJ_OUT <junction>/../dist (physically dist): refused, dist intact" \
  sh -c '[ "$(cat "$1/rc/u3-dd.rc")" != 0 ] && grep -q "the collection point" "$1/logs/u3-dd.log" && cmp -s "$1/t/u3dd.before.md5" "$1/t/u3dd.after.md5"' x "$O"

# --------------------------------------------------------------- round 5: the shell and Windows' programs read one path
echo "== U2L T1 T2 T4"
# U2L: OCLJ_BUILD=<E>/x/link/.., link a junction to y/sub: the shell reads <E>/y, Windows'
# programs the spelling, <E>/x.  A throwaway clone of round 3's clean clone sits at the lexical
# <E>/x/luajit-windows-x86_64, with an untracked object file in it; a pinned additive build of it.
E=$O/t/u2l; mkdir -p "$E/x" "$E/y/sub"; junction "$E/x/link" "$E/y/sub"
TW=$E/x/luajit-windows-x86_64
git clone -q --no-hardlinks "$C/lj-clean" "$TW" > "$O/logs/u2l-clone.log" 2>&1
echo 'untracked marker' > "$TW/src/zz-marker.o"
( cd "$TW" && find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ) > "$O/t/u2l.before.md5"
( cd "$TW" && find .git -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ) > "$O/t/u2l.before.git"
wb u2l "$E/x/link/.." OCLJ_VARIANT=additive OCLJ_LUAJIT="$TW"
( cd "$TW" && find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ) > "$O/t/u2l.after.md5"
( cd "$TW" && find .git -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ) > "$O/t/u2l.after.git"
diff "$O/t/u2l.before.md5" "$O/t/u2l.after.md5" > "$O/t/u2l.wt.diff"
check U2L-clone-untouched "OCLJ_BUILD <x>/<junction>/..: the clone at the lexical <x>/luajit-windows-x86_64 unchanged (files, untracked marker, .git)" \
  sh -c '[ ! -s "$1/t/u2l.wt.diff" ] && [ -s "$1/t/u2l.before.md5" ] && cmp -s "$1/t/u2l.before.git" "$1/t/u2l.after.git" && [ -f "$1/t/u2l/x/luajit-windows-x86_64/src/zz-marker.o" ]' x "$O"
check U2L-build "the same build succeeds in the junction's target <E>/y and collects into <E>/y/dist" \
  sh -c '[ "$(cat "$1/rc/u2l.rc")" = 0 ] && [ -f "$1/t/u2l/y/dist/$2" ]' x "$O" "$DLLA"
check U2L-objects "its 77 and 3 objects (in <E>/y) equal W1's" cmpobj "$E/y" "$O/b/w1-add" windows-x86_64 "$O/cmp/u2l-vs-w1"
# T1: OCLJ_OUT=<B>/dist. with B/dist holding W1's DLL; an unpinned additive build.
E=$O/t/t1; mkdir -p "$E/B/dist"; cp "$REL" "$E/B/dist/"
treemd5 "$E/B/dist" > "$O/t/t1.before.md5"; dllst "$E/B/dist/$DLLA" > "$O/t/t1.dll.txt"
wb t1 "$E/B" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT=$C/lj-clean OCLJ_OUT="$E/B/dist."
treemd5 "$E/B/dist" > "$O/t/t1.after.md5"; dllst "$E/B/dist/$DLLA" >> "$O/t/t1.dll.txt"
check T1-trailing-dot "OCLJ_OUT <B>/dist.: refused (a name ending in a dot), dist intact, no dist. made" \
  sh -c '[ "$(cat "$1/rc/t1.rc")" != 0 ] && grep -q "ends in a dot or a space" "$1/logs/t1.log" && cmp -s "$1/t/t1.before.md5" "$1/t/t1.after.md5" && [ ! -e "$1/t/t1/B/dist." ]' x "$O"
# T2: OCLJ_OUT=<B>/j/../dist, j a junction to <E>/else/sub; B/dist holds W1's DLL.
E=$O/t/t2; mkdir -p "$E/B/dist" "$E/else/sub"; cp "$REL" "$E/B/dist/"; junction "$E/B/j" "$E/else/sub"
treemd5 "$E/B/dist" > "$O/t/t2.before.md5"; dllst "$E/B/dist/$DLLA" > "$O/t/t2.dll.txt"
wb t2 "$E/B" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT=$C/lj-clean OCLJ_OUT="$E/B/j/../dist"
treemd5 "$E/B/dist" > "$O/t/t2.after.md5"; dllst "$E/B/dist/$DLLA" >> "$O/t/t2.dll.txt"; dllst "$E/else/dist/$DLLA" >> "$O/t/t2.dll.txt"
check T2-junction-dotdot "OCLJ_OUT <B>/<junction>/../dist: B/dist intact; the library is linked into the junction's parent <E>/else/dist, where the shell reads the path" \
  sh -c 'cmp -s "$1/t/t2.before.md5" "$1/t/t2.after.md5" && [ "$(cat "$1/rc/t2.rc")" = 0 ] && [ -f "$1/t/t2/else/dist/$2" ]' x "$O" "$DLLA"
# T4: OCLJ_BUILD <E>/Bäu and OCLJ_OUT <E>/BÄU/dist, neither made (one directory on NTFS).
E=$O/t/t4; mkdir -p "$E"
wb t4 "$E/Bäu" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT=$C/lj-clean OCLJ_OUT="$E/BÄU/dist"
ls -A "$E" > "$O/t/t4.ls"
check T4-nonascii-both-new "OCLJ_BUILD <Bäu>, OCLJ_OUT <BÄU>/dist, neither made: refused (the collection point), nothing created" \
  sh -c '[ "$(cat "$1/rc/t4.rc")" != 0 ] && grep -q "the collection point" "$1/logs/t4.log" && [ ! -s "$1/t/t4.ls" ]' x "$O"

echo "== SHIM-dot SER-dot"
# SHIM-dot: <E>/shim. holds the real shim, <E>/shim a decoy whose lj52shim.c adds a marker (the
# directory Windows' programs would read).  A pinned additive build with OCLJ_SHIM=<E>/shim.
E=$O/t/shimdot; mkdir -p "$E/shim." "$E/shim"
cp "$R/native/lj52shim.c" "$R/native/lj52shim.h" "$E/shim./"
cp "$R/native/lj52shim.h" "$E/shim/"
{ cat "$R/native/lj52shim.c"; echo 'static const char oclj_shim_decoy[] __attribute__((used)) = "OCLJ-SHIM-DECOY";'; } > "$E/shim/lj52shim.c"
wb shimdot "$O/b/shimdot" OCLJ_VARIANT=additive OCLJ_SHIM="$E/shim."
echo "decoy marker lines in lj52shim.o: $(grep -a -c OCLJ-SHIM-DECOY "$O/b/shimdot/obj-windows-x86_64/lj52shim.o" 2>/dev/null)" > "$O/t/shimdot.txt"
check SHIM-dot "OCLJ_SHIM <E>/shim.: refused (a name ending in a dot), nothing built" \
  sh -c '[ "$(cat "$1/rc/shimdot.rc")" != 0 ] && grep -q "OCLJ_SHIM is .*ends in a dot or a space" "$1/logs/shimdot.log" && [ ! -e "$1/b/shimdot" ]' x "$O"
E=$O/t/serdot; mkdir -p "$E/ser."
cp "$R/serializer/eris_lj.c" "$R/serializer/eris_lj.h" "$E/ser./"
wb serdot "$O/b/serdot" OCLJ_SER="$E/ser." OCLJ_JNLUA="$O/t/no-jnlua-here"
check SER-dot "OCLJ_SER <E>/ser.: refused (a name ending in a dot), nothing created" \
  sh -c '[ "$(cat "$1/rc/serdot.rc")" != 0 ] && grep -q "OCLJ_SER is .*ends in a dot or a space" "$1/logs/serdot.log" && [ ! -e "$1/b/serdot" ]' x "$O"

# --------------------------------------------------------------- G3: OCLJ_BUILD inside OCLJ_REPO
echo "== G3"
FR=$O/t/g3repo
mkdir -p "$FR/native/luajit" "$FR/serializer/tests"
cp "$R/native/luajit/upstream.commit" "$R/native/luajit/oclj_features.h" "$FR/native/luajit/"
echo '-- a tracked file of the scratch repository: must survive' > "$FR/serializer/tests/strpack.lua"
treemd5 "$FR" > "$O/t/g3repo.before.md5"; treels "$FR" > "$O/t/g3repo.before.ls"
wb g3-in "$FR/serializer/tests" OCLJ_REPO="$FR" OCLJ_SHIM=$R/native OCLJ_SER=$R/serializer OCLJ_LUAJIT=$C/lj-clean OCLJ_VARIANT=additive
wb g3-case "$FR/SERIALIZER/newdir" OCLJ_REPO="$FR" OCLJ_SHIM=$R/native OCLJ_SER=$R/serializer OCLJ_LUAJIT=$C/lj-clean OCLJ_VARIANT=additive
junction "$O/t/g3link" "$FR/serializer"
wb g3-junction "$O/t/g3link/tests" OCLJ_REPO="$FR" OCLJ_SHIM=$R/native OCLJ_SER=$R/serializer OCLJ_LUAJIT=$C/lj-clean OCLJ_VARIANT=additive
treemd5 "$FR" > "$O/t/g3repo.after.md5"; treels "$FR" > "$O/t/g3repo.after.ls"
for c in in case junction; do
  check G3-$c "OCLJ_BUILD inside OCLJ_REPO outside build/ ($c): refused" guardfail g3-$c "lies inside, the repository"
done
check G3-nothing-created "the scratch repository is unchanged: strpack.lua intact, no file or directory added" \
  sh -c 'cmp -s "$1/t/g3repo.before.md5" "$1/t/g3repo.after.md5" && cmp -s "$1/t/g3repo.before.ls" "$1/t/g3repo.after.ls"' x "$O"
wb g3-build "$FR/build/native" OCLJ_REPO="$FR" OCLJ_SHIM=$R/native OCLJ_SER=$R/serializer OCLJ_LUAJIT=$C/lj-clean OCLJ_VARIANT=additive OCLJ_JNLUA="$O/t/no-jnlua-here"
check G3-under-build-allowed "OCLJ_BUILD under OCLJ_REPO/build: not refused by the guard (stops later, at OCLJ_JNLUA), nothing created" \
  sh -c 'grep -q "no .*no-jnlua-here/native/src/jnlua.c" "$1/logs/g3-build.log" && ! grep -q "lies inside, the repository" "$1/logs/g3-build.log" && [ ! -e "$1/t/g3repo/build" ]' x "$O"

# --------------------------------------------------------------- H2: the repository the script lives in
echo "== H2"
HR=$O/t/h2/repo
mkdir -p "$HR/native" "$HR/serializer/tests"
cp "$S" "$HR/native/build-native.sh"
echo '-- a tracked file of the repository the script lives in: must survive' > "$HR/serializer/tests/strpack.lua"
treemd5 "$HR" > "$O/t/h2.before.md5"; treels "$HR" > "$O/t/h2.before.ls"
wbs h2 "$HR/native/build-native.sh" "$HR/serializer/tests" OCLJ_REPO="$R"
treemd5 "$HR" > "$O/t/h2.after.md5"; treels "$HR" > "$O/t/h2.after.ls"
check H2-self-repo "OCLJ_REPO the real repository, OCLJ_BUILD in the script's own repository's serializer/tests: refused, that repository unchanged" \
  sh -c '[ "$(cat "$1/rc/h2.rc")" != 0 ] && grep -q "lies inside, the repository" "$1/logs/h2.log" && grep -q -F "$2," "$1/logs/h2.log" && cmp -s "$1/t/h2.before.md5" "$1/t/h2.after.md5" && cmp -s "$1/t/h2.before.ls" "$1/t/h2.after.ls"' x "$O" "$HR"
mkdir -p "$HR/build/native/dist"; cp "$REL" "$HR/build/native/dist/"
treemd5 "$HR/build/native/dist" > "$O/t/h2dist.before.md5"; dllst "$HR/build/native/dist/$DLLA" > "$O/t/h2dist.dll.txt"
wbs h2dist "$HR/native/build-native.sh" "$O/b/h2dist" OCLJ_REPO="$R" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT=$C/lj-clean OCLJ_OUT="$HR/build/native/dist"
treemd5 "$HR/build/native/dist" > "$O/t/h2dist.after.md5"; dllst "$HR/build/native/dist/$DLLA" >> "$O/t/h2dist.dll.txt"
check H2-self-repo-dist "OCLJ_OUT the script's own repository's build/native/dist (OCLJ_REPO the real one), unpinned: refused, that dist intact" \
  sh -c '[ "$(cat "$1/rc/h2dist.rc")" != 0 ] && grep -q "the collection point" "$1/logs/h2dist.log" && cmp -s "$1/t/h2dist.before.md5" "$1/t/h2dist.after.md5"' x "$O"

# --------------------------------------------------------------- gradle
echo "== unpinned build and gradle"
wb unpinned "$O/b/unpinned" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT=$C/lj-clean
check UNP-build "an unpinned build of the clean clone: stamped unpinned, not collected into dist" \
  sh -c '[ "$(cat "$1/rc/unpinned.rc")" = 0 ] && grep -a -q "unpinned|LuaJIT 2[.]1[.]ROLLING|" "$1/b/unpinned/obj-windows-x86_64/eris_lj.o" && [ ! -e "$1/b/unpinned/dist" ]' x "$O"
G=$O/gradle
mkdir -p "$G/pinned" "$G/unpinned"
cp "$O/b/w1-add/libdir-additive/$DLLA" "$G/pinned/"
cp "$O/b/unpinned/libdir-additive/$DLLA" "$G/unpinned/"
NOK=$(cygpath -m "$G")/no-kernel-here
for c in pinned unpinned; do
  t=$(date +%s)
  ( cd "$R" && ./gradlew --offline --no-daemon --console=plain verifyModAssets \
      "-Pocljit.nativesDir=$(cygpath -m "$G/$c")" "-Pocljit.kernelDir=$NOK" ) > "$O/logs/gradle-$c.log" 2>&1
  echo $? > "$O/rc/gradle-$c.rc"
  echo "gradle $c secs=$(( $(date +%s) - t ))" >> "$O/logs/timing.txt"
done
check GRADLE-accepts-pinned "verifyModAssets accepts W1's pinned DLL" \
  sh -c '[ "$(cat "$1/rc/gradle-pinned.rc")" = 0 ] && grep -q "names the pinned LuaJIT commit 1ee778a4" "$1/logs/gradle-pinned.log"' x "$O"
check GRADLE-refuses-unpinned "verifyModAssets refuses the unpinned DLL" \
  sh -c '[ "$(cat "$1/rc/gradle-unpinned.rc")" != 0 ] && grep -q "was NOT built from the pinned LuaJIT commit" "$1/logs/gradle-unpinned.log"' x "$O"

# --------------------------------------------------------------- negctl-bitop SARCONST
echo "== negctl-bitop SARCONST"
t=$(date +%s)
env PATH="$TOOLS:$PATH" OCLJ_JNI="$JNIW" OCLJ_BUILD="$O/b/w1-add" OCLJ_NEGCTL_ARMS=SARCONST \
  sh "$R/test/native/negctl-bitop.sh" > "$O/logs/negctl-bitop.log" 2>&1
echo $? > "$O/rc/negctl-bitop.rc"
echo "negctl-bitop secs=$(( $(date +%s) - t ))" >> "$O/logs/timing.txt"
check NEGCTL-SARCONST "negctl-bitop SARCONST passes, its pristine files from W1's export" \
  sh -c '[ "$(cat "$1/rc/negctl-bitop.rc")" = 0 ] && grep -q "NEGCTL-BITOP: PASS" "$1/logs/negctl-bitop.log" && grep -q "pristine files from .*w1-add/luajit-export-windows-x86_64/src" "$1/logs/negctl-bitop.log"' x "$O"

# --------------------------------------------------------------- hygiene
echo "== hygiene"
check SHN-gitbash "sh -n build-native.sh (Git Bash)" sh -n "$S"
check SHN-alma "sh -n build-native.sh (AlmaLinux 8's sh)" [ "$(cat "$O/alma/shn.rc" 2>/dev/null)" = 0 ]
check SHN-ubuntu "sh -n build-native.sh (Ubuntu's dash)" [ "$(cat "$O/ubuntu/shn.rc" 2>/dev/null)" = 0 ]
for f in native/build-native.sh README.md docs/jit-guide.md docs/roadmap.md CLAUDE.md; do
  n=$(od -An -tx1 -v "$R/$f" | tr ' ' '|' | grep -o '|0d' | wc -l | tr -d ' ')
  check "CR0-$f" "$f has 0 CR bytes" [ "$n" = 0 ]
done
( cd "$R" && git diff --check ) > "$O/logs/git-diff-check.log" 2>&1; echo $? > "$O/rc/git-diff-check.rc"
check GIT-DIFF-CHECK "git diff --check is clean" rcis git-diff-check 0
echo "== census after"
census "$O/census/after"
check CENSUS-build "every file under build/ has its md5 of the start, none added or removed ($(wc -l < "$O/census/before-build.md5" | tr -d ' ') files)" \
  cmp -s "$O/census/before-build.md5" "$O/census/after-build.md5"
check CENSUS-pristine-stat "the pristine checkout's stat list (mtimes included) is unchanged" \
  cmp -s "$O/census/before-pristine-stat.txt" "$O/census/after-pristine-stat.txt"
check CENSUS-pristine-git "the pristine checkout's .git md5 list is unchanged" \
  cmp -s "$O/census/before-pristine-git.md5" "$O/census/after-pristine-git.md5"
md5sum "$S" "$SELF_W" > "$O/md5-end.txt"
check SCRIPTS-unchanged "build-native.sh and this script are unchanged since the start" cmp -s "$O/md5-start.txt" "$O/md5-end.txt"

NF=$(grep -c '^FAIL ' "$SUM")
NP=$(grep -c '^PASS ' "$SUM")
echo "PASS $NP FAIL $NF secs $(( $(date +%s) - T0 )) build-native.sh $(cut -c1-32 "$O/md5-start.txt" | head -1)" > "$O/ALL.done"
cat "$O/ALL.done"
