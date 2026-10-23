-- cse-fwd.lua: the refute part's int/i64 CSE twin, forward order only, by
-- value.  In each loop LuaJIT's bit library records its int op on the int
-- loop index first, then the 5.3 operator does the same op on the same index;
-- the 5.3 result is stored and checked against a reference computed without
-- bit operators.  Run under -joff and with the JIT; any mismatch is printed.
-- The reverse order (the 5.3 operator first) is deliberately not run.
local N = tonumber(arg and arg[1]) or 400

local function report(name, out, ref, base)
  local bad, first = 0, nil
  for k = 1, #out do
    if out[k] ~= ref(base + k - 1) then
      bad = bad + 1
      if not first then first = string.format("i=%d got %.17g want %.17g", base + k - 1, out[k], ref(base + k - 1)) end
    end
  end
  print(string.format("%-10s n=%d mismatches=%d%s", name, #out, bad, first and ("  first: " .. first) or ""))
  return bad
end

local total = 0

do -- bit.lshift then <<, from just below 2^29 so i << 3 passes 2^32
  local base, out = 2^29 - 100, {}
  for i = base, base + N do
    local a = bit.lshift(i, 3)
    local b = i << 3
    out[#out + 1] = b
  end
  total = total + report("lshift3", out, function(i) return i * 8 end, base)
end

do -- bit.bnot then ~
  local base, out = 1, {}
  for i = base, base + N do
    local a = bit.bnot(i)
    local b = ~i
    out[#out + 1] = b
  end
  total = total + report("bnot", out, function(i) return -i - 1 end, base)
end

do -- control: << alone, no bit library in the loop
  local base, out = 2^29 - 100, {}
  for i = base, base + N do
    out[#out + 1] = i << 3
  end
  total = total + report("ctl-shl", out, function(i) return i * 8 end, base)
end

do -- control: ~ alone
  local base, out = 1, {}
  for i = base, base + N do
    out[#out + 1] = ~i
  end
  total = total + report("ctl-bnot", out, function(i) return -i - 1 end, base)
end

print(string.format("jit %s  total mismatches %d", tostring(jit and jit.status and jit.status()), total))
