-- test/native/bitop/t_fold.lua -- the bitwise operators with LITERAL operands,
-- which the parser may fold (lj_parse.c foldbitop and the unary ~ fold; 5.3.6
-- lcode.c constfolding): r3/vm's 45 cases (2026-10-17) and U1-B's (round 3,
-- decided 2026-10-17): an inexact result is not folded, the run time raises.
-- test/native/run-bitop.sh part 1 runs it on the build's luajit.exe, JIT on
-- and -joff; part 2 runs it on PUC Lua 5.3.6.
--
-- On our luajit.exe (no argument), one line per case:
--   "<source> TAB <result> TAB <how>"
-- the result a number as %.17g, "ERR:<message without its chunk:line:
-- prefix>" or "COMPILE-ERR:<message>"; <how> is "folded" when the compiled
-- chunk holds no bitwise bytecode, else "runtime:" and the bitwise opcodes it
-- holds (jit.util.funcbc), "-" when it did not compile.  The output must equal
-- t_fold.expect exactly.
-- On PUC Lua 5.3.6, one argument, X or raw, as t_ops.lua's header says, the
-- lines without <how>.  Each source is rewritten so that every bitwise operator
-- application "a OP b" becomes "X('OP', (a) OP (b))" and "~a" becomes
-- "X('~', ~(a))" (xform below: Lua 5.3's own precedence table, lparser.c
-- priority[] and UNARY_PRIORITY), so X applies to every operator, not only to
-- the last.  In raw mode each case also runs as written, and the rewritten
-- source with the identity X must give the same line, or the run fails (exit
-- 3): the rewrite cannot change what a case computes.
-- On PUC an integer result is printed with %d in X mode as well as raw.  X's
-- results are floats, so only a case without a bitwise operator (a bare
-- literal, "5 // 1") can print an integer, and %d shows its exact value:
-- %.17g would print 5.3.6's 9007199254740993 as 9007199254740992, the text
-- ours prints, and hide a LEX deviation (deviations.txt) from run-bitop.sh's
-- part 2 (review of 2026-10-17).
local MODE = arg and arg[1]
local ISLJ = type(jit) == "table"
if ISLJ then
  assert(MODE == nil, "t_fold.lua takes no argument on LuaJIT")
else
  assert(_VERSION == "Lua 5.3" and math.type, "t_fold.lua runs on LuaJIT or on PUC Lua 5.3.6")
  assert(MODE == "X" or MODE == "raw", "t_fold.lua on PUC Lua 5.3: one argument, X or raw")
end

-- Every case's outermost operation is a bitwise operator, or it has none.
local CASES = {
  -- r3/vm's t_fold.lua
  "1 << 31", "1 << 32", "1 << 33", "1 << 63", "1 << 64", "1 << -1", "1 >> -1",
  "-1 >> 1", "-1 >> 63", "-1 >> 64", "-1 << 0", "3 & 5", "3 | 5", "3 ~ 5",
  "~0", "~5", "~-1", "~2^31", "~2^53", "2^31 | 0", "2^32 | 0", "2^53 | 0", "2^63 | 0",
  "-2^63 | 0", "2^64 | 0", "1.5 | 0", "0.5 | 0", "2.5 | 0", "-0.0 | 0", "(0/0) | 0", "(1/0) | 0",
  "0xffffffff | 0", "0x100000000 | 0", "0x7fffffffffffffff | 0", "0xffffffffffffffff | 0",
  "0x8000000000000000 | 0", "0x7fffffffffffffff", "0xffffffffffffffff", "0x8000000000000000",
  "9007199254740993", "9223372036854775807", "9223372036854775808",
  "0xff & 0x0f", "1 << 62 | 1", "5 // 1",
  -- U1-B (design-B.md section 2): folded where exact, raised at run time where not
  "1 << 62", "1 << 52 | 1", "1 << 53 | 1", "2^60 | 0", "2^60 | 1",
  "~0 >> 1", "~0 >> 10", "~0 >> 11", "-1 >> 10", "-1 >> 11", "-2^63 >> 10",
  "~(2^53 - 1)", "~(2^53)", "(-2 >> 8) & 0xFF", "((-2 & 0xFFFFFFFF) >> 8) & 0xFF",
  -- A string literal is never folded (5.3.6 tonumeral, lcode.c:43-55; LuaJIT
  -- expr_isnumk, lj_parse.c:77): only the C path computes it, and must raise.
  '"-1" >> 1', '"3" | 4',
  -- U9 (LEX): the lexer reads a hex literal with more than 53 significant bits
  -- as its nearest double before any operator sees it; here 0, in 5.3.6 255.
  "0x00ff00ff00ff00ff & 0xff",
}

