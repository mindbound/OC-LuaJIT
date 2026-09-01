-- nqueens.lua: integer backtracking, N=12. CHECK = total solution count.

local N, REPS = 12, 6

local total = 0
local clock = os.clock
local t0 = clock()
for rep = 1, REPS do
  local cols, d1, d2 = {}, {}, {}
  local count = 0
  local function solve(row)
    if row > N then
      count = count + 1
      return
    end
    for col = 1, N do
      local x, y = row - col + N, row + col
      if not (cols[col] or d1[x] or d2[y]) then
        cols[col], d1[x], d2[y] = true, true, true
        solve(row + 1)
        cols[col], d1[x], d2[y] = nil, nil, nil
      end
    end
  end
  solve(1)
  total = total + count
end
local t = clock() - t0

print(string.format("CHECK %d", total))
print(string.format("TIME %.3f", t))
