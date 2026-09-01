-- (b) Nested-coroutine infinite loop.
-- The runaway loop lives several coroutine.resume levels deep. This checks
-- that the async hook (which is GLOBAL per global_State -- g->hookmask is
-- shared by every thread of the state) interrupts whichever coroutine is
-- actually executing, not just the top-level one the harness resumed.
--
-- The innermost coroutine runs the tight loop; when the watchdog arms the
-- hook the error should be raised inside THAT coroutine and propagate:
-- coroutine.resume returns (false, errobj) at each level, but none of the
-- levels wrap the resume in pcall, so the error object surfaces all the
-- way out of the outermost resume back to the harness.
--
-- Expected: --expect interrupt   (CHECKHOOK build)
local function innermost()
  local x = 0
  while true do
    x = x + 1          -- compiled tight loop, same as (a)
  end
end

local function level(depth, fn)
  return function()
    local co = coroutine.wrap(fn)   -- wrap: error propagates out of the wrap call
    co()
  end
end

local runner = innermost
for d = 1, 4 do
  runner = level(d, runner)
end

runner()
