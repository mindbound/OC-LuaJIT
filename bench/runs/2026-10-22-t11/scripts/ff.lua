-- Fail-first wrapper for ingame-bitops.lua v2 (scratch only).
--   <lua> ff.lua <mode> <script> <outdir>
-- mode: none (control), err (bench 2 raises), bad (bench 4 returns a wrong
-- value), clock (os.clock never advances), skip (no string.pack).
local mode, script, outdir = arg[1], arg[2], arg[3]
if mode == "clock" then os.clock = function() return 0 end end
if mode == "skip" then string.pack = nil end
local real_load = load
load = function(s, name, ...)
  local f, e = real_load(s, name, ...)
  if not f or name ~= "=ingame-bitops ops" then return f, e end
  return function(...)
    local op = f(...)
    if mode == "err" then
      op.benches[2].fn = function() error("sabotage: bench raised") end
    elseif mode == "bad" then
      local g = op.benches[4].fn
      op.benches[4].fn = function(n) return g(n) + 1 end
    end
    return op
  end
end
local main = assert(loadfile(script))
main("1", outdir)
