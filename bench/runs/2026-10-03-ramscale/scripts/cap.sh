#!/bin/sh
# cap.sh <run-dir> <native additive|stock> <jit on|off> <jitearly -|off> <tier one..threehalf> <scale> <shape>
# One capacity-probe harness run on JDK 8; run it under affrun so the JVM sits on the P-cores.
set -u
RUN="$1"; NAT="$2"; JIT="$3"; EARLY="$4"; TIER="$5"; SCALE="$6"; SHAPE="$7"
REPO=/c/Users/astro/Downloads/OC-LuaJIT
OLD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad
LJEXE=$REPO/build/native/luajit-windows-x86_64/src/luajit.exe
JDK8="/c/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot"
cd "$REPO" || exit 97
[ -e "$RUN" ] && { echo "REFUSING: $RUN already exists"; exit 99; }
mkdir -p "$RUN/work" || exit 98
date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN/started.txt"
echo "native=$NAT jit=$JIT jitearly=$EARLY tier=$TIER scale=$SCALE shape=$SHAPE" > "$RUN/args.txt"
if [ "$NAT" = stock ]; then unset OCLJ_LIBDIR OCLJ_KERNEL OCLJ_JIT; else
  export OCLJ_LIBDIR=$REPO/build/native/libdir-additive OCLJ_KERNEL=watchdog OCLJ_JIT="$JIT"
  md5sum "$OCLJ_LIBDIR"/*.dll > "$RUN/native.md5"; fi
if [ "$EARLY" = "-" ]; then unset OCLJ_JIT_EARLY; else export OCLJ_JIT_EARLY="$EARLY"; fi
unset OCLJ_BENCH_ONLY
JAVA_TOOL_OPTIONS=-Dlog4j2.level=WARN \
OCLJ_JAVA="$JDK8" OCLJ_LUAJIT_EXE="$LJEXE" \
OCLJ_BRAIN=/c/Users/astro/Downloads/ocelot-brain \
OCLJ_LIBS="$OLD/flush-cost/work-1/lib" \
OCLJ_WORK="$RUN/work" OCLJ_NATIVE="$NAT" OCLJ_TIMEOUT=600 \
OCLJ_PROBE=capacity OCLJ_CAP_SHAPE="$SHAPE" OCLJ_RAM_TIER="$TIER" OCLJ_RAM_SCALE="$SCALE" \
sh test/native/smoke-test.sh > "$RUN/run.log" 2>&1
echo "$?" > "$RUN/exit.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN/finished.txt"
