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
#   OCLJ_TIMEOUT  seconds before the run is killed              [default 600]
#                 Raised from 300 when the Phase 1 suite landed: boot plus
#                 Phase 0 is about a minute, the suite is minutes more in the
#                 PUC 5.2 cell, and a kill mid-suite loses every row.
#   OCLJ_REPS     repetitions per benchmark, in-machine            [default 3]
#                 The harness reports MIN and MAX, never a mean: with one
#                 sample the two are equal and the row says so honestly.
#   OCLJ_BENCH_ONLY  comma-separated benchmark names to run   [default: all in
#                 bench/oc/references.txt].  Set it to the empty string to boot
#                 with NO benchmarks, which is how the mcode baseline for the
#                 per-benchmark delta is taken.
#   OCLJ_SUITE_WAIT  seconds to wait for the suite to finish     [default 300]
#                 Deliberately shorter than OCLJ_TIMEOUT, so a stuck suite
#                 reports the rows it did get instead of being killed.
#   OCLJ_ENCORE   benchmark kept running on a repeating timer after the suite
#                 ends                                     [default mandelbrot]
#                 This is how POST-SAVE RECOVERY is measured.  The timer holds
#                 a Lua closure, so eris has to serialise it, so it survives the
#                 persist and fires again on the other side with nothing telling
#                 it to -- the probe rides on the feature under test.  Java
#                 compares the best warm sample before the save with the first
#                 sample whose sequence number advanced after the restore.
#   OCLJ_ENCORE_PERIOD  seconds between encore runs               [default 5]
#   OCLJ_NATIVE   luajit (default) | stock.  "stock" does NOT point
#                 forceNativeLibPathFirst at our DLL, so ocelot-brain loads
#                 its own bundled PUC-Lua 5.2 native instead -- the VM a
#                 player runs today, and the only honest baseline for "what
#                 does the JIT buy".  It forces OCLJ_KERNEL=stock too, because
#                 the patched kernel hard-errors without _OCLJ_WATCHDOG, which
#                 the stock native does not provide.  The harness's guard
#                 asserts the stock fingerprint with equal force in this mode,
#                 so a mis-resolved DLL dies instead of printing a number.
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

# DEFINED HERE, NOT LOWER DOWN, BECAUSE THEY ARE USED HERE.  These four sat
# below the OCLJ_NATIVE validation that calls them, so an unrecognised value hit
# `fail: command not found`, sh carried on to the next line, and the run
# proceeded in whatever mode the defaults gave it.  A guard that cannot exit is
# not a guard.
fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
say()  { echo "[smoke] $*"; }
T0=$(date +%s)
stamp() { echo "[smoke] +$(( $(date +%s) - T0 ))s  $*"; }
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

# GC PACING, for the rate-contest experiment (memory-accounting.md section 8).
# 0 = leave the VM's own LUAI_GCMUL / LUAI_GCPAUSE alone, which is the control.
# stepmul is the only knob that changes the collector's RATE (work per byte
# allocated is ~stepmul/100); pause is inert under sustained churn and is here
# so a run can demonstrate that rather than assert it.  The harness prints the
# PREVIOUS value and fails a milestone unless it reads 200 -- otherwise "pacing
# did not help" and "the knob never took" are the same row.
: "${OCLJ_GCSTEPMUL:=0}"
: "${OCLJ_GCPAUSE:=0}"
# Defaulted BELOW, from OCLJ_NATIVE: an additive run must pin OUR architecture,
# because in that mode "Lua 5.2" is the real PUC native sitting right next to us.
: "${OCLJ_CENSUS_ARCH:=}"
: "${OCLJ_CENSUS_RAM:=1}"   # ExtendedTier.ThreeHalf sticks; MineOS declares a 2048 KB floor   # census baseline arm only; 53 measures PUC, not us
: "${OCLJ_NATIVE:=luajit}"
# WHICH LIBRARY BACKS THE MACHINE, and therefore which filename the preflight
# demands.  The name is not decoration: LuaStateFactory looks under
# forceNativeLibPathFirst for ITS OWN filename, one per factory, so the filename
# IS the selection mechanism.
#
#   luajit    (default)  libjnlua52-*    our DROPIN, wearing OC's 5.2 name.
#                        "Lua 5.2" IS LuaJIT; there is no PUC VM in the JVM.
#                        Every measurement in bench/runs/ was taken like this.
#   stock                no forced path at all -- the bundled PUC-Lua 5.2, the
#                        VM a player runs today, and the only honest baseline.
#   additive             libjnluajit52-*, backing LuaStateLuaJIT.  OpenComputers'
#                        own PUC 5.2 native ALSO loads, from the natives jar,
#                        because the 5.2 factory misses in that directory and
#                        falls back.  Both VMs live in one JVM, which is the
#                        shipped configuration -- and the machine runs on ours
#                        only because ocljit.arch.OCLuaJITArchitecture is pinned.
case $OCLJ_NATIVE in
  luajit)   DLL_NAME=libjnlua52-windows-x86_64.dll    ;;
  additive) DLL_NAME=libjnluajit52-windows-x86_64.dll ;;
  stock)    DLL_NAME=libjnlua52-windows-x86_64.dll    ;;
  *) fail "OCLJ_NATIVE must be luajit, additive or stock, not '$OCLJ_NATIVE'";;
