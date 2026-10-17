#!/bin/sh
# campaign-r2.sh <outdir> -- round 2's differential fuzz campaign against PUC 5.3.6 (Windows), on
# build/native's luajit.exe: 50 seeds x 100 000 (default profile), 5 x 300 (long, strings to 16 MiB), then
# the two documenting profiles, coerce and limits, each expected to exit 1 with exactly its one class.
set -u
OUT="$1"
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT" || exit 98
REPO=/c/Users/astro/Downloads/OC-LuaJIT
cd "$REPO" || exit 97
md5sum build/native/luajit-windows-x86_64/src/luajit.exe bench/vendor/lua-5.3.6/src/lua.exe test/native/pack/*.lua test/native/run-packfuzz.sh > "$OUT/inputs.md5"
run() {
  # run <name> <env...>
  n=$1; shift
  date -u +%H:%M:%S > "$OUT/$n.start"
  env "$@" OCLJ_PACKFUZZ_OUT="$REPO/build/native/packfuzz-campaign-$n" sh test/native/run-packfuzz.sh > "$OUT/$n.log" 2>&1
  echo "$?" > "$OUT/$n.rc"
  date -u +%H:%M:%S > "$OUT/$n.end"
}
run default50 OCLJ_PACKFUZZ_SEED=1000 OCLJ_PACKFUZZ_SEEDS=50 OCLJ_PACKFUZZ_CASES=100000
run long5 OCLJ_PACKFUZZ_PROFILE=long OCLJ_PACKFUZZ_SEED=2000 OCLJ_PACKFUZZ_SEEDS=5 OCLJ_PACKFUZZ_CASES=300
run coerce2 OCLJ_PACKFUZZ_PROFILE=coerce OCLJ_PACKFUZZ_SEED=3000 OCLJ_PACKFUZZ_SEEDS=2 OCLJ_PACKFUZZ_CASES=20000
run limits1 OCLJ_PACKFUZZ_PROFILE=limits OCLJ_PACKFUZZ_SEED=4000 OCLJ_PACKFUZZ_SEEDS=1 OCLJ_PACKFUZZ_CASES=2000
echo done > "$OUT/ALL.done"
