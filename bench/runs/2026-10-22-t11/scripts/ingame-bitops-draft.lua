-- bench/oc/ingame-bitops.lua -- T10: Lua 5.3's bitwise operators, checked and
-- timed in game, the same file on OpenComputers' "Lua 5.3" CPU and on ours.
--
-- Copy this file into the computer's /home (an OC hard disk is a directory
-- under saves/<world>/opencomputers/<address>/), then at the shell:
--
--     ingame-bitops            (or: lua /home/ingame-bitops.lua)
--     ingame-bitops 3          (3 reps per bench instead of 5)
--
-- Part 1 prints PASS or FAIL for each known-answer check, with the value it
-- got; the deviation lines print "deviation as documented" or FAIL.  Part 2
-- prints, per bench, the median and the minimum in nanoseconds per operation
-- over REPS reps.  Everything printed also goes to a results file next to this
-- one, /home/ingame-bitops-<arch>.txt (-2, -3, ... if that name is taken; an
-- earlier result is never overwritten), so it can be read from the save
-- directory.  Docs: docs/in-game-tests.md, T10.
--
-- Why it is written this way:
--   * The operators live in a string chunk, OPS below, compiled with load():
--     a Lua 5.2 CPU cannot parse &, |, ~, << or >>, and a parse error in this
--     file would stop it before it could say why.  On 5.2 it prints a "needs
--     Lua 5.3 or LuaJIT" line instead.  The chunk uses only Lua 5.3 syntax,
--     none of our dialect's extensions (no ~>>, no compound assignment), and
--     no // (our CPU has none; see the README's Lua dialect section).
--   * Operands come from tonumber() of strings or from a table: our parser
--     folds a constant bit expression at compile time, so a check written on
--     literals would test the folder, not the interpreter or the JIT.
--   * The architecture comes from computer.getArchitecture() when `computer`
--     exists (in game).  Standalone it is inferred from `jit` and _VERSION.
--     Nothing depends on `jit` in game: OC's sandbox has no `jit` table, so no
--     JIT on/off switch exists there, and T10 compares CPUs, not JIT settings.
--   * Timer, yield and output follow bench/oc/ingame-ladder.lua: os.clock()
--     brackets each rep, os.sleep(0) between reps (when os.sleep exists)
--     yields so no rep runs into the previous one's deadline, and every rep
--     stays far below OC's 5 s no-yield timeout and our watchdog
--     (docs/watchdog.md): each bench's count is calibrated so a rep takes
--     about 0.3 s, checked once by a warm-up rep that is not counted.
--   * Each bench repeats a fixed inner workload and returns its result, which
--     is checked against a reference computed without bit operators (or, for
--     CRC32 and xorshift32, against PUC Lua 5.3.6's value), so a compiled loop
--     that computed a wrong value shows as "BAD" in Part 2.
--   * The one documented deviation (README, Lua dialect; the JIT guide's
--     U1-B): on our CPU a bitwise result with more than 53 significant bits
--     raises "result of '<op>' has more than 53 significant bits (mask each
--     operand to 32 bits first)"; 5.3 returns its 64-bit integer.

local args = { ... }
local REPS = 5
local outdir
for _, a in ipairs(args) do
  if tonumber(a) then REPS = math.max(1, math.floor(tonumber(a))) else outdir = a end
end

local clock = os.clock
local sleep = os.sleep
local function yield() if sleep then sleep(0) end end

-- The architecture, and whether this run is in game.
local computer = computer
if computer == nil and type(require) == "function" then
  local ok, m = pcall(require, "computer")
  if ok and type(m) == "table" then computer = m end
end
local arch, where
if type(computer) == "table" and type(computer.getArchitecture) == "function" then
  local ok, a = pcall(computer.getArchitecture)
  if ok and type(a) == "string" then arch, where = a, "in game" end
end
if not arch then
  where = type(computer) == "table" and "in game, inferred" or "standalone"
  if rawget(_G, "jit") ~= nil then arch = "LuaJIT"
  else arch = _VERSION end
end

