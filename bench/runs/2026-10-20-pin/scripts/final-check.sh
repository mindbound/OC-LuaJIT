#!/bin/sh
# final-check.sh <outdir> -- the pin round 4 verification chain, on the repo's build-native.sh
# as it stands.  Run from Git Bash:   sh final-check.sh <fresh outdir>   (well under 30 minutes)
#
# It refuses an outdir that exists, writes everything under it, reads every exit code into a
# file (<outdir>/rc/), never writes under the repo's build/ (fresh OCLJ_BUILDs under
# <outdir>/b; gradle only as ./gradlew --offline --no-daemon verifyModAssets on scratch
# natives dirs), never touches prototype/watchdog/luajit (it is read by the canonical builds)
# nor round 3's scratch clones (read only), and runs its Linux parts by invoking itself in
# WSL (MSYS_NO_PATHCONV=1 wsl.exe -d <distro> -- env ... sh /mnt/c/.../final-check.sh --alma
# <outdir in WSL form>), whose exit codes it reads from the files that part writes.
# <outdir>/summary.txt gets one PASS or FAIL line per check; <outdir>/ALL.done is written
# last, with the count of FAIL lines and the elapsed seconds.
#
# Checks:
#   W1  canonical pinned builds: Windows additive and dropin into fresh OCLJ_BUILDs, objects
#       against build/native's (additive) and round 2's dropin reference; AlmaLinux 8 with
#       OCLJ_GLIBC_MAX=2.28, additive and dropin, .so md5s against the release's; each log's
#       "ignored from the environment: none".
#   G2  a pinned build with CFLAGS='-include <inject.h>', cpath (lower case) naming a
#       directory whose stdint.h adds a marker, and MAKEFLAGS='TARGET_CFLAGS=-O0' in the
#       environment: every object equal to W1's, no marker in any object or the DLL, the
#       three names in the "ignored from the environment" line.
#   R1  replace ref (builds the pin), R2 environment-config filter, R3 forged blob, F7 forged
#       HEAD, F2 dirty checkout (builds the pin), export-ignore in .git/info/attributes and in
#       the tree: round 3's scratch clones in claude-tmp/oclj/pin3/impl/clones.
#   U2  an unpinned OCLJ_LUAJIT at the build copy's physical path, spelled through
#       <junction>/.. and through a non-ASCII other-case name: refused, the throwaway intact.
#   U3  OCLJ_OUT physically $OCLJ_BUILD/dist, spelled through non-ASCII other case (dist
#       present, and dist not made yet) and through <junction>/..: refused, dist intact.
#   G3  OCLJ_BUILD inside a scratch OCLJ_REPO outside its build/ (directly, in other ASCII
#       case, through a junction from outside): refused before anything is created; under
#       its build/: not refused by the guard.
#   gradle accepts W1's pinned DLL and refuses an unpinned build's DLL.
#   negctl-bitop.sh with OCLJ_NEGCTL_ARMS=SARCONST on W1's additive build.
#   hygiene: sh -n in Git Bash, AlmaLinux 8 and Ubuntu (dash); CR bytes 0 in the five files
#   round 4 owns; git diff --check; build/ md5 census and the pristine checkout's stat list
#   and .git md5 list identical before and after; this script and build-native.sh unchanged.
# Written with a file tool: no heredocs; its only backslashes end continued lines.
set -u
DRIVE_REPO=/c/Users/astro/Downloads/OC-LuaJIT
WSL_REPO=/mnt/c/Users/astro/Downloads/OC-LuaJIT
SELF_W=/c/Users/astro/claude-tmp/oclj/pin4/final/final-check.sh
SELF_L=/mnt/c/Users/astro/claude-tmp/oclj/pin4/final/final-check.sh
SO_ADD=6c88805001bae0cd2b385803f5d857c7
SO_DROP=6c0715d11344c5fe075cd33f4f93cdbc
STAMP_WANT='1ee778a4|LuaJIT 2.1.ROLLING|412be694'

# cmpobj <build A> <build B> <platform> <out prefix>: md5 of the 77 LuaJIT objects and
# obj-<platform>'s .o files in A against B; 0 iff equal and 77 LuaJIT objects.
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

