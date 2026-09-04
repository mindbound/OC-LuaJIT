-- peak-inband.lua -- measure each benchmark's peak heap WITHOUT a debug hook.
--
-- WHY THIS EXISTS.  run-standalone.sh's `peaks` mode samples the heap from a
-- count hook every 10000 instructions, and that instrument changes what it
-- measures.  A hook callback is Lua work, and Lua work is GC safepoints, so a
-- hooked run hands the collector hundreds of extra chances per iteration that
-- the bare program never gives it.  The collector keeps up, the heap stays
-- low, and the number reported is the hook's heap, not the benchmark's.
--
-- Measured on sieve, luajit -joff, same file, same parameters:
--
--     REPS      hook      in-band
--      100     440.8      1143.6
--      500     440.8      1143.6
--     1500     440.8      1143.6
--     4500     440.8      1143.6
--
-- The hook column is pinned flat from REPS=100 upward, and it is that flatness
-- that bench/oc/sieve.lua's header reports as "peak 233.5 KB,
-- REPS-INDEPENDENT, measured at REPS 1500, 6000 and 12000".  The steady state
-- really is small -- live-after-collect is 52.4 KB at every REPS in every mode
-- -- but what the guard needs to know is the high-water mark, and that is 2.6x
-- what the hook reported.
--
-- THIS MATTERS BEYOND TIDINESS.  references.txt's peak column feeds the
-- in-machine RAM guard, which refuses to start a benchmark unless free memory
-- is above peak + 128 KB.  An UNDER-estimate is the dangerous direction: it
-- lets a benchmark start that then takes the machine down.  sieve was declared
-- at 312 KB, so the guard asked for 440 KB and let it run in a machine with
-- ~890 KB free -- and sieve then killed that machine 6 runs out of 6.  With a
-- truthful ~1144 KB the guard would have asked for more than the machine has
-- and skipped the row, which is the outcome the guard exists to produce.
--
-- HOW IT SAMPLES.  One collectgarbage("count") per iteration of the benchmark's
-- outermost timed loop, injected into the source.  One C call per iteration
-- against thousands of stores is not enough to pace a collector; a hook firing
-- every 10000 instructions is.  The anchor is uniform across this directory:
-- every benchmark has `local t0 = clock()` immediately before its timed
-- region, and the next line at column 0 that opens a `for` is the loop.  A
-- benchmark whose shape stops matching FAILS LOUDLY here rather than being
-- silently measured a different way.
--
-- usage: luajit -joff peak-inband.lua <repo> [name...]
--
-- Measure with -joff.  With the compiler on, traces are themselves on the heap
-- AND are pinned for as long as the running prototype is reachable (see
-- docs/research/memory-accounting.md section 8a), so the figure would be the
-- compiler's footprint rather than the workload's.

local R = arg[1] or "."
local NAMES = {}
for i = 2, #arg do NAMES[#NAMES + 1] = arg[i] end
if #NAMES == 0 then
  NAMES = { "mandelbrot", "sieve", "binarytrees", "trampoline", "matmul",
            "strings2", "nqueens", "sha256", "strings" }
end

local function slurp(p)
  local f = io.open(p, "rb"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local compat = slurp(R .. "/bench/oc/compat.lua")
if compat then _G.__OCLJ_COMPAT = assert(load(compat, "=compat"))() end

-- Inject one sampler into the outermost timed loop.  Returns nil if the shape
-- does not match, so the caller can report that rather than guess.
local function inject(src)
  local at = src:find("local t0 = clock()", 1, true)
  if not at then return nil, "no `local t0 = clock()` anchor" end
  local head, tail = src:sub(1, at - 1), src:sub(at)
  -- first column-0 `for ... do` after the anchor
  local s, e = tail:find("\nfor [^\n]* do\n")
  if not s then return nil, "no column-0 `for ... do` after the clock anchor" end
  local probe = "\n  local __k = collectgarbage('count')" ..
                " if __k > __PEAK then __PEAK = __k end\n"
  return head .. tail:sub(1, e - 1) .. probe .. tail:sub(e)
end

print("VM: " .. (jit and (jit.status() and "luajit JIT ON -- WRONG, use -joff"
                          or "luajit -joff") or _VERSION))
print("")
print(string.format("%-12s %10s %12s %10s %10s  %s",
  "benchmark", "peakKB", "onreturnKB", "liveKB", "sec", "CHECK"))

local out = {}
for _, name in ipairs(NAMES) do
  local src = slurp(R .. "/bench/oc/" .. name .. ".lua")
  if not src then
    print(string.format("%-12s %10s  MISSING", name, "-"))
  else
    local inj, why = inject(src)
    if not inj then
      print(string.format("%-12s %10s  CANNOT INSTRUMENT: %s", name, "-", why))
    else
      collectgarbage("collect"); collectgarbage("collect")
      _G.__PEAK = 0
      local fn, lerr = load(inj, "=" .. name)
      if not fn then
        print(string.format("%-12s %10s  INJECTION BROKE THE SOURCE: %s", name, "-", tostring(lerr)))
      else
        local t0 = os.clock()
        local ok, chk = pcall(fn)
        local wall = os.clock() - t0
        local onreturn = collectgarbage("count")
        collectgarbage("collect"); collectgarbage("collect")
        local live = collectgarbage("count")
        local peak = _G.__PEAK
        if onreturn > peak then peak = onreturn end   -- the tail after the last sample
        if not ok then
          print(string.format("%-12s %10s  ERROR: %s", name, "-", tostring(chk)))
        else
          out[name] = math.ceil(peak)
          print(string.format("%-12s %10.1f %12.1f %10.1f %10.3f  %s",
            name, peak, onreturn, live, wall, tostring(chk)))
        end
      end
    end
  end
end

print("")
print("references.txt peak column (third field), rounded up:")
for _, name in ipairs(NAMES) do
  if out[name] then print(string.format("  %-12s %d", name, out[name])) end
end
