-- patch-machine-lua.lua -- derive the OC-LuaJIT kernel from OpenComputers'
-- machine.lua by replacing its standing deadline hook with the watchdog.
--
--   luajit patch-machine-lua.lua <in: OC machine.lua> <out: patched machine.lua>
--
-- WHY A PATCH AND NOT A FORK.  The census argument stands: we run OC's real
-- kernel semantics and couple to no particular OS.  This script changes four
-- places, all of them the same change, and refuses to run if any anchor does
-- not match EXACTLY ONCE -- so an OpenComputers bump that moves or rewords a
-- site fails loudly at build time rather than shipping a kernel that arms the
-- old hook somewhere.
--
-- THE CHANGE.  OC enforces its per-resume timeout by arming
--     debug.sethook(co, checkDeadline, "", hookInterval)
-- before every resume and never clearing the outer one.  On LuaJIT that
-- single standing count hook forces slow dispatch for the whole VM and makes
-- every compiled trace exit on entry: measured inside a real machine, the
-- JIT is then 18.8x SLOWER than the plain interpreter and OpenOS boots 40%
-- slower (docs/research/hook-vs-jit.md).  The watchdog the native provides
-- as _OCLJ_WATCHDOG arms NOTHING until the deadline has actually passed; then
-- a timer thread injects a count=1 hook that calls checkDeadline -- the SAME
-- checkDeadline, untouched, with its sentinel, its 0.5s grace and its own
-- count=1 re-arm against pcall-swallowing loops.  What this patch changes is
-- who arms the hook and when, and nothing else.
--
-- Left alone on purpose:
--   * calcHookInterval (the bogomips loop at the top) still arms a hook for
--     0.05s at boot.  hookInterval is now used by nothing, but the loop is
--     harmless and removing it would widen the diff for no gain.
--   * checkDeadline's own debug.sethook(coroutine.running(), checkDeadline,
--     "", 1): the post-expiry re-arm.  It only ever runs after the deadline
--     has passed, when speed no longer matters, and disarm() clears it.

local inpath, outpath = arg[1], arg[2]
assert(inpath and outpath, "usage: luajit patch-machine-lua.lua <in> <out>")

local f = assert(io.open(inpath, "rb"))
local src = f:read("*a")
f:close()

-- Line endings.  A Windows checkout of ocelot-brain hands us machine.lua with
-- CRLF, and every anchor below ends in a bare newline; the first run of this
-- patcher matched nothing at all for exactly that reason.  Normalise, remember
-- the original, and write back the same convention.
local CR, LF = string.char(13), string.char(10)
local crlf = src:find(CR .. LF, 1, true) ~= nil
src = src:gsub(CR .. LF, LF)

local function count(s, needle)
  local n, pos = 0, 1
  while true do
    local a, b = s:find(needle, pos, true)
    if not a then return n end
    n, pos = n + 1, b + 1
  end
end

local function replace_once(s, what, old, new)
  local n = count(s, old)
  assert(n == 1, ("patch-machine-lua: anchor for '%s' matched %d times, expected exactly 1"):format(what, n))
  local a, b = s:find(old, 1, true)
  return s:sub(1, a - 1) .. new .. s:sub(b + 1)
end

-- 0. the kernel captures the watchdog as an upvalue, up front.
src = replace_once(src, "watchdog capture",
[==[local deadline = math.huge
]==],
[==[local deadline = math.huge
-- OC-LuaJIT: the native's deadline watchdog replaces the standing count hook
-- at the three arm sites below.  See native/kernel/patch-machine-lua.lua.
local watchdog = _OCLJ_WATCHDOG
if type(watchdog) ~= "table" then
  error("this kernel is the OC-LuaJIT variant and needs the OC-LuaJIT native (no _OCLJ_WATCHDOG)", 0)
end
-- A raw global the harness can READ BACK, so "the watchdog kernel ran" is an
-- observation rather than the echo of a command-line flag.  The sandbox
-- never sees raw _G; a string here is harmless to persist.
_OCLJ_KERNEL = "watchdog"
]==])

