#!/bin/sh
# archive-errmem.sh -- the unwinder-crash fix's evidence into bench/runs/2026-10-05-errmem/ (new files only).
set -u
W2=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2
E=$W2/E
C=$W2/errmem/census
DST=/c/Users/astro/Downloads/OC-LuaJIT/bench/runs/2026-10-05-errmem
[ -e "$DST" ] && { echo "REFUSING: $DST exists"; exit 99; }
mkdir -p "$DST/patch" "$DST/dis" "$DST/census" "$DST/logs/gates" "$DST/logs/wslgates" "$DST/logs/runsE" "$DST/scripts"
cp $E/README-archive.md "$DST/README.md"
# the patch step: the patch script's own checks, and build-native.sh's two refusals
cp $W2/errmem/patchcheck.sh $W2/errmem/patchcheck-pc2.log "$DST/patch/"
cp $E/buildneg.sh $E/buildneg-bneg2.log "$DST/patch/"
for t in A B C; do cp $E/bneg2/$t.log "$DST/patch/buildneg-$t.log"; done
# lj_err_mem as compiled: unpatched, the census's fix (the investigator's else-if), the shipped build
cp $E/census_unp_mem.dis "$DST/dis/lj_err_mem-unpatched.dis"
cp $E/census_fix_mem.dis "$DST/dis/lj_err_mem-census-fix.dis"
cp $E/lj_err_mem.dis "$DST/dis/lj_err_mem-shipped.dis"
# the census: scripts, build logs, the clamp check, the identity check, the counts, every TSV (tar.gz)
cp $C/build.sh $C/build2.sh $C/census.sh $C/job.sh $C/ident.sh $E/shipcheck.sh "$DST/census/"
cp $C/build.log $C/build2.log $C/clamp_check.txt $C/ident_nf.txt $E/census-counts.txt "$DST/census/"
(cd $C/out && tar czf "$DST/census/census-out.tar.gz" *.tsv)
# the builds, the gates (Windows and Linux) and the full suites
cp $E/build-additive.log $E/build-dropin.log $E/before.md5 $E/after.md5 "$DST/logs/"
cp /c/Users/astro/Downloads/OC-LuaJIT/build/wsl-native.log "$DST/logs/wsl-native.log"
cp $E/gatesE/*.log $E/gatesE/summary.txt $E/gatesE/objects.md5 "$DST/logs/gates/"
cp $E/wslgates/* "$DST/logs/wslgates/"
cp $W2/runsE/chain.log $W2/runsE/full.log "$DST/logs/runsE/"
for d in $W2/runsE/full/*/; do cp "$d/run.log" "$DST/logs/runsE/$(basename "$d").log"; done
cp $W2/chainE.sh $E/wsl-gates.sh $W2/../wall/gates.sh $E/archive-errmem.sh "$DST/scripts/"
find "$DST" -type f | wc -l
du -sh "$DST"
