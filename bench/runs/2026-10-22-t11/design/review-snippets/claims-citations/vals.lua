-- DEV table values and constants of t10-section.md, computed afresh.
local N = tonumber
local p53, m1, zero, dead = N("9007199254740992"), N("-1"), N("0"), N("3735928559")
local function try(name, f)
  local ok, v = pcall(f)
  if ok then
    local okf, s = pcall(string.format, "%d", v)
    print(name, okf and s or tostring(v))
  else
    print(name, "ERR", v)
  end
end
try("2^53|1", function() return p53 | 1 end)
try("-1>>1", function() return m1 >> 1 end)
try("~0>>1", function() return (~zero) >> 1 end)
try("rotr unmasked", function() return ((dead >> 7) | (dead << 25)) & 0xFFFFFFFF end)
try("hot last", function() local b = p53 - 1000 return (b + 2000) | 1 end)
try("hot 999", function() local b = p53 - 1000 return (b + 999) | 1 end)
try("hot 1000", function() local b = p53 - 1000 return (b + 1000) | 1 end)
-- xorshift32 from seed, 1000 steps
local x = N("2463534242")
for _ = 1, 1000 do
  x = x ~ ((x << 13) & 0xFFFFFFFF)
  x = x ~ (x >> 17)
  x = x ~ ((x << 5) & 0xFFFFFFFF)
end
print("xs1000", string.format("%d", x))
local f15 = N("1.5")
local K = { f15 = f15 }
try("1.5&1 field", function() return K.f15 & 1 end)
try("1.5&1 local", function() return f15 & 1 end)
