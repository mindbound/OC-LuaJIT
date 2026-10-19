#!/bin/sh
# native-tests-r3.sh <outdir> -- round 3 on Windows, against build/native (the additive build last): every
# native suite, the pack suites, the round-3 suites (run-bitop, run-bitjit and run-bitfuzz at their defaults),
# the serializer suite and its negctl (after the for-in fixture's regeneration), then the three negative
# controls: negctl-bitop (26 arms), negctl-pack (28 arms) and negative-control.sh.  One log and one rc per step.
set -u
OUT="$1"
[ -e "$OUT" ] && { echo "REFUSING: $OUT already exists"; exit 99; }
mkdir -p "$OUT" || exit 98
export PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include"
export OCLJ_JNLUA=C:/Users/astro/Downloads/OC-JNLua
REPO=/c/Users/astro/Downloads/OC-LuaJIT
cd "$REPO" || exit 97
step() {
  # step <name> <command...>
  n=$1; shift
  date -u +%H:%M:%S > "$OUT/$n.start"
  "$@" > "$OUT/$n.log" 2>&1
  echo "$?" > "$OUT/$n.rc"
  date -u +%H:%M:%S > "$OUT/$n.end"
}
step shim sh test/native/run.sh
step security sh test/native/run-security.sh
step race sh test/native/run-race.sh
step mem sh test/native/run-mem.sh
step vgc sh test/native/run-vgc.sh
step wd sh test/native/run-wd.sh
step penalty sh test/native/run-penalty.sh
step run-pack sh test/native/run-pack.sh
step run-packfuzz sh test/native/run-packfuzz.sh
step run-bitop sh test/native/run-bitop.sh
step run-bitjit sh test/native/run-bitjit.sh
step run-bitfuzz sh test/native/run-bitfuzz.sh
step ser-test make -C serializer CC=gcc test
step ser-negctl make -C serializer CC=gcc negctl
step negctl-bitop sh test/native/negctl-bitop.sh
step negctl-pack sh test/native/negctl-pack.sh
step negctl sh test/native/negative-control.sh
for f in "$OUT"/*.rc; do echo "$(basename "$f" .rc) $(cat "$f")"; done > "$OUT/summary.txt"
echo done > "$OUT/ALL.done"