# --------------------------------------------------------------- the Linux parts (in WSL)
alma_part() {
  A=$1/alma
  mkdir "$A" || exit 98
  S=$WSL_REPO/native/build-native.sh
  { uname -a; gcc --version | head -1; git --version; md5sum "$S"; } > "$A/host.txt" 2>&1
  sh -n "$S" > "$A/shn.log" 2>&1; echo $? > "$A/shn.rc"
  for v in add drop; do
    case $v in add) var=additive ;; drop) var=dropin ;; esac
    env OCLJ_JNI=/usr/lib/jvm/java-1.8.0-openjdk/include OCLJ_JNLUA=/mnt/c/Users/astro/Downloads/OC-JNLua \
      CC=gcc OCLJ_BUILD="$A/b-$v" OCLJ_VARIANT=$var OCLJ_GLIBC_MAX=2.28 sh "$S" > "$A/build-$v.log" 2>&1
    echo $? > "$A/build-$v.rc"
  done
  md5sum < "$A/b-add/libdir-additive/libjnluajit52-linux-x86_64.so" | cut -c1-32 > "$A/so-add.md5" 2>/dev/null
  md5sum < "$A/b-drop/libdir/libjnlua52-linux-x86_64.so" | cut -c1-32 > "$A/so-drop.md5" 2>/dev/null
  cmpobj "$A/b-add" "$WSL_REPO/build/native" linux-x86_64 "$A/cmp-add-vs-buildnative"; echo $? > "$A/cmp-add.rc"
  grep -h 'ignored from the environment:' "$A/build-add.log" "$A/build-drop.log" > "$A/ignored.txt"
  grep -h -E 'glibc: highest|export verified' "$A/build-add.log" "$A/build-drop.log" > "$A/gates.txt"
  echo done > "$A/part.done"
}
ubuntu_part() {
  U=$1/ubuntu
  mkdir "$U" || exit 98
  { readlink -f /bin/sh; uname -a; } > "$U/host.txt" 2>&1
  sh -n "$WSL_REPO/native/build-native.sh" > "$U/shn.log" 2>&1; echo $? > "$U/shn.rc"
  echo done > "$U/part.done"
}
case ${1:-} in
  --alma) alma_part "$2"; exit 0 ;;
  --ubuntu) ubuntu_part "$2"; exit 0 ;;
esac

