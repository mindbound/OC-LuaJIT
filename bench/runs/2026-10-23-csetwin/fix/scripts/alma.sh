#!/bin/sh
# alma.sh <fresh name> -- run INSIDE AlmaLinux 8 (WSL):
#   MSYS_NO_PATHCONV=1 wsl.exe -d AlmaLinux-8 -- env X=1 sh /mnt/c/Users/astro/claude-tmp/oclj/csetwin/round/fix/scripts/alma.sh <name>
# The CSE type twin round, fix: an additive, pinned build of the scratch
# repo round/repo (as the fixer leaves it) with OCLJ_GLIBC_MAX=2.28 into its
# own OCLJ_BUILD fix/<name>/b (fresh); its 77 LuaJIT objects and three of
# ours compared by md5 with the real repo's build/native Linux tree (read
# only; only lj_opt_fold.o may differ); then round/repo's run-bitjit.sh part
# cse with the Linux PUC 5.3.6 on the new build, and the same part on
# build/native's Linux luajit (the unfixed base, read only; its results go
# to fix/<name>/base-cse), which must FAIL (forward-order files and
# t_cserev's two no-slot shapes only: safe on any build); and sh -n of the
# changed shell scripts.  Exit codes go to files in <name>/rc/, the summary
# to <name>/summary.txt, part.done last.  Modelled on
# integrate/scripts/alma.sh.  No backslashes; no VAR=value before a shell
# function (AlmaLinux 8's sh keeps it).
set -u
N=${1:?usage: alma.sh <fresh name>}
F=/mnt/c/Users/astro/claude-tmp/oclj/csetwin/round/fix
RP=/mnt/c/Users/astro/claude-tmp/oclj/csetwin/round/repo
REAL=/mnt/c/Users/astro/Downloads/OC-LuaJIT
PUCL=/mnt/c/Users/astro/claude-tmp/oclj/puc536-alma/lua
A=$F/$N
[ -e "$A" ] && { echo "REFUSING: $A exists"; exit 99; }
mkdir -p "$A/rc" || exit 98
unset LUA_INIT LUA_INIT_5_3 LUA_PATH LUA_CPATH OCLJ_REPO OCLJ_LUA53 OCLJ_LUAJIT_UNPINNED OCLJ_OUT
unset OCLJ_BITJIT_PARTS OCLJ_BITJIT_SEED OCLJ_BITJIT_SEEDS OCLJ_BITJIT_CASES OCLJ_BITJIT_GENMODE OCLJ_BITJIT_HOTMIN OCLJ_BITJIT_OUT
{ uname -a; gcc --version | head -1; readlink -f /bin/sh; ldd --version 2>&1 | head -1; cat /etc/redhat-release; "$PUCL" -v; md5sum "$PUCL"; } > "$A/host.txt" 2>&1
( cd "$RP" && md5sum native/build-native.sh native/luajit/patch-bitop-fold.sh native/luajit/oclj_bitop.h native/luajit/oclj_bitop_rec.c test/native/negctl-bitop.sh test/native/run-bitjit.sh test/native/bitop/t_csefwd.lua test/native/bitop/cseir.lua test/native/bitop/t_cserev.lua ) > "$A/repo-files.md5" 2>&1
: > "$A/shn.txt"
for f in native/luajit/patch-bitop-fold.sh test/native/negctl-bitop.sh test/native/run-bitjit.sh; do
  sh -n "$RP/$f" > /dev/null 2>&1; echo "$? $f" >> "$A/shn.txt"
done
date -u +%H:%M:%S > "$A/t-start.txt"
env OCLJ_REPO="$RP" OCLJ_JNI=/usr/lib/jvm/java-1.8.0-openjdk/include OCLJ_JNLUA=/mnt/c/Users/astro/Downloads/OC-JNLua CC=gcc OCLJ_LUAJIT="$REAL/prototype/watchdog/luajit" OCLJ_BUILD="$A/b" OCLJ_VARIANT=additive OCLJ_GLIBC_MAX=2.28 sh "$RP/native/build-native.sh" > "$A/build.log" 2>&1
echo $? > "$A/rc/build.rc"
date -u +%H:%M:%S > "$A/t-built.txt"
if [ "$(cat "$A/rc/build.rc")" = 0 ]; then
  ( cd "$A/b/luajit-linux-x86_64/src" && md5sum *.o host/*.o ) | tr -d '*' | LC_ALL=C sort -k2 > "$A/obj-new.md5"
  ( cd "$A/b/obj-linux-x86_64" && md5sum *.o ) | tr -d '*' | LC_ALL=C sort -k2 | sed 's/ / obj-/' >> "$A/obj-new.md5"
  ( cd "$REAL/build/native/luajit-linux-x86_64/src" && md5sum *.o host/*.o ) | tr -d '*' | LC_ALL=C sort -k2 > "$A/obj-base.md5"
  ( cd "$REAL/build/native/obj-linux-x86_64" && md5sum *.o ) | tr -d '*' | LC_ALL=C sort -k2 | sed 's/ / obj-/' >> "$A/obj-base.md5"
  diff "$A/obj-base.md5" "$A/obj-new.md5" > "$A/obj.diff"
  md5sum "$A/b/luajit-linux-x86_64/src/lj_opt_fold.o" "$A/b/luajit-linux-x86_64/src/luajit" "$A/b/luajit-linux-x86_64/src/lj_opt_fold.c" "$REAL/build/native/luajit-linux-x86_64/src/lj_opt_fold.o" "$REAL/build/native/luajit-linux-x86_64/src/luajit" > "$A/key.md5" 2>&1
  grep -h 'glibc: highest version needed' "$A/build.log" > "$A/glibc.txt"
  grep -h -e 'warnings = ' -e 'ignored from the environment' -e 'export verified' -e 'patch-bitop-fold.sh:' "$A/build.log" > "$A/gates.txt"
  env OCLJ_BUILD="$A/b" OCLJ_LUA53="$PUCL" OCLJ_BITJIT_PARTS=cse OCLJ_BITJIT_OUT="$A/cse" sh "$RP/test/native/run-bitjit.sh" > "$A/cse.log" 2>&1
  echo $? > "$A/rc/cse.rc"
fi
env OCLJ_BUILD="$REAL/build/native" OCLJ_LUA53="$PUCL" OCLJ_BITJIT_PARTS=cse OCLJ_BITJIT_OUT="$A/base-cse" sh "$RP/test/native/run-bitjit.sh" > "$A/base-cse.log" 2>&1
echo $? > "$A/rc/base-cse.rc"
date -u +%H:%M:%S > "$A/t-end.txt"
{ echo "build rc=$(cat "$A/rc/build.rc")"
  echo "objects: $(grep -c . "$A/obj-new.md5" 2>/dev/null) compared with build/native's Linux tree; differing: $(grep '^>' "$A/obj.diff" 2>/dev/null | awk '{ printf "%s ", $3 }')"
  echo "cse rc=$(cat "$A/rc/cse.rc" 2>/dev/null) :: $(grep '^RUN-BITJIT' "$A/cse.log" 2>/dev/null)"
  echo "base-cse rc=$(cat "$A/rc/base-cse.rc" 2>/dev/null) :: $(grep '^RUN-BITJIT' "$A/base-cse.log" 2>/dev/null)"
  cat "$A/glibc.txt" "$A/key.md5" "$A/shn.txt" 2>/dev/null
  echo "times (UTC): $(cat "$A/t-start.txt") $(cat "$A/t-built.txt") $(cat "$A/t-end.txt")"
} > "$A/summary.txt"
echo done > "$A/part.done"
