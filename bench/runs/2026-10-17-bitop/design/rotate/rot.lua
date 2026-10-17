-- rot.lua -- how often the common 5.3 rotate idiom raises (or rounds), per rotation count.
--   ((a >> n) | (a << (32 - n))) & 0xFFFFFFFF   on random 32-bit a
-- and the masked-piece form
--   (a >> n) | ((a << (32 - n)) & 0xFFFFFFFF)
-- Prints, per n in sha256's rotation counts, the count of 10000 random words for which the idiom
-- raises, and for which it returns a value other than the true 32-bit rotation (computed by
-- arithmetic only), for each form.
local function rotref(a, n)  -- arithmetic, exact for a < 2^32
  local lo = a % (2 ^ n)
  return (a - lo) / (2 ^ n) + lo * 2 ^ (32 - n)
end
local f1 = load("return function(a, n) return ((a >> n) | (a << (32 - n))) & 0xFFFFFFFF end")()
local f2 = load("return function(a, n) return (a >> n) | ((a << (32 - n)) & 0xFFFFFFFF) end")()
local seed = 12345
local function rnd()  -- LCG, exact in doubles
  seed = (seed * 69069 + 1) % 4294967296
  return seed
end
local words = {}
for i = 1, 10000 do words[i] = rnd() end
local out = {}
for _, n in ipairs({2, 6, 7, 11, 13, 17, 18, 19, 22, 25}) do
  local r1, w1, r2, w2 = 0, 0, 0, 0
  for i = 1, #words do
    local a = words[i]
    local want = rotref(a, n)
    local ok, v = pcall(f1, a, n)
    if not ok then r1 = r1 + 1 elseif v ~= want then w1 = w1 + 1 end
    ok, v = pcall(f2, a, n)
    if not ok then r2 = r2 + 1 elseif v ~= want then w2 = w2 + 1 end
  end
  out[#out + 1] = string.format("n=%d idiom: raise %d wrong %d | masked: raise %d wrong %d", n, r1, w1, r2, w2)
end
print(table.concat(out, "\n"))