# --------------------------------------------------------------- Windows: setup
O=${1:-}
[ -n "$O" ] || { echo "usage: sh final-check.sh <fresh outdir>"; exit 2; }
[ -e "$O" ] && { echo "refusing: $O exists (never reuse a results directory)"; exit 97; }
mkdir -p "$O" || exit 98
O=$(CDPATH= cd -P -- "$O" && pwd -P)
case $O in "$DRIVE_REPO"|"$DRIVE_REPO"/*) echo "refusing: $O is inside the repo"; exit 97 ;; esac
R=$DRIVE_REPO
# FC_SCRIPT=<a copy of build-native.sh> runs the Windows checks against that copy instead (a
# fail-first run on an older text; its builds then get OCLJ_REPO=<the repo>, since the copy's
# own location is no repository).  The final run leaves it unset.
S=${FC_SCRIPT:-$R/native/build-native.sh}
FCREPO=${FC_SCRIPT:+OCLJ_REPO=$R}
BN=$R/build/native
P3=/c/Users/astro/claude-tmp/oclj/pin3/impl
C=$P3/clones
E3=$P3/exp
DROPREF=/c/Users/astro/claude-tmp/oclj/pin2/impl/win-v1/canon-dropin
INJ_SRC=/c/Users/astro/claude-tmp/oclj/pin3/verify/exp/inject.h
TOOLS=/c/Users/astro/claude-tmp/oclj/bin
JNIW="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include"
JNLUAW=C:/Users/astro/Downloads/OC-JNLua
PL=$R/prototype/watchdog/luajit
DLLA=libjnluajit52-windows-x86_64.dll
WD=$(echo "$O" | cut -c2)
WO=/mnt/$WD$(echo "$O" | cut -c3-)
mkdir -p "$O/logs" "$O/rc" "$O/b" "$O/cmp" "$O/t" "$O/census" || exit 98
SUM=$O/summary.txt
: > "$SUM"
T0=$(date +%s)
date -u +%Y-%m-%dT%H:%M:%SZ > "$O/start-time.txt"
md5sum "$S" "$SELF_W" > "$O/md5-start.txt"

res() { echo "$1 $2: $3" >> "$SUM"; echo "$1 $2: $3"; }
# check <id> <text> <command...>: PASS when the command succeeds
check() {
  ck_i=$1; ck_t=$2; shift 2
  if "$@" >> "$O/logs/checks.log" 2>&1; then res PASS "$ck_i" "$ck_t"; else res FAIL "$ck_i" "$ck_t"; fi
}
rcis() { [ "$(cat "$O/rc/$1.rc" 2>/dev/null)" = "$2" ]; }
rcnot0() { [ -f "$O/rc/$1.rc" ] && [ "$(cat "$O/rc/$1.rc")" != 0 ]; }
has() { grep -q -F -- "$2" "$O/logs/$1.log"; }
hasnot() { ! grep -q -F -- "$2" "$O/logs/$1.log"; }
failline() { grep -m1 '^BUILD FAIL' "$O/logs/$1.log" | cut -c1-200; }
# wb <label> <OCLJ_BUILD> [VAR=value...]: one Windows build; rc into rc/<label>.rc
wb() {
  wb_l=$1; wb_b=$2; shift 2
  wb_t=$(date +%s)
  env PATH="$TOOLS:$PATH" OCLJ_JNI="$JNIW" OCLJ_JNLUA="$JNLUAW" $FCREPO OCLJ_BUILD="$wb_b" "$@" sh "$S" > "$O/logs/$wb_l.log" 2>&1
  wb_r=$?
  echo "$wb_r" > "$O/rc/$wb_l.rc"
  echo "build $wb_l rc=$wb_r secs=$(( $(date +%s) - wb_t ))" >> "$O/logs/timing.txt"
  return 0
}
stampof() { grep -a -o -m1 '[0-9a-z]*|LuaJIT 2[.]1[.][A-Z0-9]*|[0-9a-f]*' "$1/obj-windows-x86_64/eris_lj.o" 2>/dev/null | head -1; }
optmem() { md5sum < "$1/luajit-windows-x86_64/src/lj_opt_mem.o" 2>/dev/null | cut -c1-8; }
treemd5() { if [ -d "$1" ]; then ( cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ); else echo "ABSENT $1"; fi; }
junction() { MSYS_NO_PATHCONV=1 cmd.exe /c mklink /J "$(cygpath -w "$1")" "$(cygpath -w "$2")" > /dev/null; }
mkthrow() {
  mkdir -p "$1/.git" "$1/src" || return 1
  echo 'ref: refs/heads/master' > "$1/.git/HEAD"
  echo "throwaway marker: must survive" > "$1/MARKER.txt"
  echo '/* LUAJIT_ENABLE_CHECKHOOK */' > "$1/src/lj_record.c"
}
census() { # census <prefix>
  ( cd "$R" && find build -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ) > "$1-build.md5"
  ( cd "$PL" && find . -print0 | LC_ALL=C sort -z | xargs -0 stat -c '%Y %s %n' ) > "$1-pristine-stat.txt"
  ( cd "$PL" && find .git -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ) > "$1-pristine-git.md5"
}

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
check W1-win-export "the export is verified (8 trees, 232 files)" has w1-add "8 trees to their names, 232 files to the pin's blob ids"
check W1-win-dist "the additive is collected into its dist" [ -f "$O/b/w1-add/dist/$DLLA" ]

