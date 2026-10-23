#!/bin/sh
# build.sh <name> -- the CSE type twin round, fix: one pinned, additive
# Windows build of the scratch repo round/repo (HEAD 1a13bed's tree exported
# with git archive, plus the round's eight files, as the fixer leaves them)
# through its own native/build-native.sh into a fresh OCLJ_BUILD
# round/fix/<name>.  The LuaJIT tree is the real repo's pristine checkout,
# which build-native.sh only reads (JIT guide 7.6).  Modelled on
# verify-code/scripts/build.sh.  Log fix/logs/build-<name>.log, exit status
# in logs/build-<name>.rc, input md5s in logs/build-<name>.inputs.md5.
# Written with a file tool; no backslashes.
set -u
F=/c/Users/astro/claude-tmp/oclj/csetwin/round/fix
RP=/c/Users/astro/claude-tmp/oclj/csetwin/round/repo
N=${1:?usage: build.sh <name>}
B=$F/$N
[ -e "$B" ] && { echo "REFUSING: $B exists"; exit 99; }
mkdir -p "$F/logs" || exit 98
[ -e "$F/logs/build-$N.log" ] && { echo "REFUSING: $F/logs/build-$N.log exists"; exit 99; }
unset LUA_INIT LUA_INIT_5_3 LUA_PATH LUA_CPATH OCLJ_LUAJIT_UNPINNED OCLJ_OUT OCLJ_REPO
PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export PATH
md5sum "$RP/native/build-native.sh" "$RP/native/luajit/patch-bitop-fold.sh" "$RP/native/luajit/oclj_bitop.h" "$RP/native/luajit/oclj_bitop_rec.c" "$RP/native/luajit/oclj_bitop_fold.c" > "$F/logs/build-$N.inputs.md5"
date +%H:%M:%S > "$F/logs/build-$N.t0"
env OCLJ_REPO="$RP" OCLJ_LUAJIT=C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit OCLJ_BUILD="$B" OCLJ_VARIANT=additive OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include" OCLJ_JNLUA=C:/Users/astro/Downloads/OC-JNLua sh "$RP/native/build-native.sh" > "$F/logs/build-$N.log" 2>&1
rc=$?
date +%H:%M:%S > "$F/logs/build-$N.t1"
echo "$rc" > "$F/logs/build-$N.rc"
echo "build $N rc=$rc ($(cat "$F/logs/build-$N.t0") - $(cat "$F/logs/build-$N.t1"))"
tail -3 "$F/logs/build-$N.log"
exit $rc
