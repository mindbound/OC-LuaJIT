#!/bin/sh
# buildneg.sh <fresh dir> -- build-native.sh's two new refusals, each shown to fire:
#   A  the pinned checkout's lj_err.c already carries the clamp -> refuse (checkout must stay pristine)
#   B  the patch step exits 0 without patching                  -> refuse before make (content assertion)
# Each runs on scratch copies (OCLJ_REPO, OCLJ_LUAJIT, OCLJ_BUILD); the repo and build/native are untouched.
set -u
D=$1
[ -e "$D" ] && { echo "REFUSING: $D exists"; exit 99; }
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
REPO=/c/Users/astro/Downloads/OC-LuaJIT
mkdir -p "$D" || exit 98
# a pristine LuaJIT tree without .git, and a scratch "repo" holding native/ and serializer/
mkdir -p "$D/luajit" && (cd "$REPO/prototype/watchdog/luajit" && tar cf - --exclude=.git .) | (cd "$D/luajit" && tar xf -)
mkdir -p "$D/repo" && cp -r "$REPO/native" "$REPO/serializer" "$D/repo/"
res() { if [ "$1" = "$2" ]; then echo "OK   $3 (exit $1)"; else echo "BAD  $3 (exit $1, want $2)"; fi; }

# A: the checkout carries the clamp
cp -r "$D/luajit" "$D/luajitA"
sh "$REPO/native/luajit/patch-fastfunc-errmem-top.sh" "$D/luajitA/src/lj_err.c" "$D/luajitA/src/lj_err.c"
OCLJ_LUAJIT="$D/luajitA" OCLJ_BUILD="$D/buildA" sh "$REPO/native/build-native.sh" > "$D/A.log" 2>&1
res $? 1 "A: patched checkout refused"
grep -n "ERRMEM top clamp\|pinned" "$D/A.log" | head -3
# the pinned checkout carries a stale libluajit.a of its own (2026-09-01), which the copy inherits:
# "make never ran" means the build copy's archive is still byte-identical to that one
if cmp -s "$D/buildA/luajit-windows-x86_64/src/libluajit.a" "$REPO/prototype/watchdog/luajit/src/libluajit.a"; then echo "OK   A: make never ran (archive = the checkout's stale one)"; else echo "BAD  A: the archive was rebuilt"; fi

# B: a patch step that does nothing
printf '#!/bin/sh\nexit 0\n' > "$D/repo/native/luajit/patch-fastfunc-errmem-top.sh"
OCLJ_REPO="$D/repo" OCLJ_LUAJIT="$D/luajit" OCLJ_BUILD="$D/buildB" sh "$D/repo/native/build-native.sh" > "$D/B.log" 2>&1
res $? 1 "B: no-op patch step refused"
grep -n "ERRMEM top clamp\|exactly once" "$D/B.log" | head -3
# the pinned checkout carries a stale libluajit.a of its own (2026-09-01), which the copy inherits:
# "make never ran" means the build copy's archive is still byte-identical to that one
if cmp -s "$D/buildB/luajit-windows-x86_64/src/libluajit.a" "$REPO/prototype/watchdog/luajit/src/libluajit.a"; then echo "OK   B: make never ran (archive = the checkout's stale one)"; else echo "BAD  B: the archive was rebuilt"; fi

# control: the same scratch setup with the real patch script builds through the LuaJIT step
cp "$REPO/native/luajit/patch-fastfunc-errmem-top.sh" "$D/repo/native/luajit/patch-fastfunc-errmem-top.sh"
OCLJ_REPO="$D/repo" OCLJ_LUAJIT="$D/luajit" OCLJ_BUILD="$D/buildC" sh "$D/repo/native/build-native.sh" > "$D/C.log" 2>&1
echo "C: exit $?"
grep -n "lj_err" "$D/C.log" | head -5
