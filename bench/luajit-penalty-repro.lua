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
