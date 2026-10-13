#!/bin/sh
# chain-fix.sh <tag> -- the post-fix suite on the frozen new natives, three runs at a time.
set -u
T="$1"
O=/c/Users/astro/claude-tmp/oclj
RUNS=$O/runs
NEWA=$O/new-6445f2e4/libdir-additive
NEWD=$O/new-6445f2e4/libdir
SAB=$O/sabotage
F="sh $O/full.sh"
LOG=$RUNS/chain-$T.txt
[ -e "$LOG" ] && { echo "REFUSING: $LOG exists"; exit 99; }
echo "chain $T started $(date -u +%H:%M:%S)" > "$LOG"
batch() {
  for spec in "$@"; do
    # spec: name|env|native|lib|jit|only
    name=${spec%%|*}; rest=${spec#*|}
    envs=${rest%%|*}; rest=${rest#*|}
    nat=${rest%%|*}; rest=${rest#*|}
    lib=${rest%%|*}; rest=${rest#*|}
    jit=${rest%%|*}; only=${rest#*|}
    echo "  $name env=[$envs] $nat $lib $jit $only" >> "$LOG"
    ( [ -n "$envs" ] && export $envs; $F "$RUNS/$name-$T" "$nat" "$lib" "$jit" "$only"; [ -n "$envs" ] && echo "$envs" > "$RUNS/$name-$T/env.txt" ) &
  done
  wait
  for spec in "$@"; do
    name=${spec%%|*}
    echo "$name exit=$(cat "$RUNS/$name-$T/exit.txt" 2>/dev/null) $(grep -E 'CHECKS:' "$RUNS/$name-$T/work/smoke.log" 2>/dev/null)" >> "$LOG"
  done
}
batch "fix-additive-on||additive|$NEWA|on|UNSET" "fix-dropin||luajit|$NEWD|on|UNSET" "fix-stock||stock|-|on|UNSET"
batch "fix-additive-off||additive|$NEWA|off|UNSET" "fix-additive-sieve||additive|$NEWA|on|sieve" "fix-disposeoff|OCLJ_DISPOSE=off|additive|$NEWA|on|UNSET"
batch "fix-bundleoff|OCLJ_PERSIST_BUNDLE=off|additive|$NEWA|on|UNSET" "sab-onecollect|OCLJ_ARCH_SRC=$SAB/OcljArch-onecollect.scala|additive|$NEWA|on|UNSET" "sab-countafter|OCLJ_JAVA_SRC=$SAB/countafter/LuaStateLuaJIT.java|additive|$NEWA|on|UNSET"
echo "chain $T finished $(date -u +%H:%M:%S)" >> "$LOG"
touch "$RUNS/chain-$T.done"
