-- bench/oc/mandelbrot.lua -- the sandbox-runnable form of bench/mandelbrot.lua.
--
-- BYTE-FOR-BYTE the same computation as bench/mandelbrot.lua: same W, H, MAXI,
-- same loop, same arithmetic in the same order.  The ONLY difference is the
-- last two lines: the standalone file prints CHECK and TIME, this one returns
-- them, because inside an OpenComputers sandbox print() goes to a scrolling
-- terminal the Java harness cannot reliably parse.  So its CHECK is the
-- PUBLISHED reference from bench/results-2026-09-01.md and needs no new
-- baseline: 37904620.
--
-- Why this one is the Phase-0 compute pole:
--   * zero allocation (~47 KB peak), so it cannot be killed by the RAM cap --
--     and LuaJIT has no emergency GC, so an oversized benchmark loses the
--     whole cell rather than just its own row;
--   * no bit operations, so it does not depend on which branch compat.lua
--     picks -- the sandbox has no `jit` global, which silently flips that
--     choice and changes the implementation being measured by 2.7x;
--   * no require() and no upvalues from outside, so it loads with a plain
--     load(src) off the filesystem proxy;
--   * pure IEEE-double arithmetic in a fixed order, so the checksum is
--     identical on PUC 5.2, on our LuaJIT interpreted, and on our LuaJIT
--     compiled -- which is what makes it a fair three-way comparison.
--
-- Run standalone with bench/oc/run-standalone.sh to regenerate references.

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

return string.format("%d", sum), t
