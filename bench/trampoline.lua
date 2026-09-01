-- trampoline.lua: the anti-benchmark. Every call in the hot loop goes through
-- two layers of vararg forwarding plus a pcall, mimicking the spcall/wrapper
-- trampolines of the OpenComputers sandbox. Deliberately JIT-hostile.
-- CHECK = accumulator.

local ITER = 20000000

local function work(a, b, c)
  return a + b - c
end

local function guarded(f, ...)
  local n = select('#', ...)
  local ok, r = pcall(f, ...)
  if not ok then return n end
  return r + n
end

local function spcall_like(f, ...)
  return guarded(f, ...)
end

local acc = 0
local clock = os.clock
local t0 = clock()
for i = 1, ITER do
  acc = (acc + spcall_like(work, acc % 64, i % 97, i % 31)) % 1048576
end
local t = clock() - t0

print(string.format("CHECK %d", acc))
print(string.format("TIME %.3f", t))
