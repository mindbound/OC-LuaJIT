-- sha256.lua: pure-Lua SHA-256 over ~1 MB of deterministically generated data.
-- CHECK = final digest hex. TIME = hashing only (data generation excluded).
-- Optional: `lua sha256.lua selftest` prints the digest of "abc" (for
-- one-time verification against a known-good SHA-256 implementation).

local C = require("compat")
local band, bxor, bnot = C.band, C.bxor, C.bnot
local rshift, rrotate = C.rshift, C.rrotate
local tohex32 = C.tohex32
local floor = math.floor
local byte, char, rep = string.byte, string.char, string.rep
local concat = table.concat
local up = C.unpack

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function be32(x)
  return char(floor(x / 16777216) % 256, floor(x / 65536) % 256,
              floor(x / 256) % 256, x % 256)
end

local function sha256(msg)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local len = #msg
  local bitlen = len * 8
  local padlen = (55 - len) % 64
  msg = msg .. char(0x80) .. rep("\0", padlen)
        .. be32(floor(bitlen / 4294967296)) .. be32(bitlen % 4294967296)
  local w = {}
  for i = 1, #msg, 64 do
    for j = 0, 15 do
      local p = i + j * 4
      local b1, b2, b3, b4 = byte(msg, p, p + 3)
      w[j + 1] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    end
    for j = 17, 64 do
      local v15, v2 = w[j - 15], w[j - 2]
      local s0 = bxor(bxor(rrotate(v15, 7), rrotate(v15, 18)), rshift(v15, 3))
      local s1 = bxor(bxor(rrotate(v2, 17), rrotate(v2, 19)), rshift(v2, 10))
      w[j] = (w[j - 16] + s0 + w[j - 7] + s1) % 4294967296
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for j = 1, 64 do
      local S1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = (h + S1 + ch + K[j] + w[j]) % 4294967296
      local S0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
      local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
      local t2 = (S0 + maj) % 4294967296
      h = g; g = f; f = e; e = (d + t1) % 4294967296
      d = c; c = b; b = a; a = (t1 + t2) % 4294967296
    end
    h0 = (h0 + a) % 4294967296; h1 = (h1 + b) % 4294967296
    h2 = (h2 + c) % 4294967296; h3 = (h3 + d) % 4294967296
    h4 = (h4 + e) % 4294967296; h5 = (h5 + f) % 4294967296
    h6 = (h6 + g) % 4294967296; h7 = (h7 + h) % 4294967296
  end
  return tohex32(h0) .. tohex32(h1) .. tohex32(h2) .. tohex32(h3)
      .. tohex32(h4) .. tohex32(h5) .. tohex32(h6) .. tohex32(h7)
end

if arg and arg[1] == "selftest" then
  print(sha256("abc"))
  os.exit(0)
end

-- setup: generate 1 MB of deterministic data (MINSTD LCG; exact in doubles)
local SIZE = 2097152
local seed = 42
local buf, parts, n = {}, {}, 0
for i = 1, SIZE do
  seed = (seed * 16807 + 3) % 2147483647
  n = n + 1
  buf[n] = seed % 256
  if n == 64 then
    parts[#parts + 1] = char(up(buf, 1, 64))
    n = 0
  end
end
local data = concat(parts)

local clock = os.clock
local t0 = clock()
local digest = sha256(data)
local t = clock() - t0

print("CHECK " .. digest)
print(string.format("TIME %.3f", t))
