#!/bin/sh
# suites-linux.sh <outdir> <OCLJ_BUILD> <PUC 5.3.6> <negctl 0|1> -- every native suite that runs on Linux,
# inside a WSL distro, against <OCLJ_BUILD> (the additive build last): shim, security, race (Win32-only:
# must exit 2), mem, vgc, wd, penalty, run-pack, run-packfuzz, run-bitop, run-bitjit, run-bitfuzz, the
# serializer's make test and make negctl, and with <negctl> = 1 the three negative controls:
# negative-control.sh, negctl-pack.sh and negctl-bitop.sh.  One .log, .rc, .start, .end per step.
set -u
OUT=$1; B=$2; PUC=$3; NEG=$4
REPO=/mnt/c/Users/astro/Downloads/OC-LuaJIT
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT" || exit 98
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
unset LUA_INIT LUA_INIT_5_3
export OCLJ_REPO=$REPO OCLJ_BUILD=$B CC=gcc OCLJ_LUA53=$PUC
export OCLJ_JNLUA=/mnt/c/Users/astro/Downloads/OC-JNLua
DISTRO=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
case $DISTRO in
  almalinux) export OCLJ_JNI=/usr/lib/jvm/java-1.8.0-openjdk/include ;;
  ubuntu)    export OCLJ_JNI=/usr/lib/jvm/java-17-openjdk-amd64/include ;;
  *) echo "unknown distro $DISTRO"; exit 97 ;;
esac
{ sed -n 's/^PRETTY_NAME=//p' /etc/os-release; getconf GNU_LIBC_VERSION; gcc --version | head -1; "$PUC" -v 2>&1; echo "OCLJ_BUILD=$B"; } > "$OUT/host.txt"
md5sum "$B"/libdir-additive/*.so "$B"/luajit-linux-x86_64/src/libluajit.a "$PUC" >> "$OUT/host.txt" 2>&1
step() {
  # step <name> <command...>
  n=$1; shift
  date -u +%H:%M:%S > "$OUT/$n.start"
  "$@" > "$OUT/$n.log" 2>&1
  echo "$?" > "$OUT/$n.rc"
  date -u +%H:%M:%S > "$OUT/$n.end"
}
cd "$REPO" || exit 96
step shim sh test/native/run.sh
step security sh test/native/run-security.sh
step race sh test/native/run-race.sh
step mem sh test/native/run-mem.sh
step vgc sh test/native/run-vgc.sh
step wd sh test/native/run-wd.sh
step penalty sh test/native/run-penalty.sh
step run-pack sh test/native/run-pack.sh
step run-packfuzz sh test/native/run-packfuzz.sh
step run-bitop sh test/native/run-bitop.sh
step run-bitjit sh test/native/run-bitjit.sh
step run-bitfuzz sh test/native/run-bitfuzz.sh
# The serializer's host is one file per platform in the repo's serializer/ (erislj_test); another distro's
# build may have left it newer than this OCLJ_BUILD's archive, so it is always relinked here.
rm -f serializer/erislj_test
step ser-test make -C serializer CC=gcc OCLJ_BUILD="$B" test
step ser-negctl make -C serializer CC=gcc OCLJ_BUILD="$B" negctl
if [ "$NEG" = 1 ]; then
  step negctl sh test/native/negative-control.sh
  step negctl-pack sh test/native/negctl-pack.sh
  step negctl-bitop sh test/native/negctl-bitop.sh
fi
for f in "$OUT"/*.rc; do echo "$(basename "$f" .rc) $(cat "$f")"; done > "$OUT/summary.txt"
cat "$OUT/summary.txt"
touch "$OUT/ALL.done"
