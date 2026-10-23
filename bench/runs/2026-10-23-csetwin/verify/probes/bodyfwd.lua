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

-- off: our operand is string.byte(s, i + off); j carries the same byte from
-- the previous iteration (string.byte(s, i + off + 1)).  v1 (off 0): the
-- copy's address of string.byte(s, i) is ADD (ADD i, 1), -1 across a PHI,
-- which PHIBARRIER keeps unfolded, so no pair forms (run dump-bodyfwd-fix-2).
-- v2 (off 1): string.byte(s, i + 1)'s address folds to i at record time,
-- and its copy is STRREF s, i', the pre-roll address of string.byte(s,
-- i + 2), so the copy's XLOAD forwards to that pre-roll XLOAD, which is also
-- what j's slot carries into the copy: the pair forms in the copy only.
local function mk(off, pair)
  return "local s, n, O, BO = ..." .. NL ..
    fmt("local j = string.byte(s, %d)", 1 + off) .. NL ..
    "for i = 1, n do" .. NL ..
    (pair and "  local a = bit.lshift(j, 30)" or "  local a = j * 1073741824 % 4294967296") .. NL ..
    fmt("  local b = string.byte(s, i + %d) << 30", off) .. NL ..
    "  O[i] = b; BO[i] = a" .. NL ..
    fmt("  j = string.byte(s, i + %d)", off + 1) .. NL ..
    "end"
end
local CASES = {
  { name = "body-v1", off = 0, pair = true, src = mk(0, true) },
  { name = "body-v2", off = 1, pair = true, src = mk(1, true) },
  -- control: our operator alone in v2's shape
  { name = "ctl-v2", off = 1, pair = false, src = mk(1, false) },
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
      local by = S:byte(i + C.off)
      local want = by * P30
      if O[i] ~= want then bad = bad + 1; first = first or fmt("%d:%.17g/%.17g", i, O[i], want) end
      local bw = C.pair and wrap32(by * P30) or (by * P30 % P32)
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
