-- bench/oc/sha256.lua -- the sandbox-runnable form of bench/sha256.lua.
--
-- SAME digest as bench/sha256.lua, over the SAME 2 MiB stream, in O(1) memory.
-- Its CHECK is therefore the PUBLISHED reference from bench/results-2026-09-01.md
-- and needs no new baseline:
--     4044b97490ea337483cb563ee4336c024272c962e86475de24c58abaade25a5d
--
-- WHAT CHANGED FROM bench/sha256.lua, AND WHY.
--
--  1. STREAMING, not because it is nicer but because the original does not fit.
--     bench/sha256.lua materialises the whole message: a 32768-entry `parts`
--     table of 64-byte strings, then a 2 MiB `concat`, then a further padded
--     copy -- about 12 MB peak.  The machine has 865-1024 KB free after boot
--     and LuaJIT has no emergency GC, so that would not fail this row: the
--     first refused allocation throws and the WHOLE RUN is lost.  Here the
--     compression function is fed 64 bytes at a time straight off the LCG, so
--     neither the parts table nor the message string ever exists.  SIZE, the
--     seed and the LCG are untouched -- that is what preserves the published
--     digest; only the plumbing between them changed.
--
--     MEASURED PEAK, sampling collectgarbage("count") from a debug count hook
--     under `luajit -joff` (never with the JIT on: a sampling loop under a
--     count hook is the exact pathology this project just fixed):
--     **64.7 KB total heap, 4.0 KB above the loader's own 60.7 KB baseline**,
--     against a 450 KB budget.  Identical to 0.1 KB at hook intervals of 200,
--     1000 and 5000 instructions, which is how we know this is a flat
--     allocation profile and not a sampling artifact; lua5.3 cross-check
--     58.7 KB total / 6.9 KB delta.  Steady state is two 64-slot arrays plus
--     the 64-entry K table, and after setup the hot loop allocates nothing.
--
--  2. TIME NOW INCLUDES DATA GENERATION.  bench/sha256.lua starts its clock
--     after `concat`, timing the hash alone.  Streaming interleaves generation
--     and hashing, so they cannot be separated and the clock covers both.
--     Every VM does exactly the same extra work, so the cross-VM comparison is
--     still fair -- but this row is NOT comparable row-for-row with the sha256
--     row in results-2026-09-01.md, which measured a strictly smaller kernel.
--     How much smaller, measured here (the LCG + store loop alone, block()
--     replaced by an empty function, min of 5): 0.017 s of 0.056 s under
--     luajit, 0.043 s of 1.314 s under luajit -joff, 0.067 s of 1.783 s under
--     lua5.3.  Generation is therefore ~30% of the JIT-on number and ~4% of
--     the interpreted ones.  Subtracting it from lua5.3 gives 1.716 s against
--     the published hashing-only 1.649 s -- 4% high, on a box that was not
--     idle -- which is an independent check that the streaming rewrite changed
--     where the message is stored, not how much work is done.
--
--     A second number here is not a like-for-like of its published twin, for a
--     different reason: `luajit -joff`.  results-2026-09-01.md measured 0.363 s
--     with compat on LuaJIT's `bit` library; bench/oc/compat.lua pins the
--     OPERATOR path on every VM (see its header), and interpreted, operators
--     go through seven Lua closures where `bit` went through C.  That is the
--     2.7x compat records, and it is most of the gap to the 1.314 s here.  The
--     pinning is deliberate: the sandbox has no `jit` global, so an unpinned
--     compat would silently have measured a different program in-machine than
--     it measured standalone.
--
--  3. The two print()s became a `return`, as the harness contract requires,
--     and the `selftest` branch went away with `arg`.
--
--  4. compat comes from the harness, not from require().  The sandbox has no
--     require() and no package path; the harness plants bench/oc/compat.lua
--     and pre-sets _G.__OCLJ_COMPAT to the loaded module.  Standalone, the
--     require() fallback picks up the sibling file, so one file serves both.
--     compat's choice of path is load-bearing here: this is the one benchmark
--     in the suite that does bit work, so it is the one whose number is
--     meaningless unless C.path is recorded beside it ("operators" on every VM
--     in this project; "bit32-STITCHED" would be a different program).
--
-- VERIFIED on this file as it stands, standalone, 2026-09-03.  The digest is
-- byte-identical to the published reference on luajit, luajit -joff, lua5.3
-- and lua5.4, loaded BOTH ways -- harness-style `load(src)` with
-- _G.__OCLJ_COMPAT preset and `require` removed from _G for the duration, and
-- standalone-style via require -- with C.path = "operators" on all four and
-- the returned CHECK of type string.  ONE distinct digest across all 19 runs.
-- Times, min of 5 (this box was under concurrent load; quote the ratios, not
-- the absolute seconds, against results-2026-09-01.md):
--     luajit 0.056   luajit -joff 1.314   lua5.3 1.783   lua5.4 1.313
-- Uses only os.clock, math.floor and -- inside compat -- string.format: no io,
-- no os.time, no print, no collectgarbage, no bit32, no `arg`.

