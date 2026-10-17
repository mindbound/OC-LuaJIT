-- test/native/bitop/t_jit2.lua -- loops built to break the JIT's recording of
-- Lua 5.3's bitwise operators.  Written by the round-3 "vm" investigator
-- (r3/vm, 20 loops) and the round-3 designer (r3/synth/probes); rebuilt for
-- U1-B by role C2 of the round-3 implementation.  test/native/run-bitjit.sh
-- runs it under our luajit.exe with several JIT option sets and with -joff
-- (every output must equal -joff's), and under PUC Lua 5.3.6 (which must
-- equal -joff's too: the PUC text applies U1-B's rule at every operator).
--
--   <vm> t_jit2.lua
--
-- Each test is a chunk run as f(400, out) that appends one result per
-- iteration to out.  It prints "<name>\t<results, comma-separated>", each
-- number as %.17g; a raise ends the list with ERR@<the iteration>:<kind>
-- (INEXACT(<op>), NOINT, TYPE:<type> or OTHER:<text>), so a JIT that raises
-- at another iteration, or for another reason, prints another line.  (Until
-- 2026-10-17 a raise printed only its message: on a NARROW sabotage under
-- -Ohotloop=1 -Ohotexit=1, bnot raised at 258 compiled and at 257
-- interpreted, and the A-era file printed the same line for both, 3 runs of 3.)
--
-- ONE TEXT, TWO DIALECTS.  Each test is written with every bit operator's
-- result wrapped in X(...).  Our text drops each X (X(a << b) is (a << b));
-- PUC's keeps it and adds the operator, X(a << b, '<<'), and X applies the
-- rule: the result's double if it equals it, else "result of '<op>' has
-- more than 53 significant bits (mask each operand to 32 bits first)".  KIND
-- reads the operator and ignores what follows "bits": it classifies, and
-- run-bitop.sh's matrix pins the text.  So 5.3's integer arithmetic between
-- operators becomes the double arithmetic ours does, and a result ours
-- refuses is refused there too.  Before anything runs, every test is checked
-- mechanically: each X wraps exactly one operator at its own top level, and
-- the operators in our text number the X's (else INSTRUMENT, exit 2).
--
-- UNDER U1-B several of the A-era loops raise early (count-range at 71,
-- near-2p63 and kfold at 1, rotate-round at 3, bnot at 257, rec-m53 at 5,
-- rec-grow at 53; measured on r3/b/bB).  They stay: each now checks that the
-- raise comes at the same iteration compiled and interpreted.  A "-b"
-- variant beside each keeps the loop's purpose with every result exact (the
-- user's remedy: mask to the width you mean before shifting).  guard-exit's
-- closure is hoisted out of its loop: created per iteration (FNEW), it kept
-- the loop from ever compiling ("NYI: bytecode FNEW", -jv on r3/b/bB).
-- rec-m54's mask is 2^54 - 2: the A-era 0x3fffffffffffff has 54 significant
-- bits, so our lexer rounds it to 2^54 (U9) and PUC does not.
local N = 400
local IS53 = math.type ~= nil
local fmt = string.format

-- The kind of an error, the same words on both VMs.
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

-- The bit operators of a text outside its strings and comments: ~>>, <<, >>,
-- &, |, and ~ (binary or unary; not ~=).  top: only those at nesting depth 0.
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

