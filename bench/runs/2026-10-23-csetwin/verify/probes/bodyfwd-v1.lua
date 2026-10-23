-- bodyfwd.lua -- verify-code's probe of a BODY-ONLY forward pair: the bit
-- library's 32-bit BSHL and our int64 BSHL have different operands in the
-- pre-roll (TOBIT of the slot j, and the u8 XLOAD of string.byte(s, i)), and
-- the same operand only in the loop copy, where j's slot (string.byte(s,
-- i + 1) of the previous iteration, a u8 XLOAD) is substituted for TOBIT j
-- (simplify_tobit_conv of the copy's CONV num.int) and the copy's
-- string.byte(s, i) is forwarded to that same XLOAD.  The bit library's
-- BSHL comes first in program order, so in the pre-roll and in the copy the
-- 32-bit instruction is emitted before ours: FORWARD ORDER ONLY, value-only,
-- no int64 ref can reach a 32-bit recorder or a slot.  Nothing through a
-- pointer.  No backslash in this file.
--   luajit bodyfwd.lua <cseir.lua path or "-">
local fmt = string.format
local NL, TAB = string.char(10), string.char(9)
local LIBPATH = ...
local LIB
if LIBPATH and LIBPATH ~= "-" and type(jit) == "table" and jit.status() then
  local chunk = assert(loadfile(LIBPATH))
  LIB = chunk("lib")
  if type(LIB) ~= "table" then print("NO READER: " .. tostring(LIB)); os.exit(2) end
end
local t = {}
for k = 1, 700 do t[k] = string.char(32 + (k * 37) % 90) end  -- bytes 32..121
local S = table.concat(t)
local N = 500
local P30, P32, P31 = 2 ^ 30, 2 ^ 32, 2 ^ 31
local function wrap32(v) v = v % P32; if v >= P31 then v = v - P32 end; return v end

local CASES = {
  { name = "body-bshl", src = "local s, n, O, BO = ..." .. NL ..
      "local j = string.byte(s, 1)" .. NL ..
      "for i = 1, n do" .. NL ..
      "  local a = bit.lshift(j, 30)" .. NL ..
      "  local b = string.byte(s, i) << 30" .. NL ..
      "  O[i] = b; BO[i] = a" .. NL ..
      "  j = string.byte(s, i + 1)" .. NL ..
      "end" },
  -- control: our operator alone in the same shape
  { name = "ctl-ours", src = "local s, n, O, BO = ..." .. NL ..
      "local j = string.byte(s, 1)" .. NL ..
      "for i = 1, n do" .. NL ..
      "  local b = string.byte(s, i) << 30" .. NL ..
      "  O[i] = b; BO[i] = j * 1073741824 % 4294967296" .. NL ..
      "  j = string.byte(s, i + 1)" .. NL ..
      "end" },
}

local total = 0
for _, C in ipairs(CASES) do
  local f = assert(load(C.src, "=" .. C.name))
  if LIB then LIB.watch(f) end
  local parts = {}
  for call = 1, 3 do
    local O, BO = {}, {}
    for k = 1, N do O[k] = 0; BO[k] = 0 end
    f(S, N, O, BO)
    local bad, bbad, first = 0, 0, nil
    for i = 1, N do
      local want = S:byte(i) * P30
      if O[i] ~= want then bad = bad + 1; first = first or fmt("%d:%.17g/%.17g", i, O[i], want) end
      local bw = (C.name == "ctl-ours") and (S:byte(i) * P30 % P32) or wrap32(S:byte(i) * P30)
      if BO[i] ~= bw then bbad = bbad + 1 end
    end
    total = total + bad + bbad
    parts[#parts + 1] = fmt("bad=%d bbad=%d%s", bad, bbad, first and (" first=" .. first) or "")
  end
  local line = C.name .. TAB .. table.concat(parts, ";")
  if LIB then
    local c = LIB.take()
    line = line .. TAB .. fmt("traces=%d direct=%d served=%d split=%d rserved=%d i64slot=%d",
      c.traces, c.direct, c.served, c.split, c.rserved, c.i64slot)
  end
  print(line)
end
print(fmt("bodyfwd: %d wrong", total))
os.exit(total == 0 and 0 or 1)
