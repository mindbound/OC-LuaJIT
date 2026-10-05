#!/bin/sh
# cap2.sh <run-dir> <native additive|luajit|stock> <libdir|-> <jit on|off> <jitearly -|off> <tier> <scale> <shape> [batch] [junk]
# One capacity-probe harness run on JDK 8 (run it under affrun: P-cores).  The wall's cap.sh plus
# THE WINDOW's gate: OCLJ_CAP_BATCH / OCLJ_CAP_JUNK (the amplified probe is batch 10), and any
# hs_err_pid*.log the JVM leaves in the repo root moved into the run directory (PROC-DEATH).
set -u
RUN="$1"; NAT="$2"; LIB="$3"; JIT="$4"; EARLY="$5"; TIER="$6"; SCALE="$7"; SHAPE="$8"
BATCH="${9:-100}"; JUNK="${10:-24}"
REPO=/c/Users/astro/Downloads/OC-LuaJIT
OLD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad
LJEXE=$REPO/build/native/luajit-windows-x86_64/src/luajit.exe
JDK8="/c/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot"
cd "$REPO" || exit 97
[ -e "$RUN" ] && { echo "REFUSING: $RUN already exists"; exit 99; }
mkdir -p "$RUN/work" || exit 98
date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN/started.txt"
echo "native=$NAT lib=$LIB jit=$JIT jitearly=$EARLY tier=$TIER scale=$SCALE shape=$SHAPE batch=$BATCH junk=$JUNK" > "$RUN/args.txt"
if [ "$NAT" = stock ]; then unset OCLJ_LIBDIR OCLJ_KERNEL OCLJ_JIT; else
  export OCLJ_LIBDIR="$LIB" OCLJ_KERNEL=watchdog OCLJ_JIT="$JIT"
  md5sum "$OCLJ_LIBDIR"/*.dll > "$RUN/native.md5"; fi
if [ "$EARLY" = "-" ]; then unset OCLJ_JIT_EARLY; else export OCLJ_JIT_EARLY="$EARLY"; fi
unset OCLJ_BENCH_ONLY
JAVA_TOOL_OPTIONS=-Dlog4j2.level=WARN \
OCLJ_JAVA="$JDK8" OCLJ_LUAJIT_EXE="$LJEXE" \
OCLJ_BRAIN=/c/Users/astro/Downloads/ocelot-brain \
OCLJ_LIBS="$OLD/flush-cost/work-1/lib" \
OCLJ_WORK="$RUN/work" OCLJ_NATIVE="$NAT" OCLJ_TIMEOUT=600 \
OCLJ_PROBE=capacity OCLJ_CAP_SHAPE="$SHAPE" OCLJ_RAM_TIER="$TIER" OCLJ_RAM_SCALE="$SCALE" \
OCLJ_CAP_BATCH="$BATCH" OCLJ_CAP_JUNK="$JUNK" \
sh test/native/smoke-test.sh > "$RUN/run.log" 2>&1
echo "$?" > "$RUN/exit.txt"
for f in "$REPO"/hs_err_pid*.log "$RUN"/work/hs_err_pid*.log; do [ -f "$f" ] && mv "$f" "$RUN/"; done
date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN/finished.txt"
