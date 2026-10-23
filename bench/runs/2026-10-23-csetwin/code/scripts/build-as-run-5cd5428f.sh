#!/bin/sh
# build.sh <name> -- the CSE type twin round, impl-code: one pinned, additive
# Windows build of the scratch repo copy csetwin/round/repo (git archive of
# HEAD 1a13bed, with hunk 12 and the two comment fixes) through its own
# native/build-native.sh into a fresh OCLJ_BUILD round/impl-code/<name>.
# The LuaJIT tree is the real repo's pristine checkout (a git-archive copy
# has none), which build-native.sh only reads: it exports the pin's tree
# from its .git with git archive and checks the export object by object
# (guide 7.6).  Modelled on numconv/proto/scripts/build.sh.
# Log: impl-code/logs/build-<name>.log; exit status in logs/build-<name>.rc.
# Written with a file tool; no backslashes.
set -u
I=/c/Users/astro/claude-tmp/oclj/csetwin/round/impl-code
R=/c/Users/astro/claude-tmp/oclj/csetwin/round/repo
N=${1:?usage: build.sh <name>}
B=$I/$N
[ -e "$B" ] && { echo "REFUSING: $B exists"; exit 99; }
mkdir -p "$I/logs" || exit 98
[ -e "$I/logs/build-$N.log" ] && { echo "REFUSING: $I/logs/build-$N.log exists"; exit 99; }
unset LUA_INIT LUA_INIT_5_3 LUA_PATH LUA_CPATH OCLJ_LUAJIT_UNPINNED OCLJ_OUT
PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export PATH
md5sum "$R/native/build-native.sh" "$R/native/luajit/patch-bitop-fold.sh" "$R/native/luajit/oclj_bitop.h" "$R/native/luajit/oclj_bitop_rec.c" "$R/native/luajit/oclj_bitop_fold.c" > "$I/logs/build-$N.inputs.md5"
date +%H:%M:%S > "$I/logs/build-$N.t0"
OCLJ_REPO=$R OCLJ_LUAJIT=C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit OCLJ_BUILD=$B \
  OCLJ_VARIANT=additive \
  OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include" \
  OCLJ_JNLUA=C:/Users/astro/Downloads/OC-JNLua \
  sh "$R/native/build-native.sh" > "$I/logs/build-$N.log" 2>&1
rc=$?
date +%H:%M:%S > "$I/logs/build-$N.t1"
echo "$rc" > "$I/logs/build-$N.rc"
echo "build $N rc=$rc ($(cat "$I/logs/build-$N.t0") - $(cat "$I/logs/build-$N.t1"))"
tail -3 "$I/logs/build-$N.log"
exit $rc
