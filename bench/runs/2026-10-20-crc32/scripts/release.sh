#!/bin/sh
# release.sh <fresh outdir> <final-check outdir> -- the CRC32 follow-up's release, for the MAIN SESSION,
# after final-check.sh passed (FAIL 0 in its ALL.done):
#   1. Windows: build-native.sh into build/native, dropin then additive (the glibc round's build-win.sh,
#      read from its archive), then AlmaLinux 8 with OCLJ_GLIBC_MAX=2.28 into build/native (its
#      build-linux.sh), as the glibc round made the release;
#   2. every LuaJIT object (77) and ours (3) of build/native's additive trees equal the final check's
#      fresh builds (<final>/b/win, <final>/alma/b), byte for byte; the fingerprints in dist;
#   3. the natives frozen (claude-tmp/oclj/new-crc-<dll md5 8>, new-crc-linux-<so md5 8>);
#   4. the JVM harness, one JVM at a time: the seven Windows arms (chain-win.sh, tag crc1) and the
#      seven AlmaLinux 8 arms (chain-linux.sh, tag crc1); the glibc round's counts are the reference
#      (additive-on 82, dropin 69, additive-off 80, sieve 76, stock 53, disposeoff 82, bundleoff 82 with
#      its 3 expected failures);
#   5. gradle verifyModAssets, then gradle build (the jar).
# Writes build/native (through build-native.sh only), claude-tmp/oclj/runs and new-crc-*, build/libs,
# and <outdir>.  No backslashes in this file (P8).
set -u
O=${1:?usage: release.sh <fresh outdir> <final-check outdir>}
F=${2:?usage: release.sh <fresh outdir> <final-check outdir>}
R=/c/Users/astro/Downloads/OC-LuaJIT
RW=/mnt/c/Users/astro/Downloads/OC-LuaJIT
GS=$R/bench/runs/2026-10-19-glibc/scripts
GSW=$RW/bench/runs/2026-10-19-glibc/scripts
OC=/c/Users/astro/claude-tmp/oclj
[ -e "$O" ] && { echo "REFUSING: $O exists"; exit 99; }
[ -f "$F/ALL.done" ] || { echo "no $F/ALL.done"; exit 2; }
grep -q ' FAIL 0 ' "$F/ALL.done" || { echo "the final check did not pass: $(cat "$F/ALL.done")"; exit 2; }
case $O in /c/*) OW=/mnt/c${O#/c} ;; *) echo "outdir must be under /c/"; exit 2 ;; esac
mkdir -p "$O" || exit 98
L=$O/release.log
log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$L"; }
cd "$R" || exit 97
log "start; HEAD $(git rev-parse --short=8 HEAD); $(git status --short | wc -l) changed files; final check: $(cat "$F/ALL.done")"
md5sum build/native/dist/* build/native/libdir/* build/native/libdir-additive/* > "$O/natives-before.md5" 2>&1

# ---- 1. builds
sh "$GS/build-win.sh" "$O/build-win" > "$O/build-win.out" 2>&1
log "windows: $(tr '[:cntrl:]' ' ' < "$O/build-win/summary.txt")"
MSYS_NO_PATHCONV=1 wsl.exe -d AlmaLinux-8 -- sh "$GSW/build-linux.sh" "$OW/build-alma" "$RW/build/native" 2.28 > "$O/build-alma.out" 2>&1
log "alma: $(tr '[:cntrl:]' ' ' < "$O/build-alma/summary.txt")"
ok=1
for p in build-win build-alma; do
  for v in dropin additive; do grep -q "build-$v exit=0" "$O/$p/summary.txt" || ok=0; done
done
[ "$ok" = 1 ] || { log "A BUILD FAILED: stopping"; exit 1; }

# ---- 2. objects equal the final check's builds
lst() { ( cd "$1" && md5sum luajit-$2/src/*.o luajit-$2/src/host/*.o obj-$2/*.o ) | tr -d '*' | LC_ALL=C sort -k2; }
lst "$R/build/native" windows-x86_64 > "$O/win-release.md5"
lst "$F/b/win" windows-x86_64 > "$O/win-final.md5"
lst "$R/build/native" linux-x86_64 > "$O/linux-release.md5"
lst "$F/alma/b" linux-x86_64 > "$O/linux-final.md5"
for p in win linux; do
  n=$(wc -l < "$O/$p-release.md5" | tr -d ' ')
  if [ "$n" = 80 ] && cmp -s "$O/$p-release.md5" "$O/$p-final.md5"; then log "PASS objects-$p: build/native's 80 objects equal the final check's"
  else log "FAIL objects-$p: $n objects; diff in $O/$p-objects.diff"; diff "$O/$p-final.md5" "$O/$p-release.md5" > "$O/$p-objects.diff"; ok=0; fi
done
md5sum build/native/dist/* build/native/libdir/* build/native/libdir-additive/* > "$O/natives-after.md5" 2>&1
for f in build/native/dist/*; do
  log "fingerprint $(basename "$f"): $(grep -aoE '[0-9a-z]+[|]LuaJIT 2[.]1[.]ROLLING[|][0-9a-f]+[|][a-z0-9.]+' "$f" | head -1)"
done
log "alma glibc: $(tr '[:cntrl:]' ' ' < "$O/build-alma/glibc.txt" | cut -c1-400)"
[ "$ok" = 1 ] || { log "OBJECTS DIFFER: stopping"; exit 1; }

# ---- 3. freeze the natives
MW=$(md5sum < build/native/libdir-additive/libjnluajit52-windows-x86_64.dll | cut -c1-8)
ML=$(md5sum < build/native/libdir-additive/libjnluajit52-linux-x86_64.so | cut -c1-8)
FW=$OC/new-crc-$MW; FL=$OC/new-crc-linux-$ML
[ -e "$FW" ] || { mkdir -p "$FW/libdir" "$FW/libdir-additive" && cp build/native/libdir/*.dll "$FW/libdir/" && cp build/native/libdir-additive/*.dll "$FW/libdir-additive/"; }
[ -e "$FL" ] || { mkdir -p "$FL/libdir" "$FL/libdir-additive" "$FL/luajit-linux-x86_64/src" && cp build/native/libdir/*.so "$FL/libdir/" && cp build/native/libdir-additive/*.so "$FL/libdir-additive/" && cp build/native/luajit-linux-x86_64/src/luajit "$FL/luajit-linux-x86_64/src/"; }
md5sum "$FW"/*/* "$FL"/*/* "$FL"/luajit-linux-x86_64/src/luajit > "$O/frozen.md5"
log "frozen $FW $FL"

# ---- 4. the harness, one JVM at a time
sh "$GS/chain-win.sh" crc1 "$FW" > "$O/chain-win.out" 2>&1
log "harness windows: $(grep -E 'exit=' "$OC/runs/chain-gl-crc1.txt" | tr '[:cntrl:]' ' ')"
FLW=/mnt/c${FL#/c}
MSYS_NO_PATHCONV=1 wsl.exe -d AlmaLinux-8 -- sh "$GSW/chain-linux.sh" crc1 "$FLW" "$OW/runs-alma" > "$O/chain-alma.out" 2>&1
log "harness alma: $(grep -E 'exit=' "$O/runs-alma/chain-linux-crc1.txt" 2>/dev/null | tr '[:cntrl:]' ' ')"

# ---- 5. gradle
./gradlew verifyModAssets > "$O/gradle-verify.log" 2>&1
log "gradle verifyModAssets rc=$? $(grep -oE 'needs at most GLIBC_[0-9.]+' "$O/gradle-verify.log" | head -1)"
./gradlew build > "$O/gradle-build.log" 2>&1
log "gradle build rc=$?"
md5sum build/libs/*.jar > "$O/jars.md5" 2>&1
log "done"
touch "$O/ALL.done"
