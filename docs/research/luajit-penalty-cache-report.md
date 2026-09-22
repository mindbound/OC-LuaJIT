# LuaJIT upstream report: the trace-abort penalty cache outlives its prototype

*2026-09-22. A self-contained issue draft for github.com/LuaJIT/LuaJIT, written
from the defect the harness found on 2026-09-22 (roadmap.md, "A RE-RUN PROGRAM
INHERITS A DEAD ONE'S TRACE-ABORT HISTORY") and re-verified for this document
on a PRISTINE upstream build -- plain `make`, no project flags, no project
patch -- with a pure-Lua reproducer that needs no C host:
`bench/luajit-penalty-repro.lua`. Sections 1-8 are the issue text. Section 9
is the verification record (binaries, md5s, logs) and is not part of the
issue. Every number below was measured; none is asserted.*

---

## 1. Title

**J->penalty[] is keyed by bytecode address and is never scrubbed when a
prototype is freed: a chunk re-loaded from source inherits a dead prototype's
abort penalties and is blacklisted to the interpreter after ~9 loads**

## 2. Version

LuaJIT 2.1 rolling, commit `1ee778a4` ("Add FOLD rule for ALEN of
TNEW/TDUP", 2026-08-19; banner `LuaJIT 2.1.1787165859`). Reproduced on
Windows x64, MinGW-w64 GCC 15.2.0, built with a plain `make` (default
`BUILDMODE=mixed`, no `XCFLAGS`), stock `luajit.exe`, stock allocator
(`lj_alloc`, not `LUAJIT_USE_SYSMALLOC`). Nothing in the mechanism is
platform-specific: it is `lj_trace.c`/`lj_func.c` logic and the allocator's
reuse of a freed block. The Linux x64 build of the project that found this
carries the same fix, but the unpatched reproduction was only run on Windows.

## 3. Summary

The round-robin penalty cache `J->penalty[PENALTY_SLOTS]` (`lj_jit.h:303-312,
485-486`) remembers, per loop-head bytecode, how often a root trace starting
there has aborted, and doubles a hotcount penalty on each abort until
`blacklist_pc()` rewrites the head to `ILOOP`/`IFORL`/`IITERL`. The cache key
is the raw `BCIns *` of the head (`penalty_pc`, `lj_trace.c:392-414`). The
cache is reset by exactly one thing, the `memset` in `lj_trace_flushall()`
(`lj_trace.c:295`); `lj_func_freeproto()` (`lj_func.c:20-23`) is a bare
`lj_mem_free`.

So a prototype's penalties survive the prototype. When the allocator gives
the freed block to the next `load()` of the same source -- which `lj_alloc`
did on all 19 re-loads in three of four runs of the reproducer below, and
which a `realloc`/`free` host allocator does immediately -- the fresh
prototype's loop heads sit at exactly the cached addresses and start life
with the dead prototype's values. Each load's ordinary aborts (an outer loop
reaching an inner one, an inner loop exiting mid-record: `LINNER`/`LLEAVE`,
`lj_record.c:647,665,2301`) double them. `PENALTY_MIN` is 72 and `PENALTY_MAX` 60000, and 72·2^10 = 73728, so
the 11th abort at one address blacklists the head, regardless of how many
prototypes those 11 aborts were spread over. After that `penalty_pc` returns
without touching the slot, so every later load that lands on the address is
blacklisted on its first abort.

The symptom is a program that is re-loaded and re-run many times in one VM
(a REPL, a test runner, a hot-reloading host, a game scripting sandbox)
suddenly running 5-12x slower, permanently, with correct results, and with
nothing in `-jv` output, because a blacklisted head never triggers
recording again.

## 4. Reproducer

Pure Lua, stock `luajit`, no `LUA_PATH` (`jit.util` is built in):

    luajit luajit-penalty-repro.lua [runs]       # default 20, ~0.1 s per run

Each run: `collectgarbage()` so the previous prototype is actually freed,
`load()` the same source again, run it, and record the run time, the
prototype's address (`jit.util.funcinfo(f).proto`; watch it recur), the
loop-head opcodes read back through `jit.util.funcbc` (`ILOOP`=86,
`IFORL`=80, `IITERL`=83 are the blacklisted forms; `FORL`/`ITERL`/`LOOP` =
79/82/85 never run, `JFORL`/`JITERL`/`JLOOP` = 81/84/87 compiled), and the
root-trace aborts `jit.attach` reported. Rows are kept as numbers and
printed at the end, so the reproducer's own garbage stays out of the size
class the prototype lives in. Exit status 1 if any run read a blacklisted
head.

```lua
-- luajit-penalty-repro.lua -- LuaJIT's trace-abort penalty cache outlives
-- the prototype it was recorded for.
--
-- J->penalty[] (lj_jit.h) is keyed by the raw ADDRESS of a loop-head
-- bytecode and is reset by exactly one thing, lj_trace_flushall.  A dying
-- prototype (lj_func_freeproto, lj_func.c) leaves its slots behind.  When
-- the allocator hands that block to the next load() of the same source,
-- the fresh prototype INHERITS the dead one's penalty values; its own
-- ordinary aborts (an outer loop hitting an inner loop, LLEAVE/LINNER)
-- double them; and once a value passes PENALTY_MAX, blacklist_pc rewrites
-- the head to ILOOP/IFORL/IITERL: the loop runs interpreted for the rest of
-- that prototype's life -- and so does every later load that lands on the
-- same address, because the slots are still there.
--
--   luajit luajit-penalty-repro.lua [runs]          (default 20, ~0.1 s each)
--
-- Pure Lua, stock luajit, no LUA_PATH needed (jit.util is built in).  Each
-- run: collectgarbage() so the previous prototype is actually freed, load()
-- the same source again, run it, and record the run time, the prototype's
-- address (watch it recur), the loop-head opcodes read back through
-- jit.util.funcbc (I* = blacklisted), and the root-trace aborts jit.attach
-- reported.  Rows are kept as numbers and printed at the end, so the
-- reproducer's own garbage stays out of the size class the prototype lives
-- in.  Exit status is 1 if any run read a blacklisted head.
--
-- Expected with the bug: after ~8-12 runs at a recurring address one run
-- reads ILOOP/IFORL, takes ~5x longer, and computes the same result.
-- Expected fixed: every run 1.0-1.3x run 1, never an I* head.

local jutil = require("jit.util")
local band = require("bit").band

local N = tonumber(arg and arg[1]) or 20

-- The source: nested loops, ~0.1 s compiled.  On every fresh load its outer
-- loop heads abort a few times with LLEAVE/LINNER before the inner loop's
-- side traces cover them.  That is normal; the point is that each such
-- abort doubles a value the previous load left at the same address.
local SRC = [[
local W, H, MAXI = 1024, 1024, 128
local sum = 0
for py = 0, H - 1 do
  local ci = 2.5 * py / H - 1.25
  for px = 0, W - 1 do
    local cr = 2.5 * px / W - 2.0
    local zr, zi, zr2, zi2 = 0.0, 0.0, 0.0, 0.0
    local it = 0
    while it < MAXI and zr2 + zi2 <= 4.0 do
      zi = 2.0 * zr * zi + ci
      zr = zr2 - zi2 + cr
      zr2 = zr * zr
      zi2 = zi * zi
      it = it + 1
    end
    sum = sum + it
  end
end
return sum
]]
local EXPECT = 37904620

-- Loop-head opcodes, numbered as in lj_bc.h (LuaJIT 2.1, commit 1ee778a4).
-- The sanity check below refuses to run if a never-executed load() does not
-- read FORL/ITERL/LOOP at its loop heads.
local OPNAME = { [79] = "FORL", [80] = "IFORL", [81] = "JFORL",
                 [82] = "ITERL", [83] = "IITERL", [84] = "JITERL",
                 [85] = "LOOP", [86] = "ILOOP", [87] = "JLOOP" }
local BLACK = { [80] = true, [83] = true, [86] = true }
-- Trace-abort reasons in lj_traceerr.h order (TraceError is 0-based).
local ERRNAME = { [0] = "RECERR", "TRACEUV", "TRACEOV", "STACKOV", "SNAPOV",
  "BLACKL", "RETRY", "NYIBC", "LLEAVE", "LINNER", "LUNROLL", "BADTYPE",
  "CJITOFF", "CUNROLL", "DOWNREC", "NYIFFU", "NYIRETL", "STORENN", "NOMM",
  "IDXLOOP", "NYITMIX", "NOCACHE", "NYICONV", "NYICALL", "GFAIL", "PHIOV",
  "TYPEINS", "MCODEAL", "MCODEOV", "MCODELM", "SPILLOV", "BADRA", "NYIIR",
  "NYIPHI", "NYICOAL" }

local function headpcs(fn)
  local out = {}
  for pc = 0, jutil.funcinfo(fn).bytecodes - 1 do
    if OPNAME[band(jutil.funcbc(fn, pc), 0xff)] then out[#out + 1] = pc end
  end
  return out
end

-- Root-trace aborts inside the chunk being run, attributed to the pc the
-- recording started at (that is the pc penalty_pc keys on).  The callback
-- writes only existing slots so it allocates nothing.
local cur_fn
local s_pc, s_root, s_ours = -1, false, false
local abcount, abcode = {}, {}
for pc = 0, 255 do abcount[pc], abcode[pc] = 0, -1 end
jit.attach(function(what, tr, func, pc, otr, oex)
  if what == "start" then
    s_pc, s_root, s_ours = pc, otr == nil, func == cur_fn
  elseif what == "abort" and s_root and s_ours and s_pc < 256 then
    abcount[s_pc] = abcount[s_pc] + 1
    abcode[s_pc] = type(otr) == "number" and otr or -1
  end
end, "trace")

-- A throwaway load: which pcs are loop heads, and do they read the
-- never-run opcodes this script assumes?
local HP
do
  local probe = assert(load(SRC, "=chunk"))
  HP = headpcs(probe)
  assert(#HP > 0, "no loop heads found")
  for _, pc in ipairs(HP) do
    local op = band(jutil.funcbc(probe, pc), 0xff)
    assert(op == 79 or op == 82 or op == 85,
      "loop head at pc " .. pc .. " reads opcode " .. op ..
      ": this LuaJIT numbers its bytecodes differently, adjust OPNAME")
  end
end

local rows = {}
for i = 1, N do
  local r = { secs = 0, addr = "", same = false, ok = false, black = false,
              ops = {}, ab = {}, abc = {} }
  for j = 1, #HP do r.ops[j], r.ab[j], r.abc[j] = 0, 0, -1 end
  rows[i] = r
end

local prev
for run = 1, N do
  collectgarbage(); collectgarbage()   -- the previous prototype must be swept
  local fn = assert(load(SRC, "=chunk"))
  local addr = tostring(jutil.funcinfo(fn).proto)
  for pc = 0, 255 do abcount[pc], abcode[pc] = 0, -1 end
  cur_fn = fn
  local t0 = os.clock()
  local okr, sum = pcall(fn)
  local secs = os.clock() - t0
  cur_fn = nil
  local r = rows[run]
  r.secs, r.addr, r.same, r.ok = secs, addr, addr == prev, okr and sum == EXPECT
  for j, pc in ipairs(HP) do
    local op = band(jutil.funcbc(fn, pc), 0xff)
    r.ops[j], r.ab[j], r.abc[j] = op, abcount[pc], abcode[pc]
    if BLACK[op] then r.black = true end
  end
  prev = addr
  fn = nil
end

print(string.format("%s  jit.status=%s  %d loads of one chunk, collectgarbage() before each",
  jit.version, tostring(jit.status()), N))
print("loop heads at pc " .. table.concat(HP, " ") .. "; expected result " .. EXPECT)
local first, nblack, firstblack, slowest = rows[1].secs, 0, nil, 0
local streak, beststreak = 0, 0
for run = 1, N do
  local r = rows[run]
  local heads, aborts = {}, {}
  for j, pc in ipairs(HP) do
    heads[j] = pc .. "=" .. (OPNAME[r.ops[j]] or r.ops[j])
    if r.ab[j] > 0 then
      aborts[#aborts + 1] = string.format("%s@%d x%d",
        ERRNAME[r.abc[j]] or ("err" .. r.abc[j]), pc, r.ab[j])
    end
  end
  if r.black then nblack = nblack + 1; firstblack = firstblack or run end
  if r.secs / first > slowest then slowest = r.secs / first end
  streak = r.same and streak + 1 or 0
  if streak > beststreak then beststreak = streak end
  print(string.format("run %2d  %6.3f s (%4.2fx)  %s %-4s %-3s  aborts: %-26s  heads: %s%s",
    run, r.secs, r.secs / first, r.addr, r.same and "same" or "new", r.ok and "ok" or "BAD",
    table.concat(aborts, " "), table.concat(heads, " "),
    r.black and "   <-- BLACKLISTED" or ""))
end
if nblack > 0 then
  print(string.format("RESULT: BLACKLISTED in %d of %d runs, first at run %d; slowest run %.2fx run 1; longest same-address streak %d",
    nblack, N, firstblack, slowest, beststreak))
else
  print(string.format("RESULT: no blacklisting in %d runs; slowest run %.2fx run 1; longest same-address streak %d%s",
    N, slowest, beststreak,
    beststreak == 0 and " (the allocator never reused a prototype's address, so this run shows nothing either way)" or ""))
end
os.exit(nblack > 0 and 1 or 0)
```

## 5. Observed

Pristine upstream `luajit.exe` (commit `1ee778a4`, plain `make`; md5
`71368fd67c8849b0e2224d213fc54413`, `lua51.dll`
`5e43ffc6d2db4fca2a5f8a5fc9fb8a91`), first run, verbatim:

```
LuaJIT 2.1.1787165859  jit.status=true  20 loads of one chunk, collectgarbage() before each
loop heads at pc 30 41 42; expected result 37904620
run  1   0.104 s (1.00x)  proto: 0x0171706b31d0 new  ok   aborts: LLEAVE@30 x3 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run  2   0.106 s (1.02x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1                heads: 30=JLOOP 41=JFORL 42=JFORL
run  3   0.106 s (1.02x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1                heads: 30=JLOOP 41=JFORL 42=FORL
run  4   0.105 s (1.01x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1                heads: 30=JLOOP 41=JFORL 42=JFORL
run  5   0.106 s (1.02x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1                heads: 30=JLOOP 41=JFORL 42=FORL
run  6   0.106 s (1.02x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1                heads: 30=JLOOP 41=JFORL 42=JFORL
run  7   0.108 s (1.04x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1                heads: 30=JLOOP 41=JFORL 42=FORL
run  8   0.102 s (0.98x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1                heads: 30=JLOOP 41=JFORL 42=JFORL
run  9   0.535 s (5.14x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1 BLACKL@41 x10 BLACKL@42 x5  heads: 30=ILOOP 41=IFORL 42=FORL   <-- BLACKLISTED
run 10   0.530 s (5.10x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1 BLACKL@41 x1 BLACKL@42 x1  heads: 30=ILOOP 41=IFORL 42=FORL   <-- BLACKLISTED
run 11   0.492 s (4.73x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1                heads: 30=ILOOP 41=JFORL 42=JFORL   <-- BLACKLISTED
run 12   0.588 s (5.65x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1 BLACKL@41 x1 BLACKL@42 x1  heads: 30=ILOOP 41=IFORL 42=FORL   <-- BLACKLISTED
run 13   0.984 s (9.46x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1 BLACKL@41 x1   heads: 30=ILOOP 41=IFORL 42=FORL   <-- BLACKLISTED
run 14   0.993 s (9.55x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1 BLACKL@41 x1 BLACKL@42 x1  heads: 30=ILOOP 41=IFORL 42=FORL   <-- BLACKLISTED
run 15   0.979 s (9.41x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1 BLACKL@41 x1   heads: 30=ILOOP 41=IFORL 42=FORL   <-- BLACKLISTED
run 16   0.994 s (9.56x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1 BLACKL@41 x1   heads: 30=ILOOP 41=IFORL 42=FORL   <-- BLACKLISTED
run 17   1.037 s (9.97x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1 BLACKL@41 x1   heads: 30=ILOOP 41=IFORL 42=FORL   <-- BLACKLISTED
run 18   1.055 s (10.14x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1 BLACKL@41 x1   heads: 30=ILOOP 41=IFORL 42=FORL   <-- BLACKLISTED
run 19   0.966 s (9.29x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1 BLACKL@41 x1 BLACKL@42 x1  heads: 30=ILOOP 41=IFORL 42=FORL   <-- BLACKLISTED
run 20   0.990 s (9.52x)  proto: 0x0171706b31d0 same ok   aborts: LLEAVE@30 x1 BLACKL@41 x1   heads: 30=ILOOP 41=IFORL 42=FORL   <-- BLACKLISTED
RESULT: BLACKLISTED in 12 of 20 runs, first at run 9; slowest run 10.14x run 1; longest same-address streak 19
```

Reading it against the arithmetic: pc 30 (the `while` head) aborts with
`LLEAVE` 3 times in run 1 and once in each of runs 2-8, i.e. 10 aborts at
one address by the end of run 8 -- value 72·2^9 = 36864. Run 9's single
`LLEAVE` is the 11th: 73728 > 60000, `blacklist_pc`, and the head reads
`ILOOP`. With the inner loop blacklisted, the outer `for` at pc 41 can no
longer be covered by the inner loop's side traces; it records, reaches the
`ILOOP` (`lj_record.c:2723-2726`, `LJ_TRERR_BLACKL`), and is blacklisted in
the same run after 10 such aborts of its own. From run 10 on every load
lands on the same address, inherits the un-lowered slots (`penalty_pc`
returns without writing once it has blacklisted), and is blacklisted on its
FIRST abort. The result is correct every time.

Replications on the same binary (details in section 9): a second 20-load
run blacklisted at run 9 (6.1x, then 10.3-11.9x); a third at run 7 (its run
1 had `LLEAVE@30 x5`, so the 11th abort came two loads earlier); a 14-load
run in which the allocator moved the prototype at runs 2 and 11 (longest
streak 8) never reached an 11th abort at one address and never blacklisted.
The address recurrence is what decides it, and it is the allocator's.

## 6. Expected

Each `load()` produces a new prototype with no abort history. A fresh
prototype's loop heads should start at `PENALTY_MIN` like any other, so 20
loads of the same chunk should all compile the same way and run at the same
speed. On a build with the fix in section 8 (pristine `1ee778a4` plus only
that diff, plain `make`; md5 `0cfe2594f5c86ccc743017fd193a76de`,
`lua51.dll` `de5e47b364ed4b6c252e0ce991621bd7`), same reproducer, verbatim:

```
LuaJIT 2.1.1787165859  jit.status=true  20 loads of one chunk, collectgarbage() before each
loop heads at pc 30 41 42; expected result 37904620
run  1   0.085 s (1.00x)  proto: 0x0234dbc531d0 new  ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run  2   0.084 s (0.99x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x3 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run  3   0.095 s (1.12x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x3 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run  4   0.088 s (1.04x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x4 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run  5   0.086 s (1.01x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x5 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run  6   0.111 s (1.31x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run  7   0.090 s (1.06x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run  8   0.087 s (1.02x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run  9   0.088 s (1.04x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x3 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run 10   0.086 s (1.01x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run 11   0.087 s (1.02x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x3 LINNER@41 x2   heads: 30=JLOOP 41=JFORL 42=FORL
run 12   0.088 s (1.04x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run 13   0.091 s (1.07x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run 14   0.107 s (1.26x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x3 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run 15   0.096 s (1.13x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x3 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run 16   0.088 s (1.04x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run 17   0.088 s (1.04x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x3 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run 18   0.083 s (0.98x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run 19   0.087 s (1.02x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x4 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run 20   0.094 s (1.11x)  proto: 0x0234dbc531d0 same ok   aborts: LLEAVE@30 x3 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
RESULT: no blacklisting in 20 runs; slowest run 1.31x run 1; longest same-address streak 19
```

Same address on all 20 loads, and every run shows run 1's abort pattern
(`LLEAVE@30` a few times, `LINNER@41` once): each prototype is starting from
nothing. Compare the pristine rows 2-8, where the inherited slot already
changes how the fresh prototype is compiled (one `LLEAVE`, no `LINNER`)
before anything is blacklisted -- see the note on `innerloopleft` below.

## 7. Analysis

All line numbers are for commit `1ee778a4`.

**The cache.** `lj_jit.h:303-307` defines `HotPenalty { MRef pc; uint16_t
val; uint16_t reason; }`; `:309-312` `PENALTY_SLOTS 64`, `PENALTY_MIN
(36*2)`, `PENALTY_MAX 60000`, `PENALTY_RNDBITS 4`; `:485-486` the array
`J->penalty[PENALTY_SLOTS]` and the round-robin index `J->penaltyslot`.

**The writer.** `trace_abort` (`lj_trace.c:604-615`): for a root trace
(`J->parent == 0`) that did not start at a return and has `J->exitno == 0`,
every abort other than `LJ_TRERR_RETRY` calls `penalty_pc(J, pt, startpc,
e)`. `penalty_pc` (`lj_trace.c:392-414`) looks the pc up by pointer
equality (`:395-396`), and on a hit computes `val = (old << 1) + rnd`
(`:398-399`); if `val > PENALTY_MAX` it calls `blacklist_pc` (`:380-390`),
which rewrites the head's opcode to the `I*` form and sets `PROTO_ILOOP`,
and RETURNS without updating the slot (`:400-403`); otherwise it stores
`val` (`:411-412`) and arms the hotcount with it (`:413`). On a miss it
takes the next round-robin slot (`:407-409`) and stores `PENALTY_MIN`.
Starting from 72, the value exceeds 60000 on the 11th abort at one pc
(72·2^10 = 73728; the random bits only add to that), and NOTHING in
`penalty_pc` asks which prototype the pc belongs to.

**The only reset.** `lj_trace_flushall` (`lj_trace.c:276`) does
`memset(J->penalty, 0, sizeof(J->penalty))` at `:295` (it also unpatches
`I*` heads through `lj_trace_reenableproto`, `:187`). That is the only
place the cache is cleared or shrunk.

**The free path never touches it.** A dead prototype is swept by
`gc_sweep` (`lj_gc.c:405-424`) through the `gc_freefunc[]` table
(`lj_gc.c:381-385`), whose `LJ_TPROTO` entry is `lj_func_freeproto`
(`lj_func.c:20-23`), which is `lj_mem_free(g, pt, pt->sizept)` and nothing
else. The bytecode lives inside that block (`proto_bc(pt)` is `pt + 1`), so
the freed range is exactly the range every one of its loop heads' pcs fell
in, and the cache still holds those pcs with their values and reasons.

**Why the next load lands on the same address.** A prototype is one block
of `pt->sizept` bytes. `collectgarbage()` frees it; the next `load()` of
the same source parses the same text and asks the allocator for the same
size. `lj_alloc` (dlmalloc-derived) returned the same block on all 19
re-loads in three of the four pristine runs recorded in section 9 (and in
the fixed-build run of section 6), and for 8 then 3 consecutive loads in
the fourth; the reproducer keeps its own garbage out of the way to make
that likely, and the earlier, noisier version of this
probe (which allocated inside the `jit.attach` callback and printed a row
per run) saw streaks of 9 in one run and mostly fresh addresses in another.
A host that installs the C library allocator (`lua_newstate` with a
`realloc`/`free` function, as embedders commonly do) hands the block
straight back: the project that found this runs its VM on CRT
`realloc`/`free` and its C-host test (`test/native/penalty_test.c` +
`penalty_test.lua`, which reads `J->penalty[]` directly) blacklists on the
8th-14th load. So how many loads it takes depends on the allocator and on
what else the program allocates between loads -- but it only ever takes
a handful of loads at one address.

**Why every load contributes aborts.** Nested loops abort at the outer
head by design. Recording a root trace at an outer `for` and reaching the
inner loop's head raises `LJ_TRERR_LINNER` ("inner loop in root trace") if
the inner loop is interpreted (`rec_loop_interp`, `lj_record.c:630-658`,
the throw at `:647`) and unconditionally if it is already compiled
(`rec_loop_jit`, `:661-673`, the throw at `:665`: "Better let the inner
loop spawn a side trace back here"). Recording a root trace at the inner
`while` and leaving the loop before it closes raises `LJ_TRERR_LLEAVE`
("leaving loop in root trace"): `lj_record_ins` throws it when a root
trace's pc leaves the loop's bytecode extent (`:2298-2301`, "Record only
closed loops for root traces"), and there are two more sites for a
`for`/`for-in` head that exits at the recorded iteration (`:637`) and for
a return out of the loop (`:994`). These are the normal way LuaJIT
arrives at "inner loop as root trace, outer loops as side traces"; the
reproducer's chunk produces 3-6 of them per fresh load (run 1 in both
outputs above, every run on the fixed build). Each one doubles whatever the
slot holds. A program that is loaded once never accumulates 11 of them at
one head, because the side traces take over and the head stops being
recorded; a program loaded 9 times at one address does.

**A second reader.** `innerloopleft` (`lj_record.c:615-626`) also looks
the cache up by address: an inner loop whose slot says `LLEAVE`/`LINNER`
with `val >= 2*PENALTY_MIN` is treated as "repeatedly didn't loop back" and
unrolled into the outer root trace instead of aborting with `LINNER`
(`:646-647`). A fresh prototype therefore also inherits that verdict. It is
visible in the pristine output: runs 2-8 show one `LLEAVE@30` and no
`LINNER@41` where every fixed-build run shows `LLEAVE@30 x2-5` and
`LINNER@41 x1` -- the fresh prototype is compiled differently from run 2
on, before anything is blacklisted. Run 11 (`41=JFORL 42=JFORL` while
`30=ILOOP`, 0.49 s) is the same effect after the blacklist.

**What is NOT affected.** The hotcounts (`GG_State.hotcount[64]`,
`lj_dispatch.h:75,126-129`) are also indexed by pc address, but they are a
hashed countdown shared by all pcs and self-correct within 56 iterations.
`PROTO_ILOOP` and the `I*` opcodes live in the prototype and die with it;
the persistence is entirely in `J->penalty[]`.

## 8. Fix

Scrub the dying prototype's range from the cache before its block is
freed. `penalty_pc` compares slot pcs against a real pc, so a `NULL` slot
matches nothing and is simply free for the round-robin. 64 pointer
compares per prototype free, only under `LJ_HASJIT`. `lj_func.c` already
includes `lj_trace.h`, which brings in `lj_jit.h` and `lj_dispatch.h`
(`G2J`).

```diff
--- a/src/lj_func.c
+++ b/src/lj_func.c
@@ -19,6 +19,23 @@
 
 void LJ_FASTCALL lj_func_freeproto(global_State *g, GCproto *pt)
 {
+#if LJ_HASJIT
+  /* Scrub this prototype's loop heads from the trace-abort penalty cache.
+  ** The cache is keyed by bytecode address and is otherwise only reset by
+  ** lj_trace_flushall(). If the allocator hands this block to the next
+  ** prototype, that one would inherit the penalties of the dead one and
+  ** its own aborts would double them until blacklist_pc() fires.
+  */
+  jit_State *J = G2J(g);
+  const BCIns *bc = proto_bc(pt);
+  const BCIns *bcend = bc + pt->sizebc;
+  uint32_t i;
+  for (i = 0; i < PENALTY_SLOTS; i++) {
+    const BCIns *pc = mref(J->penalty[i].pc, const BCIns);
+    if (pc >= bc && pc < bcend)
+      setmref(J->penalty[i].pc, NULL);
+  }
+#endif
   lj_mem_free(g, pt, pt->sizept);
 }
 
```

(The hunk's last context line is a lone space: the blank line after the
function. It is required for the hunk to apply.) Verified: the diff applies to the `1ee778a4` blob with `git apply --check`,
builds with a plain `make` (only `lj_func.o` recompiles, 2875 -> 2939
bytes), and the reproducer output in section 6 is that binary.

**Alternative placements.** The same loop can live next to `penalty_pc` in
`lj_trace.c` as a small `lj_trace_freeproto(jit_State *J, GCproto *pt)`
(or be folded into the `LJ_TPROTO` case of the sweep in `lj_gc.c`) and be
called from `lj_func_freeproto`, which keeps the cache's readers and writers
in one file; the behaviour is identical. Keying the cache by something other
than the address (e.g. `(GCproto *, BCPos)`) does not help, since the
prototype pointer recurs for the same reason the bytecode pointer does.

**Blacklisting within a live prototype is unaffected.** The scrub runs only
when a prototype is freed; a live prototype's slots are untouched, and a
loop that genuinely aborts on every record is still blacklisted after its
11th abort. The project's regression test carries two positive controls
for that (`test/native/penalty_test.lua` P5/P6: a `while` loop and a
numeric `for` whose bodies create a closure -- `BC_FNEW` is an unconditional
NYI in the recorder -- read `ILOOP` and `IFORL` after 400 000 iterations on
the patched library exactly as on the unpatched one). Note also that the
fixed-build run above still shows the ordinary `LLEAVE`/`LINNER` aborts on
every load: the penalty machinery is intact, it just starts from
`PENALTY_MIN` for each new prototype, as it does for a program loaded once.

---

## 9. Verification record (project-internal, not part of the issue)

Everything above was produced in this session; nothing was reused from the
earlier bisect except as a cross-check. Logs live under
`C:/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/pf/R/`
(`$R` below); the three binaries under `$R/../`.

**Pristine build.** `cp -r prototype/watchdog/luajit $R/../luajit-pristine`
(the pinned checkout, `1ee778a4`, `git status` clean apart from an
untracked `.stamp`; never built in), then `make -C luajit-pristine/src Q= -j4`
with no `XCFLAGS` and no `BUILDMODE`: MinGW-w64 GCC 15.2.0
(`C:/mingw64/bin/gcc`), GNU Make 4.4.1; 76 compile lines, flags exactly
`-O2 -fomit-frame-pointer -Wall -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE
-U_FORTIFY_SOURCE -DLUA_BUILD_AS_DLL`, no `LUAJIT_ENABLE_CHECKHOOK`, no
`LUAJIT_ENABLE_LUA52COMPAT`; banner `LuaJIT 2.1.1787165859 -- Copyright (C)
2005-2026 Mike Pall. https://luajit.org/`; `luajit.exe` md5
`71368fd67c8849b0e2224d213fc54413`, `lua51.dll`
`5e43ffc6d2db4fca2a5f8a5fc9fb8a91`. Log `$R/pristine-make.log`.
*Instrument note:* the FIRST `make` in the copy took one second and
compiled nothing -- the checkout's `src/` carries gitignored objects and a
`luajit.exe` from 2026-09-01 (the prototype era), and `cp -r` brought them
along, so make only re-linked them. Pass 2 in the same log ran `make clean`
first; the numbers above are pass 2. (`build-native.sh` does not have this
problem: it runs `make clean` before its make.)

**Fixed build** (pristine + the section 8 diff and nothing else):
`cp -r luajit-pristine luajit-fixed`, drop in the patched `lj_func.c`,
remove `lj_func.o` and the link products, `make -C luajit-fixed/src Q=`:
one `gcc -c` line (`lj_func.c`), `DYNLINK`, `LINK`; `lj_func.o` 2939 bytes
vs 2875; `luajit.exe` md5 `0cfe2594f5c86ccc743017fd193a76de`, `lua51.dll`
`de5e47b364ed4b6c252e0ce991621bd7`. Log `$R/fixed-build-2.log`.
*Instrument notes, both caught by the md5 lines the scripts print:* (1) the
checkout's `lj_func.c` is CRLF on this box (core.autocrlf) and MSYS awk
strips CRs on read, so the first `diff -u` was a 402-line whole-file
rewrite; the diff above is taken against the git blob (`git show
HEAD:src/lj_func.c`, LF, 191 lines, byte-identical to the CR-stripped
working copy) and is 26 lines, +17/-0; (2) `cp -r` stamps every copied
object with the copy time, so the first "fixed" make said "Nothing to be
done" and produced a binary byte-identical to pristine -- that run is kept
as `$R/repro-fixed.ATTEMPT1-was-pristine-binary.log` and counts as a
pristine replication. `$R/fixed-build.log` is the failed attempt.

**Diff provenance.** `$R/fix/lj_func.diff` (the text in section 8);
`lj_func.c.upstream` = the git blob; `lj_func.c` = patched (LF);
`git apply --check` and `git apply` on an LF copy under `$R/fix/applycheck/`
both succeed and the result equals the patched file once git's autocrlf CRs
are stripped. The block itself is the one `native/luajit/patch-penalty-scrub.sh`
inserts (same code, the OC-LuaJIT marker comment replaced by one addressed
to upstream; `$R/fix/lj_func.c.ocpatched` is the script's own output for
comparison).

**Reproducer runs** (`bench/luajit-penalty-repro.lua`, each ~4-12 s, run
one at a time, nothing else compiling):

| log | binary | N | first blacklist | slowest | longest same-address streak |
|---|---|---|---|---|---|
| `repro-pristine.log` (section 5) | pristine `71368fd6` | 20 | run 9 | 10.14x | 19 |
| `repro-fixed.ATTEMPT1-was-pristine-binary.log` | pristine `71368fd6` | 20 | run 9 | 11.86x | 19 |
| `repro-pristine-3.log` | pristine `71368fd6` | 20 | run 7 | 12.25x | 19 |
| `repro-pristine-2.log` | pristine `71368fd6` | 14 | none | 1.22x | 8 (address moved at runs 2 and 11) |
| `repro-fixed.log` (section 6) | pristine+diff `0cfe2594` | 20 | none | 1.31x | 19 |
| `repro-patched.log` | project build copy `0c2a4a3d` | 20 | none | 1.06x | 19 |

In every pristine run that blacklisted, the first blacklist is exactly the
11th `LLEAVE` abort at pc 30 summed over consecutive loads at one address
(3+7+1 at run 9; 5+5+1 at run 7). The 14-load run is the negative case the
reproducer's `RESULT` line is written for: streaks of 8 and 3 never reach 11.

The project's own patched binary
(`build/native/luajit-windows-x86_64/src/luajit.exe`, md5
`0c2a4a3d066577b5d6783a690fb3c266`, banner `LuaJIT 2.1.ROLLING`, built with
`CHECKHOOK`+`LUA52COMPAT` and the scrub script) on the same reproducer,
verbatim:

```
LuaJIT 2.1.ROLLING  jit.status=true  20 loads of one chunk, collectgarbage() before each
loop heads at pc 30 41 42; expected result 37904620
run  1   0.101 s (1.00x)  proto: 0x016ba23f3468 new  ok   aborts: LLEAVE@30 x3 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run  2   0.095 s (0.94x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run  3   0.090 s (0.89x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run  4   0.087 s (0.86x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x3 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run  5   0.086 s (0.85x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run  6   0.088 s (0.87x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run  7   0.085 s (0.84x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run  8   0.089 s (0.88x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run  9   0.087 s (0.86x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run 10   0.107 s (1.06x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run 11   0.101 s (1.00x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x3 LINNER@41 x2   heads: 30=JLOOP 41=JFORL 42=FORL
run 12   0.098 s (0.97x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run 13   0.095 s (0.94x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run 14   0.091 s (0.90x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run 15   0.089 s (0.88x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x3 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run 16   0.089 s (0.88x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x3 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run 17   0.089 s (0.88x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run 18   0.087 s (0.86x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x2 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
run 19   0.085 s (0.84x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x3 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=FORL
run 20   0.085 s (0.84x)  proto: 0x016ba23f3468 same ok   aborts: LLEAVE@30 x3 LINNER@41 x1   heads: 30=JLOOP 41=JFORL 42=JFORL
RESULT: no blacklisting in 20 runs; slowest run 1.06x run 1; longest same-address streak 19
```

**A correction to roadmap.md.** The roadmap entry for this defect says
"with LuaJIT's own allocator the address recurs 1 run in 20, which is why
upstream does not see it". That was read off the earlier, noisier probe
(`scratchpad/bump/bisect/penalty-probe/out-collect-2.txt`, which allocated
inside its `jit.attach` callback and printed a formatted row after every
run). With those allocations removed, `lj_alloc` reused the block on 19 of
19 loads in three of four runs here, and 8 then 3 in the fourth. The honest
statement is that recurrence under `lj_alloc` depends on what else is
allocated between loads, and that a quiet program gets it every time.

**Not run here**, by instruction: the harness, `run-penalty.sh` (its 6/6
and the fail-first numbers are quoted from roadmap.md), and any Linux run.
