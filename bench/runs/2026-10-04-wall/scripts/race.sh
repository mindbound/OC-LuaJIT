#!/bin/sh
# race.sh <run-dir> <native additive|luajit> <libdir> <lock on|off> [ticks]   (OCLJ_RACE_PHASE=boot from the environment: race-2)
# One OCLJ_PROBE=rawrace harness run on JDK 8 (192 KB, scale 1.8); run it under affrun.
set -u
RUN="$1"; NAT="$2"; LIB="$3"; LOCK="$4"; TICKS="${5:-1000}"
REPO=/c/Users/astro/Downloads/OC-LuaJIT
OLD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad
LJEXE=$REPO/build/native/luajit-windows-x86_64/src/luajit.exe
JDK8="/c/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot"
cd "$REPO" || exit 97
[ -e "$RUN" ] && { echo "REFUSING: $RUN already exists"; exit 99; }
mkdir -p "$RUN/work" || exit 98
date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN/started.txt"
PHASE="${OCLJ_RACE_PHASE:-idle}"
echo "native=$NAT lib=$LIB lock=$LOCK ticks=$TICKS phase=$PHASE" > "$RUN/args.txt"
export OCLJ_LIBDIR="$LIB" OCLJ_KERNEL=watchdog OCLJ_JIT=on
md5sum "$OCLJ_LIBDIR"/*.dll > "$RUN/native.md5"
unset OCLJ_BENCH_ONLY OCLJ_JIT_EARLY
JAVA_TOOL_OPTIONS=-Dlog4j2.level=WARN \
OCLJ_JAVA="$JDK8" OCLJ_LUAJIT_EXE="$LJEXE" \
OCLJ_BRAIN=/c/Users/astro/Downloads/ocelot-brain \
OCLJ_LIBS="$OLD/flush-cost/work-1/lib" \
OCLJ_WORK="$RUN/work" OCLJ_NATIVE="$NAT" OCLJ_TIMEOUT=600 \
OCLJ_PROBE=rawrace OCLJ_RACE_LOCK="$LOCK" OCLJ_RACE_TICKS="$TICKS" OCLJ_RACE_PHASE="$PHASE" OCLJ_RAM_TIER=one OCLJ_RAM_SCALE=1.8 \
sh test/native/smoke-test.sh > "$RUN/run.log" 2>&1
echo "$?" > "$RUN/exit.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN/finished.txt"
