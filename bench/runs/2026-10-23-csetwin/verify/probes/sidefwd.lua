-- sidefwd.lua -- verify-code's probe of a forward pair that forms ONLY in a
-- SIDE trace: the root trace is recorded while i <= 300 and takes the branch
-- without the pair; once i > 300 its guard exits, and the side trace
-- recorded there holds bit.lshift(b, 30) and then b << 30 on the same u8
-- XLOAD b (no SCEV index needed).  The bit library's call comes first in
-- program order, and a side trace stops at its root's loop, so the order is
-- FORWARD ONLY: value-only, no int64 ref can reach a 32-bit recorder or a
-- slot.  Nothing through a pointer.  No backslash in this file.
--   luajit sidefwd.lua <cseir.lua path or "-">
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
local N = 600
local P30, P32, P31 = 2 ^ 30, 2 ^ 32, 2 ^ 31
local function wrap32(v) v = v % P32; if v >= P31 then v = v - P32 end; return v end

local function mk(pair)
  return "local s, n, O, BO = ..." .. NL ..
    "for i = 1, n do" .. NL ..
    "  if i > 300 then" .. NL ..
    "    local b = string.byte(s, i)" .. NL ..
    (pair and "    local a = bit.lshift(b, 30)" or "    local a = b * 1073741824 % 4294967296") .. NL ..
    "    local c = b << 30" .. NL ..
    "    O[i] = c; BO[i] = a" .. NL ..
    "  else" .. NL ..
    "    O[i] = string.byte(s, i) * 1073741824; BO[i] = 0" .. NL ..
    "  end" .. NL ..
    "end"
end
local CASES = {
  { name = "side-pair", pair = true, src = mk(true) },
  { name = "ctl-side", pair = false, src = mk(false) },
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
      local by = S:byte(i)
      local want = by * P30
      if O[i] ~= want then bad = bad + 1; first = first or fmt("%d:%.17g/%.17g", i, O[i], want) end
      local bw = 0
      if i > 300 then bw = C.pair and wrap32(by * P30) or (by * P30 % P32) end
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
print(fmt("sidefwd: %d wrong", total))
os.exit(total == 0 and 0 or 1)
