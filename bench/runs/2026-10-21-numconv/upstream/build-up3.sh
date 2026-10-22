#!/bin/sh
# build-up3.sh <fresh linux work dir> <fresh outdir, WSL form>: upstream
# LuaJIT's fix for #1535, a4c0645 "Don't compile select() indexing beyond
# varargs." (a4c.tar, git archive --prefix=lj/ of the bare clone), built
# stock two ways -- a4c (GC64) and a4cnogc64 (LUAJIT_DISABLE_GC64) -- then
# the issue's repro.lua (blocks-3, run from there so the chunk name is the
# bare file name), blocks-1's konst.lua (-joff, JIT, -jv, -jdump=i) and the
# code verifier's vsel.lua under -joff and the same 21 option sets as
# build-up2.sh, on each build.  Every rc goes to a file.  No backslashes.
set -u
U=/mnt/c/Users/astro/claude-tmp/oclj/sel/upreport
V=/mnt/c/Users/astro/claude-tmp/oclj/sel/verify-code
B=$U/blocks-3
K=$U/blocks-1/konst.lua
W=$1
O=$2
[ -e "$W" ] && { echo "$W exists"; exit 2; }
[ -e "$O" ] && { echo "$O exists"; exit 2; }
mkdir -p "$W" "$O" || exit 2
{
  for t in gcc make tar python3 md5sum; do echo "$t: $(command -v $t)"; done
  gcc --version | head -1
  uname -srm
} > "$O/tools.txt" 2>&1
md5sum "$U/a4c.tar" "$B/repro.lua" "$K" "$V/probes/vsel.lua" "$V/scripts/cmpcases.py" "$0" > "$O/inputs.md5"

cd "$W" || exit 2
for b in a4c a4cnogc64; do
  mkdir "$b" || exit 2
  tar -xf "$U/a4c.tar" -C "$b"
  echo $? > "$O/extract-$b.rc"
done
grep -n 'LUAI_MAXSTACK) goto nyivarg' a4c/lj/src/lj_record.c > "$O/a4c-fixline.txt" 2>&1

NP=$(nproc)
(cd a4c/lj && make -j"$NP") > "$O/build-a4c.log" 2>&1
echo $? > "$O/build-a4c.rc"
(cd a4cnogc64/lj && make -j"$NP" XCFLAGS=-DLUAJIT_DISABLE_GC64) > "$O/build-a4cnogc64.log" 2>&1
echo $? > "$O/build-a4cnogc64.rc"

SETS="jon: hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0 he1:-Ohotloop=1_-Ohotexit=1 noloop:-O3_-O-loop O0:-O0 O1:-O1 O2:-O2 nofold:-O3_-O-fold nocse:-O3_-O-cse hx1:-Ohotexit=1 ts1:-Otryside=1_-Ohotexit=2 mx1:-Omaxside=1 hl1ms0:-Ohotloop=1_-Omaxside=0 noabc:-O3_-O-abc nonarrow:-O3_-O-narrow nofuse:-O3_-O-fuse nofwd:-O3_-O-fwd_-O-dse nosink:-O3_-O-sink hloop1:-Ohotloop=1 he1ms0:-Omaxside=0_-Ohotloop=1_-Ohotexit=1"
for b in a4c a4cnogc64; do
  LJ=$W/$b/lj/src/luajit
  [ -x "$LJ" ] || { echo "no $LJ" > "$O/$b-MISSING"; continue; }
  LUA_PATH="$W/$b/lj/src/?.lua;;"
  export LUA_PATH
  md5sum "$LJ" > "$O/$b-luajit.md5"
  "$LJ" -v > "$O/$b-v.txt" 2>&1
  "$LJ" -e "print(string.dump(function() end):byte(5))" > "$O/$b-fr2.txt" 2>&1
  cd "$B" || exit 2
  "$LJ" -joff repro.lua > "$O/$b-repro-joff.txt" 2>&1
  echo $? > "$O/$b-repro-joff.rc"
  "$LJ" repro.lua > "$O/$b-repro-jon.txt" 2>&1
  echo $? > "$O/$b-repro-jon.rc"
  "$LJ" -jv="$O/$b-repro.jv" repro.lua > "$O/$b-repro-jv.txt" 2>&1
  cd "$U/blocks-1" || exit 2
  "$LJ" -joff konst.lua > "$O/$b-konst-joff.txt" 2>&1
  "$LJ" konst.lua > "$O/$b-konst-jon.txt" 2>&1
  "$LJ" -jv="$O/$b-konst.jv" konst.lua > "$O/$b-konst-jv.txt" 2>&1
  "$LJ" -jdump=i,"$O/$b-konst.dump" konst.lua > "$O/$b-konst-dump.txt" 2>&1
  echo $? > "$O/$b-konst.rc"
  VO=$O/$b-vsel
  mkdir "$VO" || exit 2
  "$LJ" -joff "$V/probes/vsel.lua" > "$VO/joff.txt" 2> "$VO/joff.err"
  echo "joff rc=$? lines=$(grep -c . "$VO/joff.txt")" > "$VO/summary.txt"
  for s in $SETS; do
    n=${s%%:*}
    a=$(echo "${s#*:}" | tr '_' ' ')
    "$LJ" $a "$V/probes/vsel.lua" > "$VO/$n.txt" 2> "$VO/$n.err"
    rc=$?
    d=$(python3 -I "$V/scripts/cmpcases.py" "$VO/joff.txt" "$VO/$n.txt" 2>&1)
    echo "$n rc=$rc diff=$(echo "$d" | cut -c1-160) | $(grep '^#cov' "$VO/$n.err")" >> "$VO/summary.txt"
  done
  cd "$W" || exit 2
done
echo done > "$O/ALL.done"
