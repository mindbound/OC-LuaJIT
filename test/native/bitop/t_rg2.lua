-- test/native/bitop/t_rg2.lua -- loops at the 2^53 boundary of a result's
-- guard.  Written by proto-rg2 (2026-10-20) for the CRC32 follow-up's rg2,
-- a loop-body range guard that replaced a result guard's round trip through
-- a double by an integer test that the result lies in [-2^53, 2^53), and
-- speculated: an exact result outside it left the trace.  rg2 was
-- prototyped, measured (3-7x slower on loops whose exact results pass 2^53)
-- and not shipped (roadmap row 209); these loops stay, since they hold the
-- boundary on any build: every result guard, removed by the width rule or
-- kept, must agree with the interpreter at and past 2^53.  They put results
-- in range at both bounds, exact outside it (in bits 53-63), and inexact
-- just past it, many of them crossing the bound after the loop compiled.
-- test/native/run-bitjit.sh runs it (part floor) under our luajit.exe
-- with several JIT option sets and with -joff (every output must equal
-- -joff's), and under PUC Lua 5.3.6 (which must equal -joff's too, but for
-- the one LuaJIT-only loop, sar-edge).
--
--   <vm> t_rg2.lua
--
-- The format and the one-text-two-dialects machinery are t_jit2.lua's: each
-- test is run as f(400, out), one result per iteration, %.17g, and a raise
-- ends the list with ERR@<iteration>:<kind>.  Every bit operator's result is
-- wrapped in X(...): our text drops each X, PUC's keeps it with the
-- operator, and X applies U1-B's rule (the result's double if it equals it,
-- else the inexact error).  Each X must wrap exactly one operator at its own
-- top level (else INSTRUMENT, exit 2).
local N = 400
local IS53 = math.type ~= nil
local fmt = string.format

KIND = function(e)
  local m = tostring(e):gsub("^[^\n]-:%d+: ", "")
  local op = m:match("^result of '([^']+)' has more than 53 significant bits")
  if op then return "INEXACT(" .. op .. ")" end
  if m:find("has no integer representation", 1, true) then return "NOINT" end
  local t = m:match("^attempt to perform [%a ]+ on .-%(?a (%a+) value")
  if t then return "TYPE:" .. t end
  return "OTHER:" .. m:gsub("[,\t\n]", "/")
end
if IS53 then
  local tointeger = math.tointeger
  X = function(r, op)
    local f = r + 0.0
    if tointeger(f) ~= r then error("result of '" .. op .. "' has more than 53 significant bits (mask each operand to 32 bits first)", 2) end
    return f
  end
end

