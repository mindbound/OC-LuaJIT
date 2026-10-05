#!/bin/sh
# negrun.sh <log> -- negative-control.sh alone, with the wall's environment
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall/env.sh
cd /c/Users/astro/Downloads/OC-LuaJIT || exit 97
[ -e "$1" ] && { echo "REFUSING: $1 exists"; exit 99; }
sh test/native/negative-control.sh > "$1" 2>&1
echo "exit=$?" >> "$1"
