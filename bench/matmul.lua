-- matmul.lua: NxN float matrix multiply. CHECK = trace formatted %.4f.
-- Inputs are exact binary fractions; same summation order on every VM.

local N, REPS = 250, 8

local a, bT = {}, {}
for i = 1, N do
  local ai = {}
  a[i] = ai
  for j = 1, N do
    ai[j] = ((i + j) % 16) * 0.0625 + 0.5
  end
end
-- b stored transposed (setup, untimed) so the kernel walks rows linearly
for j = 1, N do
  local bj = {}
  bT[j] = bj
  for k = 1, N do
    bj[k] = ((k * 3 + j * 7) % 16) * 0.03125 + 0.25
  end
end

local c = {}
local clock = os.clock
local t0 = clock()
for rep = 1, REPS do
  c = {}
  for i = 1, N do
    local ai = a[i]
    local ci = {}
    c[i] = ci
    for j = 1, N do
      local bj = bT[j]
      local s = 0.0
      for k = 1, N do
        s = s + ai[k] * bj[k]
      end
      ci[j] = s
    end
  end
end
local t = clock() - t0

local trace = 0.0
for i = 1, N do trace = trace + c[i][i] end

print(string.format("CHECK %.4f", trace))
print(string.format("TIME %.3f", t))
