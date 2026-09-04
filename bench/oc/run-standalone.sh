#!/bin/sh
# =====================================================================
# bench/oc/run-standalone.sh -- run the IN-MACHINE benchmark suite OUTSIDE
# the machine, on every VM, and refuse to pass if the answers disagree.
#
# The files in this directory are written for the OpenComputers sandbox: they
# `return check, seconds` instead of printing, they take no arguments, and they
# get their bit-ops module from the global _G.__OCLJ_COMPAT because require()
# cannot see the machine's disk.  That makes them awkward to run by hand, which
# is exactly why they need a runner: an unrunnable benchmark is one nobody
# re-checks, and a reference value nobody re-checks rots.
#
# This script loads each one THE WAY THE MACHINE DOES -- read the source, plain
# load(src), call with no arguments, compat published as a global, and
# io/print/collectgarbage/require/dofile/loadfile/arg plus everything in `os`
# except os.clock removed for the duration of the call -- so a pass here is
# evidence about the file that will actually be planted, not about a
# convenience wrapper that is easier to satisfy than the sandbox is.
#
# usage: sh run-standalone.sh            # same as `check`
#        sh run-standalone.sh check      # CHECK + times on every VM, verified
#        sh run-standalone.sh peaks      # re-measure the peak-KB column
#        sh run-standalone.sh gates      # the checks/ gates (see below)
#        sh run-standalone.sh all        # gates, then peaks, then check
#
# env:   RUNS=3            timed runs per (VM, benchmark); the MINIMUM is
#                          reported, one fresh process per run
#        BENCHES="a b"     restrict to these names
#        VMS="luajit ..."  from: luajit luajit-joff lua5.3 lua5.4
#        OCLJ_LUAJIT / OCLJ_LUA53 / OCLJ_LUA54   override VM paths
#        PEAK_IV=10000     peak probe count-hook interval, in instructions
#
# EXIT 1 IF ANY OF:
#   * a benchmark errors, or returns something other than (string, number);
#   * a CHECK disagrees with references.txt;
#   * a CHECK disagrees between VMs, or between runs on one VM;
#   * a .lua here has no line in references.txt, or a line has no .lua.
# The last one is the boring failure that actually happens: the harness runs
# what references.txt lists (test/native/OcljSmoke.scala), so a benchmark added
# without a reference line is silently never measured in-machine, and a
# reference line without a file is silently skipped.
#
# THE TIMINGS HERE ARE A STANDALONE UPPER BOUND, not the in-machine numbers:
# no sandbox, no deadline hook, no per-allocation RAM accounting, and os.clock
# is C clock() at about 1 ms resolution rather than machine.cpuTime at
# nanoseconds.  They exist to prove the suite still computes the right answers
# at a sane cost before it is worth spending an emulator run on it.
# =====================================================================
set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"

LUAJIT="${OCLJ_LUAJIT:-$OCLJ_REPO/build/native/luajit/src/luajit.exe}"
LUA53="${OCLJ_LUA53:-$OCLJ_REPO/bench/vendor/lua-5.3.6/src/lua.exe}"
LUA54="${OCLJ_LUA54:-$OCLJ_REPO/bench/vendor/lua-5.4.8/src/lua.exe}"
[ -x "$LUAJIT" ] || LUAJIT="${LUAJIT%.exe}"
[ -x "$LUA53" ]  || LUA53="${LUA53%.exe}"
[ -x "$LUA54" ]  || LUA54="${LUA54%.exe}"

RUNS="${RUNS:-3}"
PEAK_IV="${PEAK_IV:-10000}"
REFS="$SELF_DIR/references.txt"
# luajit and luajit-joff are the same binary, and that pair is the point of the
# suite: "the JIT is worth Nx" is a claim about that binary against ITSELF.
# lua5.3 stands in for the PUC 5.2 a player runs today.
VMS="${VMS:-luajit luajit-joff lua5.3}"

vm_cmd() {
  case "$1" in
    luajit)      printf '%s' "$LUAJIT" ;;
    luajit-joff) printf '%s -joff' "$LUAJIT" ;;
    lua5.3)      printf '%s' "$LUA53" ;;
    lua5.4)      printf '%s' "$LUA54" ;;
    *) echo "unknown vm: $1" >&2; exit 2 ;;
  esac
}