esac
if [ "$OCLJ_NATIVE" = "stock" ]; then
  OCLJ_KERNEL=stock
  say "    OCLJ_NATIVE=stock -- ocelot-brain's own PUC-Lua 5.2 native (the baseline a player runs today); kernel forced to stock"
fi
if [ "$OCLJ_NATIVE" = "additive" ]; then
  say "    OCLJ_NATIVE=additive -- our fourth LuaState beside OpenComputers' real PUC 5.2, both in one JVM"
  : "${OCLJ_CENSUS_ARCH:=luajit}"
else
  : "${OCLJ_CENSUS_ARCH:=52}"
fi
case $OCLJ_CENSUS_ARCH in
  52|53|luajit) ;;
  *) fail "OCLJ_CENSUS_ARCH must be 52, 53 or luajit, not '$OCLJ_CENSUS_ARCH'";;
esac
if [ "$OCLJ_CENSUS_ARCH" = luajit ] && [ "$OCLJ_NATIVE" != additive ]; then
  # Refused rather than allowed, because it reads as the stronger test and is
  # the weaker one: in dropin mode BOTH architectures are LuaJIT, so "it ran on
  # our architecture" would be true and would prove nothing about coexistence.
  fail "OCLJ_CENSUS_ARCH=luajit needs OCLJ_NATIVE=additive (the LuaJIT architecture is backed by libjnluajit52, which only the additive build produces)"
fi
: "${OCLJ_KERNEL:=watchdog}"
: "${OCLJ_LUAJIT_EXE:=}"
: "${OCLJ_CONF_EXTRA:=}"
# Scratch dir. Deliberately NOT $PWD-relative: this script is often invoked
# from a source checkout, and a default that lands classes, jars, a 78 KB
# generated config and a log inside the repository is a trap.
: "${OCLJ_WORK:=${TMPDIR:-/tmp}/ocljit-smoke}"
: "${OCLJ_LIBS:=$OCLJ_WORK/lib}"
: "${OCLJ_SRC:=$SELF_DIR/OcljSmoke.scala}"

# THE ADAPTER AND THE CLASS IT DRIVES, compiled on every run rather than only on
# additive ones.  They cost a second, and they sit on the critical path of the
# thing this harness exists to check; a dropin run that quietly stopped
# compiling them would hide the break until the next additive run, possibly
# weeks later with a dozen unrelated changes in between.
: "${OCLJ_ARCH_SRC:=$SELF_DIR/OcljArch.scala}"
: "${OCLJ_JAVA_SRC:=$SELF_DIR/../../src/main/java/li/cil/repack/com/naef/jnlua/LuaStateLuaJIT.java}"

# WHICH HARNESS RUNS.  Everything above this line -- the classpath, the
# generated ocelot-brain config, the ramScale pin, the native selection -- is
# the same work whatever we are booting, so a second driver script would be a
# second copy of it that drifts.  Instead the main class is a variable.
#
#   the default            OpenOS + the benchmark suite (OcljSmoke.scala)
#   OS census              test/native/census-os.sh, which sets these three
#                          to boot a third-party system (CensusOs.scala)
#
# OCLJ_MAIN_ARGS is deliberately UNQUOTED at the call site: the census runner
# takes several positional arguments and they must word-split.  Paths with
# spaces are therefore not supported there; the census trees do not have any.
: "${OCLJ_MAIN:=ocljit.smoke.Smoke}"
: "${OCLJ_MAIN_CLASSFILE:=ocljit/smoke/Smoke\$.class}"
: "${OCLJ_MAIN_ARGS:=}"
: "${OCLJ_JAVA:=${JAVA_HOME:-}}"
: "${OCLJ_TIMEOUT:=600}"
# Which directory the benchmarks come from.  Defaults to the shipped suite;
# point it at a scratch copy to try a variant without editing bench/oc/ or its
# references.txt, which run-standalone.sh checks for drift.
: "${OCLJ_BENCHDIR:=bench/oc}"

