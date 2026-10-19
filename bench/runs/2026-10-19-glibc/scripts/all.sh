#!/bin/sh
# all.sh -- the glibc round's main-session chain, run from Git Bash with nohup, one step at a time:
#   1. fail-firsts: gradle on today's build/native/dist (round 3's Ubuntu .so, GLIBC_2.38: must be refused);
#      ff-linux.sh in AlmaLinux 8 (oldlink, head, nogit, release, relfile) and in Ubuntu (floor, dev)
#   2. builds: Windows into build/native (dropin, additive); THE RELEASE: AlmaLinux 8 into build/native with
#      OCLJ_GLIBC_MAX=2.28; a development build in Ubuntu into scratch
#   3. suites: Windows (native-tests-win.sh, all three negctls); AlmaLinux 8 on the release build (all
#      three negctls, the first full Linux run of negative-control.sh); Ubuntu on the development build
#   4. the natives frozen: claude-tmp/oclj/new-gl-<dll md5> and new-gl-linux-<so md5> (with the patcher luajit)
#   5. the harness: the seven arms on Windows, the seven arms in AlmaLinux 8 (JDK 8), the additive arm in
#      Ubuntu (JDK 17) on the Alma-built natives
#   6. gradle: verifyModAssets on build/native/dist (must pass, the .so at most 2.28), then the jar
# Scratch builds live under claude-tmp/oclj/glibc/main; the archive (bench/runs/2026-10-19-glibc) gets logs
# and md5s only.  Nothing is deleted.
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
RW=/mnt/c/Users/astro/Downloads/OC-LuaJIT
R=$REPO/bench/runs/2026-10-19-glibc
W=$RW/bench/runs/2026-10-19-glibc
S=$R/scripts
O=/c/Users/astro/claude-tmp/oclj
G=$O/glibc/main
GW=/mnt/c/Users/astro/claude-tmp/oclj/glibc/main
L=$R/logs/all.txt
[ -e "$L" ] && { echo "REFUSING: $L exists"; exit 99; }
[ -e "$G" ] && { echo "REFUSING: $G exists"; exit 99; }
mkdir -p "$R/logs" "$R/failfirst" "$G" || exit 98
log() { echo "$(date -u +%H:%M:%S) $*" >> "$L"; }
alma() { MSYS_NO_PATHCONV=1 wsl.exe -d AlmaLinux-8 -- sh "$@"; }
ubu() { MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu -- sh "$@"; }
cd "$REPO" || exit 97
export PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
log "start; HEAD $(git rev-parse --short=8 HEAD); $(git status --short | wc -l) changed files"
git diff --stat > "$R/logs/diffstat.txt"; git status --short > "$R/logs/status.txt"
md5sum native/build-native.sh build.gradle.kts test/native/*.sh test/native/OcljSmoke.scala serializer/Makefile > "$R/logs/sources.md5"

# ---- 1. fail-firsts
md5sum build/native/dist/* build/native/libdir*/* > "$R/failfirst/dist-before.md5"
./gradlew verifyModAssets > "$R/failfirst/gradle-dist.log" 2>&1
log "ff gradle on today's dist rc=$? $(grep -oE 'needs GLIBC_[0-9.]+, above the glibc floor GLIBC_2[.]28' "$R/failfirst/gradle-dist.log" | head -1)"
git show HEAD:native/build-native.sh > "$G/build-native.HEAD.sh"
alma "$RW/bench/runs/2026-10-19-glibc/scripts/ff-linux.sh" "$GW/ff-alma" "$GW/build-native.HEAD.sh" > "$R/failfirst/alma.out" 2>&1
log "ff alma rc=$?"
ubu "$RW/bench/runs/2026-10-19-glibc/scripts/ff-linux.sh" "$GW/ff-ubuntu" "$GW/build-native.HEAD.sh" > "$R/failfirst/ubuntu.out" 2>&1
log "ff ubuntu rc=$?"
for d in ff-alma ff-ubuntu; do
  mkdir -p "$R/failfirst/$d"
  cp "$G/$d/summary.txt" "$G/$d/host.txt" "$R/failfirst/$d/" 2>/dev/null
  for c in "$G/$d"/*/build.log; do [ -f "$c" ] && cp "$c" "$R/failfirst/$d/$(basename "$(dirname "$c")").build.log"; done
  grep -h -- '->' "$G/$d/summary.txt" | sed "s/^/  $d: /" >> "$L"
done

# ---- 2. builds
sh "$S/build-win.sh" "$R/logs/build-win" > "$G/build-win.out" 2>&1
log "build windows: $(tr '\n' ' ' < "$R/logs/build-win/summary.txt")"
alma "$W/scripts/build-linux.sh" "$W/logs/build-alma" "$RW/build/native" 2.28 > "$G/build-alma.out" 2>&1
log "build alma (release): $(tr '\n' ' ' < "$R/logs/build-alma/summary.txt")"
ubu "$W/scripts/build-linux.sh" "$W/logs/build-ubuntu" "$GW/ubuntu-build/build/native" > "$G/build-ubuntu.out" 2>&1
log "build ubuntu (dev): $(tr '\n' ' ' < "$R/logs/build-ubuntu/summary.txt")"
grep -q 'build-additive exit=0' "$R/logs/build-alma/summary.txt" && grep -q 'build-additive exit=0' "$R/logs/build-win/summary.txt" \
  || { log "A BUILD FAILED: stopping"; exit 1; }

# ---- 3. suites
sh "$S/native-tests-win.sh" "$R/logs/suite-win" > "$G/suite-win.out" 2>&1
log "suites windows: $(tr '\n' ' ' < "$R/logs/suite-win/summary.txt")"
alma "$W/scripts/suites-linux.sh" "$W/logs/suite-alma" "$RW/build/native" /mnt/c/Users/astro/claude-tmp/oclj/puc536-alma/lua 1 > "$G/suite-alma.out" 2>&1
log "suites alma: $(tr '\n' ' ' < "$R/logs/suite-alma/summary.txt")"
ubu "$W/scripts/suites-linux.sh" "$W/logs/suite-ubuntu" "$GW/ubuntu-build/build/native" /mnt/c/Users/astro/claude-tmp/oclj/puc536-linux/lua 0 > "$G/suite-ubuntu.out" 2>&1
log "suites ubuntu: $(tr '\n' ' ' < "$R/logs/suite-ubuntu/summary.txt")"

# ---- 4. freeze the natives
MW=$(md5sum build/native/libdir-additive/libjnluajit52-windows-x86_64.dll | cut -c1-8)
ML=$(md5sum build/native/libdir-additive/libjnluajit52-linux-x86_64.so | cut -c1-8)
FW=$O/new-gl-$MW; FL=$O/new-gl-linux-$ML
[ -e "$FW" ] || { mkdir -p "$FW/libdir" "$FW/libdir-additive" && cp build/native/libdir/*.dll "$FW/libdir/" && cp build/native/libdir-additive/*.dll "$FW/libdir-additive/"; }
[ -e "$FL" ] || { mkdir -p "$FL/libdir" "$FL/libdir-additive" "$FL/luajit-linux-x86_64/src" && cp build/native/libdir/*.so "$FL/libdir/" \
  && cp build/native/libdir-additive/*.so "$FL/libdir-additive/" && cp build/native/luajit-linux-x86_64/src/luajit "$FL/luajit-linux-x86_64/src/"; }
md5sum "$FW"/*/* "$FL"/*/* "$FL"/luajit-linux-x86_64/src/luajit > "$R/logs/frozen.md5"
log "frozen $FW $FL"

# ---- 5. the harness
sh "$S/chain-win.sh" a "$FW" > "$G/chain-win.out" 2>&1
log "harness windows: $(grep -E 'exit=' "$O/runs/chain-gl-a.txt" | sed 's/SMOKE| //' | tr '\n' ';')"
FLW=/mnt/c/Users/astro/claude-tmp/oclj/new-gl-linux-$ML
alma "$W/scripts/chain-linux.sh" a "$FLW" "$GW/runs-alma" > "$G/chain-alma.out" 2>&1
log "harness alma: $(grep -E 'exit=' "$G/runs-alma/chain-linux-a.txt" | sed 's/SMOKE| //' | tr '\n' ';')"
ubu "$W/scripts/full-linux.sh" "$GW/runs-ubuntu/additive-on-a" additive "$FLW/libdir-additive" on UNSET > "$G/ubuntu-arm.out" 2>&1
log "harness ubuntu additive-on: exit=$(cat "$G/runs-ubuntu/additive-on-a/exit.txt" 2>/dev/null) $(grep -E 'CHECKS:' "$G/runs-ubuntu/additive-on-a/work/smoke.log" 2>/dev/null)"

# ---- 6. gradle
mkdir -p "$R/logs/gradle"
md5sum build/native/dist/* > "$R/logs/gradle/dist.md5"
./gradlew verifyModAssets > "$R/logs/gradle/verify.log" 2>&1
log "gradle verifyModAssets rc=$? $(grep -oE 'needs at most GLIBC_[0-9.]+' "$R/logs/gradle/verify.log" | head -1)"
./gradlew build > "$R/logs/gradle/build.log" 2>&1
log "gradle build rc=$?"
md5sum build/libs/ocluajit-$(git rev-parse --short=7 HEAD)-*.jar >> "$R/logs/gradle/dist.md5" 2>/dev/null
log "done"
touch "$R/logs/all.done"
