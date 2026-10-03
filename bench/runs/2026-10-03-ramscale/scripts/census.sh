#!/bin/sh
# census.sh <run-dir> <native additive|stock> <scale> <sticks> <os axis|mineos> <ticks>
set -u
RUN="$1"; NAT="$2"; SCALE="$3"; STICKS="$4"; OS="$5"; TICKS="$6"
R=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/ramscale
REPO=/c/Users/astro/Downloads/OC-LuaJIT
OLD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad
JDK8="/c/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot"
cd "$REPO" || exit 97
[ -e "$RUN" ] && { echo "REFUSING: $RUN already exists"; exit 99; }
mkdir -p "$RUN/work" "$RUN/os" || exit 98
echo "native=$NAT scale=$SCALE sticks=$STICKS os=$OS ticks=$TICKS" > "$RUN/args.txt"
if [ "$OS" = axis ]; then cp -r "$R/os-pristine/axis-os" "$RUN/os/axis-os"; ROOT="$RUN/os/axis-os/src/kernel"; BOOT="$RUN/os/axis-os/eeprom/boot.lua"; NAME=AxisOS
else cp -r "$R/os-pristine/MineOS-installed" "$RUN/os/MineOS-installed"; ROOT="$RUN/os/MineOS-installed"; BOOT="$RUN/os/MineOS-installed/EFI/Minified.lua"; NAME=MineOS; fi
if [ "$NAT" = stock ]; then unset OCLJ_LIBDIR OCLJ_KERNEL OCLJ_JIT; else
  export OCLJ_LIBDIR=$REPO/build/native/libdir-additive OCLJ_KERNEL=watchdog OCLJ_JIT=on; fi
unset OCLJ_BENCH_ONLY OCLJ_PROBE OCLJ_CENSUS_ARCH
JAVA_TOOL_OPTIONS=-Dlog4j2.level=WARN OCLJ_JAVA="$JDK8" \
OCLJ_LUAJIT_EXE=$REPO/build/native/luajit-windows-x86_64/src/luajit.exe \
OCLJ_BRAIN=/c/Users/astro/Downloads/ocelot-brain OCLJ_LIBS="$OLD/flush-cost/work-1/lib" \
OCLJ_WORK="$RUN/work" OCLJ_NATIVE="$NAT" OCLJ_TIMEOUT=900 OCLJ_RAM_SCALE="$SCALE" OCLJ_CENSUS_RAM="$STICKS" \
sh test/native/census-os.sh "$(cygpath -m $ROOT)" "$NAME" "$(cygpath -m $BOOT)" "$TICKS" > "$RUN/run.log" 2>&1
echo "$?" > "$RUN/exit.txt"
