#!/bin/sh
# full.sh <run-dir> <native additive|stock> <jit on|off> <only|UNSET>   -- one full harness run at the default scale
set -u
RUN="$1"; NAT="$2"; JIT="$3"; ONLY="$4"
REPO=/c/Users/astro/Downloads/OC-LuaJIT
OLD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad
cd "$REPO" || exit 97
[ -e "$RUN" ] && { echo "REFUSING: $RUN already exists"; exit 99; }
mkdir -p "$RUN/work" || exit 98
if [ "$NAT" = stock ]; then unset OCLJ_LIBDIR OCLJ_KERNEL OCLJ_JIT; else
  export OCLJ_LIBDIR=$REPO/build/native/libdir-additive OCLJ_KERNEL=watchdog OCLJ_JIT="$JIT"; md5sum "$OCLJ_LIBDIR"/*.dll > "$RUN/native.md5"; fi
if [ "$ONLY" = UNSET ]; then unset OCLJ_BENCH_ONLY; else export OCLJ_BENCH_ONLY="$ONLY"; fi
unset OCLJ_PROBE OCLJ_RAM_SCALE OCLJ_RAM_TIER OCLJ_JIT_EARLY
JAVA_TOOL_OPTIONS=-Dlog4j2.level=WARN OCLJ_JAVA="/c/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot" \
OCLJ_LUAJIT_EXE=$REPO/build/native/luajit-windows-x86_64/src/luajit.exe \
OCLJ_BRAIN=/c/Users/astro/Downloads/ocelot-brain OCLJ_LIBS="$OLD/flush-cost/work-1/lib" \
OCLJ_WORK="$RUN/work" OCLJ_NATIVE="$NAT" OCLJ_TIMEOUT=600 OCLJ_REPS=5 \
sh test/native/smoke-test.sh > "$RUN/run.log" 2>&1
echo "$?" > "$RUN/exit.txt"
