-- (d) Builtin bomb -- string.rep / huge concat inside a C function.
-- THE honest hard-abort demonstrator. string.rep and '..' run entirely in
-- C (lib_string.c fast functions); they contain no bytecode, so NO hook of
-- any kind fires while they execute -- CHECKHOOK does not help here (it
-- only instruments compiled Lua loops). The watchdog arms the hook, but it
-- cannot be observed until the C call returns.
--
-- Two possible endings, both interesting:
--   * If the requested size fits under the memory cap, the C call simply
--     runs (fast, but during it the process is uninterruptible) -- run with
--     a big enough loop and it becomes a genuine HARD-ABORT case.
--   * If it exceeds the counting-allocator cap, the allocator returns NULL
--     and LuaJIT raises "not enough memory" from inside string.rep, which
--     surfaces as a normal error -> memcap.
--
-- Run it two ways:
--   --mem-mb 4096 --soft-ms 50 --hard-ms 300   -> likely HARD (stuck in C)
--   --mem-mb 32   --expect memcap               -> allocator catches it
local parts = {}
local chunk = string.rep("x", 1024 * 1024)   -- 1 MB seed
while true do
  -- each rep multiplies the live string; the C builtin is the point where
  -- no hook can fire. table growth also exercises the allocator cap.
  parts[#parts + 1] = string.rep(chunk, 64)   -- 64 MB per iteration
end
