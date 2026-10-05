#!/bin/sh
# job2.sh <exe> <shape> <off> <jit> <errdir|-> <probe.lua> <hb> [seed]  (job.sh with the probe file and the heartbeat exposed)
# ONE process, ONE cap, the census's argument list with the JIT switch exposed:
#   probe2.lua <shape> <off> <off> 16 384 <jit> 1 1 0 0 -1 24 10
# (arm, paint, no heartbeat, no control, measure at the terminal event,
# junk 24, the amplified batch 10), pinned to the E-cores.  Prints
# "off<TAB>rc<TAB><the driver's TSV data line, or NOLINE>"; stderr goes to
# <errdir>/<off>.err (or is discarded for "-").  OCLJ_REFLOG is inherited.
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/forensics
A=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/pcore/affrun.exe
cd $WD/drv || exit 99
export LUA_PATH='?.lua' LUA_CPATH='?.dll'
[ -n "${8:-}" ] && export OCLJ_SEED=$8
if [ "$5" = "-" ]; then E=/dev/null; else E=$5/$3.err; fi
out=$("$A" 3FC3FC default $WD/bin/$1 $6 $2 $3 $3 16 384 $4 1 1 $7 0 -1 24 10 2>"$E")
rc=$?
line=$(printf '%s\n' "$out" | sed -n 2p)
[ -n "$line" ] || line=NOLINE
printf '%s\t%s\t%s\n' "$3" "$rc" "$line"