-- t_jit2.lua's scanner: the bit operators outside strings and comments
-- (~>>, <<, >>, &, |, ~ binary or unary, not ~=); top: depth 0 only.
local function scanops(s, top)
  local ops, depth, i, n = {}, 0, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == '"' or c == "'" then
      local j = i + 1
      while j <= n and s:sub(j, j) ~= c do
        if s:byte(j) == 92 then j = j + 1 end
        j = j + 1
      end
      i = j + 1
    elseif s:sub(i, i + 1) == "--" then
      i = (s:find("\n", i, true) or n) + 1
    elseif c == "(" or c == "[" or c == "{" then depth = depth + 1; i = i + 1
    elseif c == ")" or c == "]" or c == "}" then depth = depth - 1; i = i + 1
    elseif s:sub(i, i + 1) == "~=" then i = i + 2
    else
      local op = (s:sub(i, i + 2) == "~>>" and "~>>") or
        ((s:sub(i, i + 1) == "<<" or s:sub(i, i + 1) == ">>") and s:sub(i, i + 1)) or
        ((c == "~" or c == "&" or c == "|") and c) or nil
      if op then
        if not top or depth == 0 then ops[#ops + 1] = op end
        i = i + #op
      else
        i = i + 1
      end
    end
  end
  return ops
end
local function ourtext(s) return (s:gsub("%f[%w_]X%(", "(")) end
local function puctext(s)
  return (s:gsub("%f[%w_]X(%b())", function(p)
    local inner = puctext(p:sub(2, -2))
    local ops = scanops(inner, true)
    if #ops ~= 1 then
      error("X(" .. inner .. ") wraps " .. #ops .. " operators at its top level, not 1", 0)
    end
    return "X(" .. inner .. ", '" .. ops[1] .. "')"
  end))
end

local T, instr = {}, {}
local function test(name, src, lj_only)
  local ours = ourtext(src)
  local nx = select(2, src:gsub("%f[%w_]X%(", ""))
  local nops = #scanops(ours, false)
  if nx ~= nops then instr[#instr + 1] = name .. ": " .. nops .. " operators but " .. nx .. " X's" end
  local ok, puc = pcall(puctext, src)
  if not ok then instr[#instr + 1] = name .. ": " .. puc end
  if lj_only and IS53 then return end
  T[#T + 1] = { name = name, src = IS53 and puc or ours }
end

-- IN RANGE: results of unknown width (table values, carried) inside
-- [-2^53, 2^53), negative ones and both bounds among them.  No exit.
test("fit-neg", [[
  local n, out = ...
  local V = { -1, -2^53, -2^53 + 1, -2^52 - 5, -12345678901234, 2^53 - 1, 2^52 + 3, -2^52 }
  local acc = 0
  for i = 1, n do acc = X(acc ~ X(V[X(i & 7) + 1] & -2)); out[#out+1] = acc end ]])
test("fit-near", [[
  local n, out = ...
  local W = { 2^53 - 1, -2^53, 2^52 + 12345, -2^52 - 777 }
  local acc = 0
  for i = 1, n do acc = X(acc ~ X(W[X(i & 3) + 1] | 0)); out[#out+1] = acc end ]])
test("crc-table", [[
  local n, out = ...
  local T = {}
  for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
      if X(c & 1) == 1 then c = X(X(c >> 1) ~ 0xedb88320) else c = X(c >> 1) end
    end
    T[i] = c
  end
  local s = string.rep("The quick brown fox jumps over the lazy dog. ", 4)
  local crc = 0xffffffff
  for k = 1, n do
    crc = X(T[X(X(crc ~ s:byte((k - 1) % #s + 1)) & 0xff)] ~ X(crc >> 8))
    out[#out+1] = crc
  end ]])
-- CROSSING UP, LATE: (i & 255) >> 6 is 0 below 64, then 1, 2, 3, and 0 again
-- from 256.  | 1 gives 2^52 + 1 (exact) and then 2^53 + 1, which raises at
-- 128; | 2 gives 2^53 + 2 and 3 * 2^52 + 2, exact and outside: no raise.
test("cross-up", [[
  local n, out = ...
  for i = 1, n do out[#out+1] = X(X(X(X(i & 255) >> 6) << 52) | 1) end ]])
test("cross-up-exact", [[
  local n, out = ...
  for i = 1, n do out[#out+1] = X(X(X(X(i & 255) >> 6) << 52) | 2) end ]])
-- CROSSING DOWN: -2^52 + 1, -2^53 + 1 (exact, inside), then -3 * 2^52 + 1,
-- which raises at 192; | 0 gives -2^53 (the bound, inside) and -3 * 2^52
-- (exact, outside).
test("cross-down", [[
  local n, out = ...
  for i = 1, n do out[#out+1] = X((X(X(i & 255) >> 6) * -2^52) ~ 1) end ]])
test("cross-down-exact", [[
  local n, out = ...
  for i = 1, n do out[#out+1] = X((X(X(i & 255) >> 6) * -2^52) | 0) end ]])
-- -2^53 (inside) and 2^53 (exact, outside), alternating.
test("edge-pm", [[
  local n, out = ...
  for i = 1, n do out[#out+1] = X(((X(i & 1) * 2 - 1) * 2^53) | 0) end ]])
-- EXACT IN BITS 53-63: counters shifted high, -2^63, flags, top-bit masks,
-- i << 45 past 2^53 from i = 256, and a carried value in bits 52-53.
test("bits-hi", [[
  local n, out = ...
  for i = 1, n do out[#out+1] = X(X(i & 7) << 60) + X(X(i & 1) << 63) end ]])
test("flags", [[
  local n, out = ...
  for i = 1, n do out[#out+1] = X(1 << (53 + i % 11)) end ]])
test("top-mask", [[
  local n, out = ...
  for i = 1, n do out[#out+1] = X(X(i << 50) & -2^56) end ]])
test("shl-grow", [[
  local n, out = ...
  for i = 1, n do out[#out+1] = X(i << 45) end ]])
test("carry-big", [[
  local n, out = ...
  local x = 0
  for i = 1, n do x = X(x ~ X(X(i & 3) << 52)); out[#out+1] = x end ]])
-- A carried value that crosses 2^53 late and then picks up a low bit: the
-- carried result is exact and outside, then raises at 192.
test("carry-raise", [[
  local n, out = ...
  local x = 0
  for i = 1, n do
    x = X(x ~ X(X(X(i & 255) >> 6) << 52))
    if i >= 192 then x = X(x | 1) end
    out[#out+1] = x
  end ]])
-- ~>> (LuaJIT only): -2^63 ~>> k is -2^53 at k = 10, exact and outside below.
test("sar-edge", [[
  local n, out = ...
  for i = 1, n do out[#out+1] = X(-2^63 ~>> (i % 20)) end ]], true)

if #instr > 0 then
  print("INSTRUMENT: t_rg2's X-wrapped texts are wrong:\n  " .. table.concat(instr, "\n  "))
  os.exit(2)
end
local lines = {}
for _, t in ipairs(T) do
  local f = assert(load(t.src, "=" .. t.name))
  local out = {}
  local ok, e = pcall(f, N, out)
  local parts = {}
  for k = 1, #out do
    local v = out[k]
    parts[k] = type(v) == "number" and fmt("%.17g", v) or tostring(v)
  end
  if not ok then parts[#parts + 1] = "ERR@" .. (#out + 1) .. ":" .. KIND(e) end
  lines[#lines + 1] = t.name .. "\t" .. table.concat(parts, ",")
end
io.write(table.concat(lines, "\n"), "\n")