-- 1: narrowing trap: x = i + 2^53 rounds; x & 1 must see the rounded double.
test("narrow-add", [[
  local n, out = ...
  for i = 1, n do local x = i + 2^53; out[#out+1] = X(x & 1) end ]])
-- 1b: the same trap at every trace entry.  narrow_convert acts only before
-- the trace's LOOP (lj_opt_fold.c: NEXTFOLD once J->chain[IR_LOOP] is set),
-- so narrow-add's single loop meets it once, at whatever iteration the trace
-- starts, and only on a non-constant operand (lj_opt_narrow.c narrows a
-- number constant only if it is a 16-bit integer: 2^53 never).  f's loop is
-- entered once per call, with x = 2^53 an argument: its first iteration, the
-- pre-roll, sees k = i for every i, half of them odd (x + k rounds to even)
test("narrow-entry", [[
  local n, out = ...
  local function f(x, i)
    local r = 0
    for k = i, i + 3 do r = r + X((x + k) & 1) end
    return r
  end
  for i = 1, n do out[#out+1] = f(2^53, i) end ]])
-- 2: same through a subtraction and a shift
test("narrow-sub-shl", [[
  local n, out = ...
  for i = 1, n do local x = 2^60 - i; out[#out+1] = X(X(x << 2) >> 2) end ]])
-- 3: guard exit mid-loop: non-integral and huge values among integers
test("guard-exit", [[
  local n, out = ...
  local v = {}
  for i = 1, n do v[i] = i end
  v[300] = 1.5; v[333] = 2^63; v[350] = 0/0; v[360] = -2^63; v[370] = -0.0
  local function f(x) return X(x | 0) end
  for i = 1, n do
    local ok, r = pcall(f, v[i])
    out[#out+1] = ok and r or ("E:" .. KIND(r))
  end ]])
-- 4: an error raised from inside a compiled loop, at the right iteration
test("guard-error", [[
  local n, out = ...
  local v = {}
  for i = 1, n do v[i] = i * 3 end
  v[250] = 0.25
  local acc = 0
  for i = 1, n do acc = X(acc ~ X(v[i] << 1)); out[#out+1] = acc end ]])
-- 5: variable shift counts crossing 0..63 both ways; -5 >> 1 raises at 71
test("count-range", [[
  local n, out = ...
  for i = 1, n do
    local c = (i % 140) - 70
    out[#out+1] = X(3 << c) + X(2^62 >> c) * 2 + X(-5 >> c)
  end ]])
-- 5b: the same with every result exact (-2^53 >> c has 11 bits or fewer)
test("count-range-b", [[
  local n, out = ...
  for i = 1, n do
    local c = (i % 140) - 70
    out[#out+1] = X(3 << c) + X(2^62 >> c) * 2 + X(-2^53 >> c)
  end ]])
-- 6: int-narrowed and number operands mixed, beyond 2^32
test("mixed", [[
  local n, out = ...
  for i = 1, n do out[#out+1] = X((i * 2^40) | X(i ~ X(i << 33))) end ]])
-- 7: values near 2^63 and negative; ~x raises at 1
test("near-2p63", [[
  local n, out = ...
  for i = 1, n do
    local x = 2^63 - 1024 * i
    local y = -2^63 + 2048 * i
    out[#out+1] = X(x & y) + X(x ~ y) - X(~x)
  end ]])
-- 7b: the same with x ~ -1024 (= -2^63 + 1024 (i - 1), exact) for ~x
test("near-2p63-b", [[
  local n, out = ...
  for i = 1, n do
    local x = 2^63 - 1024 * i
    local y = -2^63 + 2048 * i
    out[#out+1] = X(x & y) + X(x ~ y) - X(x ~ -1024)
  end ]])
-- 8: constant operands inside the trace (KINT64 folding); raises at 1
test("kfold", [[
  local n, out = ...
  for i = 1, n do
    local a, b = 2^40 + 7, 0xff00ff
    local c = X(X(X(X(a & b) | X(a ~ 0xf0)) | X(X(~a) & X(a << 20))) | X(b >> 3))
    out[#out+1] = c + i
  end ]])
-- 8b: the same folded constants, a << 12: every result fits 53 bits
test("kfold-b", [[
  local n, out = ...
  for i = 1, n do
    local a, b = 2^40 + 7, 0xff00ff
    local c = X(X(X(X(a & b) | X(a ~ 0xf0)) | X(X(~a) & X(a << 12))) | X(b >> 3))
    out[#out+1] = c + i
  end ]])
-- 9: constant shift counts at the edges, variable value
test("kshift", [[
  local n, out = ...
  for i = 1, n do
    local x = i * 0x10001 - 77
    out[#out+1] = X(x << 63) + X(x >> 64) + X(x << 64) + X(x >> -3) + X(x << -70)
      + X(x >> 1) + X(x << 0) + X(-x >> 60) + X(x >> 63)
  end ]])
-- 10: a 64-bit rotate iterated; raises at 3, past 53 bits
test("rotate-round", [[
  local n, out = ...
  local x = 0x123456789
  for i = 1, n do
    x = X(X(x << 7) | X(x >> 57))
    x = X(x ~ i)
    out[#out+1] = x
  end ]])
-- 10b: a 48-bit rotate, masked before the shift: the carried value crosses
-- the PHI as an int64 (width bound 49)
test("rotate-b", [[
  local n, out = ...
  local x = 0x123456789
  for i = 1, n do
    x = X(X(X(x & 0x1ffffffffff) << 7) | X(x >> 41))
    x = X(x ~ i)
    out[#out+1] = x
  end ]])
-- 11: unary not over varying values; i * 2^45 - i rounds past i = 256, and
-- ~ of the rounded double raises
test("bnot", [[
  local n, out = ...
  for i = 1, n do out[#out+1] = X(~(i * 2^45 - i)) end ]])
-- 12: string operands in a hot loop (each aborts the trace: BADTYPE)
test("strings", [[
  local n, out = ...
  local s = { "3", "0x10", " 7 ", "1e2", "0xffffffffffffffff", "9007199254740993" }
  for i = 1, n do out[#out+1] = X(s[i % #s + 1] & X(i | 0x100)) end ]])
-- 13: loop counter as the shifted value and as the count
test("counter", [[
  local n, out = ...
  for i = 1, n do out[#out+1] = X(X(i << (i % 64)) ~ X(1 << (i % 64))) end ]])
-- 14: crc32 of a fixed string
test("crc32", [[
  local n, out = ...
  local s = string.rep("OC-LuaJIT 64-bit ops ", 20)
  local c = 0xffffffff
  for k = 1, #s do
    c = X(c ~ s:byte(k))
    for _ = 1, 8 do
      local m = -X(c & 1)
      c = X(X(c >> 1) ~ X(0xedb88320 & m))
    end
  end
  out[1] = X(c ~ 0xffffffff) ]])
-- 16: masked recurrence, mask 2^53-1 (bound 54); the unmasked x << 9 ~ x >> 3
-- raises at 5
test("rec-m53", [[
  local n, out = ...
  local x = 12345
  for i = 1, n do
    x = X(X(X(X(x << 9) ~ X(x >> 3)) ~ i) & 0x1fffffffffffff)
    out[#out+1] = x
  end ]])
-- 16b: masked before the shift: exact, carried as an int64 (bound 54)
test("rec-m53-b", [[
  local n, out = ...
  local x = 12345
  for i = 1, n do
    x = X(X(X(X(X(x & 0xfffffffffff) << 9) ~ X(x >> 3)) ~ i) & 0x1fffffffffffff)
    out[#out+1] = x
  end ]])
-- 17: mask 2^54-2 (bound 55: the guard must stay); x = 2^k + 1 gains one
-- significant bit every fourth iteration and raises at '|' at 208 (2^53 + 1),
-- in compiled code
test("rec-m54", [[
  local n, out = ...
  local x = 3
  for i = 1, n do
    if i % 4 == 0 then x = X(X(X(x & 0x3ffffffffffffe) << 1) | 1) end
    out[#out+1] = x
  end ]])
-- 18: unmasked accumulation fed by a masked value: raises at 53, before the
-- loop is hot under the default options (-Ohotloop=1 compiles it)
test("rec-grow", [[
  local n, out = ...
  local y = 1
  for i = 1, n do
    y = X(X(y << 1) | X(i & 1))
    out[#out+1] = y
  end ]])
-- 18b: the same masked to 52 bits before the shift: exact
test("rec-grow-b", [[
  local n, out = ...
  local y = 1
  for i = 1, n do
    y = X(X(X(y & 0xfffffffffffff) << 1) | X(i & 1))
    out[#out+1] = y
  end ]])
-- 19: xorshift32 written with masks, the usual 5.3 idiom
test("xorshift32", [[
  local n, out = ...
  local x = 2463534242
  for i = 1, n do
    x = X(x ~ X(X(x << 13) & 0xffffffff))
    x = X(x ~ X(x >> 17))
    x = X(x ~ X(X(x << 5) & 0xffffffff))
    out[#out+1] = x
  end ]])
-- 20: a masked value carried, then shifted up past 2^53 each iteration
test("rec-shiftup", [[
  local n, out = ...
  local x = 1
  for i = 1, n do
    x = X((x + i) & 0xfffffffffff)
    out[#out+1] = X(X(x << 20) | 1)
  end ]])
-- 15: ~>> (LuaJIT only), constant and variable counts
test("sar", [[
  local n, out = ...
  for i = 1, n do
    local x = -i * 2^40
    out[#out+1] = X(x ~>> 3) + X(x ~>> 70) + X(x ~>> -2) + X(x ~>> (i % 64))
  end ]], true)

if #instr > 0 then
  print("INSTRUMENT: t_jit2's X-wrapped texts are wrong:\n  " .. table.concat(instr, "\n  "))
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
