-- ctl_rec.lua -- THE POSITIVE CONTROL for "the recorder absorbed it": a run
-- in which the trace recorder's own allocation MUST be refused, so the
-- instrument's recorder classification is seen to fire (prove a new check
-- can fail).  Run by lref_*.exe in place of probe2.lua (same driver: it
-- loads this file, sets the cap, calls __kernel).
--   1. fill `held` with 64-byte tables under pcall until a fill makes no
--      progress twice running: the heap is at its ceiling (every refusal is
--      caught by the fill's pcall: OCLJEV code 1);
--   2. run a hot, allocation-free arithmetic loop: the interpreter allocates
--      nothing, the recorder allocates its trace (lj_trace_alloc at
--      trace_stop, IR/snapshot growth) and is refused -- OCLJCP st=4
--      recorder=1, the OCLJREF line with recorder=1 -- and the loop runs on,
--      interpreted: the program never sees the refusal.
local rec = __rec
local held, count = {}, 0
local function fill()
  for k = 1, 100000 do
    local t = { k, k }
    held[count + 1] = t
    count = count + 1
  end
end
function __kernel()
  local stuck = 0
  for r = 1, 200 do
    local before = count
    local ok = pcall(fill)
    if not ok then rec(1, count, r) end
    if count == before then stuck = stuck + 1 else stuck = 0 end
    if stuck >= 2 then break end
  end
  local s = 0
  for i = 1, 5000 do
    s = s + (i * 3) % 7
  end
  rec(6, count, s)
end
