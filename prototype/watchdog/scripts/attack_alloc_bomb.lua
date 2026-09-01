-- (e) Alloc bomb -- table growth against the counting allocator.
-- Pure Lua bytecode loop that appends to a table forever. Unlike the
-- string bomb this stays in the interpreter/JIT (table growth calls back
-- into the allocator, and the loop body runs bytecode), so BOTH lines of
-- defence are live:
--   * the counting lua_Alloc (installed via lua_newstate, GC64) returns
--     NULL once the cap is hit -> LuaJIT raises "not enough memory".
--   * if instead you set a huge cap, the watchdog's soft hook interrupts
--     the loop on time.
--
-- Run with --mem-mb 32 --expect memcap to prove the allocator cap fires
-- first; run with --mem-mb 8192 --expect interrupt to prove the watchdog
-- catches it when memory is not the limiter.
local t = {}
local i = 0
while true do
  i = i + 1
  t[i] = { i, i * 2, "payload-" .. i }   -- allocates every iteration
end
