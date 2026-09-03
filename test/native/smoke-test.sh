#!/bin/sh
# =====================================================================
# smoke-test.sh -- "OpenOS boots on LuaJIT and resumes" as a COMMAND.
#
# Boots real OpenOS 1.8.9 on ocelot-brain against the LuaJIT-backed
# libjnlua52 native produced by build-native.sh, asserts the LuaJ guard,
# prints the in-VM fingerprint, runs to a shell, persists through OC's own
# PersistenceAPI, restores into a fresh workspace and asserts the machine
# RESUMED -- the boot-time nonce is identical and the counter kept counting.
# Also asserts the computer.lua.allowBytecode gate still bites.
#
# Exit status 0 iff every milestone passed AND the fingerprint proves the
# LuaJIT native (not LuaJ, not the stock PUC-Lua 5.2 native) was in play.
#
# ---------------------------------------------------------------------
# PARAMETERS (env)
#   OCLJ_LIBDIR   dir holding libjnlua52-windows-x86_64.dll   [required]
#                 (build-native.sh's $OCLJ_OUT)
#   OCLJ_BRAIN    ocelot-brain checkout                       [required]
#   OCLJ_BRAIN_CP explicit ocelot-brain classpath entry (classes dir or jar);
#                 auto-detected under $OCLJ_BRAIN/target if unset
#   OCLJ_LIBS     dir of dependency jars; fetched with curl if empty
#                 (default $OCLJ_WORK/lib)
#   OCLJ_JAVA     JDK home (needs java 11+; verified on 17)     [default: $JAVA_HOME, else `java` on PATH]
#   OCLJ_WORK     scratch dir for classes/conf/logs   [default $TMPDIR/ocljit-smoke]
#   OCLJ_SRC      OcljSmoke.scala                               [default: next to this script]
#   OCLJ_TIMEOUT  seconds before the run is killed              [default 300]
#   OCLJ_KERNEL   watchdog (default) | stock.  "watchdog" derives the OC-LuaJIT
#                 kernel from ocelot-brain's machine.lua with
#                 native/kernel/patch-machine-lua.lua and puts it FIRST on the
#                 classpath, where it shadows OC's.  ocelot-brain is untouched.
#                 "stock" runs OC's own machine.lua with its standing deadline
#                 hook: the CONTROL, and the "before" picture in
#                 docs/research/hook-vs-jit.md.  The k2/k3 milestones only run
#                 under the watchdog kernel with the JIT on.
#   OCLJ_LUAJIT_EXE  the luajit.exe that runs the patcher
#                 [default: $OCLJ_LIBDIR/../luajit/src/luajit.exe, i.e. the
#                  one build-native.sh built]
#   OCLJ_JIT      on (default) | off.  "off" makes the harness call
#                 jit.off()+jit.flush() on the machine's state right before
#                 OpenOS boots -- the control for the JIT PROBE line.  (This
#                 replaces OCLJ_JITOFF, which exported an env var the shim
#                 deliberately never reads; it had been dead since the shim
#                 lost its getenv() hatches.)
#
# USAGE
#   OCLJ_LIBDIR=.../build/native/libdir OCLJ_BRAIN=~/src/ocelot-brain \
#     sh smoke-test.sh
#
# ---------------------------------------------------------------------
# EXTERNAL INPUTS AND HOW TO GET THEM
#
# 1. ocelot-brain -- the headless OpenComputers emulator that is our harness:
#      git clone https://gitlab.com/cc-ru/ocelot/ocelot-brain.git
#      cd ocelot-brain && sbt compile          # verified at 0.24.2 / e98a5b2
#    It brings BOTH pieces we would otherwise have to source ourselves:
#      * the Lua BIOS EEPROM and the OpenOS 1.8.9 floppy, as resources under
#        src/main/resources/assets/opencomputers/loot/ -- Loot.LuaBiosEEPROM
#        and Loot.OpenOsFloppy in the harness.  There is NO separate floppy
#        image to download.
#      * OC's machine.lua (the real kernel) and PersistenceAPI, under
#        src/main/resources/assets/opencomputers/lua/.
#
# 2. The OC-JNLua JAR -- li.cil.repack.com.naef.jnlua.LuaState, the Java side
#    our DLL implements.  ocelot-brain declares it as
#      https://asie.pl/javadeps/OC-JNLua-20230530.0.jar
#    fetched below along with OC-LuaJ and OC-JNLua-Natives (the natives jar
#    supplies the stock 5.3/5.4 DLLs; forceNativeLibPathFirst makes OUR 5.2
#    DLL win over its stock 5.2 one).
#
# 3. A Scala 2.13.11 compiler, fetched from Maven Central below.  There is no
#    sbt/mill dependency: scalac is invoked as `java -cp <jars> scala.tools.nsc.Main`.
#
# 4. OC-JNLua SOURCES are NOT needed here -- only by build-native.sh.
# =====================================================================
set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_LIBDIR:=}"
: "${OCLJ_BRAIN:=}"
: "${OCLJ_BRAIN_CP:=}"
: "${OCLJ_ALLOW_BYTECODE:=false}"
# Extra HOCON lines appended to the generated config, one per line.  This is
# how a milestone gets run in its other polarity without forking the harness:
# the memory milestones below, for instance, are calibration-sensitive, and
# "does it still boot with a different ramScaleFor64Bit" is a question the
# suite must be able to ask rather than assume.
# THE MACHINE'S RAM SCALE, pinned deliberately rather than inherited.
#
# ramScaleFor64Bit is how many real bytes OC charges per apparent byte of
# installed RAM; it exists because objects are bigger on a 64-bit VM than on
# the 32-bit one the module sizes were written for.  OC ships 1.8, calibrated
# for 64-bit PUC Lua.  LuaJIT GC64 needs more, and now that the RAM cap is
# actually ENFORCED that is no longer a detail: measured on this harness, a
# 1024K machine booting OpenOS 1.8.9 --
#
#     ramScale 1.8 (OC's default)   1 pass  in 6
#     ramScale 2.5                  6 passes in 6
#     ramScale 3.0                  5 passes in 5
#
# -- so at OC's own default the machine runs out of RAM during boot most of the
# time.  That is a real finding about the architecture, recorded in
# docs/research/memory-accounting.md and on the roadmap; it is NOT something
# this harness should rediscover flakily on every run, because a suite that
# fails at random tells you nothing about the change under test.  So the scale
# is pinned here, above the break-even point, and printed.  Set OCLJ_RAM_SCALE
# to reproduce the finding (OCLJ_RAM_SCALE=1.8), or OCLJ_CONF_EXTRA to override
# anything at all -- it is appended last and HOCON lets the later assignment
# win.
: "${OCLJ_RAM_SCALE:=3.0}"
: "${OCLJ_KERNEL:=watchdog}"
: "${OCLJ_LUAJIT_EXE:=}"
: "${OCLJ_CONF_EXTRA:=}"
# Scratch dir. Deliberately NOT $PWD-relative: this script is often invoked
# from a source checkout, and a default that lands classes, jars, a 78 KB
# generated config and a log inside the repository is a trap.
: "${OCLJ_WORK:=${TMPDIR:-/tmp}/ocljit-smoke}"
: "${OCLJ_LIBS:=$OCLJ_WORK/lib}"
: "${OCLJ_SRC:=$SELF_DIR/OcljSmoke.scala}"
: "${OCLJ_JAVA:=${JAVA_HOME:-}}"
: "${OCLJ_TIMEOUT:=300}"

