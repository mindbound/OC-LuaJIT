#!/bin/sh
# campaign-r3.sh <outdir> -- round 3's campaigns on build/native's Windows luajit.exe, against -joff and PUC
# Lua 5.3.6 (Windows):
#   gen20   the generator, seeds 101-120 x 2000 loops (plain mix), 5 option sets x 2 closure modes + PUC twin
#   phi20   the generator, seeds 201-220 x 2000 loops, OCLJ_BITJIT_GENMODE=phi (carried, bounded values)
#   trec    t_rec.lua, 400 recurrences, seeds 101-120 plain and 121-140 with "counts", under the default
#           options, -O3 -Ohotloop=1 and -Omaxside=0, each against -joff (CR stripped)
#   fuzz50  run-bitfuzz.sh, seeds 11-60 x 20000 cases x 16 tuples, every seed's files kept (no prune)
# Every results directory is fresh; nothing is deleted.
set -u
OUT="$1"
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT" || exit 98
REPO=/c/Users/astro/Downloads/OC-LuaJIT
cd "$REPO" || exit 97
B=$REPO/build/native
# Result directories carry the campaign's tag (its outdir's name); the first campaign, logs/campaign,
# wrote the untagged names bitjit-campaign-gen20, bitjit-campaign-phi20, trec-campaign, bitfuzz-campaign-50.
TAG=$(basename "$OUT")
LJD=$B/luajit-windows-x86_64/src
md5sum "$LJD/luajit.exe" bench/vendor/lua-5.3.6/src/lua.exe test/native/bitop/*.lua test/native/run-bitjit.sh \
  test/native/run-bitfuzz.sh > "$OUT/inputs.md5"
md5sum "$LJD"/*.o > "$OUT/objects.md5"
run() {
  # run <name> <env...>
  n=$1; shift
  date -u +%H:%M:%S > "$OUT/$n.start"
  env "$@" > "$OUT/$n.log" 2>&1
  echo "$?" > "$OUT/$n.rc"
  date -u +%H:%M:%S > "$OUT/$n.end"
}
run gen20 OCLJ_BITJIT_PARTS=gen OCLJ_BITJIT_SEED=101 OCLJ_BITJIT_SEEDS=20 \
  OCLJ_BITJIT_OUT="$B/bitjit-$TAG-gen20" sh test/native/run-bitjit.sh
run phi20 OCLJ_BITJIT_PARTS=gen OCLJ_BITJIT_GENMODE=phi OCLJ_BITJIT_SEED=201 OCLJ_BITJIT_SEEDS=20 \
  OCLJ_BITJIT_OUT="$B/bitjit-$TAG-phi20" sh test/native/run-bitjit.sh
# t_rec over 40 seeds.
T=$B/trec-$TAG
mkdir "$T" || exit 96
date -u +%H:%M:%S > "$OUT/trec.start"
bad=0
for s in $(seq 101 140); do
  md=; [ "$s" -gt 120 ] && md=counts
  ( cd "$LJD" && ./luajit.exe -joff "$REPO/test/native/bitop/t_rec.lua" 400 "$s" $md ) 2> "$T/s$s-joff.err" | tr -d '\r' > "$T/s$s-joff.txt"
  nl=$(grep -c . "$T/s$s-joff.txt")
  line="seed $s${md:+ ($md)}: joff lines=$nl raised=$(grep -o 'ERR@' "$T/s$s-joff.txt" | wc -l)"
  [ "$nl" -eq 400 ] || { line="$line BADCOUNT"; bad=1; }
  for o in jon hl1 ms0; do
    case $o in jon) a= ;; hl1) a="-O3 -Ohotloop=1" ;; ms0) a="-Omaxside=0" ;; esac
    ( cd "$LJD" && ./luajit.exe $a "$REPO/test/native/bitop/t_rec.lua" 400 "$s" $md ) 2> "$T/s$s-$o.err" | tr -d '\r' > "$T/s$s-$o.txt"
    d=$(diff "$T/s$s-joff.txt" "$T/s$s-$o.txt" | grep -c '^<')
    line="$line $o=$d"
    [ "$d" -eq 0 ] || bad=1
  done
  echo "$line" >> "$OUT/trec.log"
done
echo "$bad" > "$OUT/trec.rc"
date -u +%H:%M:%S > "$OUT/trec.end"
run fuzz50 OCLJ_BITFUZZ_SEED=11 OCLJ_BITFUZZ_SEEDS=50 OCLJ_BITFUZZ_CASES=20000 \
  OCLJ_BITFUZZ_OUT="$B/bitfuzz-$TAG-50" sh test/native/run-bitfuzz.sh
for f in "$OUT"/*.rc; do echo "$(basename "$f" .rc) $(cat "$f")"; done > "$OUT/summary.txt"
echo done > "$OUT/ALL.done"