-- {======================================================
-- xform: the X rewrite of a case's source (PUC only).  Tokens are numerals
-- (llex.c read_numeral: hex digits and '.', an exponent mark and its sign),
-- quoted strings without escapes, and the operators below.
-- =======================================================
local function lex(src)
  local toks, i, n = {}, 1, #src
  while i <= n do
    local c = src:sub(i, i)
    if c == " " then
      i = i + 1
    elseif c:match("[%d.]") and not (c == "." and src:sub(i, i + 1) == "..") then
      local j, expo = i, "[Ee]"
      if src:sub(i, i + 1):match("^0[xX]$") then j, expo = i + 2, "[Pp]" end
      while j <= n do
        local d = src:sub(j, j)
        if d:match(expo) then
          j = j + 1
          if src:sub(j, j):match("[+-]") then j = j + 1 end
        elseif d:match("[%x.]") then
          j = j + 1
        else
          break
        end
      end
      toks[#toks + 1] = { k = "val", v = src:sub(i, j - 1) }
      i = j
    elseif c == "'" or c == '"' then
      local j = src:find(c, i + 1, true)
      assert(j, "xform: unterminated string")
      toks[#toks + 1] = { k = "val", v = src:sub(i, j) }
      i = j + 1
    else
      local two = src:sub(i, i + 1)
      if two == "<<" or two == ">>" or two == "//" or two == ".." then
        toks[#toks + 1] = { k = "op", v = two }
        i = i + 2
      elseif c:match("[&|~+%-*/%%^]") then
        toks[#toks + 1] = { k = "op", v = c }
        i = i + 1
      elseif c == "(" or c == ")" then
        toks[#toks + 1] = { k = c }
        i = i + 1
      else
        error("xform: unexpected character '" .. c .. "' in " .. src)
      end
    end
  end
  return toks
end

-- lparser.c (5.3.6) priority[]: {left, right}; UNARY_PRIORITY 12.
local BINPRI = {
  ["+"] = { 10, 10 }, ["-"] = { 10, 10 }, ["*"] = { 11, 11 }, ["%"] = { 11, 11 },
  ["^"] = { 14, 13 }, ["/"] = { 11, 11 }, ["//"] = { 11, 11 },
  ["&"] = { 6, 6 }, ["|"] = { 4, 4 }, ["~"] = { 5, 5 }, ["<<"] = { 7, 7 }, [">>"] = { 7, 7 },
  [".."] = { 9, 8 },
}
local UNARY_PRIORITY = 12
local BITOP = { ["&"] = true, ["|"] = true, ["~"] = true, ["<<"] = true, [">>"] = true }

-- Returns the rewritten source and whether its outermost operation is bitwise.
local function xform(src)
  local toks, i = lex(src), 1
  local subexpr
  local function simpleexp()
    local t = toks[i]
    assert(t, "xform: unexpected end of " .. src)
    if t.k == "(" then
      i = i + 1
      local e = subexpr(0)
      assert(toks[i] and toks[i].k == ")", "xform: ')' expected in " .. src)
      i = i + 1
      return "(" .. e .. ")", false
    end
    assert(t.k == "val", "xform: unexpected token in " .. src)
    i = i + 1
    return t.v, false
  end
  -- lparser.c subexpr: a unary operator, or a simple expression; then every
  -- binary operator whose left priority is above the limit.
  subexpr = function(limit)
    local e, isbit
    local t = toks[i]
    if t and t.k == "op" and (t.v == "-" or t.v == "~") then
      i = i + 1
      local o = subexpr(UNARY_PRIORITY)
      if t.v == "~" then e, isbit = "X('~', ~(" .. o .. "))", true
      else e, isbit = "-(" .. o .. ")", false end
    else
      e, isbit = simpleexp()
    end
    while true do
      t = toks[i]
      local p = t and t.k == "op" and BINPRI[t.v]
      if not p or p[1] <= limit then break end
      i = i + 1
      local r = subexpr(p[2])
      if BITOP[t.v] then e, isbit = "X('" .. t.v .. "', (" .. e .. ") " .. t.v .. " (" .. r .. "))", true
      else e, isbit = "(" .. e .. ") " .. t.v .. " (" .. r .. ")", false end
    end
    return e, isbit
  end
  local e, isbit = subexpr(0)
  assert(i == #toks + 1, "xform: trailing tokens in " .. src)
  return e, isbit
end
-- }======================================================

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
    if not ISLJ and math.type(r) == "integer" then return string.format("%d", r) end
    return string.format("%.17g", r)
  end
  return type(r) .. ":" .. tostring(r)
end

-- LuaJIT: the bitwise opcodes left in a compiled chunk, or "folded".
local how
if ISLJ then
  local jutil = require("jit.util")
  local bcnames = require("jit.vmdef").bcnames
  how = function(f)
    local ops, pc = {}, 1
    while true do
      local ins = jutil.funcbc(f, pc)
      if not ins then break end
      local o = 6 * (ins % 256)
      local name = bcnames:sub(o + 1, o + 6):gsub(" ", "")
      if name:match("^B[A-Z]+$") then ops[#ops + 1] = name end
      pc = pc + 1
    end
    return #ops == 0 and "folded" or ("runtime:" .. table.concat(ops, ","))
  end
end

local out, bad = {}, 0
for _, src in ipairs(CASES) do
  if ISLJ then
    local f, err = load("return " .. src)
    if not f then
      out[#out + 1] = src .. "\tCOMPILE-ERR:" .. tostring(err):gsub("^[^:]*:%d+: ", "") .. "\t-"
    else
      out[#out + 1] = src .. "\t" .. fmt(pcall(f)) .. "\t" .. how(f)
    end
  else
    local xs, isbit = xform(src)
    if not isbit and xs:find("X(", 1, true) then
      error("t_fold.lua: case '" .. src .. "' has a bitwise operator, but not outermost")
    end
    trace = {}
    local res = fmt(pcall(assert(load("local X = ... return " .. xs)), X))
    if MODE == "raw" then
      local plain = fmt(pcall(assert(load("return " .. src))))
      if plain ~= res then
        bad = bad + 1
        io.stderr:write("t_fold.lua: the X rewrite changed case '", src, "': ", plain, " -> ", res,
          " (", xs, ")\n")
      end
      res = res .. "\t" .. table.concat(trace, " ")
    end
    out[#out + 1] = src .. "\t" .. res
  end
end

io.write(table.concat(out, "\n"), "\n")
if bad > 0 then os.exit(3) end
