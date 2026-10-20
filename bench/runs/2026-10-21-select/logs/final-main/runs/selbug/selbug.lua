-- selbug.lua: select(k, ...) with a plain double k (no bit operator) that is
-- above the vararg count when the loop records and later a large negative
-- int32 whose k*8 wraps to a small positive int32.  The interpreter raises
-- "index out of range"; does the compiled loop?
local K = {}
for i = 1, 200 do K[i] = 100 end
K[150] = -2147483628   -- 8k mod 2^32 = 160
K[160] = -5            -- n + k < 1 for 7 varargs? no: 8 - 5 = 3: valid
K[170] = -9            -- n + k < 1: raises
local out, pos = {}, 1
local function f(...)
  for i = pos, #K do
    pos = i + 1
    local v = select(K[i], ...)
    out[#out + 1] = v == nil and "n" or v
  end
end
while pos <= #K do
  local ok, err = pcall(f, 10, 20, 30, 40, 50, 60, 70)
  if not ok then out[#out + 1] = "E" end
end
print(out[150], out[160], out[170], #out)