SCALA_VER=2.13.11
ASM_VER=9.5.0-scala-1

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
# In stock mode NONE of our artifacts are used: no forced path is written, the
# kernel is forced to stock, and the point of the arm is that no LuaJIT exists
# in the JVM at all.  Demanding our DLL there made the baseline depend on the
# thing it is the baseline FOR, and staging it planted our library in the one
# arm that must not have it.
if [ "$OCLJ_NATIVE" != stock ]; then
  [ -n "$OCLJ_LIBDIR" ] || fail "OCLJ_LIBDIR is unset (dir holding $DLL_NAME)"
  [ -f "$OCLJ_LIBDIR/$DLL_NAME" ] || fail "no $OCLJ_LIBDIR/$DLL_NAME -- run build-native.sh first"
fi
[ -n "$OCLJ_BRAIN" ] || fail "OCLJ_BRAIN is unset (git clone https://gitlab.com/cc-ru/ocelot/ocelot-brain.git)"
[ -f "$OCLJ_SRC" ] || fail "no harness source at $OCLJ_SRC"

if [ -n "$OCLJ_JAVA" ] && [ -x "$OCLJ_JAVA/bin/java" ]; then JAVA="$OCLJ_JAVA/bin/java"
elif command -v java >/dev/null 2>&1; then JAVA=java
else fail "no java: set OCLJ_JAVA to a JDK 11+ home"; fi
say "java    = $("$JAVA" -version 2>&1 | head -1)"
if [ "$OCLJ_NATIVE" != stock ]; then
  say "dll     = $OCLJ_LIBDIR/$DLL_NAME ($(wc -c < "$OCLJ_LIBDIR/$DLL_NAME") bytes)"
else
  say "dll     = <none: stock arm, ocelot-brain bundled PUC-Lua only>"
fi

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
# 2a. OUR Java class first -- the Scala adapter extends a LuaState subclass that
# lives in this repository and in no jar, so javac has to run before scalac.
[ -f "$OCLJ_JAVA_SRC" ] || fail "no $OCLJ_JAVA_SRC (regenerate it with native/jnlua/gen-luastate-subclass.py)"
if [ -n "$OCLJ_JAVA" ] && [ -x "$OCLJ_JAVA/bin/javac" ]; then JAVAC="$OCLJ_JAVA/bin/javac"
elif command -v javac >/dev/null 2>&1; then JAVAC=javac
else fail "no javac: OCLJ_JAVA must point at a JDK, not a JRE"; fi
"$JAVAC" -nowarn -cp "$CP" -d "$(w "$OCLJ_WORK/classes")" "$(w "$OCLJ_JAVA_SRC")" > "$OCLJ_WORK/javac.log" 2>&1
JC=$?
[ $JC -eq 0 ] || { head -20 "$OCLJ_WORK/javac.log"; fail "javac exit=$JC (log: $OCLJ_WORK/javac.log)"; }
# The nested class is asserted separately because its absence is not a compile
# error -- it is a System.load that throws NoClassDefFoundError with no Lua run
# yet, which is how it was found the first time.  jnlua.c JNI_OnLoad (:1741)
# references LuaStateLuaJIT$LuaDebug by name.
[ -f "$OCLJ_WORK/classes/li/cil/repack/com/naef/jnlua/"'LuaStateLuaJIT$LuaDebug.class' ] || fail "LuaStateLuaJIT compiled without its nested LuaDebug"
stamp "LuaStateLuaJIT compiled"