DLL_NAME=libjnlua52-windows-x86_64.dll
SCALA_VER=2.13.11
ASM_VER=9.5.0-scala-1

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
say()  { echo "[smoke] $*"; }
T0=$(date +%s)
stamp() { echo "[smoke] +$(( $(date +%s) - T0 ))s  $*"; }

# Windows/JVM classpath plumbing: java wants native paths and ';'.
if command -v cygpath >/dev/null 2>&1; then
  SEP=';'
  w()  { cygpath -w "$1"; }   # C:\dir\file  -- classpath entries
  wm() { cygpath -m "$1"; }   # C:/dir/file  -- HOCON strings and java args
                              # (backslashes are escapes inside a HOCON quoted
                              #  string, so the config must use forward slashes)
else
  SEP=':'
  w()  { printf '%s' "$1"; }
  wm() { printf '%s' "$1"; }
fi

# --------------------------------------------------------------- 0
say "=============== 0. preflight ==============="
[ -n "$OCLJ_LIBDIR" ] || fail "OCLJ_LIBDIR is unset (dir holding $DLL_NAME)"
[ -f "$OCLJ_LIBDIR/$DLL_NAME" ] || fail "no $OCLJ_LIBDIR/$DLL_NAME -- run build-native.sh first"
[ -n "$OCLJ_BRAIN" ] || fail "OCLJ_BRAIN is unset (git clone https://gitlab.com/cc-ru/ocelot/ocelot-brain.git)"
[ -f "$OCLJ_SRC" ] || fail "no harness source at $OCLJ_SRC"

