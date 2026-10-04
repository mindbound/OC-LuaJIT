#!/bin/sh
# archive-race.sh -- copy the race-1 evidence into the repo's 2026-10-04 archive (new files only)
set -u
W=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall
DST=/c/Users/astro/Downloads/OC-LuaJIT/bench/runs/2026-10-04-wall
[ -e "$DST/logs/race" ] && { echo "REFUSING: $DST/logs/race exists"; exit 99; }
for c in runsR runsR2 runsR3 runsRF runsJpre runsJpost runsRfinal; do
  mkdir -p "$DST/logs/race/$c"
  [ -e "$W/$c/chain.log" ] && cp "$W/$c/chain.log" "$DST/logs/race/$c/chain.log"
  for d in "$W/$c"/*/; do
    n=$(basename "$d")
    cp "$d/run.log" "$DST/logs/race/$c/$n.log"
  done
done
for s in race.sh racechain.sh chainRF.sh chainJ.sh archive-race.sh; do
  [ -e "$DST/scripts/$s" ] && { echo "REFUSING: scripts/$s exists"; exit 98; }
  cp "$W/$s" "$DST/scripts/$s"
done
find "$DST/logs/race" -type f | sort
du -sh "$DST/logs/race"
