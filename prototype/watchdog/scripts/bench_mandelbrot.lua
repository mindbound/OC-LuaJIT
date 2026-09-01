-- (f) Honest benchmark: Mandelbrot escape-time, FP heavy, JIT-friendly.
-- Runs to completion (no watchdog interrupt expected). Use it to quantify:
--   * JIT on   (stock build):            baseline
--   * JIT off  (--jitoff):               interpreter floor
--   * JIT on   (CHECKHOOK build):        the CHECKHOOK tax on tight loops
-- The harness prints the wall-clock; compare across the three binaries/flags.
--
-- Expected: --expect complete
local W = tonumber(arg and arg[1]) or 900
local H = W
local ITER = 100
local sum = 0
for py = 0, H - 1 do
  local y0 = (py / H) * 2.0 - 1.0
  for px = 0, W - 1 do
    local x0 = (px / W) * 3.0 - 2.0
    local x, y = 0.0, 0.0
    local n = 0
    while n < ITER do
      local x2 = x * x
      local y2 = y * y
      if x2 + y2 > 4.0 then break end
      y = 2.0 * x * y + y0
      x = x2 - y2 + x0
      n = n + 1
    end
    sum = sum + n
  end
end
print("mandelbrot checksum: " .. sum)   -- 'io' is not in the sandbox; use base print
