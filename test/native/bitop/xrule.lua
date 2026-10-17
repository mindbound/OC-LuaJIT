-- test/native/bitop/xrule.lua <X output> <raw output> -- run-bitop.sh part 2,
-- check (2), on PUC Lua 5.3.6: X, the rule every .expect line comes from
-- (U1-B, decided 2026-10-17), held to 5.3.6's own integers.
--
-- The two files are one matrix script's output on PUC, run as "X" and as
-- "raw" (t_ops.lua's header).  The raw run prints each case's result with %d
-- and traces every operator's exact 64-bit integer.  For each line:
--   - if an operator's integer has more than 53 significant bits, the X line
--     must be the error "result of '<op>' has more than 53 significant bits
--     (mask each operand to 32 bits first)" -- this text exactly, the hint
--     decided 2026-10-17 -- naming the FIRST such operator (operands
--     evaluate left to right, and X raises at the first);
--   - else, if the case ended in an error (no integer representation, a type
--     error), the X line must be that same error;
--   - else the X line must be the last operator's integer itself, as %.17g of
--     its double, and equal to it exactly (5.3 compares an integer with a float
--     exactly, lvm.c luaV_equalobj);
--   - a case without an operator: the X line must be the raw line's result,
--     the same text (both runs print an integer with %d, t_fold.lua's fmt).
--     The summary counts those whose integer has more than 53 significant
--     bits: our lexer rounds such a literal (U9), so each is a LEX line that
--     part 2's check (1) sees and deviations.txt lists.
-- The significant bits are counted here with integer shifts, never through a
-- double, so this does not restate X's own test (math.tointeger(r + 0.0) == r).
-- Exit 0 and a summary line, or 1 and the disagreements.
assert(_VERSION == "Lua 5.3" and math.type, "xrule.lua runs on PUC Lua 5.3.6")
local xfile, rfile = arg[1], arg[2]
assert(xfile and rfile, "usage: xrule.lua <X output> <raw output>")
local TAB, CR = string.char(9), string.char(13)

-- An int64's significant bits: the span from its magnitude's lowest set bit
-- to its highest.  -2^63's magnitude, 2^63, is the bit pattern of -2^63 (~v + 1
-- wraps), whose span is 1.  5.3's >> is logical (lvm.c luaV_shiftl).
local function sigbits(v)
  if v == 0 then return 0 end
  local m = v < 0 and (~v + 1) or v
  while m & 1 == 0 do m = m >> 1 end
  local n = 0
  while m ~= 0 do n = n + 1; m = m >> 1 end
  return n
end
-- The rule's own boundaries, so a broken count cannot pass vacuously.
assert(sigbits(1) == 1 and sigbits(-1) == 1 and sigbits(math.mininteger) == 1)
assert(sigbits((1 << 53) - 1) == 53 and sigbits(1 << 53) == 1 and sigbits((1 << 53) + 1) == 54)
assert(sigbits(math.maxinteger) == 63 and sigbits(-((1 << 53) + 1)) == 54 and sigbits(-(1 << 62)) == 1)

local function lines(f)
  local t = {}
  for l in io.lines(f) do t[#t + 1] = (l:gsub(CR .. "$", "")) end
  return t
end
local function split(l)
  local t = {}
  for field in (l .. TAB):gmatch("([^" .. TAB .. "]*)" .. TAB) do t[#t + 1] = field end
  return t
end
local function iserr(s) return s:match("^ERR:") or s:match("^E:") end

local X, R = lines(xfile), lines(rfile)
local bad, nraise, nexact, nerr, nnone, nwide = {}, 0, 0, 0, 0, 0
local HINT = " (mask each operand to 32 bits first)"
local function disagree(i, why) bad[#bad + 1] = "line " .. i .. ": " .. why end
if #X ~= #R then disagree(0, "line counts differ: X " .. #X .. ", raw " .. #R) end
for i = 1, math.min(#X, #R) do
  local x, r = split(X[i]), split(R[i])
  local id, xres, rres, rtrace = x[1], x[2], r[2], r[3]
  if #x ~= 2 or #r ~= 3 or x[1] ~= r[1] then
    disagree(i, "not a matching pair of lines: " .. X[i] .. " | " .. R[i])
  else
    local ops, first, ok = {}, nil, true
    for tok in rtrace:gmatch("%S+") do
      local op, vs = tok:match("^([^=]+)=(%-?%d+)$")
      local v = vs and math.tointeger(tonumber(vs))
      if not v then ok = false; break end
      ops[#ops + 1] = { op = op, v = v }
      if not first and sigbits(v) > 53 then first = ops[#ops] end
    end
    if not ok then
      disagree(i, "unreadable trace '" .. rtrace .. "' (" .. id .. ")")
    elseif first then
      nraise = nraise + 1
      local m = "result of '" .. first.op .. "' has more than 53 significant bits" .. HINT
      if xres ~= "ERR:" .. m and xres ~= "E:" .. m then
        disagree(i, id .. ": '" .. first.op .. "' gave " .. string.format("%d", first.v)
          .. " (" .. sigbits(first.v) .. " significant bits), but X gave " .. xres)
      end
    elseif iserr(rres) then
      nerr = nerr + 1
      if xres ~= rres then disagree(i, id .. ": PUC raised " .. rres .. ", X gave " .. xres) end
    elseif #ops > 0 then
      nexact = nexact + 1
      local last = ops[#ops].v
      local rv = math.tointeger(tonumber(rres))
      if rv ~= last then
        disagree(i, id .. ": the result " .. rres .. " is not the last operator's " .. string.format("%d", last))
      elseif xres ~= string.format("%.17g", last + 0.0) or tonumber(xres) ~= last then
        disagree(i, id .. ": exact " .. string.format("%d", last) .. ", but X gave " .. xres)
      end
    else
      nnone = nnone + 1
      local rv = math.tointeger(tonumber(rres))
      if rv and rres:match("^%-?%d+$") and sigbits(rv) > 53 then nwide = nwide + 1 end
      if xres ~= rres then
        disagree(i, id .. ": no operator, result " .. rres .. ", but X gave " .. xres)
      end
    end
  end
end

if #bad > 0 then
  print(string.format("xrule: %d disagreements in %d lines (%s, %s):", #bad, #X, xfile, rfile))
  for i = 1, math.min(#bad, 20) do print("    " .. bad[i]) end
  os.exit(1)
end
print(string.format("xrule: %d lines agree: %d raise (an operator's integer has more than 53 significant bits), %d exact, %d errors as PUC's, %d without an operator (%d of them an integer with more than 53 significant bits)",
  #X, nraise, nexact, nerr, nnone, nwide))