-- The results file: next to this script, never over an earlier one.
local function scriptdir()
  if not debug or type(debug.getinfo) ~= "function" then return nil end
  local ok, info = pcall(debug.getinfo, 1, "S")
  if not ok or type(info) ~= "table" or type(info.source) ~= "string" then return nil end
  local src = info.source
  if src:sub(1, 1) ~= "@" and src:sub(1, 1) ~= "=" then return nil end
  return src:sub(2):match("^(.*)[/\\][^/\\]*$")
end
local tag = arch:lower():gsub("[^%w]", "")
if where == "standalone" then tag = tag .. "-standalone" end
local dir = outdir or scriptdir() or (where == "standalone" and "." or "/home")
local outpath, fh
for k = 1, 99 do
  local p = dir .. "/ingame-bitops-" .. tag .. (k > 1 and ("-" .. k) or "") .. ".txt"
  local r = io.open(p, "r")
  if r then r:close() else outpath = p break end
end
if outpath then fh = io.open(outpath, "w") end

local function out(s)
  print(s)
  if fh then fh:write(s, "\n") end
end
local function detail(s) if fh then fh:write("  ", s, "\n") end end
local function flush() if fh then fh:flush() end end
local function finish()
  if fh then
    fh:close()
    print("results written to " .. outpath)
  else
    print("results file NOT written (" .. tostring(outpath or dir) .. ")")
  end
end

local ours = arch:find("LuaJIT", 1, true) ~= nil
local is54 = arch:find("5.4", 1, true) ~= nil

out("T10 ingame-bitops v1  arch=" .. arch .. " (" .. where .. ")")
local mem = ""
if type(computer) == "table" and type(computer.totalMemory) == "function" then
  local okt, tot = pcall(computer.totalMemory)
  local okf, free = pcall(computer.freeMemory)
  if okt and okf and type(tot) == "number" and type(free) == "number" then
    mem = string.format("RAM %d KB free %d KB  ", math.floor(tot / 1024), math.floor(free / 1024))
  end
end
out(mem .. "_VERSION=" .. tostring(_VERSION) .. "  jit global=" .. tostring(rawget(_G, "jit") ~= nil) .. "  reps=" .. REPS)