# --------------------------------------------------------------- W1, AlmaLinux 8; sh -n there and in Ubuntu
echo "== W1 AlmaLinux 8 (WSL)"
t=$(date +%s)
MSYS_NO_PATHCONV=1 wsl.exe -d AlmaLinux-8 -- env FC_MODE=alma sh "$SELF_L" --alma "$WO" > "$O/logs/wsl-alma.log" 2>&1
echo "wsl alma secs=$(( $(date +%s) - t ))" >> "$O/logs/timing.txt"
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu -- env FC_MODE=ubuntu sh "$SELF_L" --ubuntu "$WO" > "$O/logs/wsl-ubuntu.log" 2>&1
A=$O/alma
check W1-alma-ran "the AlmaLinux 8 part ran to its end" [ -f "$A/part.done" ]
check W1-alma-additive-rc "AlmaLinux 8 additive build (OCLJ_GLIBC_MAX=2.28) succeeds" [ "$(cat "$A/build-add.rc" 2>/dev/null)" = 0 ]
check W1-alma-dropin-rc "AlmaLinux 8 dropin build (OCLJ_GLIBC_MAX=2.28) succeeds" [ "$(cat "$A/build-drop.rc" 2>/dev/null)" = 0 ]
check W1-alma-so-additive "additive .so md5 is the release's $SO_ADD" [ "$(cat "$A/so-add.md5" 2>/dev/null)" = "$SO_ADD" ]
check W1-alma-so-dropin "dropin .so md5 is the release's $SO_DROP" [ "$(cat "$A/so-drop.md5" 2>/dev/null)" = "$SO_DROP" ]
check W1-alma-objects "AlmaLinux 8 additive: 77 and 3 objects equal build/native's Linux ones" [ "$(cat "$A/cmp-add.rc" 2>/dev/null)" = 0 ]
check W1-alma-ignored-none "both AlmaLinux 8 logs: 'ignored from the environment: none'" [ "$(grep -c 'ignored from the environment: none ' "$A/ignored.txt" 2>/dev/null)" = 2 ]

# --------------------------------------------------------------- G2, the build environment
echo "== G2"
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
  has g2-inject "ignored from the environment: CFLAGS MAKEFLAGS cpath (THE BUILD ENVIRONMENT)"
check G2-objects "every object equals the canonical additive's (W1)" \
  cmpobj "$O/b/g2-inject" "$O/b/w1-add" windows-x86_64 "$O/cmp/g2-vs-w1"
check G2-no-marker "no injected marker in the DLL, the objects or the LuaJIT log" \
  sh -c '! grep -a -q -r -E "OCLJ-VERIFY-INJECTED|OCLJ-CPATH-INJECTED" "$1/libdir-additive" "$1/obj-windows-x86_64" "$1/luajit-windows-x86_64/src" && ! grep -q -E "[-]include|-O0" "$1/luajit_build.log"' x "$O/b/g2-inject"

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
check R1-replace "replace ref: builds the pin (lj_opt_mem.o 42bd49f9, 77+3 canonical), WARNING names lj_opt_mem.c" \
  sh -c '[ "$(cat "$1/rc/a-replace.rc")" = 0 ] && grep -q "WARNING:   .*src/lj_opt_mem.c" "$1/logs/a-replace.log"' x "$O"
check R1-replace-objects "replace ref: objects equal W1's" cmpobj "$O/b/a-replace" "$O/b/w1-add" windows-x86_64 "$O/cmp/replace-vs-w1"
check R2-envcfg "environment-config filter: BUILD FAIL naming src/lj_opt_mem.c" \
  sh -c 'rc=$(cat "$1/rc/a-envcfg.rc"); [ "$rc" != 0 ] && grep -q "not the pin.s bytes: src/lj_opt_mem.c" "$1/logs/a-envcfg.log"' x "$O"
check R3-forgeblob "forged blob: BUILD FAIL naming src/lj_opt_mem.c" \
  sh -c 'rc=$(cat "$1/rc/a-forgeblob.rc"); [ "$rc" != 0 ] && grep -q "not the pin.s bytes: src/lj_opt_mem.c" "$1/logs/a-forgeblob.log"' x "$O"
check F7-forged-head "HEAD forged to 1ee778a4 and 32 zeros: refused" \
  sh -c 'rc=$(cat "$1/rc/a-f7-8.rc"); [ "$rc" != 0 ] && grep -q "is at 1ee778a400000000000000000000000000000000" "$1/logs/a-f7-8.log"' x "$O"
check F2-dirty "dirty checkout: builds the pin, WARNING names lj_opt_mem.c" \
  sh -c '[ "$(cat "$1/rc/a-dirty.rc")" = 0 ] && grep -q "WARNING:   .*src/lj_opt_mem.c" "$1/logs/a-dirty.log"' x "$O"
check F2-dirty-objects "dirty checkout: objects equal W1's" cmpobj "$O/b/a-dirty" "$O/b/w1-add" windows-x86_64 "$O/cmp/dirty-vs-w1"
check EI-infoattr "export-ignore in .git/info/attributes: BUILD FAIL, 231 files against 232" \
  sh -c 'rc=$(cat "$1/rc/a-infoattr.rc"); [ "$rc" != 0 ] && grep -q "holds 231 files, and the pin.s tree lists 232" "$1/logs/a-infoattr.log"' x "$O"
