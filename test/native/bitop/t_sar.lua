-- test/native/bitop/t_sar.lua -- "~>>", LuaJIT 3.0's arithmetic right shift
-- (a2ce8114; not Lua 5.3), kept and made 64-bit by round 3 (U8, decided
-- 2026-10-17): sar on int64, a count of 64 or more fills with the sign, a
-- negative count shifts left (0 at -64 or below), the result its double or,
-- with more than 53 significant bits, an error (U1-B).  19 operands x 23
-- counts: 437 cases (r3/synth's t_sar.lua, 2026-10-17, and two string
-- operands).  An operand that is a double has at most 53 significant bits,
-- and neither a sar nor a left shift widens that span, so only a string,
-- which reads as an exact int64 (U3), can give ~>> an inexact result: those
-- two are the only cases where "result of '~>>'" can appear.
-- test/native/run-bitop.sh part 1 runs it on the build's luajit.exe, JIT on
-- and -joff; part 2 runs the model on PUC Lua 5.3.6.
--
-- One line per case: "<x> ~>> <n> TAB <result>", the result as %.17g, or
-- "E:NOINT" (no integer representation), "E:TYPE", or "E:<message>".
--
-- On our luajit.exe (no argument), each case is computed four ways: folded
-- (literal operands), interpreted (runtime operands), and in a loop of 200
-- iterations, which compiles, once with a variable count and once with the
-- count a literal (the recorder decides a constant count at record time,
-- oclj_bitop_rec.c).  The line holds the result if all four agree, else
-- "SPLIT K=.. V=.. H=.." (and "/Hk=.." if the constant-count loop differs).
-- The output must equal t_sar.expect exactly.
-- On PUC Lua 5.3.6, one argument, X or raw, as t_ops.lua's header says: the
-- model below, written in 5.3's integer operators, its one result through X
-- (raw: printed with %d, and traced).  The model's own 5.3 operators are its
-- implementation, not the operator under test, so they are not traced.
local MODE = arg and arg[1]
local ISLJ = type(jit) == "table"
if ISLJ then
  assert(MODE == nil, "t_sar.lua takes no argument on LuaJIT")
else
  assert(_VERSION == "Lua 5.3" and math.type, "t_sar.lua runs on LuaJIT or on PUC Lua 5.3.6")
  assert(MODE == "X" or MODE == "raw", "t_sar.lua on PUC Lua 5.3: one argument, X or raw")
end

local XS = { "0", "1", "5", "-1", "-5", "2^31", "-2^31", "2^52+1", "-2^53", "2^62", "-2^62",
  "-2^63", "0x7ffffffffffffc00", "-0x7ffffffffffffc00", "1.5", "'8'", "2^63",
  "'0x7fffffffffffffff'", "'-0x7fffffffffffffff'" }
local NS = { "0", "1", "4", "31", "32", "33", "52", "53", "62", "63", "64", "65", "100",
  "-1", "-4", "-31", "-63", "-64", "-65", "-0x1p63", "0x1p62", "1.5", "'2'" }
local function val(s) return assert(load("return " .. s))() end

local function show(ok, r)
  if not ok then
    local m = tostring(r):gsub("^[^:]*:%d+: ", "")
    if m:find("no integer representation", 1, true) then return "E:NOINT" end
    if m:find("bitwise operation", 1, true) then return "E:TYPE" end
    return "E:" .. m
  end
  if MODE == "raw" and math.type(r) == "integer" then return string.format("%d", r) end
  return string.format("%.17g", r)
end

local out = {}
if not ISLJ then
  local trace
  local X
  if MODE == "X" then
    X = function(op, r)
      local f = r + 0.0
      if math.tointeger(f) ~= r then
        error("result of '" .. op .. "' has more than 53 significant bits (mask each operand to 32 bits first)", 0)
      end
      return f
    end
  else
    X = function(op, r)
      assert(math.type(r) == "integer", "a model result that is not an integer")
      trace[#trace + 1] = op .. "=" .. string.format("%d", r)
      return r
    end
  end
  -- The model: an operand converts as 5.3.6's tointeger (a string by its
  -- numeral's value); then case by case as oclj_shiftar (oclj_bitop.h).
  local model = assert(load([[
    local X, x, n = ...
    x = math.tointeger(x) or (type(x) == "string" and math.tointeger(tonumber(x)))
    n = math.tointeger(n) or (type(n) == "string" and math.tointeger(tonumber(n)))
    if not x or not n then error("number has no integer representation") end
    local r
    if n < 0 then r = (n <= -64) and 0 or (x << -n)
    elseif n >= 64 then r = (x < 0) and -1 or 0
    elseif x >= 0 then r = x >> n
    else r = ~((~x) >> n) end
    return X("~>>", r)
  ]]))
  for _, xs in ipairs(XS) do for _, ns in ipairs(NS) do
    trace = {}
    local res = show(pcall(model, X, val(xs), val(ns)))
    if MODE == "raw" then res = res .. "\t" .. table.concat(trace, " ") end
    out[#out + 1] = xs .. " ~>> " .. ns .. "\t" .. res
  end end
else
  local f = assert(load("local x, n = ... return x ~>> n"))
  for _, xs in ipairs(XS) do for _, ns in ipairs(NS) do
    local k = show(pcall(assert(load("return (" .. xs .. ") ~>> (" .. ns .. ")"))))
    local v = show(pcall(f, val(xs), val(ns)))
    local h
    do
      local x, n = val(xs), val(ns)
      local g = assert(load("local x, n = ... local r for i = 1, 200 do r = x ~>> n end return r"))
      h = show(pcall(g, x, n))
      local g2 = assert(load("local x = ... local r for i = 1, 200 do r = x ~>> (" .. ns .. ") end return r"))
      local h2 = show(pcall(g2, x))
      if h2 ~= h then h = h .. "/Hk=" .. h2 end
    end
    local r = (k == v and v == h) and v or ("SPLIT K=" .. k .. " V=" .. v .. " H=" .. h)
    out[#out + 1] = xs .. " ~>> " .. ns .. "\t" .. r
  end end
end
io.write(table.concat(out, "\n"), "\n")
