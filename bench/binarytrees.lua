-- binarytrees.lua: GC pressure (allocate/walk/discard binary trees).
-- Adapted from the benchmarks-game shape. CHECK = sum of all node counts.

local MINDEPTH, MAXDEPTH = 4, 16

local function make(d)
  if d > 0 then
    return { make(d - 1), make(d - 1) }
  end
  return {}
end

local function nodes(t)
  local l = t[1]
  if l then
    return 1 + nodes(l) + nodes(t[2])
  end
  return 1
end

local total = 0
local clock = os.clock
local t0 = clock()

total = total + nodes(make(MAXDEPTH + 1))     -- stretch tree
local longlived = make(MAXDEPTH)               -- survives to the end

for d = MINDEPTH, MAXDEPTH, 2 do
  local iters = 1
  for _ = 1, MAXDEPTH - d + MINDEPTH do iters = iters * 2 end
  local sum = 0
  for i = 1, iters do
    sum = sum + nodes(make(d))
  end
  total = total + sum
end

total = total + nodes(longlived)
local t = clock() - t0

print(string.format("CHECK %d", total))
print(string.format("TIME %.3f", t))
