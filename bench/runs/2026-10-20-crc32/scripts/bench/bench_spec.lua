-- bench_spec.lua -- the rg2 prototype's speculation (crc/rg2, 2026-10-20):
-- loops whose bit results are EXACT but lie outside [-2^53, 2^53), where the
-- loop body's range guard fails and leaves the trace, though the shipped
-- guard passes.  Every intermediate is exact (B-legal: no raise under U1-B);
-- the PUC 5.3.6 twin is spec_twin.lua's run of the same text.
--   luajit bench_spec.lua [N] [name]   (N default 2e6; name: one loop only)
-- Prints per loop: ns per iteration (best of 3), the result, and the ratio to
-- the same-run arithmetic reference loop (bench_bit2.lua's rgb_ref).
local N = tonumber(arg and arg[1]) or 2e6
local ONLY = arg and arg[2]
local SRC = {
  -- small counters shifted high: bits 60-62, >= 2^53 in 7 of 8 iterations
  hi60 = [[
    local n = ...
    local x, s = 0, 0
    for i = 1, n do
      x = x ~ ((i & 7) << 60)
      s = s + (x >> 60)
    end
    return s ]],
  -- flag words in bits 60-63 (1 << 63 is -2^63): a variable shift count
  flag63 = [[
    local n = ...
    local f, s = 0, 0
    for i = 1, n do
      f = f ~ (1 << (60 + (i & 3)))
      s = s + (f >> 60)
    end
    return s ]],
  -- i << 40 for i up to 2^23: exact, >= 2^53 once i >= 8192
  sh40 = [[
    local n = ...
    local h, s = 0, 0
    for i = 1, n do
      h = h ~ (i << 40)
      s = s + (h >> 40)
    end
    return s ]],
  -- a mask of the top 8 bits (-2^56 is 0xff00000000000000)
  top8 = [[
    local n = ...
    local s = 0
    for i = 1, n do
      local v = (i << 56) & -2^56
      s = s + (v >> 56)
    end
    return s ]],
  -- half in range, half out: (i & 15) << 50 is >= 2^53 when i & 15 >= 8
  half = [[
    local n = ...
    local x, s = 0, 0
    for i = 1, n do
      x = x ~ ((i & 15) << 50)
      s = s + (x >> 50)
    end
    return s ]],
  -- the range guard's best case: six results of unknown width (three >> of
  -- a table value, three ~), all in range, on a three-xor carried chain
  mix = [[
    local n = ...
    local T = {}
    local r = 12345
    for k = 1, 256 do r = (r * 69069 + 1) % 4294967296; T[k] = r end  -- exact: below 2^53
    local s = 0
    for i = 1, n do
      local v = T[(i & 255) + 1]
      s = s ~ (v >> 1) ~ (v >> 2) ~ (v >> 3)
    end
    return s ]],
  -- the control: the same shape, every value below 2^53 (no exit)
  lo50 = [[
    local n = ...
    local x, s = 0, 0
    for i = 1, n do
      x = x ~ ((i & 7) << 50)
      s = s + (x >> 50)
    end
    return s ]],
}
local ORDER = { "mix", "lo50", "hi60", "flag63", "sh40", "top8", "half" }
local ref = assert(load([[
  local n = ...
  local acc = 0
  for i = 1, n do
    local c = (i * 2654435761) % 16777216
    local r, g, b = math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
    acc = (acc + (b * 65536 + g * 256 + r)) % 4294967296
  end
  return acc
]]))
local function t(f, n)
  local best, r = math.huge, nil
  for _ = 1, 3 do
    local t0 = os.clock(); r = f(n); local dt = os.clock() - t0
    if dt < best then best = dt end
  end
  return best / n * 1e9, r
end
local out = {}
local tr = ONLY and 1 or t(ref, N)
if not ONLY then out[#out + 1] = string.format("ref %.2f", tr) end
for _, name in ipairs(ORDER) do
  if not ONLY or ONLY == name then
    local f = assert(load(SRC[name], "=" .. name))
    local ns, r = t(f, N)
    out[#out + 1] = string.format("%s %.2f (r=%.17g) x%.2f", name, ns, r, ns / tr)
  end
end
print(table.concat(out, " | "))