# 2b. the harness main PLUS the architecture adapter.  Our classes dir goes
# first on scalac's classpath, so the adapter resolves LuaStateLuaJIT from what
# javac just produced rather than from anything that might lurk in a jar.
SRC_CP="$(w "$OCLJ_WORK/classes")$SEP$CP"
"$JAVA" -cp "$SCALAC_CP" scala.tools.nsc.Main -classpath "$SRC_CP" -d "$(w "$OCLJ_WORK/classes")" "$(w "$OCLJ_SRC")" "$(w "$OCLJ_ARCH_SRC")" > "$OCLJ_WORK/scalac.log" 2>&1
SC=$?
grep -E '^.*error' "$OCLJ_WORK/scalac.log" | head -20
[ $SC -eq 0 ] || fail "scalac exit=$SC (log: $OCLJ_WORK/scalac.log)"
[ -f "$OCLJ_WORK/classes/$OCLJ_MAIN_CLASSFILE" ] || fail "harness did not compile (no $OCLJ_MAIN_CLASSFILE)"
[ -f "$OCLJ_WORK/classes/ocljit/arch/OCLuaJITArchitecture.class" ] || fail "the architecture adapter did not compile"
stamp "harness compiled"

# --------------------------------------------------------------- 3
say "=============== 3. generate the ocelot-brain config ==============="
# Settings.load parses the given file with NO fallback to the packaged
# reference, so the config has to be COMPLETE: start from ocelot-brain's own
# application.conf and append HOCON path assignments, which merge over it.
CONF="$OCLJ_WORK/ocljit.conf"
cp "$BRAIN_RES/application.conf" "$CONF" || fail "cannot copy application.conf"
# STAGE THE LIBRARY INSTEAD OF POINTING AT THE BUILD TREE.
#
# LuaStateFactory.init() ends with `catch { case t => ...; tmpLibFile.delete() }`,
# and under forceNativeLibPathFirst tmpLibFile IS the file that setting names.
# So any load failure -- a missing MSVC runtime, a half-written DLL, a JNI_OnLoad
# that throws -- DELETES the artifact build-native.sh just produced, and the next
# thing anyone sees is "no such file", which describes the cleanup rather than
# the fault.  Copying first means the deletion falls on a copy in the scratch
# dir and the build output is never at risk.
#
# THE STAGING DIRECTORY IS PER-VARIANT, AND IS EMPTIED FIRST.  build-native.sh
# deliberately builds the dropin and the additive into SEPARATE directories,
# because forceNativeLibPathFirst names one directory and every factory looks in
# it for its own filename -- so a directory holding both makes "Lua 5.2" resolve
# to the dropin at the very moment an additive run is trying to prove it
# coexists with the REAL PUC 5.2.  A single shared staging directory would have
# quietly undone that split the first time someone ran both variants with the
# default OCLJ_WORK, and the coexistence probe would have reported a collision
# that does not exist.
STAGE="$OCLJ_WORK/libdir-$OCLJ_NATIVE"
mkdir -p "$STAGE" || fail "cannot create $STAGE"
rm -f "$STAGE"/libjnlua*.dll "$STAGE"/libjnlua*.so "$STAGE"/libjnlua*.dylib
if [ "$OCLJ_NATIVE" != stock ]; then
  cp "$OCLJ_LIBDIR/$DLL_NAME" "$STAGE/$DLL_NAME" || fail "cannot stage $DLL_NAME"
  STAGED=$(ls "$STAGE" | wc -l)
  [ "$STAGED" = 1 ] || fail "staging dir $STAGE holds $STAGED files, expected exactly 1 -- forceNativeLibPathFirst would offer more than one VM"
