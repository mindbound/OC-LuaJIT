#!/bin/sh
# job.sh <exe> <shape> <off> [seed]: ONE process, ONE cap (probe2, JIT on, arm, paint, junk 24, batch 10),
# pinned to the E-cores.  Prints "off<TAB>rc<TAB><the driver's TSV data line, or NOLINE>".
# rc 139 = the process died of an access violation (MSYS maps 0xC0000005 to 128+11).
D=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/errmem/census
A=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/pcore/affrun.exe
cd $D || exit 99
export LUA_PATH='?.lua' LUA_CPATH='?.dll'
[ -n "${4:-}" ] && export OCLJ_SEED=$4
out=$("$A" 3FC3FC default ./bin/$1 probe2.lua $2 $3 $3 16 384 1 1 1 0 0 -1 24 10 2>/dev/null)
rc=$?
line=$(printf '%s\n' "$out" | sed -n 2p)
[ -n "$line" ] || line=NOLINE
printf '%s\t%s\t%s\n' "$3" "$rc" "$line"
