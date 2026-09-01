-- mandelbrot.lua: float escape-time over a grid. CHECK = sum of iteration counts.
-- Pure IEEE-double arithmetic in a fixed order => identical on all VMs.

local W, H, MAXI = 1024, 1024, 128

local sum = 0
local clock = os.clock
local t0 = clock()
for py = 0, H - 1 do
  local ci = 2.5 * py / H - 1.25
  for px = 0, W - 1 do
    local cr = 2.5 * px / W - 2.0
    local zr, zi, zr2, zi2 = 0.0, 0.0, 0.0, 0.0
    local it = 0
    while it < MAXI and zr2 + zi2 <= 4.0 do
      zi = 2.0 * zr * zi + ci
      zr = zr2 - zi2 + cr
      zr2 = zr * zr
      zi2 = zi * zi
      it = it + 1
    end
    sum = sum + it
  end
end
local t = clock() - t0

print(string.format("CHECK %d", sum))
print(string.format("TIME %.3f", t))
