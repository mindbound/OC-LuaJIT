#!/bin/sh
# archive-window.sh -- THE WINDOW's evidence into bench/runs/2026-10-05-window/ (new files only).
set -u
W2=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2
DST=/c/Users/astro/Downloads/OC-LuaJIT/bench/runs/2026-10-05-window
[ -e "$DST" ] && { echo "REFUSING: $DST exists"; exit 99; }
mkdir -p "$DST/design" "$DST/logs" "$DST/scripts" "$DST/repro" "$DST/crash" "$DST/review" "$DST/analysis"
cp $W2/README-archive.md "$DST/README.md"
# the design round: requirements, surveys, designs, verdicts, synthesis
cp $W2/design/REQUIREMENTS.md $W2/design/u2-*.md $W2/design/d2-*.md $W2/design/j2-*.md "$DST/design/"
# the code review and the unwinder crash
cp $W2/review/findings.json "$DST/review/"
cp $W2/crash/report.md "$DST/crash/report.md"; cp $W2/crash-verify/verdict.md "$DST/crash/verdict.md"
cp $W2/crash/patch-fastfunc-errmem-top.sh "$DST/crash/"
# the hermetic reproduction's sources (u2-repro.md)
for f in lj_repro.c probe2.lua probe3.lua w16probe.lua puc_repro.c traj.c model.py sitepass.py build.sh robust.sh mkinstr.py mkring.py mkfull.py mkw16.py mklend.py mklend2.py; do
  [ -f "$W2/repro/$f" ] && cp "$W2/repro/$f" "$DST/repro/"
done
# the in-machine chains: chain logs and every run's harness log
for c in runsG runsT runsV; do
  [ -d "$W2/$c" ] || continue
  mkdir -p "$DST/logs/$c"
  cp $W2/$c/*.log "$DST/logs/$c/" 2>/dev/null
  for sec in "$W2/$c"/*/; do
    s=$(basename "$sec"); mkdir -p "$DST/logs/$c/$s"
    for d in "$sec"*/; do [ -f "$d/run.log" ] && cp "$d/run.log" "$DST/logs/$c/$s/$(basename "$d").log"; done
  done
done
# mem_test and the gates
mkdir -p "$DST/logs/mem" "$DST/logs/gates"
cp -r $W2/W/mt1 "$DST/logs/mem/W-mt1" && rm -rf "$DST/logs/mem/W-mt1"/build-*
cp -r $W2/W2/mt1 "$DST/logs/mem/W2-mt1" && rm -rf "$DST/logs/mem/W2-mt1"/build-*
cp -r $W2/W2/mt2 "$DST/logs/mem/W2-mt2" && rm -rf "$DST/logs/mem/W2-mt2"/build-*
for g in W/gatesW W2/gatesW2; do
  n=$(basename $g); mkdir -p "$DST/logs/gates/$n"
  cp $W2/$g/*.log $W2/$g/summary.txt $W2/$g/objects.md5 "$DST/logs/gates/$n/" 2>/dev/null
done
cp $W2/W2/negctl-1.log "$DST/logs/gates/negctl-measure.log"
cp $W2/an/*.txt "$DST/analysis/" 2>/dev/null
# the launchers and chains
cp $W2/cap2.sh $W2/chainlib2.sh $W2/chainG.sh $W2/chainT.sh $W2/chainV.sh $W2/mt.sh $W2/negrun.sh $W2/archive-window.sh "$DST/scripts/"
find "$DST" -type f | wc -l
du -sh "$DST"
