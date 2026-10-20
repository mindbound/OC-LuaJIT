-- bench_idx.lua (proto-folda, 2026-10-20) -- loops the table-index fold
-- touches, best of 3, against bench_bit2.lua's arithmetic reference loop in
-- the same run.  crct and crctm are review1's bench_tf.lua rows (CRC32 by
-- table, and the same with crc masked to 32 bits each byte).  idx: a masked
-- bit result as a table key (the fold's target).  phi: the key carried to
-- the next iteration (the fold must not cross the PHI: unchanged).  phi2:
-- the key used now and carried (after the fold the carried key takes a
-- guarded conversion in the loop body, where round 3's build commoned it
-- with the pre-roll's: the one shape the fold can slow).  cnt: a masked
-- variable shift count.
local N = tonumber(arg and arg[1]) or 1e7
local function L(body, pre)
  return assert(load([[
  local n = ...
  local T = {}
  for k = 0, 255 do T[k] = (k * 2654435761) % 4294967296 end
  ]] .. (pre or "") .. [[
  local acc, ep = 0, 0
  for i = 1, n do ]] .. body .. [[ end
  return acc
]]))
end
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
local function crcsrc(mask)
  return [[
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
    crc = ]] .. (mask and "(T[(crc ~ byte) & 0xff] ~ (crc >> 8)) & 0xffffffff"
                       or "T[(crc ~ byte) & 0xff] ~ (crc >> 8)") .. [[

  end
  return crc ~ 0xffffffff
]]
end
local rows = {
  { "crct", assert(load(crcsrc(false))) },
  { "crctm", assert(load(crcsrc(true))) },
  { "idx", L("acc = (acc + T[(i * 7) & 0xff]) % 4294967296") },
  { "phi", L("acc = (acc + T[ep]) % 4294967296; ep = (i * 7) & 0xff") },
  { "phi2", L("local e = (i * 7) & 0xff; acc = (acc + T[e] + T[ep]) % 4294967296; ep = e") },
  { "cnt", L("acc = (acc + (1 << ((i * 7) & 31))) % 4294967296") },
}
local function t(f, n)
  local best, r = math.huge, nil
  for _ = 1, 3 do
    local t0 = os.clock(); r = f(n); local dt = os.clock() - t0
    if dt < best then best = dt end
  end
  return best / n * 1e9, r
end
local a = t(ref, N)
local out = { string.format("ref %.2f", a) }
for _, row in ipairs(rows) do
  local b, r = t(row[2], N)
  out[#out + 1] = string.format("%s %.2f (r=%.17g) ratio %.3f", row[1], b, r, b / a)
end
print(table.concat(out, " | "))
