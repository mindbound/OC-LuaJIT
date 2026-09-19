-- patch-machine-lua.lua -- derive the OC-LuaJIT kernel from OpenComputers'
-- machine.lua by replacing its standing deadline hook with the watchdog.
--
--   luajit patch-machine-lua.lua <in: OC machine.lua> <out: patched machine.lua>
--
-- WHY A PATCH AND NOT A FORK.  The census argument stands: we run OC's real
-- kernel semantics and couple to no particular OS.  This script changes eleven
-- places and refuses to run if any anchor does not match EXACTLY ONCE -- so an
-- OpenComputers bump that moves or rewords a site fails loudly at build time
-- rather than shipping a kernel that arms the old hook somewhere.
--
-- The eleven are FOUR changes, not one.  Sites 0-3 replace the standing
-- deadline hook with the watchdog.  Sites 4-5 bind the name _ENV, which LuaJIT
-- does not provide at all; see THE SECOND CHANGE below.  Sites 6-9 convert the
-- kernel's two __persist recipes to the shell-fill protocol; see THE THIRD
-- CHANGE.  Sites 10-11 replace the kernel's two iterators that wrap next in a
-- closure with snapshot walks that survive a save; see THE FOURTH CHANGE.
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
-- THE SECOND CHANGE: _ENV.  LuaJIT is API/ABI-locked to Lua 5.1, which is
-- precisely why it cannot implement 5.2's _ENV -- upstream says so.  What it
-- DOES honour is load(ld, source, mode, env): the env becomes the chunk's
-- fenv, reads and writes go through it, and __index fallthrough works.  Only
-- the NAME _ENV is unbound.  Measured on our own luajit.exe.
--
-- That gap is not cosmetic.  OpenOS reads _ENV at eleven sites, and this
-- project's own docs claimed it read it at none (feasibility.md:68,
-- report-compat-and-perf.md:28) -- a claim the first in-game boot refuted with
-- "lua_shell.lua:14: attempt to index global '_ENV' (a nil value)".  Worse
-- than the crash: an unbound global reads as nil in LuaJIT, so
-- boot/01_process.lua:68's "env = _ENV" silently set the init process's env to
-- nil, lib/process.lua:32 propagated the nil down the whole process tree, and
-- machine.lua's own "env or sandbox" default below then handed EVERY program
-- the raw sandbox.  Per-process environments were collapsed machine-wide, with
-- nothing raised anywhere.
--
-- WHY THE OBVIOUS FIX IS WRONG.  Setting sandbox._ENV = sandbox alone (site 5
-- only) resolves at every site, because every OpenOS env chains to _G through
-- __index -- and answers with the WRONG TABLE everywhere a chunk has its own
-- environment, which is nine of the eleven.  lib/shell.lua:21 loads /bin/sh.lua
-- into a fresh table shadowing _G on purpose ("shells do not keep a global
-- state"); boot/01_process.lua:29-41 wraps any non-nil env in a further table
-- before the kernel sees it.  Under the one-site fix, .install floppies read
-- _ENV.install as nil (the documented contract, usr/man/install:68), program
-- globals escape the shell's shadow table into machine-wide _G, and the lua
-- REPL's auto-require cache at lua_shell.lua:14 injects every module name typed
-- into the real sandbox globals permanently.  All silent.
--
-- So site 4 publishes _ENV in the very table the chunk resolves globals
-- through, and site 5 is only the base case for chunks the kernel loads itself
-- (the BIOS at load(code, "=bios", "t", sandbox)).
--
-- What this does NOT fix, because nothing can: "local _ENV = t" is an ordinary
-- local under LuaJIT, and assigning _ENV = t does not rebind name resolution.
-- OpenOS does neither (zero hits), but third-party code might, silently.
-- Divergences we accept: pairs(env) now yields _ENV where 5.2 yields nothing,
-- and rawget(_G, "_ENV") is non-nil for us and nil on stock OC.

-- THE THIRD CHANGE: SHELL-FILL (docs/shell-fill.md).  Eris, and our fork until
-- 2026-09-17, called a __persist recipe the instant its record was read --
-- partway through rebuilding the graph, so anything not yet restored read as
-- nil.  In-game: "machine:1162: attempt to call upvalue 'wrapSingleUserdata'
-- (a nil value)" on any save holding an open file handle.  The serializer now
-- creates the special's FINAL table when its record is read and calls the
-- recipe as recipe(shell) once, after the whole graph exists; the recipe fills
-- its argument in place and must leave it with a metatable.  A recipe of the
-- old shape -- returning a fresh table -- is refused at load by name.
--
-- The kernel's two recipes are the ONLY recipe authors (persistKey is absent
-- from the sandbox), so this is the whole migration: the registry recipe sets
-- its metatable on the shell it is handed; the proxy recipe fills the shell
-- through wrapUserdataInto, a helper that is wrapSingleUserdata minus the
-- reuse scan -- not needed on the restore path, because persist-time dedup by
-- the reftable already collapsed every reference to one record, and a restored
-- Value is a fresh Java object that can never compare equal to another.
-- Fields are written BEFORE setmetatable because userdataWrapper.__newindex
-- routes writes to udinvoke.
--
-- THE FOURTH CHANGE: SNAPSHOT WALKS (docs/forin-iterator-gap.md,
-- docs/research/os-shape-census.md #1 and #3).  A coroutine suspended inside
-- "for k, v in pairs(t)" is restored EXACTLY: the replay iterator (M3.1)
-- recognises the loop by the real next in its func slot and re-walks the
-- rebuilt table to the same key.  A Lua closure that WRAPS next has no such
-- marker.  It persists like any closure, its position key round-trips
-- perfectly, and on restore next(t, k) continues from wherever k now sits in
-- the rebuilt table's hash layout -- a different layout, because the table
-- was rebuilt by insertion in record order -- visiting the wrong keys with
-- nothing raised.  No serializer change can reach it: the position is an
-- upvalue, not a control slot, and its meaning IS the layout.
--
-- OC's own kernel writes that shape twice, and both shipped in our kernel
-- until 2026-09-19.  component.list (site 10) returns a table that is ALSO
-- callable as an iterator, its __call advancing a key upvalue by next; the
-- census put it on every OS's boot path at probability ~1 and measured 18 and
-- 20 of 20 rotated layouts visiting the wrong key multiset -- one of them the
-- RIGHT COUNT, having dropped three components and repeated three
-- (os-shape-census.md:37, :80).  componentProxy.__pairs (site 11), live
-- because we build LUA52COMPAT, walks the proxy and then its fields with a
-- phase flag between them; worse: most layouts both lose keys and repeat
-- them, the flag flipping wherever the first walk happens to end (:38, :82).
--
-- THE FIX, at both sites: take the keys NOW, at list()/pairs() time, into an
-- array, in a loop that finishes before the function returns and so can
-- never be inside a save; then walk that array by an integer upvalue.  An
-- integer into an array means the same thing in every layout -- keys[i+1] is
-- the right next key however the nodes are ordered -- which is why the design
-- doc calls this (the sorted() shape) the one shape the replay scan does NOT
-- need to see, and why the diagnostic planned for OS-authored wrappers must
-- not flag it: its criterion is a closure whose body reaches next on its own
-- loop state, and a snapshot walker's body reaches no such thing.
--
-- WHY NOT "return next, list, nil".  That is tests/forin.lua's oclist_fixed
-- and it is exact, 20 pads of 20 -- and it is not this API.  Callers index
-- the result (component.list("filesystem")[addr], OpenOS
-- lib/filesystem.lua:206) and call it once for the first pair
-- (component.list("eeprom")(): this kernel's own boot, OpenOS
-- boot/04_component.lua:51), and a raw triple does neither.  So the table
-- stays the very table spcall returned, with the same metatable shape; order
-- was never promised and remains hash order, now as of the snapshot.  For
-- __pairs the triple would also drop the whole second phase, the fields.
-- After this change the kernel calls next nowhere, and the patcher asserts
-- that, the same way it asserts the surviving debug.sethook count.

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

-- The ORIGINAL size, captured before any substitution runs. The success line
-- used to report #src at the END, which by then is the PATCHED source -- so it
-- printed 47162 -> 47607 for a 46483-byte input and read as though the kernel
-- had grown by 445 bytes when it had grown by 1124.
local srcbytes = #src

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

-- 4. _ENV, per chunk.  This is the load every sandboxed chunk goes through.
-- rawget/rawset rather than plain indexing: the env tables OpenOS builds carry
-- an __index to _G and an __newindex that writes through, so a plain read would
-- find _G's _ENV (site 5) and conclude the key was already set, and a plain
-- write would go somewhere else entirely.  The type guard keeps a non-table env
-- reaching load() as the same error it would raise on stock OC, rather than a
-- new one from us.
src = replace_once(src, "per-chunk _ENV",
[==[    return load(ld, source, mode, env or sandbox)
]==],
[==[    env = env or sandbox
    if type(env) == "table" and rawget(env, "_ENV") == nil then
      rawset(env, "_ENV", env)
    end
    return load(ld, source, mode, env)
]==])

-- 5. _ENV, the base case, for chunks the kernel loads directly without going
-- through sandbox.load above -- the BIOS being the one that matters.
src = replace_once(src, "sandbox _ENV base case",
[==[sandbox._G = sandbox
]==],
[==[sandbox._G = sandbox
sandbox._ENV = sandbox
]==])

-- 6. wrapUserdataInto joins the forward declarations, so it is an open upvalue
-- of the kernel chunk frame exactly like wrapSingleUserdata -- and under
-- shell-fill every thread slot is written before any recipe runs.
src = replace_once(src, "wrapUserdataInto declaration",
[==[local wrapUserdata, wrapSingleUserdata, unwrapUserdata, wrappedUserdataMeta
]==],
[==[local wrapUserdata, wrapSingleUserdata, unwrapUserdata, wrappedUserdataMeta, wrapUserdataInto
]==])

-- 7. The registry recipe fills the shell it is handed.
src = replace_once(src, "registry recipe",
[==[    return function()
      -- When using special persistence we have to manually reassign the
      -- metatable of the persisted value.
      return setmetatable({}, wrappedUserdataMeta)
    end
]==],
[==[    return function(self)
      -- SHELL-FILL: the serializer hands us our own final table. Give it its
      -- metatable in place; each proxy's fill repopulates the contents.
      setmetatable(self, wrappedUserdataMeta)
    end
]==])

-- 8. The proxy recipe fills the shell it is handed.
src = replace_once(src, "proxy recipe",
[==[    return function()
      return wrapSingleUserdata(userdata.load(className, nbt))
    end
]==],
[==[    return function(proxy)
      wrapUserdataInto(proxy, userdata.load(className, nbt))
    end
]==])

-- 9. The helper, immediately before wrapUserdata.
src = replace_once(src, "wrapUserdataInto helper",
[==[
function wrapUserdata(values)
]==],
[==[
-- SHELL-FILL: fill an EXISTING table as a userdata proxy (docs/shell-fill.md).
-- Fields first, metatable last: userdataWrapper.__newindex routes writes to
-- udinvoke.  No reuse scan: persist-time dedup already collapsed every
-- reference to one record, and a restored Value is a fresh Java object.
function wrapUserdataInto(proxy, data)
  proxy.type = "userdata"
  local methods = spcall(userdata.methods, data)
  for method in pairs(methods) do
    proxy[method] = setmetatable({name=method, proxy=proxy}, userdataCallback)
  end
  wrappedUserdata[proxy] = data
  return setmetatable(proxy, userdataWrapper)
end

function wrapUserdata(values)
]==])

-- 10. component.list: the keys are taken into an array before the function
-- returns; __call walks the array by an integer.  The comment inside is the
-- one a reader of the shipped kernel sees, so it carries the why on its own.
-- The value is still read from the table at call time, as OC's was, so a
-- value overwritten mid-walk is seen and a key cleared mid-walk is skipped --
-- the one mutation Lua permits during a next traversal keeps its meaning.
src = replace_once(src, "component.list snapshot walk",
[==[  list = function(filter, exact)
    checkArg(1, filter, "string", "nil")
    local list = spcall(component.list, filter, not not exact)
    local key = nil
    return setmetatable(list, {__call=function()
      key = next(list, key)
      if key then
        return key, list[key]
      end
    end})
  end,
]==],
[==[  list = function(filter, exact)
    checkArg(1, filter, "string", "nil")
    local list = spcall(component.list, filter, not not exact)
    -- OC-LuaJIT: SNAPSHOT WALK (THE FOURTH CHANGE in patch-machine-lua.lua).
    -- OC's __call kept its position as a KEY upvalue and advanced it with the
    -- real next.  Persisted mid-walk and restored, that key is looked up in
    -- the rebuilt table's hash layout, which is a different one, and the walk
    -- goes on from wherever the key now sits: wrong keys, nothing raised
    -- (os-shape-census.md #1: 18 and 20 of 20 rotated layouts wrong, one of
    -- them the right COUNT with three dropped and three repeated).  Here the
    -- position is an integer into an array of the keys taken now, in a loop
    -- that finishes before this function returns and so can never be inside
    -- a save; keys[i + 1] is the right next key in every layout.  Returning
    -- the raw triple instead would break both indexing the result and the
    -- component.list("eeprom")() idiom, so the table stays the one spcall
    -- returned, with the same metatable shape and the same hash order.
    local keys, i = {}, 0
    for k in pairs(list) do
      keys[#keys + 1] = k
    end
    return setmetatable(list, {__call=function()
      while true do
        i = i + 1
        local key = keys[i]
        if key == nil then
          i = 0 -- exhausted: the following call starts over, as OC's did
          return
        end
        local value = list[key]
        if value ~= nil then -- a key cleared mid-walk is skipped, as next skips it
          return key, value
        end
      end
    end})
  end,
]==])

-- 11. componentProxy.__pairs: both phases are taken into ONE array of
-- {key, value} before the metamethod returns, and the closure walks it by an
-- integer.  The snapshot loops go through the raw next triple, not pairs --
-- pairs(self) would call this very metamethod -- and they are the sound
-- shape: synchronous, finished before anything can yield.
src = replace_once(src, "componentProxy.__pairs snapshot walk",
[==[  __pairs = function(self)
    local keyProxy, keyField, value
    return function()
      if not keyField then
        repeat
          keyProxy, value = next(self, keyProxy)
        until not keyProxy or keyProxy ~= "fields"
      end
      if not keyProxy then
        keyField, value = next(self.fields, keyField)
      end
      return keyProxy or keyField, value
    end
  end
]==],
[==[  __pairs = function(self)
    -- OC-LuaJIT: SNAPSHOT WALK (THE FOURTH CHANGE in patch-machine-lua.lua).
    -- OC's walker advanced two key upvalues with the real next, one per
    -- phase -- the proxy's own keys minus "fields", then the names in fields
    -- -- with a phase flag between them.  Persisted mid-walk and restored,
    -- each key is looked up in a rebuilt hash layout and the flag flips
    -- wherever the first walk now happens to end: most rotated layouts both
    -- lose keys and repeat them (os-shape-census.md #3).  Here both phases
    -- are taken now into one array of {key, value}, in loops that finish
    -- before pairs() returns and so can never be inside a save, and the
    -- closure walks it by an integer, which means the same thing in every
    -- layout.  The loops use the raw next triple, not pairs: pairs(self)
    -- would call this metamethod.  "return next, self, nil" would be exact
    -- too, and would drop the whole second phase.
    local entries, i = {}, 0
    for k, v in next, self do
      if k ~= "fields" then
        entries[#entries + 1] = {k, v}
      end
    end
    for k, v in next, self.fields do
      entries[#entries + 1] = {k, v}
    end
    return function()
      i = i + 1
      local entry = entries[i]
      if entry then
        return entry[1], entry[2]
      end
      i = 0 -- exhausted: the following call starts over, as OC's did
    end
  end
]==])

-- What must remain: exactly the three debug.sethook calls we leave alone
-- (two in calcHookInterval, one in checkDeadline).  Anything else means OC
-- grew a fourth arm site this patch does not know about.
local remaining = count(src, "debug.sethook(")
assert(remaining == 3,
  ("patch-machine-lua: %d debug.sethook( calls remain after patching, expected 3"):format(remaining))

-- And no call to next at all.  OC's kernel called it exactly three times, all
-- inside the two blocks sites 10-11 replace (the synchronous snapshot loops
-- name it as a for-in triple, which is not a call).  A fourth means OC grew
-- an iterator this patch does not know about, and it must be looked at
-- before it ships: a closure over next is the shape that restores wrong.
local nextcalls = count(src, "next(")
assert(nextcalls == 0,
  ("patch-machine-lua: %d next( calls remain after patching, expected 0"):format(nextcalls))

local banner = [==[-- =====================================================================
-- OC-LuaJIT KERNEL VARIANT -- generated by native/kernel/patch-machine-lua.lua
-- from OpenComputers' machine.lua.  Do not edit; edit the patcher.
-- Eleven sites changed: the standing deadline hook is replaced by the native's
-- asynchronous watchdog (4), the name _ENV is bound per chunk, which LuaJIT
-- does not do (2), the two __persist recipes fill the shell the serializer
-- hands them instead of returning a fresh table (3), and component.list and
-- componentProxy.__pairs walk a snapshot of their keys by an integer instead
-- of wrapping next in a closure, which restores wrong (2).  Everything else
-- is OpenComputers' own kernel.
-- =====================================================================
]==]

local out = banner .. src
if crlf then out = out:gsub(LF, CR .. LF) end
local g = assert(io.open(outpath, "wb"))
g:write(out)
g:close()
io.write(("patch-machine-lua: ok  %d -> %d bytes, 11 sites, %d debug.sethook left, %d next( left, %s endings"):format(
  srcbytes, #out, remaining, nextcalls, crlf and "CRLF" or "LF") .. LF)
