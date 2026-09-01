-- (c) pcall-swallowing loop -- re-arm / escalation test.
-- The classic "I'll just catch everything and keep going" griefer. The
-- inner infinite loop is wrapped in pcall so the soft error object is
-- caught and discarded; the outer while immediately retries.
--
-- Why the soft mechanism still wins (with CHECKHOOK): the watchdog arms
-- the hook with count == 1, so lj_dispatch_ins fires the hook on EVERY
-- bytecode instruction (lj_dispatch.c:437, hookcount resets to hookcstart
-- each time -- it stays armed). The inner pcall catches one raise, but the
-- very next instruction of the OUTER (unprotected) while loop trips the
-- hook again and the error escapes. So forward progress is impossible and
-- the resume returns within microseconds.
--
-- The harness ALSO re-arms every --rearm-ms as belt-and-suspenders, in
-- case a future attacker managed to clear the mask. This script is here to
-- prove pcall-swallowing does NOT defeat the watchdog.
--
-- Expected: --expect interrupt   (CHECKHOOK build)
local n = 0
while true do
  n = n + 1
  pcall(function()
    while true do end     -- inner runaway, compiled loop trace
  end)
end
