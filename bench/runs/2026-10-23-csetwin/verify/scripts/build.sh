#!/bin/sh
# build.sh <repo dir> <name> -- the CSE type twin round, verify-code: one
# pinned, additive Windows build of <repo dir> (a scratch repo: HEAD 60a24ec
# exported with git archive, plus the round's eight files) through its own
# native/build-native.sh into a fresh OCLJ_BUILD round/verify-code/<name>.
# The LuaJIT tree is the real repo's pristine checkout, which build-native.sh
# only reads (guide 7.6).  Modelled on impl-code/scripts/build.sh.
# Log: verify-code/logs/build-<name>.log; exit status in logs/build-<name>.rc.
# Written with a file tool; no backslashes.
set -u
I=/c/Users/astro/claude-tmp/oclj/csetwin/round/verify-code
R=${1:?usage: build.sh <repo dir> <name>}
N=${2:?usage: build.sh <repo dir> <name>}
B=$I/$N
[ -e "$B" ] && { echo "REFUSING: $B exists"; exit 99; }
mkdir -p "$I/logs" || exit 98
[ -e "$I/logs/build-$N.log" ] && { echo "REFUSING: $I/logs/build-$N.log exists"; exit 99; }
unset LUA_INIT LUA_INIT_5_3 LUA_PATH LUA_CPATH OCLJ_LUAJIT_UNPINNED OCLJ_OUT
PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export PATH
md5sum "$R/native/build-native.sh" "$R/native/luajit/patch-bitop-fold.sh" "$R/native/luajit/oclj_bitop.h" "$R/native/luajit/oclj_bitop_rec.c" "$R/native/luajit/oclj_bitop_fold.c" > "$I/logs/build-$N.inputs.md5"
date +%H:%M:%S > "$I/logs/build-$N.t0"
OCLJ_REPO=$R OCLJ_LUAJIT=C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit OCLJ_BUILD=$B OCLJ_VARIANT=additive OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include" OCLJ_JNLUA=C:/Users/astro/Downloads/OC-JNLua sh "$R/native/build-native.sh" > "$I/logs/build-$N.log" 2>&1
rc=$?
date +%H:%M:%S > "$I/logs/build-$N.t1"
echo "$rc" > "$I/logs/build-$N.rc"
echo "build $N rc=$rc ($(cat "$I/logs/build-$N.t0") - $(cat "$I/logs/build-$N.t1"))"
tail -3 "$I/logs/build-$N.log"
exit $rc
