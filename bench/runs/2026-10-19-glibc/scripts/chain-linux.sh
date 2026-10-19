#!/bin/sh
# chain-linux.sh <tag> <natives-dir> [runs-dir] -- chain-r3.sh's seven harness arms on Linux, ONE JVM at a
# time, through full-linux.sh beside this script.  It runs INSIDE a WSL distro; from Git Bash, for the
# main session:
#
#   MSYS_NO_PATHCONV=1 nohup wsl.exe -d AlmaLinux-8 -- sh /mnt/c/<...>/chain-linux.sh <tag> /mnt/c/<natives> \
#       > <out> 2>&1 &
#
# and watch for <runs-dir>/chain-linux-<tag>.done.  The distro picks the JDK (full-linux.sh: AlmaLinux 8
# JDK 8u504, Ubuntu JDK 17).
#
# VARIABLES SET IN GIT BASH DO NOT CROSS wsl.exe, exported or not.  The two negative-control arms set
# theirs here, inside the distro; anything else (OCLJ_LUAJIT_EXE, OCLJ_JAVA, OCLJ_TIMEOUT, OCLJ_SMOKE)
# must be passed inside too: wsl.exe -d AlmaLinux-8 -- env OCLJ_TIMEOUT=900 sh /mnt/c/<...>/chain-linux.sh ...
# <natives-dir> and [runs-dir] may be relative to the caller's directory; both are made absolute first.
# An arm whose run dir already exists is REFUSED in the log (nothing runs, nothing is written into it):
# an old run is never reported as the new arm's result.
# Changed 2026-10-20, AFTER the glibc round's chain ran: the chain ran the earlier text (md5
# 79e2323bb150a98e80696a8c2cf7c372), which reported an existing run dir's old exit and CHECKS as the arm's
# and passed relative paths through to full-linux.sh.
#
# <natives-dir> holds libdir/libjnlua52-linux-x86_64.so and libdir-additive/libjnluajit52-linux-x86_64.so.
# The kernel patcher's luajit is resolved ONCE, here, and every arm uses it: OCLJ_LUAJIT_EXE if set, else
# <natives-dir>/luajit-linux-x86_64/src/luajit (a build dir or a frozen copy that carries it), else the
# repository's build/native/luajit-linux-x86_64/src/luajit; it must run on this host.
# [runs-dir] defaults to claude-tmp/oclj/runs-linux, apart from the Windows chains' runs/.
#
# Predicted CHECKS, the Windows chain's (r3-f, bench/runs/2026-10-17-bitop/logs/harness/chain-r3-f.txt):
# additive-on 82, dropin 69, additive-off 80, sieve 76, stock 53, disposeoff 82, bundleoff 82 with its 3
# expected failures (stk-2, stk-3, stk-4); d3, d4 and d5 PASS everywhere (stock: d4 and d5 want absent).
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[ $# -ge 2 ] || { echo "usage: chain-linux.sh <tag> <natives-dir> [runs-dir]" >&2; exit 2; }
T="$1"; N="$2"
H=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RUNS=${3:-/mnt/c/Users/astro/claude-tmp/oclj/runs-linux}
case $N in /*) ;; *) N=$PWD/$N ;; esac
case $RUNS in /*) ;; *) RUNS=$PWD/$RUNS ;; esac
REPO=/mnt/c/Users/astro/Downloads/OC-LuaJIT
F="sh $H/full-linux.sh"
LOG=$RUNS/chain-linux-$T.txt
[ "$(uname -s)" = Linux ] || { echo "REFUSING: chain-linux.sh runs inside Linux; this is $(uname -s)"; exit 95; }
mkdir -p "$RUNS" || exit 97
[ -e "$LOG" ] && { echo "REFUSING: $LOG exists"; exit 99; }
[ -f "$N/libdir/libjnlua52-linux-x86_64.so" ] && [ -f "$N/libdir-additive/libjnluajit52-linux-x86_64.so" ] \
  || { echo "no Linux natives under $N (libdir/libjnlua52-linux-x86_64.so, libdir-additive/libjnluajit52-linux-x86_64.so)"; exit 98; }
if [ -z "${OCLJ_LUAJIT_EXE:-}" ]; then
  for c in "$N/luajit-linux-x86_64/src/luajit" "$REPO/build/native/luajit-linux-x86_64/src/luajit"; do
    [ -f "$c" ] && { OCLJ_LUAJIT_EXE=$c; break; }
  done
fi
[ -n "${OCLJ_LUAJIT_EXE:-}" ] || { echo "no Linux luajit for the kernel patcher under $N or $REPO/build/native: set OCLJ_LUAJIT_EXE"; exit 98; }
LJV=$("$OCLJ_LUAJIT_EXE" -v 2>&1 | head -1)
case $LJV in LuaJIT*) ;; *) echo "OCLJ_LUAJIT_EXE=$OCLJ_LUAJIT_EXE does not run on this host: $LJV"; exit 98;; esac
export OCLJ_LUAJIT_EXE
{ echo "chain-linux $T started $(date -u +%H:%M:%S) natives=$N"
  echo "  host: $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"'), $(getconf GNU_LIBC_VERSION), $(uname -r)"
  echo "  patcher: $OCLJ_LUAJIT_EXE ($LJV)"
  md5sum "$N/libdir/libjnlua52-linux-x86_64.so" "$N/libdir-additive/libjnluajit52-linux-x86_64.so" "$OCLJ_LUAJIT_EXE" | sed 's/^/  /'
} > "$LOG"
one() {
  # one <name> <env|-> <native> <lib> <jit> <only>
  name=$1; envs=$2; nat=$3; lib=$4; jit=$5; only=$6
  echo "  $name env=[$envs] $nat $lib $jit $only" >> "$LOG"
  # full-linux.sh refuses an existing run dir and writes nothing; reading that dir's files below would
  # report the OLD run as this arm's (and write env.txt into it).
  [ -e "$RUNS/$name-$T" ] && { echo "$name REFUSED: $RUNS/$name-$T already exists (not run, not read)" >> "$LOG"; return 0; }
  ( [ "$envs" != - ] && export $envs; $F "$RUNS/$name-$T" "$nat" "$lib" "$jit" "$only"; [ "$envs" != - ] && echo "$envs" > "$RUNS/$name-$T/env.txt" )
  echo "$name exit=$(cat "$RUNS/$name-$T/exit.txt" 2>/dev/null) $(grep -E 'CHECKS:' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null)" >> "$LOG"
  [ -f "$RUNS/$name-$T/refused.txt" ] && sed 's/^/      REFUSED /' "$RUNS/$name-$T/refused.txt" >> "$LOG"
  grep -E 'MILESTONE d[345]-' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null | cut -c1-220 | sed 's/^/      /' >> "$LOG"
  grep -E 'MILESTONE .*: FAIL' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null | cut -c1-220 | sed 's/^/      FAIL /' >> "$LOG"
}
one lx-additive-on - additive "$N/libdir-additive" on UNSET
one lx-dropin - luajit "$N/libdir" on UNSET
one lx-additive-off - additive "$N/libdir-additive" off UNSET
one lx-sieve - additive "$N/libdir-additive" on sieve
one lx-stock - stock - on UNSET
one lx-disposeoff OCLJ_DISPOSE=off additive "$N/libdir-additive" on UNSET
one lx-bundleoff OCLJ_PERSIST_BUNDLE=off additive "$N/libdir-additive" on UNSET
echo "chain-linux $T finished $(date -u +%H:%M:%S)" >> "$LOG"
touch "$RUNS/chain-linux-$T.done"