check EI-tree "export-ignore in the tree: BUILD FAIL, 231 files against 232" \
  sh -c 'rc=$(cat "$1/rc/a-eitree.rc"); [ "$rc" != 0 ] && grep -q "holds 231 files, and the pin.s tree lists 232" "$1/logs/a-eitree.log"' x "$O"

# --------------------------------------------------------------- U2, U3: the directory guards
echo "== U2 U3"
# U2 dd: OCLJ_BUILD=<E>/x/link/.., x/link a junction to y/sub, so physically <E>/y; the
# throwaway "checkout" at <E>/y/luajit-windows-x86_64.
E=$O/t/u2dd; mkdir -p "$E/y/sub" "$E/x"; junction "$E/x/link" "$E/y/sub"
TW=$E/y/luajit-windows-x86_64; mkthrow "$TW"; treemd5 "$TW" > "$O/t/u2dd.before.md5"
wb u2-dd "$E/x/link/.." OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT="$TW"
treemd5 "$TW" > "$O/t/u2dd.after.md5"
check U2-junction-dotdot "OCLJ_BUILD <junction>/..: refused (a directory this script removes), the throwaway intact" \
  sh -c 'rc=$(cat "$1/rc/u2-dd.rc"); [ "$rc" != 0 ] && grep -q "a directory this script" "$1/logs/u2-dd.log" && cmp -s "$1/t/u2dd.before.md5" "$1/t/u2dd.after.md5"' x "$O"
# U2 case: OCLJ_BUILD=<C>/Bäu, the throwaway at <C>/BÄU/luajit-windows-x86_64 (one directory).
E=$O/t/u2case; mkdir -p "$E/Bäu"
TW=$E/Bäu/luajit-windows-x86_64; mkthrow "$TW"; treemd5 "$TW" > "$O/t/u2case.before.md5"
wb u2-case "$E/Bäu" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT="$E/BÄU/luajit-windows-x86_64"
treemd5 "$TW" > "$O/t/u2case.after.md5"
check U2-nonascii-case "OCLJ_LUAJIT in non-ASCII other case: refused, the throwaway intact" \
  sh -c 'rc=$(cat "$1/rc/u2-case.rc"); [ "$rc" != 0 ] && grep -q "a directory this script" "$1/logs/u2-case.log" && cmp -s "$1/t/u2case.before.md5" "$1/t/u2case.after.md5"' x "$O"
# U3: dist holds W1's DLL; an unpinned additive build of the clean clone.
REL=$O/b/w1-add/libdir-additive/$DLLA
E=$O/t/u3case; mkdir -p "$E/Bäu/dist"; cp "$REL" "$E/Bäu/dist/"; treemd5 "$E/Bäu/dist" > "$O/t/u3case.before.md5"
wb u3-case "$E/Bäu" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT=$C/lj-clean OCLJ_OUT="$E/BÄU/dist"
treemd5 "$E/Bäu/dist" > "$O/t/u3case.after.md5"
check U3-nonascii-case "OCLJ_OUT <BÄU>/dist for OCLJ_BUILD <Bäu>: refused (the collection point), dist intact, nothing built" \
  sh -c 'rc=$(cat "$1/rc/u3-case.rc"); [ "$rc" != 0 ] && grep -q "the collection point" "$1/logs/u3-case.log" && cmp -s "$1/t/u3case.before.md5" "$1/t/u3case.after.md5" && [ ! -e "$1/t/u3case/Bäu/obj-windows-x86_64" ]' x "$O"
E=$O/t/u3new; mkdir -p "$E/BÄU"
wb u3-new "$E/BÄU" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT=$C/lj-clean OCLJ_OUT="$E/Bäu/dist"
check U3-nonascii-case-nodist "OCLJ_OUT <Bäu>/dist, dist not made yet, OCLJ_BUILD <BÄU>: refused, nothing created" \
  sh -c 'rc=$(cat "$1/rc/u3-new.rc"); [ "$rc" != 0 ] && grep -q "the collection point" "$1/logs/u3-new.log" && [ -z "$(ls -A "$1/t/u3new/BÄU")" ]' x "$O"
