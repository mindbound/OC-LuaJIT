#!/bin/sh
# full-linux.sh <run-dir> <native additive|luajit|stock> <libdir|-> <jit on|off> <only|UNSET>
#
# The Linux counterpart of claude-tmp/oclj/full.sh (bench/runs/2026-10-17-bitop/scripts/full.sh): ONE full
# harness arm at the default scale, with the same arguments and the same run-dir files (args.txt,
# started.txt, finished.txt, native.md5, run.log, exit.txt, work/smoke.log).  It runs INSIDE a WSL distro:
#
#   MSYS_NO_PATHCONV=1 wsl.exe -d AlmaLinux-8 -- sh /mnt/c/<...>/full-linux.sh /mnt/c/<runs>/<name> \
#       additive /mnt/c/<natives>/libdir-additive on UNSET
#
# VARIABLES SET IN GIT BASH DO NOT CROSS wsl.exe, exported or not: every OCLJ_* below must be set inside
# the distro, or the arm runs without it and still reads like a pass (a disposeoff arm run that way is the
# product, 82/0).  Pass them inside, as env arguments:
#
#   MSYS_NO_PATHCONV=1 wsl.exe -d AlmaLinux-8 -- env OCLJ_DISPOSE=off sh /mnt/c/<...>/full-linux.sh ...
#
# (or name them in WSLENV).  args.txt records what arrived.
# <run-dir> and <libdir> may be relative: both are made absolute against the caller's directory before
# the script enters the run dir.
# Changed 2026-10-20, AFTER the glibc round's chain ran: the chain ran the earlier text (md5
# bdfa837e3c4a66717936109101cbd8e0), which lacked the two paragraphs above and the relative-path fix.
#
# THE DISTRO is read from /etc/os-release and picks the JDK:
#   almalinux  JDK 8, /usr/lib/jvm/java-1.8.0-openjdk (1.8.0_504, the Windows chain's JDK update) -- the
#              glibc floor's own host (2.28), the primary Linux host
#   ubuntu     JDK 17, /usr/lib/jvm/java-17-openjdk-amd64 (Ubuntu 26.04, glibc 2.43) -- the forward host
# OCLJ_JAVA overrides it (a JDK home with javac); any other distro must set it.
#
# Where it differs from full.sh, and why:
#   - The JVM's working directory is the RUN DIR, not the repository.  OC extracts its stock natives into
#     the working directory (Ocelot-<ver>-5x-libjnlua5x-linux-x86_64.so; deleted at exit on Linux), and
#     OcljArch's fallback uses "." too, so a per-run directory keeps them out of the repository and out of
#     each other's way.  smoke-test.sh then defaults OCLJ_BENCHDIR to the repository's bench/oc, absolute.
#   - PATH is Linux-only.  WSL appends the whole Windows PATH (Git's usr/bin, three Adoptium JDKs,
#     mingw64), and a tool missing from the distro would otherwise resolve to a Windows one via interop.
#   - The patcher's luajit (OCLJ_LUAJIT_EXE), unless set: <libdir>/../luajit-linux-x86_64/src/luajit, the
#     one built with the library (a frozen natives dir carries its own), else the repository's
#     build/native/luajit-linux-x86_64/src/luajit (the AlmaLinux 8 release build).  It must RUN here:
#     a luajit built on a newer glibc does not run in AlmaLinux 8, and that is refused before the harness.
#   - Host facts (host.txt) and each library's glibc needs (native.glibc) are recorded in the run dir.
#   - OCLJ_TIMEOUT may be set (default 600, as full.sh).
# Passed through when set: OCLJ_DISPOSE, OCLJ_PERSIST_BUNDLE, OCLJ_JAVA_SRC, OCLJ_CONF_EXTRA, OCLJ_BENCHDIR,
# OCLJ_SMOKE (the smoke-test.sh to run; default the repository's).
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# NOT LC_ALL=C: a JDK 8 under the C locale reads and writes ASCII (file.encoding=ANSI_X3.4-1968).  The
# distro's own locale is kept and its file.encoding recorded in host.txt (UTF-8 in both distros; Cp1252
# on the Windows chain).
[ $# -eq 5 ] || { echo "usage: full-linux.sh <run-dir> <native> <libdir|-> <jit> <only|UNSET>" >&2; exit 2; }
RUN="$1"; NAT="$2"; LIB="$3"; JIT="$4"; ONLY="$5"
# Absolute before the cd below: a relative run dir or libdir would otherwise be read from inside the run
# dir, where neither exists (every write to the run dir failed, and no exit.txt was left for a chain).
case $RUN in /*) ;; *) RUN=$PWD/$RUN ;; esac
case $LIB in /*|-) ;; *) LIB=$PWD/$LIB ;; esac
REPO=/mnt/c/Users/astro/Downloads/OC-LuaJIT
: "${OCLJ_SMOKE:=$REPO/test/native/smoke-test.sh}"
[ "$(uname -s)" = Linux ] || { echo "REFUSING: full-linux.sh runs inside Linux (wsl.exe -d <distro> -- sh ...); this is $(uname -s)"; exit 95; }
[ -e "$RUN" ] && { echo "REFUSING: $RUN already exists"; exit 99; }
mkdir -p "$RUN/work" || exit 98
cd "$RUN" || exit 97
# refuse <code> <reason>: a launcher-level refusal, recorded where a chain looks for the exit code
refuse() { echo "$2" > "$RUN/refused.txt"; echo "$1" > "$RUN/exit.txt"; echo "REFUSING: $2"; exit "$1"; }
date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN/started.txt"
echo "native=$NAT lib=$LIB jit=$JIT only=$ONLY dispose=${OCLJ_DISPOSE:-} bundle=${OCLJ_PERSIST_BUNDLE:-} javasrc=${OCLJ_JAVA_SRC:-} smoke=$OCLJ_SMOKE timeout=${OCLJ_TIMEOUT:-600} benchdir=${OCLJ_BENCHDIR:-} confextra=${OCLJ_CONF_EXTRA:-}" > "$RUN/args.txt"

DISTRO=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
if [ -z "${OCLJ_JAVA:-}" ]; then
  case $DISTRO in
    almalinux) OCLJ_JAVA=/usr/lib/jvm/java-1.8.0-openjdk ;;
    ubuntu)    OCLJ_JAVA=/usr/lib/jvm/java-17-openjdk-amd64 ;;
    *) refuse 96 "no JDK default for distro '$DISTRO': set OCLJ_JAVA to a JDK home" ;;
  esac
fi
[ -x "$OCLJ_JAVA/bin/javac" ] || refuse 96 "no javac at $OCLJ_JAVA/bin/javac (OCLJ_JAVA must be a JDK, not a JRE)"
export OCLJ_JAVA

{ sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"'
  getconf GNU_LIBC_VERSION 2>/dev/null
  uname -srm
  echo "OCLJ_JAVA=$OCLJ_JAVA"
  "$OCLJ_JAVA/bin/java" -version 2>&1 | head -2
  "$OCLJ_JAVA/bin/java" -XshowSettings:properties -version 2>&1 | grep -E '^ *(file[.]encoding|sun[.]jnu[.]encoding) '
} > "$RUN/host.txt"
HOSTG=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')

if [ "$NAT" = stock ]; then
  unset OCLJ_LIBDIR OCLJ_KERNEL OCLJ_JIT OCLJ_LUAJIT_EXE
  # The stock arm loads OC's own libjnlua52-linux-x86_64.so out of this jar (extracted into the cwd).
  md5sum /mnt/c/Users/astro/claude-tmp/oclj/lib/OC-JNLua-Natives-*.jar > "$RUN/native.md5"
else
  export OCLJ_LIBDIR="$LIB" OCLJ_KERNEL=watchdog OCLJ_JIT="$JIT"
  ls "$OCLJ_LIBDIR"/libjnlua*.so > /dev/null 2>&1 || refuse 94 "no libjnlua*.so in $OCLJ_LIBDIR"
  md5sum "$OCLJ_LIBDIR"/libjnlua*.so > "$RUN/native.md5"
  # What each library needs from glibc, by the build gate's readelf reading (native/build-native.sh):
  # the highest GLIBC_x.y version need, and the non-weak imports that carry no version at all.
  for f in "$OCLJ_LIBDIR"/libjnlua*.so; do
    GMAX=$(readelf -V -W "$f" | sed -n '/Version needs section/,$p' | awk '/Name:/ {for (i = 1; i <= NF; i++) if ($i == "Name:") print $(i + 1)}' | grep -E '^GLIBC_[0-9]+([.][0-9]+)+$' | LC_ALL=C sort -V | tail -1)
    UNV=$(readelf --dyn-syms -W "$f" | awk '$1 ~ /^[0-9]+:$/ && $7 == "UND" && $5 != "WEAK" && NF >= 8 && $8 !~ /@/ {print $8}' | sort | tr '\n' ' ')
    NEEDED=$(readelf -d -W "$f" | awk '$2 == "(NEEDED)" {print $NF}' | tr -d '[]' | tr '\n' ' ')
    echo "$(basename "$f") needs=${GMAX:-?} host=glibc-$HOSTG unversioned=[${UNV% }] NEEDED=[${NEEDED% }]" >> "$RUN/native.glibc"
    # The dynamic loader refuses a library that needs a newer glibc than the host's; the JVM would
    # then fall back and the harness's guard would die twenty seconds in, so say it here instead.
    if [ -n "$GMAX" ] && [ -n "$HOSTG" ]; then
      TOP=$(printf '%s\n%s\n' "${GMAX#GLIBC_}" "$HOSTG" | LC_ALL=C sort -V | tail -1)
      [ "$TOP" = "$HOSTG" ] || refuse 93 "$(basename "$f") needs $GMAX, and this host has glibc $HOSTG: it cannot load here"
    fi
  done
  if [ -z "${OCLJ_LUAJIT_EXE:-}" ]; then
    for c in "$OCLJ_LIBDIR/../luajit-linux-x86_64/src/luajit" "$REPO/build/native/luajit-linux-x86_64/src/luajit"; do
      [ -f "$c" ] && { OCLJ_LUAJIT_EXE=$c; break; }
    done
  fi
  [ -n "${OCLJ_LUAJIT_EXE:-}" ] || refuse 92 "no Linux luajit for the kernel patcher beside $OCLJ_LIBDIR or in $REPO/build/native: set OCLJ_LUAJIT_EXE"
  LJV=$("$OCLJ_LUAJIT_EXE" -v 2>&1 | head -1)
  case $LJV in
    LuaJIT*) ;;
    *) refuse 92 "OCLJ_LUAJIT_EXE=$OCLJ_LUAJIT_EXE does not run on this host: $LJV" ;;
  esac
  export OCLJ_LUAJIT_EXE
  md5sum "$OCLJ_LUAJIT_EXE" >> "$RUN/native.md5"
  echo "patcher $OCLJ_LUAJIT_EXE: $LJV" >> "$RUN/host.txt"
fi
if [ "$ONLY" = UNSET ]; then unset OCLJ_BENCH_ONLY; else export OCLJ_BENCH_ONLY="$ONLY"; fi
unset OCLJ_PROBE OCLJ_RAM_SCALE OCLJ_RAM_TIER OCLJ_JIT_EARLY
[ -n "${OCLJ_JAVA_SRC:-}" ] && md5sum "$OCLJ_JAVA_SRC" >> "$RUN/native.md5"
md5sum "$OCLJ_SMOKE" >> "$RUN/native.md5"
export JAVA_TOOL_OPTIONS=-Dlog4j2.level=WARN
export OCLJ_BRAIN=/mnt/c/Users/astro/Downloads/ocelot-brain
export OCLJ_LIBS=/mnt/c/Users/astro/claude-tmp/oclj/lib
export OCLJ_WORK="$RUN/work" OCLJ_NATIVE="$NAT" OCLJ_TIMEOUT="${OCLJ_TIMEOUT:-600}" OCLJ_REPS=5
sh "$OCLJ_SMOKE" > "$RUN/run.log" 2>&1
echo "$?" > "$RUN/exit.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN/finished.txt"
# What the JVM left in its working directory (OC's extracted natives should be gone: deleteOnExit).
ls -la "$RUN" > "$RUN/cwd-after.txt"
