#!/bin/bash
# wsl-negctl-r3.sh <outdir> -- negctl-bitop.sh on Linux (Ubuntu WSL), against the Linux build wsl-r3.sh made
# in build/native: the first ELF run of its object fingerprint (lj_vm.o comes from buildvm's lj_vm.S here),
# its canon, its 27 arms and its restore.  Its copies go under build/native/negctl-bitop/<stamp>.
set -u
REPO=/mnt/c/Users/astro/Downloads/OC-LuaJIT
OUT=$1
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT"
export OCLJ_REPO=$REPO OCLJ_BUILD=$REPO/build/native CC=gcc
export OCLJ_JNI=/usr/lib/jvm/java-17-openjdk-amd64/include
export OCLJ_LUA53=/mnt/c/Users/astro/claude-tmp/oclj/puc536-linux/lua
date -u +%H:%M:%S > "$OUT/negctl-bitop.start"
sh "$REPO/test/native/negctl-bitop.sh" > "$OUT/negctl-bitop.log" 2>&1
echo "$?" > "$OUT/negctl-bitop.rc"
date -u +%H:%M:%S > "$OUT/negctl-bitop.end"
tail -3 "$OUT/negctl-bitop.log"
touch "$OUT/ALL.done"
