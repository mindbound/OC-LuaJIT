#!/bin/sh
# full.sh <run-dir> <native additive|luajit|stock> <libdir|-> <jit on|off> <only|UNSET>
# One full harness run at the default scale; the 2026-10-04 launcher (bench/runs/2026-10-04-wall/scripts/full.sh)
# with a durable jar cache, and with OCLJ_DISPOSE / OCLJ_PERSIST_BUNDLE / OCLJ_JAVA_SRC passed through when set.
set -u
RUN="$1"; NAT="$2"; LIB="$3"; JIT="$4"; ONLY="$5"
REPO=/c/Users/astro/Downloads/OC-LuaJIT
cd "$REPO" || exit 97
[ -e "$RUN" ] && { echo "REFUSING: $RUN already exists"; exit 99; }
mkdir -p "$RUN/work" || exit 98
date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN/started.txt"
echo "native=$NAT lib=$LIB jit=$JIT only=$ONLY dispose=${OCLJ_DISPOSE:-} bundle=${OCLJ_PERSIST_BUNDLE:-} javasrc=${OCLJ_JAVA_SRC:-}" > "$RUN/args.txt"
if [ "$NAT" = stock ]; then unset OCLJ_LIBDIR OCLJ_KERNEL OCLJ_JIT; else
  export OCLJ_LIBDIR="$LIB" OCLJ_KERNEL=watchdog OCLJ_JIT="$JIT"; md5sum "$OCLJ_LIBDIR"/*.dll > "$RUN/native.md5"; fi
if [ "$ONLY" = UNSET ]; then unset OCLJ_BENCH_ONLY; else export OCLJ_BENCH_ONLY="$ONLY"; fi
unset OCLJ_PROBE OCLJ_RAM_SCALE OCLJ_RAM_TIER OCLJ_JIT_EARLY
[ -n "${OCLJ_JAVA_SRC:-}" ] && md5sum "$OCLJ_JAVA_SRC" >> "$RUN/native.md5"
export JAVA_TOOL_OPTIONS=-Dlog4j2.level=WARN
export OCLJ_JAVA="/c/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot"
export OCLJ_LUAJIT_EXE=$REPO/build/native/luajit-windows-x86_64/src/luajit.exe
export OCLJ_BRAIN=/c/Users/astro/Downloads/ocelot-brain
export OCLJ_LIBS=/c/Users/astro/claude-tmp/oclj/lib
export OCLJ_WORK="$RUN/work" OCLJ_NATIVE="$NAT" OCLJ_TIMEOUT=600 OCLJ_REPS=5
sh test/native/smoke-test.sh > "$RUN/run.log" 2>&1
echo "$?" > "$RUN/exit.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN/finished.txt"
