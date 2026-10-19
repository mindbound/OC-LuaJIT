#!/bin/sh
# final.sh -- the glibc round's final verification, after the follow-up's fixes to negative-control.sh and
# serializer/tests/forin.lua: on Windows against build/native, then in AlmaLinux 8 against the release
# build/native, then in Ubuntu against the development build: negative-control.sh and the serializer suite.
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
RW=/mnt/c/Users/astro/Downloads/OC-LuaJIT
R=$REPO/bench/runs/2026-10-19-glibc/logs/final
W=$RW/bench/runs/2026-10-19-glibc
[ -e "$R" ] && { echo "REFUSING: $R exists"; exit 99; }
mkdir -p "$R/win" || exit 98
cd "$REPO" || exit 97
export PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include" OCLJ_JNLUA=C:/Users/astro/Downloads/OC-JNLua
unset LUA_INIT LUA_INIT_5_3 MEMTEST_CFLAGS
md5sum test/native/negative-control.sh serializer/tests/forin.lua build/native/libdir-additive/*.dll > "$R/win/host.txt"
sh test/native/negative-control.sh > "$R/win/negctl.log" 2>&1; echo $? > "$R/win/negctl.rc"
rm -f serializer/erislj_test.exe
make -C serializer CC=gcc test > "$R/win/ser-test.log" 2>&1; echo $? > "$R/win/ser-test.rc"
echo "negctl rc=$(cat "$R/win/negctl.rc") $(grep -c 'RESULT: PASS' "$R/win/negctl.log") PASS $(grep -c 'RESULT: FAIL' "$R/win/negctl.log") FAIL" > "$R/win/summary.txt"
echo "ser-test rc=$(cat "$R/win/ser-test.rc") $(grep -E 'RESULT' "$R/win/ser-test.log" | tr '\n' ' ' | cut -c1-300)" >> "$R/win/summary.txt"
MSYS_NO_PATHCONV=1 wsl.exe -d AlmaLinux-8 -- sh "$W/scripts/final-linux.sh" "$W/logs/final/alma" "$RW/build/native" > /dev/null 2>&1
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu -- sh "$W/scripts/final-linux.sh" "$W/logs/final/ubuntu" /mnt/c/Users/astro/claude-tmp/oclj/glibc/main/ubuntu-build/build/native > /dev/null 2>&1
for h in win alma ubuntu; do echo "== $h"; cat "$R/$h/summary.txt"; done > "$R/summary.txt"
touch "$R/ALL.done"
