#!/bin/sh
# chainlib2.sh -- sourced by THE WINDOW's chains: run2() and the paths.
W=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall
W2=$W/../wall2
A=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/pcore/affrun.exe
SH="C:/Program Files/Git/usr/bin/sh.exe"
CAP2=$(cygpath -m $W2/cap2.sh)
FULL=$(cygpath -m $W/full.sh)
CADD=$(cygpath -m $W/C/libdir-additive)      # stage C, the positive control
CDROP=$(cygpath -m $W/C/libdir-dropin)
WADD=$(cygpath -m $W2/W/libdir-additive)     # THE WINDOW
WDROP=$(cygpath -m $W2/W/libdir-dropin)
REPO=/c/Users/astro/Downloads/OC-LuaJIT
run2() { # name native libdir jit early tier scale shape batch junk   (LOG and RUNS set by the chain)
  D=$RUNS/$1
  "$A" C03C03 default "$SH" "$CAP2" "$(cygpath -m $D)" $2 "$3" $4 $5 $6 $7 $8 $9 ${10} > /dev/null 2>&1
  cls=$(grep -oE 'CAP-X\| .* class=[A-Z-]+' $D/run.log | grep -oE 'class=[A-Z-]+' | cut -d= -f2)
  if [ -z "$cls" ]; then
    # A JVM crash dump is a process death whatever else the log says; a failed
    # boot milestone means BOOT-FAIL only when the probe never printed its
    # CAPACITY line (the probe still runs after a failed milestone).
    if ls $D/hs_err_pid*.log > /dev/null 2>&1; then cls=PROC-DEATH
    elif grep -qE 'MILESTONE (c-openos-shell|d-autorun-counter-live): FAIL' $D/run.log && ! grep -q 'CAPACITY|' $D/run.log; then cls=BOOT-FAIL
    elif [ "$(cat $D/exit.txt 2>/dev/null)" != "0" ]; then cls=PROC-DEATH
    else cls=NOCAPX; fi
  fi
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null) CLASS=$cls $(grep -E 'SMOKE\| CAPACITY\|' $D/run.log | cut -c9-)" >> $LOG
  grep -E 'SMOKE\| CAP-(IDLE|LIVE|GC|X)\|' $D/run.log | sed "s/^SMOKE| /    $1 /" >> $LOG
  grep -E 'MILESTONE (cap-1|km-1)' $D/run.log | sed "s/^/    $1 /" >> $LOG
  ls $D/hs_err_pid*.log > /dev/null 2>&1 && echo "    $1 HS_ERR $(ls $D/hs_err_pid*.log)" >> $LOG
}
