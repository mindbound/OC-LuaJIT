#!/bin/sh
# ffall-r3.sh -- the native fail-firsts (ff-r3.sh), then the harness fail-first (chain-r3ff.sh a, on
# new-r2-0f55e727), one after the other so that no JVM overlaps the native suites.
set -u
S=/c/Users/astro/Downloads/OC-LuaJIT/bench/runs/2026-10-17-bitop/scripts
O=/c/Users/astro/claude-tmp/oclj
sh "$S/ff-r3.sh" > "$O/runs/ff-r3.out" 2>&1
sh "$S/chain-r3ff.sh" a "$O/new-r2-0f55e727" > "$O/runs/chain-r3ff-a.out" 2>&1
touch "$O/runs/ffall-r3.done"
