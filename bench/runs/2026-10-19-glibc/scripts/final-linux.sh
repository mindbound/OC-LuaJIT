#!/bin/sh
# final-linux.sh <outdir> <OCLJ_BUILD> -- after the follow-up's fixes: negative-control.sh (the fixed script)
# and the serializer's make test (the fixed for-in test) inside a WSL distro, against <OCLJ_BUILD>: the
# release build/native in AlmaLinux 8, the development build in Ubuntu.  <outdir> must not exist.
set -u
OUT=$1; B=$2
REPO=/mnt/c/Users/astro/Downloads/OC-LuaJIT
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT" || exit 98
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
unset LUA_INIT LUA_INIT_5_3 MEMTEST_CFLAGS
export OCLJ_REPO=$REPO OCLJ_BUILD=$B CC=gcc
export OCLJ_JNLUA=/mnt/c/Users/astro/Downloads/OC-JNLua
DISTRO=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
case $DISTRO in
  almalinux) export OCLJ_JNI=/usr/lib/jvm/java-1.8.0-openjdk/include ;;
  ubuntu)    export OCLJ_JNI=/usr/lib/jvm/java-17-openjdk-amd64/include ;;
  *) echo "unknown distro $DISTRO"; exit 97 ;;
esac
{ sed -n 's/^PRETTY_NAME=//p' /etc/os-release; getconf GNU_LIBC_VERSION; ls -l /bin/sh; echo "OCLJ_BUILD=$B"; } > "$OUT/host.txt"
md5sum "$REPO/test/native/negative-control.sh" "$REPO/serializer/tests/forin.lua" "$B"/libdir-additive/*.so >> "$OUT/host.txt"
cd "$REPO" || exit 96
date -u +%H:%M:%S > "$OUT/negctl.start"
sh test/native/negative-control.sh > "$OUT/negctl.log" 2>&1; echo $? > "$OUT/negctl.rc"
date -u +%H:%M:%S > "$OUT/negctl.end"
rm -f serializer/erislj_test
make -C serializer CC=gcc OCLJ_BUILD="$B" test > "$OUT/ser-test.log" 2>&1; echo $? > "$OUT/ser-test.rc"
echo "negctl rc=$(cat "$OUT/negctl.rc") $(grep -c 'RESULT: PASS' "$OUT/negctl.log") PASS $(grep -c 'RESULT: FAIL' "$OUT/negctl.log") FAIL $(grep 'NEGATIVE CONTROL' "$OUT/negctl.log" | head -1 | cut -c1-60)" > "$OUT/summary.txt"
echo "ser-test rc=$(cat "$OUT/ser-test.rc") $(grep -E 'RESULT' "$OUT/ser-test.log" | tr '\n' ' ' | cut -c1-300)" >> "$OUT/summary.txt"
cat "$OUT/summary.txt"
touch "$OUT/ALL.done"
