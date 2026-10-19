#!/bin/sh
# ff-linux.sh <outdir> <head-build-native.sh> -- the glibc round's build-side fail-firsts, run INSIDE a WSL
# distro (AlmaLinux 8 or Ubuntu), each build into a fresh OCLJ_BUILD under <outdir>, never build/native.
# On AlmaLinux 8.  The user installed git there on 2026-10-19; "git cannot read the checkout" is made by
# GIT_DIR=/nonexistent (git then fails with "not a git repository", as with no git at all):
#   oldlink  the working tree's build-native.sh with only its Linux LINK_EXTRA put back to round 3's
#            "-static-libgcc": must FAIL at the ELF import gate, naming the six unversioned pthread imports
#   head     HEAD's build-native.sh (3adfeaf) with git failing: builds, and its log says
#            "luajit = ... @ unknown" -- the fingerprint the commit fix exists for
#   nogit    the working tree's build-native.sh, git failing, on a copy of the LuaJIT checkout without
#            .git: must FAIL ("cannot read the LuaJIT checkout's commit")
#   release  the working tree's build-native.sh as is, OCLJ_GLIBC_MAX=2.28, git working: the positive
#            control (passes, "@ 1ee778a4", GLIBC_2.17)
#   relfile  the same with git failing: the commit comes from .git/HEAD; its .so must be byte-identical
#            to release's (the two ways agree)
# On Ubuntu:
#   floor    the working tree's build-native.sh with OCLJ_GLIBC_MAX=2.28: must FAIL above the floor
#   dev      the same with OCLJ_GLIBC_MAX unset: the positive control (passes, reports GLIBC_2.38)
# Every case is the additive variant.  One summary line per case in <outdir>/summary.txt.
set -u
OUT=$1; HEADBN=$2
REPO=/mnt/c/Users/astro/Downloads/OC-LuaJIT
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT" || exit 98
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export OCLJ_REPO=$REPO CC=gcc OCLJ_VARIANT=additive
export OCLJ_JNLUA=/mnt/c/Users/astro/Downloads/OC-JNLua
DISTRO=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
case $DISTRO in
  almalinux) export OCLJ_JNI=/usr/lib/jvm/java-1.8.0-openjdk/include ;;
  ubuntu)    export OCLJ_JNI=/usr/lib/jvm/java-17-openjdk-amd64/include ;;
  *) echo "unknown distro $DISTRO"; exit 97 ;;
esac
{ sed -n 's/^PRETTY_NAME=//p' /etc/os-release; getconf GNU_LIBC_VERSION; gcc --version | head -1; command -v git || echo "git: none"; } > "$OUT/host.txt"
md5sum "$REPO/native/build-native.sh" "$HEADBN" >> "$OUT/host.txt"
case1() {
  # case1 <name> <want: fail|pass> <grep that must match the log> <script> [env...]
  n=$1; want=$2; pat=$3; bn=$4; shift 4
  mkdir -p "$OUT/$n"
  env "$@" OCLJ_BUILD="$OUT/$n/build/native" sh "$bn" > "$OUT/$n/build.log" 2>&1
  rc=$?
  if grep -qE -- "$pat" "$OUT/$n/build.log"; then hit=yes; else hit=no; fi
  verdict=WRONG
  [ "$want" = fail ] && [ "$rc" -ne 0 ] && [ "$hit" = yes ] && verdict=AS-WANTED
  [ "$want" = pass ] && [ "$rc" -eq 0 ] && [ "$hit" = yes ] && verdict=AS-WANTED
  echo "$n want=$want rc=$rc match=$hit [$pat] -> $verdict" >> "$OUT/summary.txt"
}
if [ "$DISTRO" = almalinux ]; then
  sed 's/LINK_EXTRA="-static-libgcc -pthread -Wl,--no-undefined"/LINK_EXTRA="-static-libgcc"/' \
    "$REPO/native/build-native.sh" > "$OUT/bn-oldlink.sh"
  echo "oldlink copy differs in $(diff "$REPO/native/build-native.sh" "$OUT/bn-oldlink.sh" | grep -c '^<') line(s)" >> "$OUT/summary.txt"
  case1 oldlink fail 'imports these symbols with NO version: pthread_attr_setstacksize pthread_condattr_setclock pthread_create pthread_join pthread_setname_np pthread_sigmask' "$OUT/bn-oldlink.sh" OCLJ_GLIBC_MAX=2.28
  case1 head pass 'luajit  = .* @ unknown' "$HEADBN" GIT_DIR=/nonexistent
  mkdir -p "$OUT/luajit-nogit"
  ( cd "$REPO/prototype/watchdog/luajit" && tar --exclude=./.git -cf - . ) | ( cd "$OUT/luajit-nogit" && tar -xf - )
  [ -e "$OUT/luajit-nogit/.git" ] && echo "nogit copy HAS .git" >> "$OUT/summary.txt"
  case1 nogit fail "cannot read the LuaJIT checkout's commit" "$REPO/native/build-native.sh" OCLJ_LUAJIT="$OUT/luajit-nogit" OCLJ_GLIBC_MAX=2.28 GIT_DIR=/nonexistent
  case1 release pass 'luajit  = .* @ 1ee778a4' "$REPO/native/build-native.sh" OCLJ_GLIBC_MAX=2.28
  grep -hE 'glibc|ELF imports|NEEDED' "$OUT/release/build.log" | head -5 >> "$OUT/summary.txt"
  case1 relfile pass 'luajit  = .* @ 1ee778a4' "$REPO/native/build-native.sh" OCLJ_GLIBC_MAX=2.28 GIT_DIR=/nonexistent
  for d in head release relfile; do
    f="$OUT/$d/build/native/libdir-additive/libjnluajit52-linux-x86_64.so"
    [ -f "$f" ] && echo "$d .so $(md5sum < "$f" | cut -c1-8) fingerprint: $(grep -aoE '[0-9a-z]+[|]LuaJIT 2[.]1[.]ROLLING[|][0-9a-f]+[|][a-z0-9.]+' "$f" | head -1)" >> "$OUT/summary.txt"
  done
  a=$(md5sum < "$OUT/release/build/native/libdir-additive/libjnluajit52-linux-x86_64.so" 2>/dev/null)
  b=$(md5sum < "$OUT/relfile/build/native/libdir-additive/libjnluajit52-linux-x86_64.so" 2>/dev/null)
  if [ -n "$a" ] && [ "$a" = "$b" ]; then echo "release and relfile .so: byte-identical -> AS-WANTED" >> "$OUT/summary.txt"
  else echo "release and relfile .so: DIFFER -> WRONG" >> "$OUT/summary.txt"; fi
else
  case1 floor fail 'needs more than OCLJ_GLIBC_MAX=2.28 allows' "$REPO/native/build-native.sh" OCLJ_GLIBC_MAX=2.28
  case1 dev pass 'highest version needed GLIBC_2[.]38, NOT within the release floor' "$REPO/native/build-native.sh"
fi
cat "$OUT/summary.txt"
touch "$OUT/ALL.done"
