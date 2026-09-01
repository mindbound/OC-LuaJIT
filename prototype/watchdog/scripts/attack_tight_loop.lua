-- (a) THE canonical evasion case.
-- A tight numeric loop with no calls, no allocations, no yields. LuaJIT
-- compiles this to a single self-contained loop trace (FORL/loop) that
-- polls NOTHING. On a STOCK LuaJIT build the async count hook set by the
-- watchdog will never be observed while this trace runs, so the interrupt
-- never fires -> HARD-ABORT-NEEDED.
--
-- On a LUAJIT_ENABLE_CHECKHOOK build, lj_record.c:2953 emits a volatile
-- XLOAD of g->hookmask + a guard at the top of every loop, so the trace
-- exits to the interpreter as soon as the watchdog arms the hook, and the
-- soft error fires. This one script, run against both binaries, is the
-- load-bearing A/B experiment.
--
-- Expected: --expect interrupt   (CHECKHOOK build)
--           --expect hard        (stock build)  [the thing we must avoid]
local x = 0
while true do
  x = x + 1
end
-- unreachable
return x
