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
-- The benches RETURN (check, seconds) rather than printing.  Every rep LOADS
-- the file again, as the harness suite does, and os.sleep(0) between reps
-- yields so no rep can run into the previous one's deadline.
--   Why every rep loads: the first version loaded each file once and called
-- the chunk five times, and that is the version the 2026-10-02 T7 run used.
-- Every call creates new closures of the same prototypes while the traces
-- compiled for the earlier calls' closures stay attached; binarytrees ran
-- 1.5x slower at the second call and ~2x from the third (1.2-1.3x and
-- 1.5-1.6x on the C-allocator host) on all three builds tried, upstream
-- included, slower than with the compiler off.  A jit.flush() before each
-- call removed the climb with LuaJIT's closure count past its threshold
-- (later calls within 1.08x of the first; faster than the first on the
-- C-allocator host), so the climb needs the trace state the earlier calls
-- leave behind, not the closure count.  A fresh load per rep keeps every
-- rep on the path the standalone rungs and the harness measure.
--   sha256 is left out on purpose: it would need compat.lua copied too;
-- compat probes load() for operator syntax, not `jit`, and takes the same
-- 'operators' path in the sandbox as standalone.  sieve is left out because
-- it is quarantined (it needs more than a 1 MB machine has).  "jit global" in
-- the first line says only whether the sandbox exposes a `jit` table (it does
-- not, by design); it is not the JIT's state.

local computer = require("computer")
local names = { "mandelbrot", "matmul", "binarytrees" }
local REPS = 5

print(string.format("machine RAM total=%d KB free=%d KB  jit global=%s",
  math.floor(computer.totalMemory() / 1024), math.floor(computer.freeMemory() / 1024), tostring(rawget(_G, "jit") ~= nil)))

for _, name in ipairs(names) do
  local path = "/home/" .. name .. ".lua"
  local best, check, times, failed = nil, nil, {}, nil
  for rep = 1, REPS do
    local fn, err = loadfile(path)
    if not fn then failed = err break end
    local c, t = fn()
    check = c
    times[#times + 1] = string.format("%.3f", t)
    if not best or t < best then best = t end
    os.sleep(0)
  end
  if failed then
    print(name .. ": cannot load " .. path .. ": " .. tostring(failed))
  else
    print(string.format("%-12s CHECK=%s  min=%.4f s  reps: %s", name, tostring(check), best, table.concat(times, " ")))
  end
end