------------------------------------------------------------------------------
-- The operator chunk.  Lua 5.3 syntax only.  It returns the checks, the
-- deviation cases and the benches; this file runs and reports them.
------------------------------------------------------------------------------
local OPS = [==[
local N = tonumber
local byte, char, format = string.byte, string.char, string.format
local C, D, B = {}, {}, {}
local function chk(name, fn, want, only53) C[#C + 1] = { name = name, fn = fn, want = want, only53 = only53 } end
local function raises(name, fn, text) C[#C + 1] = { name = name, fn = fn, raises = text } end
local function skip(name, why) C[#C + 1] = { name = name, skip = why } end

-- Operands the parser cannot fold.
local K = {
  zero = N("0"), one = N("1"), m1 = N("-1"), m2 = N("-2"), five = N("5"),
  eight = N("8"), ff = N("255"), f0f0 = N("61680"), ff00 = N("65280"),
  x1234 = N("305419896"), dead = N("3735928559"), f15 = N("1.5"),
  p53 = N("9007199254740992"), s16 = "0x10", seed = N("2463534242"),
  rgb = N("3381759"),
}

-- CRC32 (reflected, polynomial 0xEDB88320), table-driven and bitwise.
local CRCT = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if (c & 1) ~= 0 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
  end
  CRCT[i] = c
end
local function crc_table(s)
  local c, T = 0xFFFFFFFF, CRCT
  for i = 1, #s do c = (c >> 8) ~ T[(c ~ byte(s, i)) & 0xFF] end
  return c ~ 0xFFFFFFFF
end
local function crc_bit(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do
    c = c ~ byte(s, i)
    for _ = 1, 8 do
      if (c & 1) ~= 0 then c = (c >> 1) ~ 0xEDB88320 else c = c >> 1 end
    end
  end
  return c ~ 0xFFFFFFFF
end

-- The benches' data: 4096 bytes, and 1024 integral doubles.
local parts = {}
for i = 1, 4096 do parts[i] = char((i * 7 + 3) % 256) end
local DATA = table.concat(parts)
local BYTES = {}
for i = 1, #DATA do BYTES[i] = byte(DATA, i) end
local FL = {}
for i = 1, 1024 do FL[i] = (i - 500) * 3.0 end

-- Part 1: known answers.
chk("crc32 table '123456789'", function() return crc_table("123456789") end, 3421780262)
chk("crc32 bitwise '123456789'", function() return crc_bit("123456789") end, 3421780262)
chk("crc32 table, 4 KB", function() return crc_table(DATA) end, 3823016021)
chk("crc32 bitwise, 4 KB", function() return crc_bit(DATA) end, 3823016021)
chk("1 << 31", function() return K.one << 31 end, 2147483648)
chk("1 << 32", function() return K.one << 32 end, 4294967296)
chk("1 << 63 == -2^63", function() return K.one << 63 end, -2^63)
chk("-1 >> 63", function() return K.m1 >> 63 end, 1)
chk("1 << 64", function() return K.one << 64 end, 0)
chk("-1 << 64", function() return K.m1 << 64 end, 0)
chk("-1 >> 64", function() return K.m1 >> 64 end, 0)
chk("255 << 100", function() return K.ff << 100 end, 0)
chk("8 << -2", function() return K.eight << -2 end, 2)
chk("8 >> -2", function() return K.eight >> -2 end, 32)
chk("1 >> -63 == -2^63", function() return K.one >> -63 end, -2^63)
chk("1 << -64", function() return K.one << -64 end, 0)
chk("0xDEADBEEF & 0xFFFF", function() return K.dead & 0xFFFF end, 48879)
chk("0xF0F0 | 0x0F0F", function() return K.f0f0 | 0x0F0F end, 65535)
chk("0xFF00 ~ 0x0FF0", function() return K.ff00 ~ 0x0FF0 end, 61680)
chk("x ~ x", function() return K.dead ~ K.dead end, 0)
chk("~0", function() return ~K.zero end, -1)
chk("~5", function() return ~K.five end, -6)
chk("~0x12345678 & 0xFFFFFFFF", function() return (~K.x1234) & 0xFFFFFFFF end, 3989547399)
chk("'0x10' | 0", function() return K.s16 | 0 end, 16, true)
raises("1.5 & 1 raises", function() return K.f15 & 1 end, "has no integer representation")
chk("pack bytes DE AD BE EF", function()
  local a, b, c, d = byte(char(0xDE, 0xAD, 0xBE, 0xEF), 1, 4)
  return (a << 24) | (b << 16) | (c << 8) | d
end, 3735928559)
chk("unpack 0xDEADBEEF", function()
  local w = K.dead
  return format("%d,%d,%d,%d", (w >> 24) & 0xFF, (w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF)
end, "222,173,190,239")
chk("pack rgb 33 99 FF", function()
  local r, g, b = byte(char(0x33, 0x99, 0xFF), 1, 3)
  return (r << 16) | (g << 8) | b
end, 3381759)
chk("unpack rgb 0x3399FF", function()
  local c = K.rgb
  return format("%d,%d,%d", (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF)
end, "51,153,255")
chk("xorshift32 step 1", function()
  local x = K.seed
  x = x ~ ((x << 13) & 0xFFFFFFFF)
  x = x ~ (x >> 17)
  x = x ~ ((x << 5) & 0xFFFFFFFF)
  return x
end, 723471715)
chk("masked rotr(0xDEADBEEF, 7)", function()
  local x = K.dead
  return (x >> 7) | ((x << 25) & 0xFFFFFFFF)
end, 3753728893)
chk("((-2 & 0xFFFFFFFF) >> 8) & 0xFF", function() return ((K.m2 & 0xFFFFFFFF) >> 8) & 0xFF end, 255)
chk("~0 >> 11", function() return (~K.zero) >> 11 end, 9007199254740991)

local hasPack = type(string.pack) == "function" and type(string.unpack) == "function"
if hasPack then
  chk("string.pack('<I4', 0x12345678)", function() return string.pack("<I4", K.x1234) end,
    char(0x78, 0x56, 0x34, 0x12))
  chk("string.unpack('<I4', 78 56 34 12)", function()
    local v, p = string.unpack("<I4", char(0x78, 0x56, 0x34, 0x12))
    return format("%d next %d", v, p)
  end, "305419896 next 5")
  chk("string.pack('>i8', -2)", function() return string.pack(">i8", K.m2) end,
    char(255, 255, 255, 255, 255, 255, 255, 254))
  chk("string.unpack('>i8', FF..FF FE)", function()
    return (string.unpack(">i8", char(255, 255, 255, 255, 255, 255, 255, 254)))
  end, -2)
  chk("string.unpack('>i8', 00 01 .. 07)", function()
    return (string.unpack(">i8", char(0, 1, 2, 3, 4, 5, 6, 7)))
  end, 283686952306183)
else
  skip("string.pack / string.unpack", "this CPU has no string.pack")
end

-- The deviation (U1-B): 5.3 returns the 64-bit integer, ours raises.
local hot_i
local function dev(name, op, want53, fn, at, last)
  D[#D + 1] = { name = name, op = op, want53 = want53, fn = fn, at = at, last = last,
    where = function() return hot_i end }
end
dev("2^53 | 1", "|", "9007199254740993", function() return K.p53 | 1 end)
dev("-1 >> 1", ">>", "9223372036854775807", function() return K.m1 >> 1 end)
dev("~0 >> 1", ">>", "9223372036854775807", function() return (~K.zero) >> 1 end)
dev("rotr(0xDEADBEEF, 7) unmasked", "|", "3753728893", function()
  local x = K.dead
  return ((x >> 7) | (x << 25)) & 0xFFFFFFFF
end)
dev("hot loop (2^53-1000+i) | 1", "|", "9007199254741993", function()
  local base, r = K.p53 - 1000
  for i = 1, 2000 do hot_i = i r = (base + i) | 1 end
  return r
end, 1000, 2000)

-- Part 2: the benches.  Each repeats a fixed inner workload n times.
local function bench_crc(n)
  local T, s, len, c = CRCT, DATA, #DATA
  for _ = 1, n do
    c = 0xFFFFFFFF
    for i = 1, len do c = (c >> 8) ~ T[(c ~ byte(s, i)) & 0xFF] end
    c = c ~ 0xFFFFFFFF
  end
  return c
end
local function bench_xs(n)
  local x
  for _ = 1, n do
    x = K.seed
    for _ = 1, 1000 do
      x = x ~ ((x << 13) & 0xFFFFFFFF)
      x = x ~ (x >> 17)
      x = x ~ ((x << 5) & 0xFFFFFFFF)
    end
  end
  return x
end
local function bench_pack(n)
  local Bt, acc, bs = BYTES
  for _ = 1, n do
    acc, bs = 0, 0
    for i = 1, 4096, 4 do
      local w = (Bt[i] << 24) | (Bt[i + 1] << 16) | (Bt[i + 2] << 8) | Bt[i + 3]
      acc = acc + w
      bs = bs + ((w >> 24) & 0xFF) + ((w >> 16) & 0xFF) + ((w >> 8) & 0xFF) + (w & 0xFF)
    end
  end
  return format("%d/%d", acc, bs)
end
local function bench_or0(n)
  local F, s = FL
  for _ = 1, n do
    s = 0
    for i = 1, 1024 do s = s + (F[i] | 0) end
  end
  return s
end
local function vsum(...)
  local s = 0
  for i = 1, select("#", ...) do s = s + (select(i, ...)) end
  return s
end
local function bench_sel(n)
  local r
  for _ = 1, n do
    r = 0
    for k = 1, 100 do r = r + vsum(k, 2, 3, 4, 5, 6, 7, 8) end
  end
  return r
end

-- References without bit operators.
local accr, bsr = 0, 0
for i = 1, 4096, 4 do
  accr = accr + BYTES[i] * 16777216 + BYTES[i + 1] * 65536 + BYTES[i + 2] * 256 + BYTES[i + 3]
end
for i = 1, 4096 do bsr = bsr + BYTES[i] end
local orr = 0
for i = 1, 1024 do orr = orr + FL[i] end
local selr = 0
for k = 1, 100 do selr = selr + k + 35 end

B[1] = { name = "crc32 table", unit = "byte", ops = #DATA, fn = bench_crc, want = 3823016021 }
B[2] = { name = "xorshift32", unit = "step", ops = 1000, fn = bench_xs, want = 3298996588 }
B[3] = { name = "pack+unpack", unit = "word", ops = 1024, fn = bench_pack, want = format("%d/%d", accr, bsr) }
B[4] = { name = "x | 0", unit = "op", ops = 1024, fn = bench_or0, want = orr }
B[5] = { name = "select(i,...)", unit = "call", ops = 800, fn = bench_sel, want = selr }

return { checks = C, devs = D, benches = B }
]==]

local opsfn, loaderr = load(OPS, "=ingame-bitops ops")
if not opsfn then
  out("needs Lua 5.3 or LuaJIT: this CPU (" .. arch .. ") cannot compile Lua 5.3's bitwise operators")
  out("  load: " .. tostring(loaderr))
  if ours then out("FAIL: the LuaJIT CPU should have them") end
  out("verdict: " .. (ours and "FAIL" or "not run") .. "  (" .. arch .. ", " .. where .. ")")
  finish()
  return
end
local okops, OP = pcall(opsfn)
if not okops or type(OP) ~= "table" then
  out("FAIL: the operator chunk raised while setting up: " .. tostring(OP))
  out("verdict: FAIL  (" .. arch .. ", " .. where .. ")")
  finish()
  return
end

-- Formatting.
local function fmtint(v)
  if type(v) ~= "number" then return tostring(v) end
  local ok, s = pcall(string.format, "%d", v)
  if ok then return s end
  return string.format("%.17g", v)
end
local function show(v)
  if type(v) == "number" then
    if v == math.floor(v) and v >= -2^63 and v < 2^63 then
      local s = fmtint(v)
      if v >= 65536 and v < 2^32 then s = s .. string.format(" (0x%X)", v) end
      return s
    end
    return string.format("%.17g", v)
  elseif type(v) == "string" then
    if v:find("[^%w%p ]") then
      return "bytes " .. (v:gsub(".", function(c) return string.format("%02X ", c:byte()) end)):sub(1, -2)
    end
    return '"' .. v .. '"'
  end
  return tostring(v)
end
local function msgof(e) return (tostring(e):gsub("^[^:]*:%d+: ", "")) end

------------------------------------------------------------------------------
-- Part 1.
------------------------------------------------------------------------------
local npass, nfail, ndev, nskip = 0, 0, 0, 0
out("Part 1: known answers")
for _, c in ipairs(OP.checks) do
  if c.skip then
    nskip = nskip + 1
    out("SKIP " .. c.name .. ": " .. c.skip)
  elseif c.only53 and is54 then
    nskip = nskip + 1
    out("SKIP " .. c.name .. ": Lua 5.4 has no string coercion for bitwise operators")
  else
    local ok, got = pcall(c.fn)
    if c.raises then
      if not ok and tostring(got):find(c.raises, 1, true) then
        npass = npass + 1
        out("PASS " .. c.name .. ": " .. msgof(got))
      else
        nfail = nfail + 1
        out("FAIL " .. c.name .. ": " .. (ok and ("returned " .. show(got)) or msgof(got)) .. "; want an error naming '" .. c.raises .. "'")
      end
    elseif ok and got == c.want then
      npass = npass + 1
      out("PASS " .. c.name .. " = " .. show(got))
    else
      nfail = nfail + 1
      out("FAIL " .. c.name .. ": got " .. (ok and show(got) or ("error: " .. msgof(got))) .. ", want " .. show(c.want))
    end
  end
end

out("Deviation (README, Lua dialect; U1-B): " .. (ours and "LuaJIT raises" or "5.3 gives the 64-bit integer"))
for _, d in ipairs(OP.devs) do
  local ok, got = pcall(d.fn)
  local at = d.where()
  local good, how
  if ours then
    local text = "result of '" .. d.op .. "' has more than 53 significant bits"
    good = (not ok) and tostring(got):find(text, 1, true) ~= nil and (d.at == nil or at == d.at)
    if ok then how = "returned " .. show(got) .. "; LuaJIT should raise"
    else how = "raised: " .. msgof(got) end
    if d.at then how = how .. " (at i = " .. tostring(at) .. ", want " .. d.at .. ")" end
  else
    good = ok and fmtint(got) == d.want53 and (d.last == nil or at == d.last)
    if ok then how = "5.3.6's value " .. fmtint(got) else how = "error: " .. msgof(got) end
    if not good then how = how .. ", want " .. d.want53 end
    if d.last then how = how .. " (loop ran to i = " .. tostring(at) .. ")" end
  end
  if good then
    ndev = ndev + 1
    out("DEV  " .. d.name .. ": deviation as documented: " .. how)
  else
    nfail = nfail + 1
    out("FAIL " .. d.name .. ": " .. how)
  end
end
out(string.format("Part 1: %d PASS, %d FAIL, %d deviation as documented, %d SKIP", npass, nfail, ndev, nskip))
flush()
yield()

------------------------------------------------------------------------------
-- Part 2.
------------------------------------------------------------------------------
local TARGET, LO, HI = 0.3, 0.2, 0.5

local function timeit(fn, n)
  local t0 = clock()
  local c = fn(n)
  return clock() - t0, c
end

local nbad = 0
out(string.format("Part 2: ns per op, median and min of %d reps", REPS))
out(string.format("%-13s %-4s %9s %9s %s", "bench", "per", "median", "min", "check"))
for _, b in ipairs(OP.benches) do
  -- Calibrate: grow n until a run takes 50 ms, then scale it to TARGET.
  local n, t, c = 1, 0, nil
  while true do
    t, c = timeit(b.fn, n)
    if t >= 0.05 or n >= 1e8 then break end
    if t < 0.005 then n = n * 8 else n = n * 2 end
  end
  yield()
  if t > 0 then n = math.max(1, math.floor(n * TARGET / t + 0.5)) end
  -- One warm-up rep, not counted; rescale once if it fell outside LO..HI.
  local tw = timeit(b.fn, n)
  if tw > 0 and (tw < LO or tw > HI) then n = math.max(1, math.floor(n * TARGET / tw + 0.5)) end
  yield()
  local times, sorted, bad, badval = {}, {}, false, nil
  for rep = 1, REPS do
    local dt, cr = timeit(b.fn, n)
    if cr ~= b.want then bad, badval = true, cr end
    times[rep] = dt
    sorted[rep] = dt
    yield()
  end
  table.sort(sorted)
  local med
  if REPS % 2 == 1 then med = sorted[(REPS + 1) / 2]
  else med = (sorted[REPS / 2] + sorted[REPS / 2 + 1]) / 2 end
  local scale = 1e9 / (n * b.ops)
  if bad then nbad = nbad + 1 end
  out(string.format("%-13s %-4s %9.2f %9.2f %s", b.name, b.unit, med * scale, sorted[1] * scale,
    bad and ("BAD " .. show(badval)) or "ok"))
  local ts = {}
  for i = 1, #times do ts[i] = string.format("%.3f", times[i]) end
  detail(string.format("n=%d x %d %s; warm-up %.3f s; reps (s): %s; check %s", n, b.ops, b.unit, tw,
    table.concat(ts, " "), bad and ("BAD " .. show(badval) .. ", want " .. show(b.want)) or ("ok " .. show(b.want))))
  flush()
end

out(string.format("Part 2: %d benches, %d with a BAD check", #OP.benches, nbad))
out("verdict: " .. ((nfail == 0 and nbad == 0) and "PASS" or "FAIL") .. "  (" .. arch .. ", " .. where .. ")")
finish()
