-- T10 instrument, not a deliverable: runs ingame-bitops.lua as if in game.
-- A stub `computer` answers getArchitecture() with the name given, and a stub
-- os.sleep records how long the script ran between two yields.
-- usage: <lua> stubrun.lua <script> <arch name> <outdir> [reps]
local script, archname, outdir, reps = ...
computer = {
  getArchitecture = function() return archname end,
  totalMemory = function() return 16777216 end,
  freeMemory = function() return 15000000 end,
}
local last, maxgap, n = os.clock(), 0, 0
os.sleep = function(t)
  local now = os.clock()
  if now - last > maxgap then maxgap = now - last end
  last = now
  n = n + 1
end
local f = assert(loadfile(script))
if reps then f(reps, outdir) else f(outdir) end
local now = os.clock()
if now - last > maxgap then maxgap = now - last end
print(string.format("STUB: arch stub '%s', %d yields, longest stretch without a yield %.3f s", archname, n, maxgap))