-- 1. the synchronous-__gc path: arm AFTER the shortened deadline is set.
src = replace_once(src, "sgc arm/disarm",
[==[  debug.sethook(sgcco, checkDeadline, "", hookInterval)
  deadline, hitDeadline = math.min(oldDeadline, computer.realTime() + 0.5), true
  local _, result, reason = coroutine.resume(sgcco, self, gc)
  debug.sethook(sgcco)
]==],
[==[  deadline, hitDeadline = math.min(oldDeadline, computer.realTime() + 0.5), true
  local wd = watchdog.arm(deadline - computer.realTime(), checkDeadline, false, sgcco)
  local _, result, reason = coroutine.resume(sgcco, self, gc)
  watchdog.disarm(wd)
]==])

-- 2. the sandbox's coroutine.resume wrapper, around every user coroutine.
src = replace_once(src, "sandbox coroutine.resume arm/disarm",
[==[        debug.sethook(co, checkDeadline, "", hookInterval)
        local result = table.pack(
          coroutine.resume(co, table.unpack(args, 1, args.n)))
        debug.sethook(co) -- avoid gc issues
]==],
[==[        local wd = watchdog.arm(deadline - computer.realTime(), checkDeadline, false, co)
        local result = table.pack(
          coroutine.resume(co, table.unpack(args, 1, args.n)))
        watchdog.disarm(wd) -- avoid gc issues
]==])

-- 3. the main kernel loop.  OC never cleared this one; we must, or a
--    deadline expiring while the machine is idle between ticks would fire on
--    the first instruction of the next resume.  This arm is the OUTERMOST
--    (third argument true): it resets the watchdog's stack first, so anything
--    a previous resume leaked -- a disarm skipped because checkDeadline fired
--    on the kernel's own instructions past the grace, and a sandbox pcall then
--    swallowed the error -- is discarded before the next resume starts.
--    Every arm also names the coroutine it is about to resume (fourth
--    argument).  The injected hook is global, and a fire landing after that
--    coroutine has yielded but before disarm() runs must NOT call
--    checkDeadline on the kernel's own thread -- on OC that crash cannot
--    happen, because PUC's hooks are per-thread.  The native skips a fire
--    only on a thread that armed a live entry and is not the one the top
--    entry protects, i.e. a parent waiting on a child; every other thread
--    fires, including coroutines nested past the native's depth cap, which
--    have no entry of their own.
src = replace_once(src, "main loop arm/disarm",
[==[    debug.sethook(co, checkDeadline, "", hookInterval)
    local result = table.pack(coroutine.resume(co, table.unpack(args, 1, args.n)))
    args = nil -- clear upvalue, avoids trying to persist it
]==],
[==[    local wd = watchdog.arm(deadline - computer.realTime(), checkDeadline, true, co)
    local result = table.pack(coroutine.resume(co, table.unpack(args, 1, args.n)))
    watchdog.disarm(wd)
    args = nil -- clear upvalue, avoids trying to persist it
]==])

-- What must remain: exactly the three debug.sethook calls we leave alone
-- (two in calcHookInterval, one in checkDeadline).  Anything else means OC
-- grew a fourth arm site this patch does not know about.
local remaining = count(src, "debug.sethook(")
assert(remaining == 3,
  ("patch-machine-lua: %d debug.sethook( calls remain after patching, expected 3"):format(remaining))

local banner = [==[-- =====================================================================
-- OC-LuaJIT KERNEL VARIANT -- generated by native/kernel/patch-machine-lua.lua
-- from OpenComputers' machine.lua.  Do not edit; edit the patcher.
-- Four sites changed: the standing deadline hook is replaced by the native's
-- asynchronous watchdog.  Everything else is OpenComputers' own kernel.
-- =====================================================================
]==]

local out = banner .. src
if crlf then out = out:gsub(LF, CR .. LF) end
local g = assert(io.open(outpath, "wb"))
g:write(out)
g:close()
io.write(("patch-machine-lua: ok  %d -> %d bytes, 4 sites, 3 debug.sethook left, %s endings"):format(
  #src, #out, crlf and "CRLF" or "LF") .. LF)
