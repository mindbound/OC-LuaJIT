#!/bin/sh
# run.sh — checksum-verified Lua VM benchmark harness.
# usage: sh run.sh all            # measure every VM, then report
#        sh run.sh measure <vm>   # vm in: lua5.3 lua5.4 luajit luajit-joff
#        sh run.sh report         # verify checksums + emit results markdown
# env:   RUNS=5  BENCHES="sha256 ..."
set -u
BENCHDIR=$(cd "$(dirname "$0")" && pwd)
cd "$BENCHDIR" || exit 1
export PATH="/c/mingw64/bin:$PATH"
export LUA_PATH="./?.lua;;"

LUA53="$BENCHDIR/vendor/lua-5.3.6/src/lua.exe"
LUA54="$BENCHDIR/vendor/lua-5.4.8/src/lua.exe"
LUAJIT="C:/Users/astro/Downloads/OC-LuaJIT/prototype/LuaJIT/src/luajit.exe"

RUNS="${RUNS:-5}"
BENCHES="${BENCHES:-sha256 mandelbrot matmul nqueens sieve binarytrees strings trampoline}"
VMS="lua5.3 lua5.4 luajit luajit-joff"
RAWDIR="$BENCHDIR/raw"
OUT="$BENCHDIR/results-2026-09-01.md"
mkdir -p "$RAWDIR"

vm_cmd() {
  case "$1" in
    lua5.3)      printf '%s' "$LUA53" ;;
    lua5.4)      printf '%s' "$LUA54" ;;
    luajit)      printf '%s' "$LUAJIT" ;;
    luajit-joff) printf '%s -joff' "$LUAJIT" ;;
    *) echo "unknown vm: $1" >&2; exit 2 ;;
  esac
}

measure() {
  vm="$1"
  cmd=$(vm_cmd "$vm")
  out="$RAWDIR/$vm.tsv"
  : > "$out"
  for b in $BENCHES; do
    r=1
    while [ "$r" -le "$RUNS" ]; do
      res=$($cmd "$b.lua" 2>&1)
      check=$(printf '%s\n' "$res" | tr -d '\r' | sed -n 's/^CHECK //p' | head -n1)
      tm=$(printf '%s\n' "$res" | tr -d '\r' | sed -n 's/^TIME //p' | head -n1)
      if [ -n "$check" ] && [ -n "$tm" ]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$vm" "$b" "$r" "$check" "$tm" >> "$out"
      else
        reason=$(printf '%s' "$res" | tr '\r\n\t' '   ' | cut -c1-200)
        printf '%s\t%s\t%s\tDNF\tDNF\t%s\n' "$vm" "$b" "$r" "$reason" >> "$out"
        echo "DNF: $vm/$b: $reason" >&2
        break
      fi
      r=$((r + 1))
    done
    echo "measured: $vm $b"
  done
}