fi
LIBDIR_ABS=$(wm "$(CDPATH= cd -- "$STAGE" && pwd)")
{
  echo ""
  echo "# ---- appended by smoke-test.sh ----"
  # Make ocelot-brain load OUR libjnlua52 instead of the stock one bundled in
  # OC-JNLua-Natives.  This is the ONLY hook the whole thing needs.
  # In stock mode this line is OMITTED, which is the whole mechanism:
  # LuaStateFactory then falls back to the bundled PUC-Lua 5.2 native.
  # Emitted for BOTH native-backed modes, and the reason they share one line is
  # that they select by FILENAME, not by path: the dropin is libjnlua52-* and the
  # additive is libjnluajit52-*, so pointing the same setting at libdir-additive
  # hands our library to the LuaJIT factory while the 5.2 factory misses and
  # falls back to the bundled PUC native.  Omitted only for stock.
  [ "$OCLJ_NATIVE" != "stock" ] && echo "opencomputers.debug.forceNativeLibPathFirst = \"$LIBDIR_ABS\""
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
  # WHICH DELIVERY MECHANISM, and it follows the ARCHITECTURE, not taste.
  #
  #   dropin/stock arm  drives OpenComputers' own NativeLua52Architecture, which
  #                     loads /assets/opencomputers/lua/machine.lua and has no
  #                     override, so the only way in is to shadow that path.
  #   additive arm      drives OCLuaJITArchitecture, whose initialize() swaps in
  #                     a kernel from OUR resource domain after super() runs.
  #                     That is the mechanism the shipped mod has to use, since
  #                     no mod can win a classpath race against OC for its own
  #                     resource path -- so the harness must exercise IT, not
  #                     the shadow.
  #
  # BOTH PATHS ARE CLEARED FIRST. A stale kernel left at the shadow path by an
  # earlier run would deliver the watchdog to the additive arm for free, and k0
  # would pass while the override did nothing at all -- a green run proving the
  # opposite of what it claims.
  rm -f "$OCLJ_WORK/classes/assets/opencomputers/lua/machine.lua"         "$OCLJ_WORK/classes/assets/ocluajit/lua/machine.lua"
  if [ "$OCLJ_NATIVE" = additive ]; then
    KDIR="$OCLJ_WORK/classes/assets/ocluajit/lua"
    KHOW="OUR resource domain -- OCLuaJITArchitecture.initialize() swaps it in"
  else
    KDIR="$OCLJ_WORK/classes/assets/opencomputers/lua"
    KHOW="shadows OC's on the classpath (this arm drives OC's own architecture)"
  fi
  mkdir -p "$KDIR" || fail "cannot create $KDIR"
  "$OCLJ_LUAJIT_EXE" "$SELF_DIR/../../native/kernel/patch-machine-lua.lua" \
    "$BRAIN_RES/assets/opencomputers/lua/machine.lua" "$KDIR/machine.lua" \
    || fail "the kernel patcher refused ocelot-brain's machine.lua (an anchor no longer matches)"
  say "    kernel  = WATCHDOG variant at $KDIR/machine.lua"
  say "              $KHOW"
else
  # Make sure a stale patched kernel from a previous watchdog run cannot
  # linger in the shared classes dir and silently turn a stock run into one.
  rm -f "$OCLJ_WORK/classes/assets/opencomputers/lua/machine.lua"         "$OCLJ_WORK/classes/assets/ocluajit/lua/machine.lua"
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
  timeout -k 10 "$OCLJ_TIMEOUT" "$JAVA" -Docljit.jit="$OCLJ_JIT" -Docljit.kernel="$OCLJ_KERNEL" -Docljit.native="$OCLJ_NATIVE" -Docljit.benchdir="$OCLJ_BENCHDIR" -Docljit.gcstepmul="$OCLJ_GCSTEPMUL" -Docljit.gcpause="$OCLJ_GCPAUSE" -Docljit.censusarch="$OCLJ_CENSUS_ARCH" -Docljit.censusram="$OCLJ_CENSUS_RAM" -cp "$RUNCP" $OCLJ_MAIN "$CONF_ARG" $OCLJ_MAIN_ARGS > "$LOG" 2>&1
else
  "$JAVA" -Docljit.jit="$OCLJ_JIT" -Docljit.kernel="$OCLJ_KERNEL" -Docljit.native="$OCLJ_NATIVE" -Docljit.benchdir="$OCLJ_BENCHDIR" -Docljit.gcstepmul="$OCLJ_GCSTEPMUL" -Docljit.gcpause="$OCLJ_GCPAUSE" -Docljit.censusarch="$OCLJ_CENSUS_ARCH" -Docljit.censusram="$OCLJ_CENSUS_RAM" -cp "$RUNCP" $OCLJ_MAIN "$CONF_ARG" $OCLJ_MAIN_ARGS > "$LOG" 2>&1
fi
RC=$?
cat "$LOG"

# --------------------------------------------------------------- 5
say "=============== 5. verdict ==============="
# GATES PER HARNESS, because the gates below are assertions about what the MAIN
# printed, and the mains print different things.  They used to be hard-coded to
# OcljSmoke, so every census run -- which emits CENSUS| lines and no SMOKE|
# line and no GUARD line -- ended in "SMOKE FAIL" no matter how well it went.
# A verdict that is always wrong for a whole class of runs is worse than none:
# it is read once, disbelieved, and then ignored on the run where it was right.
: "${OCLJ_VERDICT:=smoke}"
case $OCLJ_VERDICT in
  smoke|census) ;;
  # Validated because it SELECTS A GATE SET.  Any unrecognised value silently
  # chose the OpenOS gates, which is the always-wrong verdict this block exists
  # to stop -- and it would have chosen them for a census run, scoring it FAIL.
  *) fail "OCLJ_VERDICT must be smoke or census, not '$OCLJ_VERDICT'";;
