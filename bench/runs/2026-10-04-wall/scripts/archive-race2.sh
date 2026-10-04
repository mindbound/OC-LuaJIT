#!/bin/sh
# archive-race2.sh -- the race evidence after archive-race.sh: the dropin's JIT-off baseline, the
# final fix and race-2, the race-2 batch, the final-tree check; and the launchers as they ended up
# (race.sh, racechain.sh and chainJ.sh gained the phase and the native, backward-compatibly).
set -u
W=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall
DST=/c/Users/astro/Downloads/OC-LuaJIT/bench/runs/2026-10-04-wall
for c in runsJdpre runsF runsH runsZ; do
  [ -e "$DST/logs/race/$c" ] && { echo "REFUSING: logs/race/$c exists"; exit 99; }
  mkdir -p "$DST/logs/race/$c"
  cp "$W/$c/chain.log" "$DST/logs/race/$c/chain.log"
  for d in "$W/$c"/*/; do cp "$d/run.log" "$DST/logs/race/$c/$(basename "$d").log"; done
done
for s in chainF.sh chainZ.sh archive-race2.sh; do
  [ -e "$DST/scripts/$s" ] && { echo "REFUSING: scripts/$s exists"; exit 98; }
  cp "$W/$s" "$DST/scripts/$s"
done
for s in race.sh racechain.sh chainJ.sh; do cp "$W/$s" "$DST/scripts/$s"; done
find "$DST/logs/race" -type f | wc -l
du -sh "$DST/logs/race"
