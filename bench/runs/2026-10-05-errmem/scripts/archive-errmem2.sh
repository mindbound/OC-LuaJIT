#!/bin/sh
# archive-errmem2.sh -- the two-site build's evidence ADDED to bench/runs/2026-10-05-errmem/
# (archive-errmem.sh made the directory from the one-site build): the one-site logs move under
# logs/one-site/, the final build's take their place; new files only, nothing deleted.
set -u
W2=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2
E=$W2/E; E2=$W2/E2; C=$W2/errmem/census
DST=/c/Users/astro/Downloads/OC-LuaJIT/bench/runs/2026-10-05-errmem
[ -d "$DST/logs/gates" ] || { echo "REFUSING: $DST is not the one-site archive"; exit 99; }
[ -e "$DST/logs/one-site" ] && { echo "REFUSING: $DST/logs/one-site exists"; exit 99; }
mkdir -p "$DST/logs/one-site"
for f in build-additive.log build-dropin.log wsl-native.log before.md5 after.md5 gates wslgates runsE; do
  mv "$DST/logs/$f" "$DST/logs/one-site/$f"
done
cp $E/README-archive.md "$DST/README.md"
# the patch step, both sites
cp $W2/errmem/patchcheck2.sh $W2/errmem/patchcheck2-pc3.log "$DST/patch/"
cp $E/buildneg2.sh $E/buildneg2-bneg4.log "$DST/patch/"
for t in A A2 B C; do cp $E/bneg4/$t.log "$DST/patch/buildneg2-$t.log"; done
# the final build's lj_err_mem and lj_err_err
cp $E2/lj_err_mem.dis "$DST/dis/lj_err_mem-final.dis"
cp $E2/lj_err_err.dis "$DST/dis/lj_err_err-final.dis"
# the identity checks the note cites, and the two shipped-archive censuses
cp $C/ident_nf_more.txt "$DST/census/"
rm -f "$DST/census/census-out.tar.gz.new"
(cd $C/out && tar czf "$DST/census/census-out.tar.gz.new" *.tsv) && mv -f "$DST/census/census-out.tar.gz.new" "$DST/census/census-out.tar.gz"
# the final build: builds, gates, suites, the shipped-archive census
cp $E2/build-additive.log $E2/build-dropin.log $E2/wsl-native.log $E2/before.md5 $E2/after.md5 $E2/chain.log "$DST/logs/"
mkdir -p "$DST/logs/gates" "$DST/logs/wslgates" "$DST/logs/runsE2"
cp $E2/gatesE2/*.log $E2/gatesE2/summary.txt $E2/gatesE2/objects.md5 "$DST/logs/gates/"
cp $E2/wslgates/* "$DST/logs/wslgates/"
cp $W2/runsE2/full.log "$DST/logs/runsE2/"
for d in $W2/runsE2/full/*/; do cp "$d/run.log" "$DST/logs/runsE2/$(basename "$d").log"; done
cp $E2/ship2-build.log $E2/ship2-census.out $E2/ship2-ident.txt "$DST/logs/"
cp $W2/chainE2.sh $E/archive-errmem2.sh "$DST/scripts/"
find "$DST" -type f | wc -l
du -sh "$DST"
