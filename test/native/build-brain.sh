#!/bin/sh
# =====================================================================
# build-brain.sh -- compile ocelot-brain WITHOUT sbt, for smoke-test.sh.
#
# smoke-test.sh needs $OCLJ_BRAIN compiled, and tells you to run `sbt compile`.
# On this box that does not work, for two reasons that are worth writing down
# because neither is obvious and both cost a debugging session:
#
#   1. ocelot-brain 0.24.2 pins sbt.version = 2.0.7, and sbt 2.x requires
#      JDK 11 or newer.  The JDK on PATH here is 8.
#   2. Building it under the JDK 17 that IS installed would emit class files
#      the JDK 8 that runs the smoke test cannot load -- and switching the
#      smoke test to JDK 17 would change the JVM out from under the Phase 0
#      numbers we are comparing against.
#
# So this compiles the sources directly with the Scala 2.13.11 compiler on
# JDK 8, which is exactly what `sbt compile` would have produced for our
# purposes.  It is viable because ocelot-brain is a plain library: no
# sbt plugins (there is no project/plugins.sbt), no sourceGenerators, no
# BuildInfo -- its version is hardcoded in Ocelot.scala, which build.sbt's own
# comment tells you to keep in sync by hand.  The `assembly*` settings in
# build.sbt are for packaging a fat jar and are irrelevant to compiling.
#
# The dependency list below is build.sbt's, and it is identical to the one
# smoke-test.sh already downloads -- the jars land in the same $OCLJ_LIBS, so
# whichever script runs first pays for them once.
#
# usage: sh build-brain.sh
# env:   OCLJ_BRAIN   ocelot-brain checkout                        [required]
#        OCLJ_LIBS    jar cache        [default $OCLJ_WORK/lib, as smoke-test]
#        OCLJ_WORK    scratch dir                 [default $TMPDIR/ocljit-smoke]
#
# On success it prints the line to feed smoke-test.sh:
#     export OCLJ_BRAIN_CP=<classes dir>
# =====================================================================
set -e

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

: "${OCLJ_BRAIN:=}"
: "${OCLJ_WORK:=${TMPDIR:-/tmp}/ocljit-smoke}"
: "${OCLJ_LIBS:=$OCLJ_WORK/lib}"
: "${OCLJ_JAVA:=${JAVA_HOME:-}}"

SCALA_VER=2.13.11
ASM_VER=9.5.0-scala-1
M=https://repo1.maven.org/maven2

fail() { echo "BRAIN FAIL: $*" >&2; exit 1; }
say()  { echo "[brain] $*"; }

[ -n "$OCLJ_BRAIN" ] || fail "OCLJ_BRAIN is unset (git clone https://gitlab.com/cc-ru/ocelot/ocelot-brain.git)"
[ -d "$OCLJ_BRAIN/src/main/scala" ] || fail "$OCLJ_BRAIN does not look like ocelot-brain (no src/main/scala)"

if [ -n "$OCLJ_JAVA" ]; then JAVA="$OCLJ_JAVA/bin/java"; JAVAC="$OCLJ_JAVA/bin/javac"
else JAVA=java; JAVAC=javac; fi
command -v "$JAVA" >/dev/null 2>&1 || [ -x "$JAVA" ] || fail "no java (set OCLJ_JAVA or JAVA_HOME)"

# Windows/JVM classpath plumbing, same convention as smoke-test.sh.
if command -v cygpath >/dev/null 2>&1; then
  SEP=';'; w() { cygpath -w "$1"; }
else
  SEP=':'; w() { printf '%s' "$1"; }
fi

mkdir -p "$OCLJ_LIBS" || fail "cannot create $OCLJ_LIBS"

get() {
  f="$OCLJ_LIBS/$(basename "$1")"
  [ -s "$f" ] && return 0
  say "fetching $(basename "$1")"
  curl -sSL --max-time 180 -o "$f" "$1" || fail "download failed: $1"
  [ -s "$f" ] || fail "empty download: $1"
}

