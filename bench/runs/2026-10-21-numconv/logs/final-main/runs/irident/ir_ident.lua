-- ir_ident.lua: for each bit expression in FORMS, run it in a hot loop over
-- a table of doubles and read the IR of the traces it compiles (jit.util,
-- as in JIT guide 12.5/12.6).  Per form it prints, for the pre-roll and the
-- loop body of every trace that has a LOOP: the number of i64 EQ guards (in
-- a loop of bit operators on doubles these are the result guards; an
-- operand guard is a num EQ), the number of marked CONV i64.num (0x16ae, the
-- result guard's own conversion back), and the number of CONV i64.num whose
-- operand is a non-CONV (an operand's own conversion of a double).
-- Run from the build's src/ (so jit/*.lua load): luajit ir_ident.lua
-- Value-level only; nothing here reads or writes memory through pointers.
local jutil = require("jit.util")
local vmdef = require("jit.vmdef")

local function opname(ot) local o = ot >> 8; return vmdef.irnames:sub(o * 6 + 1, o * 6 + 6) end
local IRT_I64 = 21

local FORMS = {
  -- identity operations: res folds to x's own CONV i64.num
  "x | 0", "x & -1", "x ~ 0", "x << 0", "x >> 0", "x ~>> 0", "~~x",
  "x & x", "x | x", "0 | x", "-1 & x",
  -- cancellations that fold to x's conversion
  "(x ~ y) ~ y", "(x ~ 5) ~ 5", "~(x ~ -1)", "(x | 0) & -1",
  -- controls: the guard must stay (x | 1, x ~ y, x << 1), or the width rule
  -- already removes it (x & 0xff)
  "x | 1", "x ~ y", "x << 1", "x & 0xff",
}

local VALS = {}
for i = 1, 64 do VALS[i] = (i % 2 == 0) and (i * 2^20) or -(i * 3) end

local cur
local seen = {}
jit.attach(function(what, tr)
  if what ~= "stop" then return end
  local info = jutil.traceinfo(tr)
  local loopref
  for ref = 1, info.nins do
    local m, ot = jutil.traceir(tr, ref)
    if opname(ot) == "LOOP  " then loopref = ref end
  end
  local c = { pre = { eq = 0, back = 0, opnd = 0 }, body = { eq = 0, back = 0, opnd = 0 } }
  for ref = 1, info.nins do
    local m, ot, op1, op2 = jutil.traceir(tr, ref)
    local part = (loopref and ref > loopref) and c.body or c.pre
    local name = opname(ot)
    if name == "EQ    " and (ot & 31) == IRT_I64 and (ot & 128) ~= 0 then part.eq = part.eq + 1 end
    if name == "CONV  " and (op2 & 0x3ff) == 0x2ae then
      if (op2 & 0x400) ~= 0 then part.back = part.back + 1
      else
        local isconv = false
        if op1 > 0 then
          local _, ot1 = jutil.traceir(tr, op1)
          isconv = opname(ot1) == "CONV  "
        end
        if not isconv then part.opnd = part.opnd + 1 end
      end
    end
  end
  seen[#seen + 1] = { form = cur, tr = tr, loop = loopref ~= nil, c = c }
end, "trace")

for _, f in ipairs(FORMS) do
  cur = f
  jit.flush()
  local src = "local T, n = ...; local out = {}; local y = 12345\n" ..
    "for i = 1, n do local x = T[(i & 63) + 1]; out[(i & 7) + 1] = " .. f .. " end\n" ..
    "return out[1], out[8]"
  local fn = assert(load(src, "=" .. f))
  fn(VALS, 3000)
end
jit.attach(function() end)

for _, f in ipairs(FORMS) do
  local line = string.format("%-14s", f)
  local n = 0
  for _, s in ipairs(seen) do
    if s.form == f and s.loop then
      n = n + 1
      line = line .. string.format("  tr%d pre eq=%d back=%d opnd=%d | body eq=%d back=%d opnd=%d",
        s.tr, s.c.pre.eq, s.c.pre.back, s.c.pre.opnd, s.c.body.eq, s.c.body.back, s.c.body.opnd)
    end
  end
  if n == 0 then line = line .. "  NO LOOP TRACE" end
  print(line)
end
