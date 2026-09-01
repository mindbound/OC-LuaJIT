-- sieve.lua: repeated prime sieve in freshly allocated tables.
-- CHECK = accumulated prime count over all repetitions.

local N, REPS = 100000, 400

local total = 0
local clock = os.clock
local t0 = clock()
for r = 1, REPS do
  local flags = {}
  for i = 2, N do flags[i] = true end
  local i = 2
  while i * i <= N do
    if flags[i] then
      for j = i * i, N, i do flags[j] = false end
    end
    i = i + 1
  end
  local count = 0
  for k = 2, N do
    if flags[k] then count = count + 1 end
  end
  total = total + count
end
local t = clock() - t0

print(string.format("CHECK %d", total))
print(string.format("TIME %.3f", t))
