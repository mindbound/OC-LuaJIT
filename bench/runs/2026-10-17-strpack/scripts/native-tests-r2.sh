#!/bin/sh
# native-tests-r2.sh <outdir> -- round 2 on Windows, against build/native (the additive build last):
# every native suite, the pack suites (run-pack, the default fuzz run, the full negctl-pack sweep), the
# serializer suite and its negctl, then negative-control.sh.  One log and one rc per step.
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
step ser-test make -C serializer CC=gcc test
step ser-negctl make -C serializer CC=gcc negctl
step negctl-pack sh test/native/negctl-pack.sh
step negctl sh test/native/negative-control.sh
echo done > "$OUT/ALL.done"
