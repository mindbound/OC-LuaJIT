-- test/native/bitop/twin.lua -- one text, two dialects: the PUC twin's
-- machinery for t_idx.lua, t_cnt33.lua and t_idx2.lua (the table-index
-- fold's suites, the CRC32 follow-up, roadmap row 209).  Loaded with dofile
-- by each suite from its own directory; returns a table and, under PUC Lua
-- 5.3, defines the globals X and SAR that the PUC text calls.
--
-- What twins: the operators, table keys and shift counts.  What does not:
-- a library's integer arguments.  LuaJIT reads them as int32s
-- (lj_lib_checkint, lj_opt_narrow_toint), 5.3.6 as lua_Integers, so
-- string.byte, sub, find, char and rep, table.concat and unpack, and select
-- answer differently at and past +-2^31 (proto-folda, 2026-10-20); a suite
-- compares those consumers with -joff only.
--
-- A test is written ONCE, with every bit operator's result wrapped in
-- X(...), as t_jit2.lua writes its loops.  Our text drops each X
-- (X(a << b) is (a << b)).  PUC's keeps it and names the operator,
-- X(a << b, '<<'), and X applies round 3's rule U1-B: the result's double
-- if it equals it, else "result of '<op>' has more than 53 significant bits
-- (mask each operand to 32 bits first)".  An X around LuaJIT's ~>>, which
-- 5.3 lacks, becomes SAR(a, b) on PUC: 5.3.6's integers, shifted
-- arithmetically as oclj_bitop.h's oclj_shiftar does (a count of 64 or more
-- fills with the sign, a negative count shifts left), under the same rule.
-- X and SAR are drv.lua's.  So 5.3's integer arithmetic between operators
-- becomes the double arithmetic ours does, and a result ours refuses is
-- refused there too.
--
-- check(name, src) is the mechanical check that the text says what it
-- means: each X wraps exactly one operator at its own top level, and our
-- text has as many operators as the source has X's.  A suite that finds a
-- problem prints INSTRUMENT and exits 2 before running anything.
local M = {}
M.IS53 = math.type ~= nil

-- The kind of an error, the same words on both VMs (t_jit2.lua's KIND).
function M.KIND(e)
  local m = tostring(e):gsub("^[^\n]-:%d+: ", "")
  local op = m:match("^result of '([^']+)' has more than 53 significant bits")
  if op then return "INEXACT(" .. op .. ")" end
  if m:find("has no integer representation", 1, true) then return "NOINT" end
  local t = m:match("^attempt to perform [%a ]+ on .-%(?a (%a+) value")
  if t then return "TYPE:" .. t end
  return "OTHER:" .. m:gsub("[,\t\n]", "/")
end

if M.IS53 then
  local mt = math.tointeger
  X = function(r, op)
    local f = r + 0.0
    if mt(f) ~= r then error("result of '" .. op .. "' has more than 53 significant bits (mask each operand to 32 bits first)", 2) end
    return f
  end
  SAR = function(a, k)
    local ai, ki = mt(a), mt(k)
    if ai == nil or ki == nil then error("number has no integer representation", 2) end
    local r
    if ki < 0 then r = (ki <= -64) and 0 or (ai << -ki)
    elseif ki >= 64 then r = (ai < 0) and -1 or 0
    else r = (ai < 0) and ~((~ai) >> ki) or (ai >> ki) end
    local f = r + 0.0
    if mt(f) ~= r then error("result of '~>>' has more than 53 significant bits (mask each operand to 32 bits first)", 2) end
    return f
  end
end

-- The bit operators of a text outside its strings and comments: ~>>, <<,
-- >>, &, |, and ~ (binary or unary; not ~=).  Each is { op, start, stop }.
-- top: only those at nesting depth 0.
local function scanops(s, top)
  local ops, depth, i, n = {}, 0, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == '"' or c == "'" then
      local j = i + 1
      while j <= n and s:sub(j, j) ~= c do
        if s:byte(j) == 92 then j = j + 1 end  -- an escaped character
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
        if not top or depth == 0 then ops[#ops + 1] = { op, i, i + #op - 1 } end
        i = i + #op
      else
        i = i + 1
      end
    end
  end
  return ops
end
M.scanops = scanops

function M.ourtext(s) return (s:gsub("%f[%w_]X%(", "(")) end

function M.puctext(s)
  return (s:gsub("%f[%w_]X(%b())", function(p)
    local inner = M.puctext(p:sub(2, -2))
    local ops = scanops(inner, true)
    if #ops ~= 1 then
      error("X(" .. inner .. ") wraps " .. #ops .. " operators at its top level, not 1", 0)
    end
    local op = ops[1]
    if op[1] == "~>>" then
      return "SAR(" .. inner:sub(1, op[2] - 1) .. ", " .. inner:sub(op[3] + 1) .. ")"
    end
    return "X(" .. inner .. ", '" .. op[1] .. "')"
  end))
end

-- check(name, src): nil, or what is wrong with the text.
function M.check(name, src)
  local nx = select(2, src:gsub("%f[%w_]X%(", ""))
  local nops = #scanops(M.ourtext(src), false)
  if nx ~= nops then return name .. ": " .. nops .. " operators but " .. nx .. " X's" end
  local ok, e = pcall(M.puctext, src)
  if not ok then return name .. ": " .. e end
  return nil
end

-- The text this VM runs.
function M.text(src) return M.IS53 and M.puctext(src) or M.ourtext(src) end

-- Coverage, on LuaJIT with the JIT on: attach(get) counts, for the function
-- get() names when a trace stops, the traces that completed and the
-- CONV int.i64 instructions in them (mode (IRT_INT<<5)|IRT_I64 = 0x275, the
-- table-index fold's; read as op2 % 1024, so string.buffer's #buf, which
-- records a NONE-mode one, 0x1275, would count too, and no suite here uses
-- string.buffer).  Returns a reader of { traced, convs, jit }.
function M.coverage()
  local hasjit = type(jit) == "table" and jit.status and jit.status() and jit.attach
  local st = { traced = 0, cases = 0, convs = 0, jit = hasjit and "on" or "off" }
  if not hasjit then return st, function() end end
  local okv, vmdef = pcall(require, "jit.vmdef")
  local oku, jutil = pcall(require, "jit.util")
  if not (okv and oku) then
    st.jit = "on(no jit.vmdef: set LUA_PATH to the build's src/?.lua)"
    return st, function() end
  end
  local CONV
  for o = 0, #vmdef.irnames / 6 - 1 do
    if vmdef.irnames:sub(o * 6 + 1, o * 6 + 6) == "CONV  " then CONV = o end
  end
  local cur, hit = nil, false
  jit.attach(function(what, tr, func)
    if what == "stop" and func == cur then
      st.traced = st.traced + 1
      if not hit then hit = true; st.cases = st.cases + 1 end
      local nins = jutil.traceinfo(tr).nins
      for ref = 1, nins do
        local _, ot, _, op2 = jutil.traceir(tr, ref)
        if ot and math.floor(ot / 256) == CONV and op2 % 1024 == 629 then st.convs = st.convs + 1 end
      end
    end
  end, "trace")
  return st, function(f) cur, hit = f, false end
end

return M
