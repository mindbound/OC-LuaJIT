#!/bin/sh
# T10 rerun on FIX-NUMCONV's committed natives (19a7806): standalone on the
# release's luajit.exe (JIT on, -joff) and PUC 5.3.6, the harness's two arms
# with DLL 9ac03aeb, then gradle verifyModAssets and build on the clean tree.
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
T=/c/Users/astro/claude-tmp/oclj/t10
O=$T/rerun-2
[ -e "$O" ] && { echo "REFUSING: $O exists (never reuse a results directory)"; exit 99; }
mkdir -p "$O/standalone/luajit" "$O/standalone/luajit-joff" "$O/standalone/puc53" || exit 98
PROG=$T/ingame-bitops.lua
LJ=$REPO/build/native/luajit-windows-x86_64/src/luajit.exe
PUC=$REPO/bench/vendor/lua-5.3.6/src/lua.exe
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$O/chain.log"; }
log start
md5sum "$PROG" "$LJ" "$PUC" "$REPO"/build/native/dist/* > "$O/inputs.md5"
git -C "$REPO" rev-parse HEAD > "$O/head.txt"
git -C "$REPO" status --short > "$O/status.txt"
if tasklist | grep -i -E "^javaw?[.]exe" > /dev/null; then log "REFUSING: a java.exe or javaw.exe is running"; exit 96; fi
"$LJ" "$PROG" "$O/standalone/luajit" > "$O/standalone/luajit/stdout.txt" 2>&1
log "standalone luajit rc=$?"
"$LJ" -joff "$PROG" 3 "$O/standalone/luajit-joff" > "$O/standalone/luajit-joff/stdout.txt" 2>&1
log "standalone luajit -joff rc=$?"
"$PUC" "$PROG" "$O/standalone/puc53" > "$O/standalone/puc53/stdout.txt" 2>&1
log "standalone puc53 rc=$?"
sh "$T/harness/run-ingame-2.sh" luajit "$O/ig-luajit" "$PROG"
log "harness luajit rc=$? exit=$(cat "$O/ig-luajit/exit.txt" 2>/dev/null)"
sh "$T/harness/run-ingame-2.sh" lua53 "$O/ig-lua53" "$PROG"
log "harness lua53 rc=$? exit=$(cat "$O/ig-lua53/exit.txt" 2>/dev/null)"
cd "$REPO" || exit 97
./gradlew verifyModAssets > "$O/gradle-verify.log" 2>&1
log "gradle verifyModAssets rc=$?"
./gradlew build > "$O/gradle-build.log" 2>&1
log "gradle build rc=$?"
ls -la build/libs/ > "$O/libs.txt"
JAR=$(ls -t build/libs/ocluajit-*.jar | grep -v -e '-dev[.]jar$' -e '-sources[.]jar$' | head -1)
log "jar $JAR $(wc -c < "$JAR") bytes"
md5sum "$JAR" > "$O/jar.md5"
unzip -p "$JAR" assets/opencomputers/lib/libjnluajit52-windows-x86_64.dll | md5sum >> "$O/jar.md5"
unzip -p "$JAR" assets/opencomputers/lib/libjnluajit52-linux-x86_64.so | md5sum >> "$O/jar.md5"
unzip -l "$JAR" > "$O/jar-list.txt"
git -C "$REPO" status --short > "$O/status-after.txt"
log done