report() {
  CPU=$( (grep -m1 'model name' /proc/cpuinfo 2>/dev/null || true) | sed 's/^.*: *//' )
  if [ -z "$CPU" ]; then
    CPU=$(powershell -NoProfile -Command '(Get-CimInstance Win32_Processor).Name' 2>/dev/null | tr -d '\r' | head -n1)
  fi
  GCCV=$(gcc --version 2>/dev/null | head -n1 | tr -d '\r')
  V53=$("$LUA53" -v 2>&1 | head -n1 | tr -d '\r')
  V54=$("$LUA54" -v 2>&1 | head -n1 | tr -d '\r')
  VJ=$("$LUAJIT" -v 2>&1 | head -n1 | tr -d '\r')

  {
    echo "# Lua VM benchmark — OpenComputers compute-bound workloads"
    echo
    echo "Date: 2026-09-01. Baseline: lua5.3 (GTNH OpenComputers default CPU architecture)."
    echo
    echo "## Machine"
    echo
    echo "- CPU: $CPU"
    echo "- OS: Windows 11 (Git Bash harness)"
    echo "- Compiler used for the interpreters: $GCCV"
    echo "- lua5.3: $V53"
    echo "- lua5.4: $V54"
    echo "- luajit: $VJ"
    echo "- luajit-joff: same LuaJIT binary run with \`-joff\` (JIT disabled, interpreter only)"
    echo
  } > "$OUT"

  awk -F'\t' -v benches="$BENCHES" -v runs="$RUNS" '
  {
    vm = $1; b = $2; run = $3; ck = $4; t = $5
    i = ++cnt
    V[i] = vm; B[i] = b; R[i] = run; CK[i] = ck
    if (ck != "DNF") {
      key = vm SUBSEP b
      if (!(key in min) || t + 0 < min[key]) min[key] = t + 0
      if (vm == "lua5.3" && !(b in ref)) ref[b] = ck
    } else {
      dnf[vm SUBSEP b] = $6
    }
  }
  END {
    nb = split(benches, BL, " ")
    nv = split("lua5.3 lua5.4 luajit luajit-joff", VL, " ")
    for (i = 1; i <= cnt; i++)
      if (CK[i] != "DNF" && !(B[i] in ref)) ref[B[i]] = CK[i]
    mism = 0
    for (i = 1; i <= cnt; i++) {
      if (CK[i] == "DNF") continue
      if (CK[i] != ref[B[i]]) {
        mism++
        msg = sprintf("CHECKSUM MISMATCH: vm=%s bench=%s run=%s got=[%s] want=[%s]", V[i], B[i], R[i], CK[i], ref[B[i]])
        print msg > "/dev/stderr"
        mlist[mism] = msg
      }
    }
    print "## Checksums"
    print ""
    if (mism == 0) {
      print "All CHECK values byte-identical across all VMs and all runs. Reference values (from lua5.3):"
      print ""
      for (bi = 1; bi <= nb; bi++) printf "- %s: `%s`\n", BL[bi], ref[BL[bi]]
    } else {
      print "**MISMATCHES DETECTED — results below are NOT trustworthy:**"
      print ""
      for (i = 1; i <= mism; i++) print "- " mlist[i]
    }
    print ""
    print "## Results (min of " runs " runs, seconds; speedup = lua5.3 time / VM time)"
    print ""
    print "| benchmark | lua5.3 (s) | lua5.4 (s) | lua5.4 | luajit (s) | luajit | luajit -joff (s) | -joff |"
    print "|---|---:|---:|---:|---:|---:|---:|---:|"
    for (bi = 1; bi <= nb; bi++) {
      b = BL[bi]
      bk = "lua5.3" SUBSEP b
      base = (bk in min) ? min[bk] : -1
      row = "| " b " |"
      for (vi = 1; vi <= nv; vi++) {
        vm = VL[vi]; key = vm SUBSEP b
        if (key in min) {
          tt = min[key]
          ct = (tt > 0.0005) ? tt : 0.0005   # clamp for ratio (clock resolution)
          if (vi == 1) row = row sprintf(" %.3f |", tt)
          else if (base > 0) row = row sprintf(" %.3f | %.2fx |", tt, base / ct)
          else row = row sprintf(" %.3f | n/a |", tt)
        } else {
          if (vi == 1) row = row " DNF |"
          else row = row " DNF | — |"
        }
      }
      print row
    }
    # geometric mean of speedups vs lua5.3, excluding trampoline
    row = "| **geomean (excl. trampoline)** | — |"
    for (vi = 2; vi <= nv; vi++) {
      vm = VL[vi]; lg = 0; k = 0; missing = 0
      for (bi = 1; bi <= nb; bi++) {
        b = BL[bi]
        if (b == "trampoline") continue
        k1 = vm SUBSEP b; k0 = "lua5.3" SUBSEP b
        if ((k1 in min) && (k0 in min) && min[k0] > 0) {
          ct = (min[k1] > 0.0005) ? min[k1] : 0.0005
          lg += log(min[k0] / ct); k++
        } else missing++
      }
      if (k > 0) row = row sprintf(" — | **%.2fx**%s |", exp(lg / k), (missing ? " (partial)" : ""))
      else row = row " — | DNF |"
    }
    print row
    print ""
    # trampoline callout
    tb = "trampoline"
    k0 = "lua5.3" SUBSEP tb
    if (k0 in min) {
      print "## Trampoline anti-benchmark (reported separately, excluded from geomean)"
      print ""
      printf "pcall + vararg-forwarding trampolines per call, as in the OC sandbox spcall wrappers.\n\n"
      for (vi = 2; vi <= nv; vi++) {
        vm = VL[vi]; k1 = vm SUBSEP tb
        if (k1 in min) {
          ct = (min[k1] > 0.0005) ? min[k1] : 0.0005
          printf "- %s: %.3f s vs lua5.3 %.3f s => %.2fx\n", vm, min[k1], min[k0], min[k0] / ct
        } else printf "- %s: DNF\n", vm
      }
      print ""
    }
    # DNF notes
    ndnf = 0
    for (key in dnf) ndnf++
    if (ndnf > 0) {
      print "## DNF details"
      print ""
      for (bi = 1; bi <= nb; bi++) for (vi = 1; vi <= nv; vi++) {
        key = VL[vi] SUBSEP BL[bi]
        if (key in dnf) printf "- %s / %s: %s\n", VL[vi], BL[bi], dnf[key]
      }
      print ""
    }
    exit (mism > 0 ? 1 : 0)
  }' "$RAWDIR"/*.tsv >> "$OUT"
  status=$?

  {
    echo "## Method / caveats"
    echo
    echo "- Timing: \`os.clock()\` inside each benchmark around the measured kernel only (setup/data generation excluded). On Windows, C \`clock()\` is wall-clock milliseconds since process start; machine otherwise idle. Resolution ~1 ms."
    echo "- Best-of-$RUNS minimum per (VM, benchmark); identical iteration counts and identical Lua sources for every VM."
    echo "- Bit ops go through \`compat.lua\`: LuaJIT uses its built-in \`bit\` library; 5.3/5.4 use native operators masked to 32 bits, so all VMs produce byte-identical checksums."
    echo "- Standalone upper bound: no OpenComputers sandbox, no \`debug.sethook\` instruction-count throttling, no component-call overhead. In-game deltas will be smaller."
    echo "- \`trampoline\` is deliberately JIT-hostile (every call crosses pcall + vararg forwarding, like OC spcall wrappers) and is excluded from the geomean."
  } >> "$OUT"

  if [ "$status" -ne 0 ]; then
    echo "CHECKSUM VERIFICATION FAILED — see mismatches above and in $OUT" >&2
    exit 1
  fi
  echo "report written: $OUT"
}

case "${1:-all}" in
  measure) measure "$2" ;;
  report)  report ;;
  all)
    for vm in $VMS; do measure "$vm"; done
    report
    ;;
  *) echo "usage: run.sh [all|measure <vm>|report]" >&2; exit 2 ;;
esac
