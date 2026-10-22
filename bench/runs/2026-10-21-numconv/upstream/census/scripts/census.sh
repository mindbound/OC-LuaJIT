#!/bin/sh
# census.sh <commit> <fresh outdir>: export <commit>'s tree from the
# read-only bare clone with git archive (core.autocrlf=false, core.eol=lf, as
# build-native.sh's ljgit does), then run the repo's twelve LuaJIT patch
# scripts on copies of its files in build-native.sh's order (THE FIRST ...
# THE TWELFTH: lj_func.c lj_err.c lj_ffrecord.c lj_arch.h lib_string.c, then
# BITOP_PATCHES lj_parse.c vm_x64.dasc lj_meta.c lj_record.c lj_opt_fold.c
# lj_bcdump.h lib_jit.c), each as "sh <script> <file> <file>" on a fresh copy
# of the pristine file.  NO build.  Unlike build-native.sh it does not stop
# at the first refusal: every script runs, and each verdict and rc goes to a
# file.  No backslashes, no heredocs.
set -u
C=$1
O=$2
REPO=/c/Users/astro/Downloads/OC-LuaJIT
BARE=/c/Users/astro/claude-tmp/oclj/sel/upstream.git
[ -e "$O" ] && { echo "$O exists"; exit 2; }
mkdir -p "$O/tree" "$O/work" "$O/tmp" "$O/out" || exit 2
TMPDIR=$O/tmp
export TMPDIR
git --git-dir="$BARE" rev-parse "$C^{commit}" > "$O/commit.txt" 2>&1
git --git-dir="$BARE" rev-parse "$C^{tree}" > "$O/tree-hash.txt" 2>&1
git --git-dir="$BARE" -c core.autocrlf=false -c core.eol=lf archive --format=tar "$C" > "$O/tree.tar"
echo $? > "$O/archive.rc"
tar -xf "$O/tree.tar" -C "$O/tree"
echo $? > "$O/extract.rc"
md5sum "$O/tree.tar" > "$O/tree-tar.md5"
rm -f "$O/tree.tar"
md5sum "$REPO"/native/luajit/patch-*.sh "$0" > "$O/scripts.md5"
S=$O/tree/src
N=0
for p in lj_func.c:patch-penalty-scrub.sh lj_err.c:patch-fastfunc-errmem-top.sh lj_ffrecord.c:patch-strfmt-xint-noffi.sh lj_arch.h:patch-features-include.sh lib_string.c:patch-strpack-register.sh lj_parse.c:patch-bitop-parse.sh vm_x64.dasc:patch-bitop-vm.sh lj_meta.c:patch-bitop-meta.sh lj_record.c:patch-bitop-record.sh lj_opt_fold.c:patch-bitop-fold.sh lj_bcdump.h:patch-bitop-bcdump.sh lib_jit.c:patch-bitop-jitlib.sh; do
  N=$((N + 1))
  f=${p%%:*}
  s=${p#*:}
  cp -f "$S/$f" "$O/work/$f" || { echo "cannot copy $f" > "$O/out/$N-$s.err"; continue; }
  sh "$REPO/native/luajit/$s" "$O/work/$f" "$O/work/$f" > "$O/out/$N-$s.out" 2> "$O/out/$N-$s.err"
  rc=$?
  echo $rc > "$O/out/$N-$s.rc"
  echo "$N $s $f rc=$rc | $(cat "$O/out/$N-$s.out" "$O/out/$N-$s.err" | tr -s ' ' | cut -c1-400)" >> "$O/verdicts.txt"
done
echo done > "$O/ALL.done"
