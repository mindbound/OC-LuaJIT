#!/bin/sh
# build-syn.sh <fresh linux work dir> <fresh outdir, WSL form>: upstream
# a4c0645 (a4c.tar) and our pin 1ee778a4 (pin.tar), both stock and built
# with LUAJIT_ENABLE_LUA52COMPAT as our native is, then syn/probe.lua on
# each.  Every rc goes to a file.  No backslashes.
set -u
U=/mnt/c/Users/astro/claude-tmp/oclj/sel/upreport
P=$U/syn/probe.lua
W=$1
O=$2
[ -e "$W" ] && { echo "$W exists"; exit 2; }
[ -e "$O" ] && { echo "$O exists"; exit 2; }
mkdir -p "$W" "$O" || exit 2
md5sum "$U/a4c.tar" "$U/syn/pin.tar" "$P" "$0" > "$O/inputs.md5"
cd "$W" || exit 2
NP=$(nproc)
for b in a4c pin; do
  mkdir "$b" || exit 2
  case $b in a4c) T=$U/a4c.tar ;; pin) T=$U/syn/pin.tar ;; esac
  tar -xf "$T" -C "$b"
  echo $? > "$O/extract-$b.rc"
  (cd "$b/lj" && make -j"$NP" XCFLAGS=-DLUAJIT_ENABLE_LUA52COMPAT) > "$O/build-$b.log" 2>&1
  echo $? > "$O/build-$b.rc"
  LJ=$W/$b/lj/src/luajit
  md5sum "$LJ" > "$O/$b-luajit.md5"
  "$LJ" -e "print(table.unpack ~= nil, _VERSION, jit.version)" > "$O/$b-v.txt" 2>&1
  "$LJ" "$P" > "$O/$b-probe.txt" 2>&1
  echo $? > "$O/$b-probe.rc"
done
echo done > "$O/ALL.done"
