#!/bin/sh
# post-r3.sh -- after the final Windows chain (final-r3.sh): the Linux build and suites in the Ubuntu WSL
# distro (wsl-r3.sh into logs/linux) and the final build's campaign (campaign-r3.sh into logs/campaign-2,
# Windows luajit.exe only) side by side, then gradle (gradle-r3.sh into logs/gradle: it packs the .so the
# Linux build put in build/native/dist).  No harness runs here, so nothing overlaps a JVM timing.
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
R=$REPO/bench/runs/2026-10-17-bitop
S=$R/scripts
L=$R/logs/post-chain.txt
[ -e "$L" ] && { echo "REFUSING: $L exists"; exit 99; }
echo "post-r3 started $(date -u +%H:%M:%S)" > "$L"
while [ ! -e "$R/logs/final-chain.done" ]; do sleep 15; done
echo "final chain done $(date -u +%H:%M:%S)" >> "$L"
cd "$REPO" || exit 98
( MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu -- bash /mnt/c/Users/astro/Downloads/OC-LuaJIT/bench/runs/2026-10-17-bitop/scripts/wsl-r3.sh \
    /mnt/c/Users/astro/Downloads/OC-LuaJIT/bench/runs/2026-10-17-bitop/logs/linux > "$R/logs/wsl-r3.out" 2>&1
  echo "wsl exit=$? $(date -u +%H:%M:%S)" >> "$L" ) &
WPID=$!
sh "$S/campaign-r3.sh" "$R/logs/campaign-2" > /c/Users/astro/claude-tmp/oclj/runs/campaign-r3-2.out 2>&1
echo "campaign-2 done $(date -u +%H:%M:%S): $(tr '\n' ' ' < "$R/logs/campaign-2/summary.txt")" >> "$L"
wait $WPID
sh "$S/gradle-r3.sh" "$R/logs/gradle" > /c/Users/astro/claude-tmp/oclj/runs/gradle-r3.out 2>&1
echo "gradle: $(tr '\n' ' ' < "$R/logs/gradle/summary.txt" | cut -c1-300)" >> "$L"
echo "post-r3 finished $(date -u +%H:%M:%S)" >> "$L"
touch "$R/logs/post-chain.done"
