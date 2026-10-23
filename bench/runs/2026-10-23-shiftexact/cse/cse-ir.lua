-- cse-ir.lua: the lshift3 loop of cse-fwd.lua alone, for -jdump=i (forward order only).
local base, out = 2^29 - 100, {}
for i = base, base + 400 do
  local a = bit.lshift(i, 3)
  local b = i << 3
  out[#out + 1] = b
end
local bad = 0
for k = 1, #out do if out[k] ~= (base + k - 1) * 8 then bad = bad + 1 end end
print("mismatches", bad)