if [ -n "$OCLJ_JAVA" ] && [ -x "$OCLJ_JAVA/bin/java" ]; then JAVA="$OCLJ_JAVA/bin/java"
elif command -v java >/dev/null 2>&1; then JAVA=java
else fail "no java: set OCLJ_JAVA to a JDK 11+ home"; fi
say "java    = $("$JAVA" -version 2>&1 | head -1)"
say "dll     = $OCLJ_LIBDIR/$DLL_NAME ($(wc -c < "$OCLJ_LIBDIR/$DLL_NAME") bytes)"

mkdir -p "$OCLJ_WORK/classes" "$OCLJ_LIBS" || fail "cannot create $OCLJ_WORK"

# ocelot-brain compiled classes (or jar)
if [ -z "$OCLJ_BRAIN_CP" ]; then
  OCLJ_BRAIN_CP=$(find "$OCLJ_BRAIN/target" -type d -name classes 2>/dev/null | head -1)
  [ -n "$OCLJ_BRAIN_CP" ] || OCLJ_BRAIN_CP=$(find "$OCLJ_BRAIN/target" -name 'ocelot-brain*.jar' 2>/dev/null | head -1)
fi
[ -n "$OCLJ_BRAIN_CP" ] || fail "ocelot-brain is not compiled: run 'sbt compile' in $OCLJ_BRAIN,
       or set OCLJ_BRAIN_CP to its classes dir / jar"
BRAIN_RES="$OCLJ_BRAIN/src/main/resources"
[ -f "$BRAIN_RES/application.conf" ] || fail "no $BRAIN_RES/application.conf"
say "brain   = $OCLJ_BRAIN_CP"

# --------------------------------------------------------------- 1
say "=============== 1. dependency jars ==============="
M=https://repo1.maven.org/maven2
get() {
  f="$OCLJ_LIBS/$(basename "$1")"
  if [ -s "$f" ]; then return 0; fi
  say "    fetching $(basename "$1")"
  curl -sSL --max-time 180 -o "$f" "$1" || fail "download failed: $1"
  [ -s "$f" ] || fail "empty download: $1"
}
# Versions are ocelot-brain 0.24.2's build.sbt; bump them with it.
get $M/org/scala-lang/scala-library/$SCALA_VER/scala-library-$SCALA_VER.jar
get $M/org/scala-lang/scala-compiler/$SCALA_VER/scala-compiler-$SCALA_VER.jar
get $M/org/scala-lang/scala-reflect/$SCALA_VER/scala-reflect-$SCALA_VER.jar
get $M/org/scala-lang/modules/scala-asm/$ASM_VER/scala-asm-$ASM_VER.jar
get $M/org/apache/logging/log4j/log4j-api/2.26.1/log4j-api-2.26.1.jar
get $M/org/apache/logging/log4j/log4j-core/2.26.1/log4j-core-2.26.1.jar
get $M/com/google/guava/guava/33.7.1-jre/guava-33.7.1-jre.jar
get $M/com/google/guava/failureaccess/1.0.3/failureaccess-1.0.3.jar
get $M/commons-codec/commons-codec/1.22.1/commons-codec-1.22.1.jar
get $M/com/typesafe/config/1.4.9/config-1.4.9.jar
get $M/org/apache/commons/commons-lang3/3.20.0/commons-lang3-3.20.0.jar
get $M/org/apache/commons/commons-text/1.15.0/commons-text-1.15.0.jar
get $M/commons-io/commons-io/2.22.0/commons-io-2.22.0.jar
get $M/org/ow2/asm/asm/9.10.1/asm-9.10.1.jar
get https://asie.pl/javadeps/OC-LuaJ-20220907.1.jar
get https://asie.pl/javadeps/OC-JNLua-20230530.0.jar
get https://asie.pl/javadeps/OC-JNLua-Natives-20220928.1.jar
stamp "jars ready ($(ls "$OCLJ_LIBS"/*.jar | wc -l) files)"

