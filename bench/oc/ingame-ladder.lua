-- bench/oc/ingame-ladder.lua -- the in-game column of the sandbox-tax ladder.
--
-- Runs the compat-free benches from this directory inside an OpenComputers
-- machine and prints, per bench, the CHECK the script returned and the min of
-- N repetitions, the same shape the harness's PHASE1 ROW carries.  Copy this
-- file and the bench files into the computer's /home (an OC hard disk is a
-- directory under saves/<world>/opencomputers/<address>/), then at the shell:
--
--     ingame-ladder            (or: lua /home/ingame-ladder.lua)
--
-- The benches RETURN (check, seconds) rather than printing; each rep is a
-- fresh call of the same loaded chunk, and os.sleep(0) between reps yields so
-- no rep can run into the previous one's deadline.  sha256 is left out on
-- purpose: it goes through compat.lua's bit ops, and with no `jit` global in
-- the sandbox compat picks a different implementation than the standalone
-- rungs measured.  sieve is left out because it is quarantined (it needs more
-- than a 1 MB machine has).

local computer = require("computer")
local names = { "mandelbrot", "matmul", "binarytrees" }
local REPS = 5

print(string.format("machine RAM total=%d KB free=%d KB  jit global=%s",
  math.floor(computer.totalMemory() / 1024), math.floor(computer.freeMemory() / 1024), tostring(rawget(_G, "jit") ~= nil)))

for _, name in ipairs(names) do
  local path = "/home/" .. name .. ".lua"
  local fn, err = loadfile(path)
  if not fn then
    print(name .. ": cannot load " .. path .. ": " .. tostring(err))
  else
    local best, check, times = nil, nil, {}
    for rep = 1, REPS do
      local c, t = fn()
      check = c
      times[#times + 1] = string.format("%.3f", t)
      if not best or t < best then best = t end
      os.sleep(0)
    end
    print(string.format("%-12s CHECK=%s  min=%.4f s  reps: %s", name, tostring(check), best, table.concat(times, " ")))
  end
end
