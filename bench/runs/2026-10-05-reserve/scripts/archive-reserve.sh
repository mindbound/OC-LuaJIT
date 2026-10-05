#!/bin/sh
# archive-reserve.sh -- THE RESERVE'S SIZE's evidence into bench/runs/2026-10-05-reserve/ (new files
# only; refuses if the directory exists).  Reports, sources, diffs, scripts and run logs; census TSVs
# as tar.gz; never the .err directories (one file per cap), binaries or work trees.
set -u
W2=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2
SC=$W2/sc
DST=/c/Users/astro/Downloads/OC-LuaJIT/bench/runs/2026-10-05-reserve
[ -e "$DST" ] && { echo "REFUSING: $DST exists"; exit 99; }
cpq() { # cpq <dest dir> <files...>: copy what exists, quietly
  d=$1; shift; mkdir -p "$d"; for f in "$@"; do [ -f "$f" ] && cp "$f" "$d/"; done; return 0; }
tsvtar() { # tsvtar <out.tar.gz> <dir>: every .tsv (incl. .class.tsv) in dir, flat
  ( cd "$2" 2>/dev/null && ls *.tsv >/dev/null 2>&1 && tar czf "$1" *.tsv ) || echo "no tsv in $2"; }
mkdir -p "$DST"
cp "$SC/README-archive.md" "$DST/README.md"
# the understanding: the absorber map, the hermetic forensics (report, the instrumented copy, its tools and
# drivers, the analyses), the in-machine forensics (runsR)
cpq "$DST/map" "$SC/map/REPORT.txt"
cpq "$DST/forensics" "$SC/forensics/REPORT.txt" "$SC/forensics"/*.sh "$SC/forensics"/*.py
cpq "$DST/forensics/src" "$SC/forensics/src/lj52shim.c" "$SC/forensics/src/lj52shim.h"
cpq "$DST/forensics/tools" "$SC/forensics/tools"/*
cpq "$DST/forensics/drv" "$SC/forensics/drv"/*.lua "$SC/forensics/drv"/*.c "$SC/forensics/drv"/*.py
cpq "$DST/forensics/analysis" "$SC/forensics/out"/*.txt
tsvtar "$DST/forensics/census-out.tar.gz" "$SC/forensics/out"
mkdir -p "$DST/logs/runsR"
cpq "$DST/logs/runsR" "$W2/runsR/an/NOTE.txt" "$W2/runsR/an/per-run.txt" "$W2/runsR/an/refusals.tsv" "$W2/runsR/chain.log" "$W2/runsR/gate.log" "$W2/runsR/reflines.txt"
for d in "$W2"/runsR/gate/*/; do cp "$d/run.log" "$DST/logs/runsR/$(basename "$d").log"; done
cpq "$DST/logs/refnative" "$SC/refnative2/shim.md5" "$SC/refnative2/natives.md5" "$SC/refnative2/build-additive.log" "$SC/refnative2/build-dropin.log"
# the design round: three designs, three judges, the synthesis; each design's diff, tests, sabotages, analyses
cpq "$DST/design" "$SC/design"/*.txt
cpq "$DST/design/lifetime" "$SC/design/lifetime/R4K.diff" "$SC/design/lifetime/L4.diff" "$SC/design/lifetime/mem_test_lt.c" "$SC/design/lifetime"/*.sh
cpq "$DST/design/lifetime/tools" "$SC/design/lifetime/tools"/*
cpq "$DST/design/lifetime/analysis" "$SC/design/lifetime/out"/*.txt
tsvtar "$DST/design/lifetime/census-out.tar.gz" "$SC/design/lifetime/out"
cpq "$DST/design/verdict" "$SC/verdict"/*.diff "$SC/verdict"/*.c "$SC/verdict"/*.sh "$SC/verdict"/*.txt
cpq "$DST/design/verdict/tools" "$SC/verdict/tools"/*
cpq "$DST/design/verdict/analysis" "$SC/verdict/out"/*.txt
cpq "$DST/design/identify" "$SC/identify"/*.diff "$SC/identify"/*.c "$SC/identify"/*.sh "$SC/identify"/*.txt
cpq "$DST/design/identify/tools" "$SC/identify/tools"/*
cpq "$DST/design/identify/analysis" "$SC/identify/out"/*.txt
# the final object: the instrumented copy of the final source, its inertness logs, the M1 census
cpq "$DST/finst" "$SC/finst/README.txt" "$SC/finst"/*.sh
cpq "$DST/finst/src" "$SC/finst/src/lj52shim.c" "$SC/finst/src/lj52shim.h"
cpq "$DST/finst/tools" "$SC/finst/tools"/*
cpq "$DST/finst/logs" "$SC/finst/logs"/*
cpq "$DST/finst/analysis" "$SC/finst/out"/*.txt
tsvtar "$DST/finst/census-out.tar.gz" "$SC/finst/out"
cpq "$DST/logs/finst-native" "$SC/finst-native/shim.md5" "$SC/finst-native/natives.md5" "$SC/finst-native/build-additive.log" "$SC/finst-native/build-dropin.log"
# the natives, the unit tests, the negative control, the smoke runs
R=$SC/R
cpq "$DST/logs/native" "$R/build-additive.log" "$R/build-dropin.log" "$R/new.md5" "$R/failfirst-old.log" "$R/mem-new-1.log" "$R/mem-new-2.log" "$R/mem-fast.log" "$R/negctl-measure.log" "$R/negctl-confirm.log" "$R/chainM.log" "$R/mt/summary.txt"
mkdir -p "$DST/logs/native/mt"; cp "$R"/mt/*.log "$DST/logs/native/mt/" 2>/dev/null
cpq "$DST/logs/native/guards" "$SC/guards1"/*/*.err
for d in smoke-recover smoke-recover2 smoke-recover-E smoke-recover-Ei rec-Ei-L1 rec-Ei-L2 rec-Ei-L3; do
  [ -f "$R/$d/run.log" ] && { mkdir -p "$DST/logs/smoke"; cp "$R/$d/run.log" "$DST/logs/smoke/$d.log"; }
done
# the in-machine gate
mkdir -p "$DST/logs/runsF"
cpq "$DST/logs/runsF" "$W2/runsF/chain.log" "$W2/runsF/gate.log" "$W2/runsF/recover.log" "$W2/runsF/matrix.log" "$W2/runsF/full.log" "$R/analyzeF.txt"
for sec in gate recover matrix full; do
  [ -d "$W2/runsF/$sec" ] || continue
  mkdir -p "$DST/logs/runsF/$sec"
  for d in "$W2/runsF/$sec"/*/; do [ -f "$d/run.log" ] && cp "$d/run.log" "$DST/logs/runsF/$sec/$(basename "$d").log"; done
done
# the scripts
cpq "$DST/scripts" "$W2/chainR.sh" "$W2/chainF.sh" "$SC/chainM.sh" "$SC/build-ref-native.sh" "$SC/build-finst-native.sh" "$SC/guards.sh" "$SC/archive-reserve.sh" "$R/analyzeF.py" "$R/fixsets.py" "$R/fixnl.py" "$W2/cap2.sh" "$W2/chainlib2.sh" "$W2/mt.sh"
find "$DST" -type f | wc -l
du -sh "$DST"
