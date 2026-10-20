-- bench_bit2.lua: typical 5.3 bitop shapes. Unpinned; ratios to a same-run
-- arithmetic reference loop. Results printed so builds can be compared.
local N = tonumber(arg and arg[1]) or 1e7
local rgb = assert(load([[
  local n = ...
  local acc = 0
  for i = 1, n do
    local c = (i * 2654435761) % 16777216            -- arithmetic, < 2^24
    local r, g, b = (c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff
    acc = (acc + ((b << 16) | (g << 8) | r)) % 4294967296
  end
  return acc
]]))
local rgb_ref = assert(load([[
  local n = ...
  local acc = 0
  for i = 1, n do
    local c = (i * 2654435761) % 16777216
    local r, g, b = math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
    acc = (acc + (b * 65536 + g * 256 + r)) % 4294967296
  end
  return acc
]]))
local crct = assert(load([[
  local n = ...
  local T = {}
  for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
      if c & 1 == 1 then c = (c >> 1) ~ 0xedb88320 else c = c >> 1 end
    end
    T[i] = c
  end
  local s = string.rep("The quick brown fox jumps over the lazy dog. ", 64)
  local crc = 0xffffffff
  local len = #s
  for k = 1, n do
    local byte = s:byte((k - 1) % len + 1)
    crc = T[(crc ~ byte) & 0xff] ~ (crc >> 8)
  end
  return crc ~ 0xffffffff
]]))
local function t(f, n)
  local best, r = math.huge, nil
  for _ = 1, 3 do
    local t0 = os.clock(); r = f(n); local dt = os.clock() - t0
    if dt < best then best = dt end
  end
  return best / n * 1e9, r
end
local a, ra = t(rgb, N)
local b, rb = t(rgb_ref, N)
local c, rc = t(crct, N)
print(string.format("rgb %.2f ns (r=%.17g) ref %.2f ns (r=%.17g) ratio %.2f | crc-table %.2f ns/byte (r=%.17g)",
  a, ra, b, rb, a / b, c, rc))
