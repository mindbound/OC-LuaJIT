-- test/native/bitop/t_ops.lua -- Lua 5.3's bitwise operators with RUNTIME
-- operands, which the parser cannot fold: & | ~ over every pair of a 47-value
-- operand list, << >> over a 12-value list and a 28-value count list (and
-- every operand shifted by 1), unary ~ over the 47 values: 7440 cases (r3/vm's
-- t_ops.lua, 2026-10-17).  Then a few named extras (string operands, which only
-- the C path computes) and the operand naming of the error messages.
-- test/native/run-bitop.sh part 1 runs it on the build's luajit.exe, JIT on
-- and -joff; part 2 runs it on PUC Lua 5.3.6.
--
-- One line per case: "<id> TAB <result>", the result a number as %.17g or
-- "ERR:<message without its chunk:line: prefix>".  22 ids occur twice: the 11
-- operands in both SHA and A shifted by 1, once per loop, the same case
-- computed twice (kept, so the matrix stays r3/vm's 7440).  run-bitop.sh
-- compares line by line and keeps repeated ids, so neither copy can hide.
--
-- On our luajit.exe (no argument): the operators as they are.  The output must
-- equal t_ops.expect exactly.
-- On PUC Lua 5.3.6, one argument:
--   X    every operator's result goes through X(), U1-B's rule (decided
--        2026-10-17): the result's double if that double equals it
--        (math.tointeger(r + 0.0) == r), else the error "result of '<op>' has
--        more than 53 significant bits (mask each operand to 32 bits first)"
--        (the hint decided 2026-10-17).  Reworded to LuaJIT's word order
--        (reword.lua), this must equal t_ops.expect in every line but the ones
--        deviations.txt lists.
--   raw  no X: "<id> TAB <result> TAB <trace>", an integer printed with %d
--        (5.3.6's exact value: %.17g would print its nearest double and hide
--        what X refuses), the trace one "<op>=<integer>" per operator evaluated.
--        xrule.lua holds the X run to this one: X raises exactly where an
--        operator's integer has more than 53 significant bits, and otherwise
--        returns that integer.
local MODE = arg and arg[1]
local ISLJ = type(jit) == "table"
if ISLJ then
  assert(MODE == nil, "t_ops.lua takes no argument on LuaJIT")
else
  assert(_VERSION == "Lua 5.3" and math.type, "t_ops.lua runs on LuaJIT or on PUC Lua 5.3.6")
  assert(MODE == "X" or MODE == "raw", "t_ops.lua on PUC Lua 5.3: one argument, X or raw")
end

local A = {
  "0", "1", "3", "5", "-1", "-2", "2^31-1", "2^31", "-2^31", "-2^31-1",
  "2^32-1", "2^32", "2^32+1", "2^52+1", "2^53", "2^53+2", "-2^53-2",
  "2^62", "2^63-1024", "2^63", "-2^63", "-2^63-2048", "2^64", "2^70",
  "1.5", "-0.5", "0.5", "2.5", "-0.0", "1/0", "-1/0", "0/0",
  "'3'", "'0x10'", "' 7 '", "'1e2'", "'1.5'", "'abc'", "''",
  "'9007199254740993'", "'0x7fffffffffffffff'", "'0xffffffffffffffff'",
  "'-9223372036854775808'", "'9223372036854775808'",
  "nil", "true", "{}",
}
local SH = {
  "0", "1", "31", "32", "33", "52", "53", "63", "64", "65", "100",
  "-1", "-31", "-32", "-33", "-63", "-64", "-65", "1.5", "2^31", "2^32",
  "-2^63", "2^63", "1/0", "0/0", "'3'", "'-1'", "'1.5'",
}
local SHA = { "1", "-1", "3", "5", "2^31", "2^32+1", "2^52+1", "2^62", "-2^63", "2^63-1024", "1.5", "'1'" }

-- Runtime operands, beyond the cross products.  A string operand never takes
-- the interpreter's fast path (vm_x64.dasc), so these are computed by the C
-- path alone (oclj_bitop_meta.c): "-1" >> 1 is 2^63-1, which must raise there
-- too, not come back as the rounded double (negctl-bitop.sh INEXACT-SLOW).
local EXTRA = {
  { ">>", "'-1'", "1" },
  { ">>", "'-1'", "'1'" },
  { "|", "'0x4000000000000000'", "1" },
  { "<<", "'1'", "62" },
  { "~u", "'0x20000000000000'" },
  { "~u", "'-0x20000000000000'" },
}

-- Which operand an error names, and how.  "@(" marks the one operator: on
-- LuaJIT it is a plain "(", on PUC it becomes "X('<op>', ".  5.3.6 names the
-- operand "(kind 'name')" after the message (ldebug.c varinfo); LuaJIT names it
-- before, as all its operator errors do (U5); reword.lua maps one to the other.
-- The two "field '?'" cases are RESID-varinfo (deviations.txt): LuaJIT's
-- lj_debug_slotname (lj_debug.c:255-295) names the results of MOV, GGET,
-- TGETS and UGET only, so a TGETV result is named nothing.
local NAMING = {
  { "global type", "|", "gT = {} return @(gT | 1)" },
  { "global noint", "|", "gF = 1.5 return @(gF | 1)" },
  { "upvalue type", "&", "local u = {} return (function() return @(1 & u) end)()" },
  { "upvalue noint", "&", "local u = 1.5 return (function() return @(u & 1) end)()" },
  { "local type", "~", "local a = true return @(a ~ 1)" },
  { "local noint", "<<", "local a = 2^63 return @(a << 1)" },
  { "local noint count", ">>", "local n = 0.5 return @(1 >> n)" },
  { "field type", "|", "local t = {x = true} return @(t.x | 1)" },
  { "field noint", "~", "local t = {x = 1.5} return @(t.x ~ 1)" },
  { "field ? type", "|", "local t, k = {x = {}}, 'x' return @(t[k] | 1)" },
  { "field ? noint", "<<", "local t, k = {x = 1.5}, 'x' return @(t[k] << 1)" },
  { "constant string", "|", "return @('abc' | 1)" },
  { "constant nil", "|", "return @(nil | 1)" },
  { "constant boolean", "<<", "return @(1 << true)" },
  { "constant float", "|", "local a = 1 return @(a | 1.5)" },
  { "constant numeric string", "|", "local a = 1 return @(a | '1.5')" },
  { "unary local type", "~", "local a = {} return @(~a)" },
  { "unary field noint", "~", "local t = {x = 0.5} return @(~t.x)" },
  { "call result noint", "|", "local function f() return 1.5 end return @(f() | 1)" },
  { "string local inexact", ">>", "local a = '-1' return @(a >> 1)" },
  { "unary local inexact", "~", "local a = 2^53 return @(~a)" },
}

local function val(src)
  local f = assert(load("return " .. src))
  return f()
end

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
elseif MODE == "raw" then
  X = function(op, r)
    assert(math.type(r) == "integer", "a 5.3 bitwise result that is not an integer")
    trace[#trace + 1] = op .. "=" .. string.format("%d", r)
    return r
  end
end

local function fmt(ok, r)
  if not ok then
    local m = tostring(r):gsub("^[^:]*:%d+: ", "")
    return "ERR:" .. m
  end
  if type(r) == "number" then
    if MODE == "raw" and math.type(r) == "integer" then return string.format("%d", r) end
    return string.format("%.17g", r)
  end
  return type(r) .. ":" .. tostring(r)
end

local out = {}
local function emit(id, res) out[#out + 1] = id .. "\t" .. res end

-- f(...) as the operator op computes it here: on LuaJIT f itself, on PUC f's
-- result through X.
local function run(op, f, ...)
  if ISLJ then return fmt(pcall(f, ...)) end
  trace = {}
  local res = fmt(pcall(function(...) return X(op, f(...)) end, ...))
  if MODE == "raw" then res = res .. "\t" .. table.concat(trace, " ") end
  return res
end

local OPS = { "&", "|", "~", "<<", ">>" }
local F = {}
for _, op in ipairs(OPS) do
  F[op] = assert(load("local a, b = ... return a " .. op .. " b"))
end
F["~u"] = assert(load("local a = ... return ~a"))
local SYM = { ["~u"] = "~" }

local function case(op, sa, sb)
  if op == "~u" then
    emit("~u " .. sa, run("~", F["~u"], val(sa)))
  else
    emit(op .. " " .. sa .. " " .. sb, run(SYM[op] or op, F[op], val(sa), val(sb)))
  end
end

for _, op in ipairs({ "&", "|", "~" }) do
  for _, sa in ipairs(A) do
    for _, sb in ipairs(A) do case(op, sa, sb) end
  end
end
for _, op in ipairs({ "<<", ">>" }) do
  for _, sa in ipairs(SHA) do
    for _, sb in ipairs(SH) do case(op, sa, sb) end
  end
  for _, sa in ipairs(A) do case(op, sa, "1") end
end
for _, sa in ipairs(A) do case("~u", sa) end
for _, e in ipairs(EXTRA) do case(e[1], e[2], e[3]) end

-- The naming cases.  On PUC, raw mode also runs each chunk as written (no X)
-- and requires the X-wrapped chunk, with the identity X, to give the same line:
-- the wrapper must not change which operand is named or how.
local bad = 0
for _, c in ipairs(NAMING) do
  local id, op, src = "name: " .. c[1], c[2], c[3]
  assert(select(2, src:gsub("@%(", "")) == 1, "a naming case needs exactly one @(")
  if ISLJ then
    emit(id, fmt(pcall(assert(load((src:gsub("@%(", "(")))))))
  else
    local wrapped = assert(load("local X = ... " .. src:gsub("@%(", "X('" .. op .. "', ")))
    trace = {}
    local res = fmt(pcall(wrapped, X))
    if MODE == "raw" then
      local plain = fmt(pcall(assert(load((src:gsub("@%(", "("))))))
      if plain ~= res then
        bad = bad + 1
        io.stderr:write("t_ops.lua: the X wrapper changed case '", id, "': ", plain, " -> ", res, "\n")
      end
      res = res .. "\t" .. table.concat(trace, " ")
    end
    emit(id, res)
  end
end

io.write(table.concat(out, "\n"), "\n")
if bad > 0 then os.exit(3) end
