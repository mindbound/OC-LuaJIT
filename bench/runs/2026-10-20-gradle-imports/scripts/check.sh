#!/bin/sh
# check.sh <outdir> -- gradle's verifyModAssets, the real task, on: the AlmaLinux 8 trial .so built with round 3's
# link flags (six unversioned pthread imports; must be REFUSED, and HEAD's build.gradle.kts must ACCEPT it --
# the fail-first), the release .so (must be ACCEPTED), and the default nativesDir build/native/dist (must be
# ACCEPTED); then ./gradlew build.  Each case is a fresh natives dir under <outdir>/cases; nothing under
# build/native is written.
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
OUT=$1
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT/cases/trial" "$OUT/cases/release" || exit 98
cd "$REPO" || exit 97
cp /c/Users/astro/claude-tmp/oclj/glibc/impl-gradle/src/trial.so "$OUT/cases/trial/libjnluajit52-linux-x86_64.so"
cp build/native/dist/libjnluajit52-linux-x86_64.so "$OUT/cases/release/libjnluajit52-linux-x86_64.so"
md5sum "$OUT"/cases/*/*.so build/native/dist/* build.gradle.kts > "$OUT/inputs.md5"
git show HEAD:build.gradle.kts | md5sum >> "$OUT/inputs.md5"
run() {
  # run <name> <args...>
  n=$1; shift
  ./gradlew --offline --no-daemon verifyModAssets "$@" > "$OUT/$n.log" 2>&1
  echo "$n rc=$? $(grep -hE '^> OC-LuaJIT|imports, every|needs at most' "$OUT/$n.log" | head -2 | cut -c1-260 | tr '\n' ' ')" >> "$OUT/summary.txt"
}
run trial -Pocljit.nativesDir="$(cygpath -m "$OUT/cases/trial")"
run release -Pocljit.nativesDir="$(cygpath -m "$OUT/cases/release")"
run dist
# The fail-first: HEAD's build.gradle.kts on the trial .so.  The new file is saved, HEAD's is put in place for
# this one run, and the new one is restored and checked by md5 (nothing else uses the file meanwhile).
cp build.gradle.kts "$OUT/build.gradle.kts.new"
git show HEAD:build.gradle.kts > build.gradle.kts
./gradlew --offline --no-daemon verifyModAssets -Pocljit.nativesDir="$(cygpath -m "$OUT/cases/trial")" > "$OUT/head-trial.log" 2>&1
echo "head-trial rc=$? $(grep -hE '^> OC-LuaJIT|needs at most|BUILD' "$OUT/head-trial.log" | head -3 | cut -c1-200 | tr '\n' ' ')" >> "$OUT/summary.txt"
cp "$OUT/build.gradle.kts.new" build.gradle.kts
cmp -s build.gradle.kts "$OUT/build.gradle.kts.new" && echo "restored build.gradle.kts: $(md5sum < build.gradle.kts | cut -c1-8)" >> "$OUT/summary.txt" || { echo RESTORE FAILED >> "$OUT/summary.txt"; exit 1; }
./gradlew build > "$OUT/build.log" 2>&1
echo "build rc=$?" >> "$OUT/summary.txt"
md5sum build/libs/ocluajit-$(git rev-parse --short=7 HEAD)-*.jar >> "$OUT/summary.txt" 2>/dev/null
cat "$OUT/summary.txt"