local C = _G.__OCLJ_COMPAT
if not C and type(require) == "function" then C = require("compat") end
if not C then
  error("sha256: no compat -- harness must set _G.__OCLJ_COMPAT", 0)
end
local band, bxor, bnot = C.band, C.bxor, C.bnot
local rshift, rrotate = C.rshift, C.rrotate
local tohex32 = C.tohex32
local floor = math.floor

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

local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
local w = {}

local function block(b)                 -- b = 64 bytes as an array of 64 ints
  for j = 0, 15 do
    local p = j * 4
    w[j + 1] = ((b[p+1] * 256 + b[p+2]) * 256 + b[p+3]) * 256 + b[p+4]
  end
  for j = 17, 64 do
    local v15, v2 = w[j - 15], w[j - 2]
    local s0 = bxor(bxor(rrotate(v15, 7), rrotate(v15, 18)), rshift(v15, 3))
    local s1 = bxor(bxor(rrotate(v2, 17), rrotate(v2, 19)), rshift(v2, 10))
    w[j] = (w[j - 16] + s0 + w[j - 7] + s1) % 4294967296
  end
  local a, bb, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
  for j = 1, 64 do
    local S1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
    local ch = bxor(band(e, f), band(bnot(e), g))
    local t1 = (h + S1 + ch + K[j] + w[j]) % 4294967296
    local S0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
    local maj = bxor(bxor(band(a, bb), band(a, c)), band(bb, c))
    local t2 = (S0 + maj) % 4294967296
    h = g; g = f; f = e; e = (d + t1) % 4294967296
    d = c; c = bb; bb = a; a = (t1 + t2) % 4294967296
  end
  h0 = (h0 + a) % 4294967296; h1 = (h1 + bb) % 4294967296
  h2 = (h2 + c) % 4294967296; h3 = (h3 + d) % 4294967296
  h4 = (h4 + e) % 4294967296; h5 = (h5 + f) % 4294967296
  h6 = (h6 + g) % 4294967296; h7 = (h7 + h) % 4294967296
end

local SIZE = 2097152                    -- bytes; a multiple of 64, so the tail
local seed = 42                         -- is one all-padding block
local buf = {}
local clock = os.clock
local t0 = clock()
local n = 0
for i = 1, SIZE do
  seed = (seed * 16807 + 3) % 2147483647
  n = n + 1
  buf[n] = seed % 256
  if n == 64 then block(buf); n = 0 end
end
-- padding: SIZE is a multiple of 64, so 0x80 then zeros then the 8-byte length
local bitlen = SIZE * 8
for k = 1, 64 do buf[k] = 0 end
buf[1] = 0x80
local hi = floor(bitlen / 4294967296) % 4294967296
local lo = bitlen % 4294967296
buf[57] = floor(hi / 16777216) % 256; buf[58] = floor(hi / 65536) % 256
buf[59] = floor(hi / 256) % 256;      buf[60] = hi % 256
buf[61] = floor(lo / 16777216) % 256; buf[62] = floor(lo / 65536) % 256
buf[63] = floor(lo / 256) % 256;      buf[64] = lo % 256
block(buf)
local t = clock() - t0

return tohex32(h0) .. tohex32(h1) .. tohex32(h2) .. tohex32(h3)
    .. tohex32(h4) .. tohex32(h5) .. tohex32(h6) .. tohex32(h7), t
