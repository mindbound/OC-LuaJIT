-- cse-fwd2.lua: cse-fwd.lua with constant loop bounds, so the 5.3 operator can
-- take the int loop index directly (jit-guide 3.12's `i64 BSHL 0003 +7`), and
-- both results stored so neither op is dead.  Forward order only: LuaJIT's
-- bit library records its int op first, then the 5.3 operator.  By value
-- against a reference without bit operators; run under -joff and the JIT.
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

do -- bit.lshift then <<, from 2^29 so i << 3 passes 2^32
  local out, outa = {}, {}
  for i = 536870912, 536871312 do
    local a = bit.lshift(i, 3)
    local b = i << 3
    outa[#outa + 1] = a
    out[#out + 1] = b
  end
  total = total + report("lshift3", out, function(i) return i * 8 end, 536870912)
end

do -- bit.bnot then ~
  local out, outa = {}, {}
  for i = 1, 401 do
    local a = bit.bnot(i)
    local b = ~i
    outa[#outa + 1] = a
    out[#out + 1] = b
  end
  total = total + report("bnot", out, function(i) return -i - 1 end, 1)
end

do -- control: << alone
  local out = {}
  for i = 536870912, 536871312 do
    out[#out + 1] = i << 3
  end
  total = total + report("ctl-shl", out, function(i) return i * 8 end, 536870912)
end

do -- control: ~ alone
  local out = {}
  for i = 1, 401 do
    out[#out + 1] = ~i
  end
  total = total + report("ctl-bnot", out, function(i) return -i - 1 end, 1)
end

do -- check of the checker: a wrong reference must report mismatches
  local out = {}
  for i = 1, 401 do out[#out + 1] = ~i end
  local bad = report("failfirst", out, function(i) return -i end, 1)
  print(bad > 0 and "failfirst ok (the checker reports a wrong reference)" or "failfirst BROKEN")
end

print(string.format("jit %s  total mismatches %d", tostring(jit and jit.status and jit.status()), total))
