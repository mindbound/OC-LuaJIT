#!/bin/sh
# build-linux.sh <outdir> <OCLJ_BUILD> [OCLJ_GLIBC_MAX] -- both Linux variants (dropin, then additive) inside a
# WSL distro, into <OCLJ_BUILD>: the release build is AlmaLinux 8 into the repo's build/native with 2.28; a
# development build is Ubuntu into a scratch OCLJ_BUILD with no limit.  Logs, md5s of every object and .so,
# and each .so's glibc needs (readelf) go to <outdir>, which must not exist.
set -u
OUT=$1; B=$2; MAX=${3:-}
REPO=/mnt/c/Users/astro/Downloads/OC-LuaJIT
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT" || exit 98
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export OCLJ_REPO=$REPO OCLJ_BUILD=$B CC=gcc
export OCLJ_JNLUA=/mnt/c/Users/astro/Downloads/OC-JNLua
DISTRO=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
case $DISTRO in
  almalinux) export OCLJ_JNI=/usr/lib/jvm/java-1.8.0-openjdk/include ;;
  ubuntu)    export OCLJ_JNI=/usr/lib/jvm/java-17-openjdk-amd64/include ;;
  *) echo "unknown distro $DISTRO"; exit 97 ;;
esac
[ -n "$MAX" ] && export OCLJ_GLIBC_MAX=$MAX
{ sed -n 's/^PRETTY_NAME=//p' /etc/os-release; getconf GNU_LIBC_VERSION; gcc --version | head -1; ld --version | head -1
  command -v git || echo "git: none"; echo "OCLJ_BUILD=$B OCLJ_GLIBC_MAX=${MAX:-unset}"; } > "$OUT/host.txt"
md5sum "$REPO/native/build-native.sh" >> "$OUT/host.txt"
for v in dropin additive; do
  OCLJ_VARIANT=$v sh "$REPO/native/build-native.sh" > "$OUT/build-$v.log" 2>&1
  echo "build-$v exit=$?" >> "$OUT/summary.txt"
  cp "$B/luajit_build.log" "$OUT/luajit_build-$v.log" 2>/dev/null
done
L=$B/luajit-linux-x86_64/src
md5sum "$L/libluajit.a" "$L/luajit" "$L"/*.o "$L"/host/*.o "$B"/obj-linux-x86_64/*.o \
  "$B"/libdir/*.so "$B"/libdir-additive/*.so "$B"/dist/*.so > "$OUT/natives.md5" 2>&1
for f in "$B"/libdir/*.so "$B"/libdir-additive/*.so; do
  [ -f "$f" ] || continue
  echo "== $(basename "$f")" >> "$OUT/glibc.txt"
  readelf -V -W "$f" | sed -n '/Version needs section/,$p' | awk '/Name:/ {for (i = 1; i <= NF; i++) if ($i == "Name:") print $(i + 1)}' \
    | sort -uV | tr '\n' ' ' >> "$OUT/glibc.txt"; echo >> "$OUT/glibc.txt"
  readelf -d -W "$f" | awk '$2 == "(NEEDED)" {print "  NEEDED", $NF}' >> "$OUT/glibc.txt"
  echo "  fingerprint: $(grep -aoE '[0-9a-z]+[|]LuaJIT 2[.]1[.]ROLLING[|][0-9a-f]+[|][a-z0-9.]+' "$f" | head -1)" >> "$OUT/glibc.txt"
done
cat "$OUT/summary.txt"
grep -hE 'luajit  = |glibc|ELF imports|NEEDED|bitwise-operator gate|jit tools gate|GG=|serializer hash|VM-features|ABI surface' "$OUT"/build-*.log | cut -c1-220
cat "$OUT/glibc.txt"
touch "$OUT/ALL.done"