CP="$(w "$OCLJ_BRAIN_CP")$SEP$(w "$BRAIN_RES")"
for j in "$OCLJ_LIBS"/*.jar; do
  case "$(basename "$j")" in scala-compiler*|scala-reflect*|scala-asm*) continue;; esac
  CP="$CP$SEP$(w "$j")"
done
SCALAC_CP="$(w "$OCLJ_LIBS/scala-compiler-$SCALA_VER.jar")$SEP$(w "$OCLJ_LIBS/scala-reflect-$SCALA_VER.jar")$SEP$(w "$OCLJ_LIBS/scala-library-$SCALA_VER.jar")$SEP$(w "$OCLJ_LIBS/scala-asm-$ASM_VER.jar")"

# --------------------------------------------------------------- 2
say "=============== 2. compile the harness ==============="
"$JAVA" -cp "$SCALAC_CP" scala.tools.nsc.Main \
  -classpath "$CP" -d "$(w "$OCLJ_WORK/classes")" "$(w "$OCLJ_SRC")" \
  > "$OCLJ_WORK/scalac.log" 2>&1
SC=$?
grep -E '^.*error' "$OCLJ_WORK/scalac.log" | head -20
[ $SC -eq 0 ] || fail "scalac exit=$SC (log: $OCLJ_WORK/scalac.log)"
[ -f "$OCLJ_WORK/classes/ocljit/smoke/Smoke\$.class" ] || fail "harness did not compile"
stamp "harness compiled"

# --------------------------------------------------------------- 3
say "=============== 3. generate the ocelot-brain config ==============="
# Settings.load parses the given file with NO fallback to the packaged
# reference, so the config has to be COMPLETE: start from ocelot-brain's own
# application.conf and append HOCON path assignments, which merge over it.
CONF="$OCLJ_WORK/ocljit.conf"
cp "$BRAIN_RES/application.conf" "$CONF" || fail "cannot copy application.conf"
LIBDIR_ABS=$(wm "$(CDPATH= cd -- "$OCLJ_LIBDIR" && pwd)")
{
  echo ""
  echo "# ---- appended by smoke-test.sh ----"
  # Make ocelot-brain load OUR libjnlua52 instead of the stock one bundled in
  # OC-JNLua-Natives.  This is the ONLY hook the whole thing needs.
  echo "opencomputers.debug.forceNativeLibPathFirst = \"$LIBDIR_ABS\""
  # The security setting whose enforcement we assert.  OCLJ_ALLOW_BYTECODE
  # exists ONLY so the d2 milestone can be run in its open polarity as a
  # negative control; it defaults to false and any other value is announced
  # loudly, renames the milestone, and changes the final verdict line so a
  # negative-control run can never be mistaken for a security pass.
  echo "opencomputers.computer.lua.allowBytecode = $OCLJ_ALLOW_BYTECODE"
  echo "opencomputers.computer.lua.ramScaleFor64Bit = $OCLJ_RAM_SCALE"
  if [ -n "$OCLJ_CONF_EXTRA" ]; then
    echo "# ---- OCLJ_CONF_EXTRA ----"
    printf '%s
' "$OCLJ_CONF_EXTRA"
  fi
} >> "$CONF"
[ -n "$OCLJ_CONF_EXTRA" ] && say "    EXTRA   = $OCLJ_CONF_EXTRA"
say "    conf    = $CONF"
say "    libdir  = $LIBDIR_ABS"
case $OCLJ_KERNEL in stock|watchdog) ;; *) fail "OCLJ_KERNEL must be stock or watchdog, not '$OCLJ_KERNEL'";; esac
if [ "$OCLJ_KERNEL" = "watchdog" ]; then
  # The patched kernel goes where the harness's own classes live -- the FIRST
  # classpath entry -- so NativeLuaArchitecture's
  #   getResourceAsStream("/assets/opencomputers/lua/machine.lua")
  # finds ours before ocelot-brain's.  Nothing in ocelot-brain changes.
  [ -n "$OCLJ_LUAJIT_EXE" ] || OCLJ_LUAJIT_EXE="$OCLJ_LIBDIR/../luajit/src/luajit.exe"
  [ -x "$OCLJ_LUAJIT_EXE" ] || fail "OCLJ_KERNEL=watchdog needs luajit.exe to run the kernel patcher; none at $OCLJ_LUAJIT_EXE (set OCLJ_LUAJIT_EXE)"
  KDIR="$OCLJ_WORK/classes/assets/opencomputers/lua"
  mkdir -p "$KDIR" || fail "cannot create $KDIR"
  "$OCLJ_LUAJIT_EXE" "$SELF_DIR/../../native/kernel/patch-machine-lua.lua" \
    "$BRAIN_RES/assets/opencomputers/lua/machine.lua" "$KDIR/machine.lua" \
    || fail "the kernel patcher refused ocelot-brain's machine.lua (an anchor no longer matches)"
  say "    kernel  = WATCHDOG variant at $KDIR/machine.lua (shadows OC's on the classpath)"
else
  # Make sure a stale patched kernel from a previous watchdog run cannot
  # linger in the shared classes dir and silently turn a stock run into one.
  rm -f "$OCLJ_WORK/classes/assets/opencomputers/lua/machine.lua"
  say "    kernel  = stock (OC's own machine.lua, standing deadline hook)"
fi
say "    ramScale= $OCLJ_RAM_SCALE   (OC ships 1.8; LuaJIT GC64 needs more -- see the comment above)"

# --------------------------------------------------------------- 4
say "=============== 4. boot OpenOS ==============="
LOG="$OCLJ_WORK/smoke.log"
RUNCP="$(w "$OCLJ_WORK/classes")$SEP$CP"
: "${OCLJ_JIT:=on}"
case $OCLJ_JIT in on|off) ;; *) fail "OCLJ_JIT must be on or off, not '$OCLJ_JIT'";; esac
[ "$OCLJ_JIT" = "off" ] && say "    OCLJ_JIT=off -- the harness will jit.off() the machine's state (JIT PROBE control run)"
CONF_ARG=$(wm "$CONF")
if command -v timeout >/dev/null 2>&1; then
  timeout -k 10 "$OCLJ_TIMEOUT" "$JAVA" -Docljit.jit="$OCLJ_JIT" -Docljit.kernel="$OCLJ_KERNEL" -cp "$RUNCP" ocljit.smoke.Smoke "$CONF_ARG" > "$LOG" 2>&1
else
  "$JAVA" -Docljit.jit="$OCLJ_JIT" -Docljit.kernel="$OCLJ_KERNEL" -cp "$RUNCP" ocljit.smoke.Smoke "$CONF_ARG" > "$LOG" 2>&1
fi
RC=$?
cat "$LOG"

# --------------------------------------------------------------- 5
say "=============== 5. verdict ==============="
# Three independent gates, because a JVM that dies inside the native can exit
# with a status that means nothing.
OK=1
[ $RC -eq 0 ] || { echo "  java exit=$RC (124 = timed out)"; OK=0; }
# The diagnostic deliberately does NOT contain the string it is reporting the
# absence of.  It used to read "no 'VERDICT: PASS' line", which meant a caller
# scoring a batch of runs with `grep -q 'VERDICT: PASS'` scored every FAILURE
# as a pass.  That is not hypothetical: it produced a confident "3/3 at
# ramScale 1.8" here that a second measurement contradicted, and the truth was
# 2/10.  Anything scanning these logs should match the harness's own line,
# anchored: grep -qx 'SMOKE| VERDICT: PASS'.
grep -q "^SMOKE| VERDICT: PASS" "$LOG" || { echo "  the harness did not report a passing verdict"; OK=0; }
grep -q "GUARD VM FINGERPRINT: native=luajit/" "$LOG" || {
  echo "  no LuaJIT fingerprint: the run did not prove which VM it used --"
  echo "  ocelot-brain substitutes LuaJ when the native fails to load, and LuaJ"
  echo "  has no Eris, so every persistence assertion would pass vacuously."
  OK=0; }
grep -c "MILESTONE .*: FAIL" "$LOG" | grep -qv '^0$' && { echo "  failing milestones:"; grep "MILESTONE .*: FAIL" "$LOG" | sed 's/^/    /'; OK=0; }

stamp "log: $LOG"
if [ $OK -eq 1 ]; then
  if [ "$OCLJ_ALLOW_BYTECODE" = false ]; then
    echo "SMOKE PASS -- OpenOS booted on LuaJIT, persisted, and resumed."
  else
    echo "SMOKE PASS (NEGATIVE CONTROL, allowBytecode=$OCLJ_ALLOW_BYTECODE) --"
    echo "  the sandbox gate was expected to be OPEN and was.  This run shows"
    echo "  the d2 probe reads the setting; it is NOT a security result."
  fi
  exit 0
fi
echo "SMOKE FAIL"
exit 1
