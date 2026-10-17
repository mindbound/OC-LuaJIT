#!/bin/sh
# final-r3.sh -- round 3's FINAL Windows chain, after the hint and the review's fixes: wait for the first
# build's campaign to finish (it runs build/native's luajit.exe), then build-r3.sh (dropin, additive) into
# logs/builds-2; the object diff against the first build (logs/builds/natives.md5: only lj_meta.o and
# lib_jit.o may differ among the LuaJIT objects); freeze the natives at claude-tmp/oclj/new-r3f-<md5>;
# native-tests-r3.sh into logs/suite-native-2; the seven harness arms (chain-r3.sh, tag f).
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
R=$REPO/bench/runs/2026-10-17-bitop
S=$R/scripts
O=/c/Users/astro/claude-tmp/oclj
L=$R/logs/final-chain.txt
[ -e "$L" ] && { echo "REFUSING: $L exists"; exit 99; }
echo "final-r3 started $(date -u +%H:%M:%S)" > "$L"
while [ ! -e "$R/logs/campaign/ALL.done" ]; do sleep 15; done
echo "campaign done $(date -u +%H:%M:%S)" >> "$L"
cd "$REPO" || exit 98
sh "$S/build-r3.sh" "$R/logs/builds-2" > "$O/runs/build-r3-2.out" 2>&1
cat "$R/logs/builds-2/summary.txt" >> "$L"
grep -q 'build-dropin exit=0' "$R/logs/builds-2/summary.txt" && grep -q 'build-additive exit=0' "$R/logs/builds-2/summary.txt" \
  || { echo "BUILD FAILED; stopping" >> "$L"; exit 1; }
# Object diff against the first build.
LJS=build/native/luajit-windows-x86_64/src
grep -E 'luajit-windows-x86_64/src/(host/)?[a-z_0-9]+\.o$' "$R/logs/builds/natives.md5" | sed 's#\*##' | sort -k2 > "$R/logs/builds-2/objects-first.md5"
grep -E 'luajit-windows-x86_64/src/(host/)?[a-z_0-9]+\.o$' "$R/logs/builds-2/natives.md5" | sed 's#\*##' | sort -k2 > "$R/logs/builds-2/objects-final.md5"
join -1 2 -2 2 "$R/logs/builds-2/objects-first.md5" "$R/logs/builds-2/objects-final.md5" | awk '$2 != $3 { print $1 }' > "$R/logs/builds-2/objects-changed.txt"
echo "objects changed against the first build: $(tr '\n' ' ' < "$R/logs/builds-2/objects-changed.txt")" >> "$L"
echo "objects compared: $(wc -l < "$R/logs/builds-2/objects-final.md5") final, $(wc -l < "$R/logs/builds-2/objects-first.md5") first" >> "$L"
M=$(md5sum build/native/libdir-additive/libjnluajit52-windows-x86_64.dll | cut -c1-8)
F=$O/new-r3f-$M
[ -e "$F" ] && { echo "FREEZE DIR $F EXISTS; stopping" >> "$L"; exit 1; }
mkdir -p "$F/libdir" "$F/libdir-additive"
cp build/native/libdir/*.dll "$F/libdir/"; cp build/native/libdir-additive/*.dll "$F/libdir-additive/"
md5sum "$F"/*/* >> "$L"
sh "$S/native-tests-r3.sh" "$R/logs/suite-native-2" > "$O/runs/native-tests-r3-2.out" 2>&1
cat "$R/logs/suite-native-2/summary.txt" >> "$L"
sh "$S/chain-r3.sh" f "$F" > "$O/runs/chain-r3-f.out" 2>&1
grep -E 'exit=' "$O/runs/chain-r3-f.txt" >> "$L"
echo "final-r3 finished $(date -u +%H:%M:%S)" >> "$L"
touch "$R/logs/final-chain.done"
