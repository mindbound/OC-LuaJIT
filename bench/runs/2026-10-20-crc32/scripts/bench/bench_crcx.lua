-- bench_crcx.lua [N] -- crc/combine's CRC32 rows beside bench_bit2.lua's
-- crc-table and bench_idx.lua's crct/crctm (2026-10-20).  Best of 3, ns per
-- byte, against bench_bit2.lua's arithmetic reference loop in the same run.
--   crcprobe  docs/jit-guide.md 8.8's crcprobe.lua, its loop as printed
--             there, run for N bytes (its 20000 made a parameter); before
--             timing, the 20000-byte run must print the guide's
--             3012454781, or this file says INSTRUMENT and exits 2
--   crcmb     crc masked to 32 bits each byte AND the byte masked
--             (byte & 0xff): guide 8.8's "masked-byte" CRC, where scoring a
--             u8 operand 9 bits (roadmap row 211 (1)) would matter
-- Runs unchanged on PUC 5.3.6 (integers there, doubles here; the results
-- print alike).
local N = tonumber(arg and arg[1]) or 1e7
local function chunk(update)
  return assert(load([[
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
    ]] .. update .. [[

  end
  return crc ~ 0xffffffff
]]))
end
local crcprobe = chunk("crc = T[(crc ~ byte) & 0xff] ~ (crc >> 8)")
local crcmb = chunk("crc = (T[(crc ~ (byte & 0xff)) & 0xff] ~ (crc >> 8)) & 0xffffffff")
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
local check = crcprobe(20000)
if check ~= 3012454781 then
  print(string.format("bench_crcx: INSTRUMENT: crcprobe(20000) = %.17g, not the guide's 3012454781", check))
  os.exit(2)
end
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
for _, row in ipairs({ { "crcprobe", crcprobe }, { "crcmb", crcmb } }) do
  local b, r = t(row[2], N)
  out[#out + 1] = string.format("%s %.2f (r=%.17g) ratio %.3f", row[1], b, r, b / a)
end
print(table.concat(out, " | "))
