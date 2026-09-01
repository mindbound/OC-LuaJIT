-- compat.lua: cross-VM 32-bit bit operations for Lua 5.3 / 5.4 / LuaJIT.
--
-- Contract for identical results across VMs:
--  * Outputs of bit ops may only be fed into (a) other bit ops, or
--    (b) additions that are followed by `% 4294967296` (mod 2^32).
--    (LuaJIT bit.* returns SIGNED 32-bit values; PUC masked ops return
--    unsigned. The two are congruent mod 2^32, so bit ops and mod-2^32
--    sums agree; raw comparisons/prints of intermediates would not.)
--  * Print 32-bit values only via tohex32() (or after norm()).

local M = {}

M.is_luajit = (type(jit) == "table")
M.unpack = table.unpack or unpack

if M.is_luajit then
  local bit = require("bit")
  M.band    = bit.band
  M.bor     = bit.bor
  M.bxor    = bit.bxor
  M.bnot    = bit.bnot
  M.lshift  = bit.lshift
  M.rshift  = bit.rshift
  M.rrotate = bit.ror
else
  -- Lua 5.3 / 5.4: build with native operators via load() so this file
  -- still parses on LuaJIT (which has no bitwise operator syntax).
  local src = [[
    return
      function(a, b) return (a & b) & 0xFFFFFFFF end,
      function(a, b) return (a | b) & 0xFFFFFFFF end,
      function(a, b) return (a ~ b) & 0xFFFFFFFF end,
      function(a) return (~a) & 0xFFFFFFFF end,
      function(a, n) return (a << n) & 0xFFFFFFFF end,
      function(a, n) return (a & 0xFFFFFFFF) >> n end,
      function(a, n)
        a = a & 0xFFFFFFFF
        if n == 0 then return a end
        return ((a >> n) | (a << (32 - n))) & 0xFFFFFFFF
      end
  ]]
  local f = assert(load(src, "compat-bitops"))
  M.band, M.bor, M.bxor, M.bnot, M.lshift, M.rshift, M.rrotate = f()
end

function M.norm(x)
  return x % 4294967296
end

local HEX = "0123456789abcdef"
local floor = math.floor

function M.tohex32(x)
  x = x % 4294967296
  local out = {}
  for i = 8, 1, -1 do
    local d = x % 16
    out[i] = HEX:sub(d + 1, d + 1)
    x = floor(x / 16)
  end
  return table.concat(out)
end

return M