esac

# WHICH VM THIS RUN IS SUPPOSED TO HAVE USED.  Not the same as OCLJ_NATIVE: the
# census 53 arm runs the stock PUC 5.3 native DELIBERATELY, as the baseline that
# separates "this OS cannot run on our VM" from "this OS cannot run on a
# 5.2-class VM at all", and it does so with OCLJ_NATIVE at its luajit default.
# Keying the marker gate on OCLJ_NATIVE alone made that documented arm
# unpassable.  Every gate below is TWO-SIDED: when we expect LuaJIT we demand
# the LuaJIT marker, and when we expect PUC we demand a marker that is NOT
# LuaJIT.  A one-sided gate cannot catch a baseline that silently ran on us,
# which is the direction that would quietly invalidate a comparison.
EXPECT_VM=luajit
[ "$OCLJ_NATIVE" = stock ] && EXPECT_VM=puc
[ "$OCLJ_VERDICT" = census ] && [ "$OCLJ_CENSUS_ARCH" = 53 ] && EXPECT_VM=puc

OK=1
[ $RC -eq 0 ] || { echo "  java exit=$RC (124 = timed out)"; OK=0; }

if [ "$OCLJ_VERDICT" = census ]; then
  grep -q "^CENSUS| VERDICT:" "$LOG" || { echo "  the census did not report a verdict at all"; OK=0; }
  grep -q "^CENSUS| lastError      = <none>" "$LOG" || {
    echo "  the machine ended with an error:"; grep "^CENSUS| lastError" "$LOG" | sed 's/^/    /'; OK=0; }
  grep -q "^CENSUS| VERDICT: no panic" "$LOG" || { echo "  panic text on screen"; OK=0; }

  # LIVENESS.  Every gate above is satisfied by a machine that never ran: no
  # verdict error, no panic text, lastError none.  The verdict line claims the
  # system "ran to the tick limit", so check that rather than assert it.
  TICKLINE=$(grep "^CENSUS| ticks run" "$LOG" | head -1)
  RAN=$(printf '%s' "$TICKLINE" | awk '{print $5}')
  TOT=$(printf '%s' "$TICKLINE" | awk '{print $7}')
  if [ -z "$RAN" ] || [ -z "$TOT" ]; then
    echo "  no tick count in the log: nothing establishes the machine ever ran"; OK=0
  elif [ "$RAN" = 0 ]; then
    echo "  the machine ran 0 ticks -- it never started"; OK=0
  elif [ "$RAN" != "$TOT" ]; then
    echo "  the machine stopped early: $RAN of $TOT ticks"; OK=0
  fi

  if [ "$EXPECT_VM" = luajit ]; then
    grep -q "^CENSUS| native marker  = luajit/" "$LOG" || {
      echo "  no LuaJIT marker: this run did not prove which VM it used, and"
      echo "  ocelot-brain substitutes LuaJ or its own PUC native when ours fails"
      echo "  to load -- so every number above would describe a different VM."
      OK=0; }
  else
    grep -q "^CENSUS| native marker  =" "$LOG" || { echo "  no native marker line at all"; OK=0; }
    grep -q "^CENSUS| native marker  = luajit/" "$LOG" && {
      echo "  this is a BASELINE arm (expected PUC) but it ran on OUR LuaJIT native --"
      echo "  it cannot serve as a control for anything."
      OK=0; }
  fi

  # The pin is load-bearing and CensusOs shouts when it slips; treat that as fatal
  # rather than as a line in the log nobody reads.
  grep -q "^CENSUS| !! architecture is" "$LOG" && {
    echo "  the architecture pin did not take:"; grep "^CENSUS| !! architecture" "$LOG" | sed 's/^/    /'; OK=0; }

  # COEXISTENCE, asserted POSITIVELY.  Checking only for the shouted failure
  # line let the probe be absent entirely -- and its "OpenComputers 5.2 native
  # did not load" branch shouts nothing, because from CensusOs side that is a
  # report, not an error.  In the additive arm the probe IS the result, so
  # demand that it ran and said what it must say.
  if [ "$OCLJ_CENSUS_ARCH" = luajit ]; then
    grep -q "^CENSUS| coexistence    = OpenComputers' own LuaState reports <stock PUC>" "$LOG" || {
      echo "  the coexistence probe did not report a separate PUC state:"
      grep "^CENSUS| coexistence" "$LOG" | sed 's/^/    /'
      echo "  (absent, or OpenComputers' own LuaState answered with OUR marker)"
      OK=0; }
  fi
  grep -q "^CENSUS| !! OpenComputers" "$LOG" && {
    echo "  the coexistence probe failed:"; grep "^CENSUS| !!" "$LOG" | sed 's/^/    /'; OK=0; }
