#!/bin/sh
# T10 instrument (scratch only, not for the repo): run ingame-bitops.lua in the
# ocelot-brain census harness, booted into OpenOS from a scratch copy of its
# tree, with /home/.shrc launching the program the way a user at the prompt
# would.  Repo files are only read or executed; every write lands in $RUN.
#
#   sh run-ingame.sh <luajit|lua53> <fresh run dir, no spaces> <ingame-bitops.lua> [ticks]
set -u
ARM=$1; RUN=$2; PROG=$3; TICKS=${4:-3000}
REPO=/c/Users/astro/Downloads/OC-LuaJIT
[ -e "$RUN" ] && { echo "REFUSING: $RUN exists (never reuse a results directory)"; exit 99; }
if tasklist | grep -i -E "^javaw?[.]exe" > /dev/null; then
  echo "REFUSING: a java.exe or javaw.exe is running"; exit 96
fi
mkdir -p "$RUN/work" "$RUN/cwd" || exit 98
cp -r /c/Users/astro/Downloads/ocelot-brain/src/main/resources/assets/opencomputers/loot/openos "$RUN/os" || exit 95
cp "$PROG" "$RUN/os/home/ingame-bitops.lua" || exit 94
printf '%s\n' /home/ingame-bitops.lua > "$RUN/os/home/.shrc"
md5sum "$PROG" "$RUN/os/home/ingame-bitops.lua" > "$RUN/inputs.md5"
export JAVA_TOOL_OPTIONS=-Dlog4j2.level=WARN
export OCLJ_JAVA="/c/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot"
export OCLJ_BRAIN=/c/Users/astro/Downloads/ocelot-brain
export OCLJ_LIBS=/c/Users/astro/claude-tmp/oclj/lib
export OCLJ_WORK="$RUN/work"
export OCLJ_TIMEOUT=300
unset OCLJ_PROBE OCLJ_BENCH_ONLY OCLJ_RAM_SCALE OCLJ_CONF_EXTRA OCLJ_KERNEL OCLJ_JIT
if [ "$ARM" = luajit ]; then
  export OCLJ_NATIVE=additive
  export OCLJ_CENSUS_ARCH=luajit
  export OCLJ_LIBDIR=/c/Users/astro/claude-tmp/oclj/new-nc-9ac03aeb/libdir-additive
  export OCLJ_LUAJIT_EXE=$REPO/build/native/luajit-windows-x86_64/src/luajit.exe
  md5sum "$OCLJ_LIBDIR"/*.dll "$OCLJ_LUAJIT_EXE" >> "$RUN/inputs.md5"
elif [ "$ARM" = lua53 ]; then
  export OCLJ_NATIVE=stock
  export OCLJ_CENSUS_ARCH=53
  unset OCLJ_LIBDIR OCLJ_LUAJIT_EXE
else
  echo "arm must be luajit or lua53"; exit 2
fi
cd "$RUN/cwd" || exit 97
date > "$RUN/start.txt"
sh $REPO/test/native/census-os.sh "$(cygpath -m "$RUN/os")" OpenOS bios "$TICKS" > "$RUN/run.log" 2>&1
echo $? > "$RUN/exit.txt"
date > "$RUN/end.txt"