# --- the drivers -----------------------------------------------------
# Written to a scratch dir rather than kept in this directory, because
# OcljSmoke.scala plants EVERY *.lua from bench/oc/ onto the machine disk; a
# helper living here would be shipped into the sandbox for no reason.
WORK="${TMPDIR:-/tmp}/ocljbench.$$"
mkdir -p "$WORK" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

cat > "$WORK/driver.lua" <<'DRIVER'
-- driver.lua <benchdir> <name> -- load one benchmark the way the in-machine
-- driver (the autorun.lua embedded in OcljSmoke.scala) loads it, then print
-- CHECK / TIME / COMPAT for the shell to parse.
local dir, name = arg[1], arg[2]
local function slurp(p)
  local f = io.open(p, "rb"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end
local src = assert(slurp(dir .. "/" .. name .. ".lua"), "no benchmark " .. tostring(name))
local csrc = assert(slurp(dir .. "/compat.lua"), "no compat.lua")
_G.__OCLJ_COMPAT = assert(load(csrc, "=compat"))()
local cpath = tostring(_G.__OCLJ_COMPAT.path)
local fn, lerr = load(src, "=" .. name)
if not fn then print("ERROR load: " .. tostring(lerr)); os.exit(1) end
local out, fmt = print, string.format
-- The sandbox denials, so that a pass here is a pass in the machine too.
local DENIED = {"io", "print", "collectgarbage", "require", "dofile", "loadfile", "arg"}
local saved, realos = {}, _G.os
for _, k in ipairs(DENIED) do saved[k] = _G[k]; _G[k] = nil end
_G.os = {clock = realos.clock}   -- os.clock is machine.cpuTime in the sandbox
local ok, a, b = pcall(fn)
_G.os = realos
for _, k in ipairs(DENIED) do _G[k] = saved[k] end
if not ok then out("ERROR " .. tostring(a)); os.exit(1) end
if type(a) ~= "string" then out("ERROR first return is " .. type(a) .. ", must be a string"); os.exit(1) end
if type(b) ~= "number" then out("ERROR second return is " .. type(b) .. ", must be seconds"); os.exit(1) end
out("CHECK " .. a)
out(fmt("TIME %.4f", b))
out("COMPAT " .. cpath)
DRIVER

cat > "$WORK/peak.lua" <<'PEAK'
-- peak.lua <benchdir> <name> <interval> -- peak Lua heap, in KB.
-- MUST run under `luajit -joff`.  With the JIT on this measures the compiler
-- instead of the workload (trace objects are charged to the same heap) and the
-- count hook itself inflates the run by an order of magnitude.
local dir, name, iv = arg[1], arg[2], tonumber(arg[3] or 10000)
local function slurp(p)
  local f = io.open(p, "rb"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end
local src = assert(slurp(dir .. "/" .. name .. ".lua"))
local csrc = assert(slurp(dir .. "/compat.lua"))
_G.__OCLJ_COMPAT = assert(load(csrc, "=compat"))()
local fn = assert(load(src, "=" .. name))
local cg, fmt, out = collectgarbage, string.format, print
cg("collect"); cg("collect")
local base = cg("count")
local peak = base
debug.sethook(function()
  local c = cg("count")
  if c > peak then peak = c end
end, "", iv)
local ok, a = pcall(fn)
debug.sethook()
if not ok then out("ERROR " .. tostring(a)); os.exit(1) end
out(fmt("PEAK %.1f BASE %.1f DELTA %.1f", peak, base, peak - base))
PEAK

# --- what to run -----------------------------------------------------
[ -f "$REFS" ] || { echo "FATAL: no $REFS" >&2; exit 1; }

FILES=$(cd "$SELF_DIR" && for f in *.lua; do
          [ "$f" = "compat.lua" ] && continue
          printf '%s\n' "${f%.lua}"
        done | sort)
LISTED=$(sed 's/#.*//' "$REFS" | awk 'NF >= 2 { sub(/^!/, "", $1); print $1 }' | sort)

drift=0
for n in $FILES; do
  printf '%s\n' "$LISTED" | grep -qx -- "$n" || {
    echo "DRIFT: $n.lua is here but has no line in references.txt -- the harness will never run it" >&2
    drift=1
  }
done
for n in $LISTED; do
  printf '%s\n' "$FILES" | grep -qx -- "$n" || {
    echo "DRIFT: references.txt lists $n but $n.lua is missing" >&2
    drift=1
  }
done

BENCHES="${BENCHES:-$(printf '%s' "$FILES" | tr '\n' ' ')}"

ref_of() {
  sed 's/#.*//' "$REFS" |
    awk -v n="$1" 'NF >= 2 { k = $1; sub(/^!/, "", k); if (k == n) { print $2; exit } }'
}
peak_of() {
  sed 's/#.*//' "$REFS" |
    awk -v n="$1" 'NF >= 3 { k = $1; sub(/^!/, "", k); if (k == n) { print $3; exit } }'
}

# --- check -----------------------------------------------------------
do_check() {
  raw="$WORK/raw.tsv"
  : > "$raw"
  fail=0

  CKW=8
  for b in $BENCHES; do
    r=$(ref_of "$b"); l=${#r}
    [ "$l" -gt "$CKW" ] && CKW=$l
  done
  FMT="%-12s %-12s %-${CKW}s %8s\n"

  echo "suite:    $BENCHES"
  echo "VMs:      $VMS   (min of $RUNS runs, one fresh process per run)"
  echo "refs:     $REFS"
  echo
  # shellcheck disable=SC2059
  printf "$FMT" benchmark vm CHECK sec
  for b in $BENCHES; do
    want=$(ref_of "$b")
    if [ -z "$want" ]; then
      echo "FAIL: $b has no reference value" >&2; fail=1; continue
    fi
    for vm in $VMS; do
      cmd=$(vm_cmd "$vm")
      best=""; got=""; err=""
      r=1
      while [ "$r" -le "$RUNS" ]; do
        res=$($cmd "$WORK/driver.lua" "$SELF_DIR" "$b" 2>&1)
        ck=$(printf '%s\n' "$res" | tr -d '\r' | sed -n 's/^CHECK //p' | head -n1)
        tm=$(printf '%s\n' "$res" | tr -d '\r' | sed -n 's/^TIME //p' | head -n1)
        cp=$(printf '%s\n' "$res" | tr -d '\r' | sed -n 's/^COMPAT //p' | head -n1)
        if [ -z "$ck" ] || [ -z "$tm" ]; then
          err=$(printf '%s' "$res" | tr '\r\n\t' '   ' | cut -c1-160)
          break
        fi
        # A CHECK that moves BETWEEN RUNS OF ONE VM is worse than a wrong one:
        # it means the benchmark is not a function of its source alone.
        if [ -n "$got" ] && [ "$ck" != "$got" ]; then
          err="unstable CHECK on $vm: run $r gave [$ck], earlier runs gave [$got]"
          break
        fi
        got="$ck"
        if [ -z "$best" ] || awk -v x="$tm" -v y="$best" 'BEGIN { exit !(x + 0 < y + 0) }'; then
          best="$tm"
        fi
        r=$((r + 1))
      done
      if [ -n "$err" ]; then
        # shellcheck disable=SC2059
        printf "$FMT" "$b" "$vm" "DNF" "-"
        echo "  FAIL: $b/$vm: $err" >&2
        fail=1
        continue
      fi
      # shellcheck disable=SC2059
      printf "$FMT" "$b" "$vm" "$got" "$best"
      printf '%s\t%s\t%s\t%s\n' "$b" "$vm" "$got" "$best" >> "$raw"
      if [ "$got" != "$want" ]; then
        echo "  FAIL: $b/$vm CHECK [$got] != references.txt [$want]" >&2
        fail=1
      fi
      # compat.lua is PINNED to native bitwise operators; a VM that falls back
      # to bit32 is running a different implementation and its seconds are not
      # comparable with the rest of the column.  sha256 is the only row here
      # that reads compat at all, so this is a warning, not a failure.
      if [ -n "$cp" ] && [ "$cp" != "operators" ]; then
        echo "  WARN: $b/$vm ran with compat path [$cp], not [operators]" >&2
      fi
    done
  done

  echo
  echo "min seconds, and speedup over lua5.3 (the PUC baseline a player runs today):"
  echo
  awk -F'\t' -v vms="$VMS" '
    { t[$1 SUBSEP $2] = $4; if (!($1 in seen)) { seen[$1] = 1; order[++nb] = $1 } }
    END {
      nv = split(vms, VL, " ")
      printf "%-12s", "benchmark"
      for (v = 1; v <= nv; v++) printf "%12s %7s", VL[v], "x5.3"
      printf "\n"
      for (i = 1; i <= nb; i++) {
        b = order[i]
        base = t[b SUBSEP "lua5.3"] + 0
        printf "%-12s", b
        for (v = 1; v <= nv; v++) {
          k = b SUBSEP VL[v]
          if (k in t) {
            tt = t[k] + 0
            ct = (tt > 0.0005) ? tt : 0.0005     # clock-resolution floor
            if (base > 0) printf "%12.3f %6.2fx", tt, base / ct
            else printf "%12.3f %7s", tt, "-"
          } else printf "%12s %7s", "-", "-"
        }
        printf "\n"
      }
    }' "$raw"
  echo
  if [ "$drift" -ne 0 ]; then
    echo "RESULT: FAIL -- bench/oc/ and references.txt disagree about which benchmarks exist" >&2
    return 1
  fi
  if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL -- see the messages above; the numbers are NOT trustworthy" >&2
    return 1
  fi
  echo "RESULT: PASS -- every CHECK matches references.txt and is identical on every VM"
  return 0
}

# --- peaks -----------------------------------------------------------
do_peaks() {
  echo "peak Lua heap under \`luajit -joff\`, count hook every $PEAK_IV instructions."
  echo "The third column of references.txt must stay at or above PEAK: the in-machine"
  echo "driver skips a benchmark unless free memory >= peak*2 + 64 KB, and with about"
  echo "865 KB free after boot that caps a runnable benchmark at roughly 400 KB."
  echo
  printf '%-12s %10s %10s %10s %10s\n' benchmark peakKB baseKB deltaKB refKB
  pfail=0
  for b in $BENCHES; do
    res=$("$LUAJIT" -joff "$WORK/peak.lua" "$SELF_DIR" "$b" "$PEAK_IV" 2>&1 | tr -d '\r')
    pk=$(printf '%s\n' "$res" | sed -n 's/^PEAK \([0-9.]*\).*/\1/p')
    bs=$(printf '%s\n' "$res" | sed -n 's/.*BASE \([0-9.]*\).*/\1/p')
    dl=$(printf '%s\n' "$res" | sed -n 's/.*DELTA \([0-9.]*\).*/\1/p')
    rf=$(peak_of "$b")
    if [ -z "$pk" ]; then
      echo "  peak probe FAILED for $b: $res" >&2
      pfail=1
      continue
    fi
    over=$(awk -v p="$pk" -v r="${rf:-0}" 'BEGIN { print (r + 0 > 0 && p + 0 > r + 0) ? "   <- OVER the declared peak" : "" }')
    printf '%-12s %10s %10s %10s %10s%s\n' "$b" "$pk" "$bs" "$dl" "${rf:--}" "$over"
    [ -n "$over" ] && pfail=1
  done
  echo
  return "$pfail"
}

# ---------------------------------------------------------------- gates
# checks/ holds two questions that the CHECK-matching above cannot answer, and
# they run from here because a gate nothing invokes is a gate nobody re-runs --
# the same argument this script's own header makes about the benchmarks.
#
#   contract.lua         loads each benchmark THE WAY autorun.lua DOES, with
#                        io/print/collectgarbage/require and everything in `os`
#                        except os.clock poisoned, so a benchmark that reaches
#                        for one fails here with a traceback instead of inside
#                        the emulator as a bare ERROR row.
#   compat-branches.lua  cell A of the in-machine comparison is PUC 5.2, which
#                        cannot parse bitwise operators and therefore takes
#                        compat.lua's bit32 branch -- a branch NO VM in the
#                        matrix above exercises, since luajit, lua5.3 and
#                        lua5.4 all parse operators.  This proves the two
#                        branches agree, so cell A reports the same CHECK.
do_gates() {
  gfail=0
  echo "== gates =============================================================="
  echo
  echo "-- contract: every benchmark under the sandbox's restrictions --"
  # shellcheck disable=SC2086
  "$LUAJIT" "$SELF_DIR/checks/contract.lua" "$OCLJ_REPO" $BENCHES || gfail=1
  echo
  echo "-- compat: the operator branch and the bit32 branch must agree --"
  "$LUAJIT" "$SELF_DIR/checks/compat-branches.lua" "$OCLJ_REPO" || gfail=1
  echo
  return "$gfail"
}

case "${1:-check}" in
  check) do_check ;;
  peaks) do_peaks ;;
  gates) do_gates ;;
  all)   do_gates; s=$?; do_peaks || s=1; do_check || s=1; exit "$s" ;;
  *) echo "usage: run-standalone.sh [check|peaks|gates|all]" >&2; exit 2 ;;
esac