say "=============== 1. dependencies ==============="
# scala first: the compiler itself, plus the library the output links against.
get $M/org/scala-lang/scala-library/$SCALA_VER/scala-library-$SCALA_VER.jar
get $M/org/scala-lang/scala-compiler/$SCALA_VER/scala-compiler-$SCALA_VER.jar
get $M/org/scala-lang/scala-reflect/$SCALA_VER/scala-reflect-$SCALA_VER.jar
get $M/org/scala-lang/modules/scala-asm/$ASM_VER/scala-asm-$ASM_VER.jar
# ocelot-brain's own, from build.sbt.
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
say "jars ready ($(ls "$OCLJ_LIBS"/*.jar | wc -l) files in $OCLJ_LIBS)"

# The compile classpath is every jar EXCEPT the compiler's own -- those go on
# the JVM classpath that runs scalac, not on the classpath it compiles against.
DEPS=""
for j in "$OCLJ_LIBS"/*.jar; do
  case "$(basename "$j")" in scala-compiler*|scala-reflect*|scala-asm*) continue;; esac
  DEPS="$DEPS$SEP$(w "$j")"
done
DEPS=${DEPS#"$SEP"}
SCALAC_CP="$(w "$OCLJ_LIBS/scala-compiler-$SCALA_VER.jar")$SEP$(w "$OCLJ_LIBS/scala-reflect-$SCALA_VER.jar")$SEP$(w "$OCLJ_LIBS/scala-library-$SCALA_VER.jar")$SEP$(w "$OCLJ_LIBS/scala-asm-$ASM_VER.jar")"

OUT="$OCLJ_BRAIN/target/classes"
mkdir -p "$OUT" || fail "cannot create $OUT"

# The source list goes in a file: 240 paths blow past the Windows command-line
# limit, and scalac/javac both accept @argfile.
ARGS="$OCLJ_WORK/brain-sources.txt"
: > "$ARGS"
find "$OCLJ_BRAIN/src/main/scala" -name '*.scala' | while read -r f; do w "$f" >> "$ARGS"; done
JARGS="$OCLJ_WORK/brain-java-sources.txt"
: > "$JARGS"
find "$OCLJ_BRAIN/src/main" -name '*.java' | while read -r f; do w "$f" >> "$JARGS"; done
NS=$(grep -c . "$ARGS" || true)
NJ=$(grep -c . "$JARGS" || true)

say "=============== 2. scalac ($NS scala, $NJ java for signatures) ==============="
# JOINT COMPILATION.  The .java files are handed to scalac as well as to javac:
# scalac only PARSES them, for the signatures the Scala code refers to, and
# emits no class files for them.  javac then compiles them for real, against
# scalac's output.  Getting this order wrong is the classic mixed-project
# failure -- javac first cannot see the Scala classes, scalac alone leaves the
# Java ones missing at runtime.
"$JAVA" -Xmx2g -cp "$SCALAC_CP" scala.tools.nsc.Main \
  -classpath "$DEPS" -d "$(w "$OUT")" "@$(w "$ARGS")" "@$(w "$JARGS")" \
  > "$OCLJ_WORK/brain-scalac.log" 2>&1 || {
    grep -E 'error' "$OCLJ_WORK/brain-scalac.log" | head -20
    fail "scalac failed (log: $OCLJ_WORK/brain-scalac.log)"
  }
grep -E '^warning|warnings? found' "$OCLJ_WORK/brain-scalac.log" | tail -2 || true
say "scala compiled"

if [ "$NJ" -gt 0 ]; then
  say "=============== 3. javac ($NJ files) ==============="
  "$JAVAC" -nowarn -cp "$(w "$OUT")$SEP$DEPS" -d "$(w "$OUT")" "@$(w "$JARGS")" \
    > "$OCLJ_WORK/brain-javac.log" 2>&1 || {
      head -20 "$OCLJ_WORK/brain-javac.log"
      fail "javac failed (log: $OCLJ_WORK/brain-javac.log)"
    }
  say "java compiled"
fi

# Sanity: the class the harness actually instantiates must exist.  A compile
# that "succeeded" but produced no NativeLua52Architecture would fail much
# later and much more confusingly, inside the smoke test.
PROBE=totoro/ocelot/brain/entity/machine/luac/NativeLua52Architecture.class
[ -f "$OUT/$PROBE" ] || fail "compiled, but $PROBE is missing from $OUT"
say "=============== done ==============="
say "classes: $(find "$OUT" -name '*.class' | wc -l) in $OUT"
echo
echo "export OCLJ_BRAIN_CP=\"$OUT\""
