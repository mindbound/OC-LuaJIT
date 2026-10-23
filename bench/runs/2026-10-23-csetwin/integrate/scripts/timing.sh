#!/bin/sh
# timing.sh <fresh outdir> [rounds] -- the CSE round's smoke timing (design
# 4.6): build/native's luajit.exe (base, lj_opt_fold.o f6d916e2) against
# integrate/b1's (new, hunk 12, lj_opt_fold.o a6c5fcc2; the two builds'
# other 79 objects are equal), alternating the order each round, on
# bench_bit.lua 2e7 (bit, ref, crc), bench_bit2.lua 1e7 (rgb, ref,
# crc-table), ident.lua 1e7 time (ten identity rows) and bench_numconv.lua
# 2e7 (five rows), each row the best of 3 inside its process.  Refuses an
# existing outdir (rc 99) and a running java or javaw (rc 97); stops between
# rounds if one appears (STOPPED, rc 96).  Records inputs.md5, the CPU load
# and the process list before and after, raw.txt (one line per bench output
# line: round= pos= vm= bench=), progress.txt; summary.txt by
# timing-summ.py; timing.done last.  Rounds default 8.  No backslashes.
set -u
I=/c/Users/astro/claude-tmp/oclj/csetwin/round/integrate
O=${1:?usage: timing.sh <fresh outdir> [rounds]}
NR=${2:-8}
[ -e "$O" ] && { echo "REFUSING: $O exists"; exit 99; }
BLJ=/c/Users/astro/Downloads/OC-LuaJIT/build/native/luajit-windows-x86_64/src/luajit.exe
NLJ=$I/b1/luajit-windows-x86_64/src/luajit.exe
BENCH=$I/timing/bench
javacheck() { tasklist 2>/dev/null | grep -i -E 'java(w)?[.]exe' > "$1"; [ -s "$1" ]; }
mkdir -p "$O" || exit 98
if javacheck "$O/jvms-start.txt"; then echo "REFUSING: a java or javaw process is running (jvms-start.txt)"; exit 97; fi
unset LUA_INIT LUA_INIT_5_3 LUA_PATH LUA_CPATH
md5sum "$BLJ" "$NLJ" /c/Users/astro/Downloads/OC-LuaJIT/build/native/luajit-windows-x86_64/src/lj_opt_fold.o "$I/b1/luajit-windows-x86_64/src/lj_opt_fold.o" "$BENCH"/*.lua > "$O/inputs.md5"
powershell -NoProfile -Command "(Get-CimInstance Win32_Processor).LoadPercentage" > "$O/cpuload-before.txt" 2>/dev/null
tasklist > "$O/procs-before.txt" 2>/dev/null
r=1; stopped=0
while [ "$r" -le "$NR" ]; do
  if javacheck "$O/jvms-round-$r.txt"; then
    { echo "STOPPED before round $r: a Java process started"; cat "$O/jvms-round-$r.txt"; } > "$O/STOPPED"
    stopped=1; break
  fi
  if [ $((r % 2)) = 1 ]; then ORDER="base new"; else ORDER="new base"; fi
  p=1
  for v in $ORDER; do
    if [ "$v" = base ]; then E=$BLJ; else E=$NLJ; fi
    for b in "bench_bit.lua 2e7" "bench_bit2.lua 1e7" "ident.lua 1e7 time" "bench_numconv.lua 2e7"; do
      n=${b%%.lua*}
      ( cd "$BENCH" && "$E" $b 2>&1 ) | awk -v r="$r" -v p="$p" -v v="$v" -v n="$n" '{ sub(/[[:cntrl:]]+$/, ""); print "round=" r " pos=" p " vm=" v " bench=" n ": " $0 }' >> "$O/raw.txt"
    done
    p=$((p + 1))
  done
  echo "round $r done $(date -u +%H:%M:%SZ) order: $ORDER" >> "$O/progress.txt"
  r=$((r + 1))
done
powershell -NoProfile -Command "(Get-CimInstance Win32_Processor).LoadPercentage" > "$O/cpuload-after.txt" 2>/dev/null
tasklist > "$O/procs-after.txt" 2>/dev/null
python -I "$I/scripts/timing-summ.py" "$O/raw.txt" "$NR" > "$O/summary.txt" 2>&1
echo $? > "$O/summary.rc"
echo "stopped=$stopped" > "$O/timing.done"
cat "$O/summary.txt"
[ "$stopped" = 0 ] || exit 96
exit 0
