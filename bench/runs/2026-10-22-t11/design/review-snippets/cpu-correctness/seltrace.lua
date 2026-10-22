-- The select bench's loop, as in the file, small n: what does the trace keep?
local function vsum(...)
  local s = 0
  for i = 1, select("#", ...) do s = s + (select(i, ...)) end
  return s
end
local function bench_sel(n)
  local r
  for _ = 1, n do
    r = 0
    for k = 1, 100 do r = r + vsum(k, 2, 3, 4, 5, 6, 7, 8) end
  end
  return r
end
print(bench_sel(20))