# U3 dd: OCLJ_BUILD=<E>/B, OCLJ_OUT=<E>/q/l/../dist, q/l a junction to B/sub and q/dist an
# empty directory (where a plain cd would land), physically <E>/B/dist.
E=$O/t/u3dd; mkdir -p "$E/B/sub" "$E/B/dist" "$E/q/dist"; junction "$E/q/l" "$E/B/sub"
cp "$REL" "$E/B/dist/"; treemd5 "$E/B/dist" > "$O/t/u3dd.before.md5"
wb u3-dd "$E/B" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT=$C/lj-clean OCLJ_OUT="$E/q/l/../dist"
treemd5 "$E/B/dist" > "$O/t/u3dd.after.md5"
check U3-junction-dotdot "OCLJ_OUT <junction>/../dist: refused, dist intact" \
  sh -c 'rc=$(cat "$1/rc/u3-dd.rc"); [ "$rc" != 0 ] && grep -q "the collection point" "$1/logs/u3-dd.log" && cmp -s "$1/t/u3dd.before.md5" "$1/t/u3dd.after.md5"' x "$O"

# --------------------------------------------------------------- G3: OCLJ_BUILD inside OCLJ_REPO
echo "== G3"
FR=$O/t/g3repo
mkdir -p "$FR/native/luajit" "$FR/serializer/tests"
cp "$R/native/luajit/upstream.commit" "$R/native/luajit/oclj_features.h" "$FR/native/luajit/"
echo '-- a tracked file of the scratch repository: must survive' > "$FR/serializer/tests/strpack.lua"
treemd5 "$FR" > "$O/t/g3repo.before.md5"
( cd "$FR" && find . | LC_ALL=C sort ) > "$O/t/g3repo.before.ls"
wb g3-in "$FR/serializer/tests" OCLJ_REPO="$FR" OCLJ_SHIM=$R/native OCLJ_SER=$R/serializer OCLJ_LUAJIT=$C/lj-clean OCLJ_VARIANT=additive
wb g3-case "$FR/SERIALIZER/newdir" OCLJ_REPO="$FR" OCLJ_SHIM=$R/native OCLJ_SER=$R/serializer OCLJ_LUAJIT=$C/lj-clean OCLJ_VARIANT=additive
junction "$O/t/g3link" "$FR/serializer"
wb g3-junction "$O/t/g3link/tests" OCLJ_REPO="$FR" OCLJ_SHIM=$R/native OCLJ_SER=$R/serializer OCLJ_LUAJIT=$C/lj-clean OCLJ_VARIANT=additive
treemd5 "$FR" > "$O/t/g3repo.after.md5"
( cd "$FR" && find . | LC_ALL=C sort ) > "$O/t/g3repo.after.ls"
for c in in case junction; do
  check G3-$c "OCLJ_BUILD inside OCLJ_REPO outside build/ ($c): refused" \
    sh -c 'rc=$(cat "$1/rc/g3-$2.rc"); [ "$rc" != 0 ] && grep -q "lies inside, the repository" "$1/logs/g3-$2.log"' x "$O" "$c"
done
check G3-nothing-created "the scratch repository is unchanged: strpack.lua intact, no file or directory added" \
  sh -c 'cmp -s "$1/t/g3repo.before.md5" "$1/t/g3repo.after.md5" && cmp -s "$1/t/g3repo.before.ls" "$1/t/g3repo.after.ls"' x "$O"
wb g3-build "$FR/build/native" OCLJ_REPO="$FR" OCLJ_SHIM=$R/native OCLJ_SER=$R/serializer OCLJ_LUAJIT=$C/lj-clean OCLJ_VARIANT=additive OCLJ_JNLUA="$O/t/no-jnlua-here"
check G3-under-build-allowed "OCLJ_BUILD under OCLJ_REPO/build: not refused by the guard (stops later, at OCLJ_JNLUA), nothing created" \
  sh -c 'grep -q "no .*no-jnlua-here/native/src/jnlua.c" "$1/logs/g3-build.log" && ! grep -q "lies inside, the repository" "$1/logs/g3-build.log" && [ ! -e "$1/t/g3repo/build" ]' x "$O"

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
