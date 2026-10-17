-- test/native/bitop/drv.lua -- runs a case file written by bitop/gen.lua.
-- Written by the round-3 width-fold reviewer (r3/review/widthfold/gen); its
-- U1-B rule by the main session (r3/b/gen); error kinds and the coverage line
-- by role C2 of the round-3 implementation.  test/native/run-bitjit.sh runs it.
--
--   <lua> drv.lua <cases file> <mode: shared|fresh> [N]
--
-- Prints one line per case: id, then per start "x y z h" (%.17g; nan/inf
-- normalised) or "ERR@<loop variable>:<kind>", the kind INEXACT(<op>),
-- NOINT, TYPE or OTHER:<text>.  "shared" runs the seven starts on one closure
-- (the traces of the first start serve the rest: side exits, side traces);
-- "fresh" loads the chunk again for each start.  Works under our LuaJIT and
-- PUC 5.3.6; under PUC, X and SAR apply U1-B's rule as the PUC twin's text
-- asks.  On stderr, one line:
--   #cov cases <n> starts <n> errors <n> errors-past-60 <n> traced <n> traces <n> aborts <n> jit <on|off>
-- errors-past-60 counts the runs that raised after their 60th iteration
-- (past the JIT's default hotloop of 56: the raise is likely a compiled
-- trace's exit); traced counts the cases during which a trace completed.
local file, mode, N = arg[1], arg[2] or "shared", tonumber(arg[3]) or 300
local cases = assert(loadfile(file))()
local IS53 = math.type ~= nil
local SAR
if IS53 then
  -- U1-B: a result is its double only if that double equals it.  r + 0.0 =
  -- 2^63 (r near maxinteger) has no integer and fails too.
  local mt = math.tointeger
  X = function(r, op)
    local f = r + 0.0
    if mt(f) ~= r then error("result of '" .. op .. "' has more than 53 significant bits (mask each operand to 32 bits first)", 2) end
    return f
  end
  -- ~>> (LuaJIT's, not 5.3's): a 64-bit arithmetic shift; a count of 64 or
  -- more fills with the sign, a negative count shifts left (oclj_bitop.h
  -- oclj_shiftar), and the result takes the rule like any other.
  SAR = function(a, k)
    local ai, ki = mt(a), mt(k)
    if ai == nil or ki == nil then error("number has no integer representation") end
    local r
    if ki < 0 then r = (ki <= -64) and 0 or (ai << -ki)
    elseif ki >= 64 then r = (ai < 0) and -1 or 0
    else r = (ai < 0) and ~((~ai) >> ki) or (ai >> ki) end
    return X(r, "~>>")
  end
end
local function fmt(v)
  if v ~= v then return "nan" end
  if v == math.huge then return "inf" end
  if v == -math.huge then return "-inf" end
  return string.format("%.17g", v)
end
-- The kind only classifies: the inexact error by its operator, whatever
-- follows "bits" (the hint, decided 2026-10-17; run-bitop.sh's matrix and
-- bitop_test.c BT3 pin the whole text).
local function kind(e)
  local m = tostring(e)
  local op = m:match("result of '([^']+)' has more than 53 significant bits")
  if op then return "INEXACT(" .. op .. ")" end
  if m:find("has no integer representation", 1, true) then return "NOINT" end
  if m:find("attempt to perform", 1, true) then return "TYPE" end
  return "OTHER:" .. m:gsub("^[^\n]-:%d+: ", ""):gsub("[|\t\n]", "/")
end
local hasjit = type(jit) == "table" and jit.status and jit.status() and jit.attach
local nstop, nabort = 0, 0
if hasjit then
  jit.attach(function(what)
    if what == "stop" then nstop = nstop + 1 elseif what == "abort" then nabort = nabort + 1 end
  end, "trace")
end
local STARTS = {
  { 1, 2, 3 }, { 2^52 + 1, -3, 7 }, { -1, 2^62, -2^63 },
  { 9223372036854774784, 12345, -987654321 },  -- 0x7ffffffffffffc00 (exact)
  { 2^53 - 1, 2^53 + 2, -2^53 }, { 0, 0, 0 }, { 6755399441055744, 3, 1.5 },
}
local out = {}
local nstarts, nerr, nerr60, ntraced = 0, 0, 0, 0
for id = 1, #cases do
  local src = cases[id]
  local res = {}
  local run, getit, iterof
  local s0 = nstop
  for s = 1, #STARTS do
    if mode == "fresh" or not run then
      local chunk = assert(load(src, "=c" .. id))
      run, getit, iterof = chunk(SAR, table.sort)
    end
    local st = STARTS[s]
    local x0, y0, z0 = st[1], st[2], st[3]
    if IS53 then x0, y0, z0 = x0 + 0.0, y0 + 0.0, z0 + 0.0 end
    local ok, a, b, c, d = pcall(run, N, x0, y0, z0)
    nstarts = nstarts + 1
    if ok then
      res[s] = fmt(a) .. " " .. fmt(b) .. " " .. fmt(c) .. " " .. fmt(d)
    else
      nerr = nerr + 1
      if iterof(getit(), N) > 60 then nerr60 = nerr60 + 1 end
      res[s] = string.format("ERR@%d:%s", getit(), kind(a))
    end
  end
  if nstop > s0 then ntraced = ntraced + 1 end
  out[#out + 1] = id .. "\t" .. table.concat(res, " | ")
end
io.write(table.concat(out, "\n"), "\n")
io.stderr:write(string.format("#cov cases %d starts %d errors %d errors-past-60 %d traced %d traces %d aborts %d jit %s\n",
  #cases, nstarts, nerr, nerr60, ntraced, nstop, nabort, hasjit and "on" or "off"))