else
  # The diagnostic deliberately does NOT contain the string it is reporting the
  # absence of.  It used to read "no 'VERDICT: PASS' line", which meant a caller
  # scoring a batch of runs with `grep -q 'VERDICT: PASS'` scored every FAILURE
  # as a pass.  That is not hypothetical: it produced a confident "3/3 at
  # ramScale 1.8" here that a second measurement contradicted, and the truth was
  # 2/10.  Anything scanning these logs should match the harness's own line,
  # anchored: grep -qx 'SMOKE| VERDICT: PASS'.
  grep -q "^SMOKE| VERDICT: PASS" "$LOG" || { echo "  the harness did not report a passing verdict"; OK=0; }
  # TWO-SIDED, like the census gate and for the same reason.  This was
  # unconditional, so every OCLJ_NATIVE=stock run scored SMOKE FAIL however well
  # it went -- while OcljSmoke's own in-VM guard asserted the stock fingerprint
  # correctly and printed VERDICT: PASS. The shell disagreed with the harness on
  # a whole arm.
  grep -q "GUARD VM FINGERPRINT:" "$LOG" || { echo "  no VM fingerprint line: the run did not prove which VM it used"; OK=0; }
  if [ "$EXPECT_VM" = luajit ]; then
    grep -q "GUARD VM FINGERPRINT: native=luajit/" "$LOG" || {
      echo "  no LuaJIT fingerprint: the run did not prove which VM it used --"
      echo "  ocelot-brain substitutes LuaJ when the native fails to load, and LuaJ"
      echo "  has no Eris, so every persistence assertion would pass vacuously."
      OK=0; }
  else
    grep -q "GUARD VM FINGERPRINT: native=luajit/" "$LOG" && {
      echo "  OCLJ_NATIVE=stock but the fingerprint says LuaJIT: this is not a baseline."
      OK=0; }
  fi
  grep -c "MILESTONE .*: FAIL" "$LOG" | grep -qv '^0$' && { echo "  failing milestones:"; grep "MILESTONE .*: FAIL" "$LOG" | sed 's/^/    /'; OK=0; }
fi

stamp "log: $LOG"
if [ $OK -eq 1 ]; then
  if [ "$OCLJ_VERDICT" = census ]; then
    echo "CENSUS PASS -- the system ran to the tick limit on the pinned architecture, without error."
  elif [ "$OCLJ_ALLOW_BYTECODE" = false ]; then
    # NAME THE VM THAT ACTUALLY RAN.  This line was hard-coded to "on LuaJIT",
    # which was simply false for the stock arm -- and unnoticeable for as long as
    # the stock arm could never reach it.  A pass message that asserts something
    # the run did not check is the same defect as a gate that cannot fail.
    if [ "$EXPECT_VM" = luajit ]; then
      echo "SMOKE PASS -- OpenOS booted on LuaJIT, persisted, and resumed."
    else
      echo "SMOKE PASS (BASELINE) -- OpenOS booted on ocelot-brain's stock PUC-Lua 5.2,"
      echo "  persisted, and resumed. No LuaJIT was involved; this is the control."
    fi
  else
    echo "SMOKE PASS (NEGATIVE CONTROL, allowBytecode=$OCLJ_ALLOW_BYTECODE) --"
    echo "  the sandbox gate was expected to be OPEN and was.  This run shows"
    echo "  the d2 probe reads the setting; it is NOT a security result."
  fi
  exit 0
fi
if [ "$OCLJ_VERDICT" = census ]; then echo "CENSUS FAIL"; else echo "SMOKE FAIL"; fi
exit 1
