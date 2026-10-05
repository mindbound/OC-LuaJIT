-- probe.lua -- the capacity probe's shape (OcljSmoke.scala, CapacityAutorunLua),
-- hermetic and deterministic.  Shared by the LuaJIT driver (lj_repro.c) and
-- the PUC 5.2 driver (puc_repro.c).
--
-- Parameters, set as globals by the driver BEFORE the cap:
--   P_SHAPE   record | array | string | closure      (the probe's makers)
--   P_BATCH   objects per step (the probe: 100)
--   P_JUNK    the churn string's length (the probe: 24)
--   P_MAXRES  bound on resumes (a fill that stops only when refused also stops here)
--   P_ARM     1 = each resume under _OCLJ_WATCHDOG.arm, as machine.lua resumes the sandbox
--   P_PAINT   1 = the probe's pcall(paint) after every step
--   P_HB      heartbeat period in resumes (the probe's 0.05 s timer), 0 = none
--   P_CONTROL 1 = the between-batch allocations moved INSIDE the batch's pcall
--
-- __rec(code, count) is the driver's C recorder; it allocates nothing and
-- returns true when the driver wants the live set measured at this event.
--   1 inside   the batch's pcall caught a refusal (the probe's normal end)
--   2 outside  a refusal escaped step() and was caught by the dispatcher's pcall:
--              the probe's STALL (timer chain broken, machine up)
--   3 paint    pcall(paint) swallowed a refusal (harmless; the run goes on)
--   4 down     the sandbox coroutine died: a refusal in the dispatcher's own code
--   6 done     the probe wrote its result (stage = "done/...")
--   7 hb       the heartbeat handler raised
--   0 bound    P_MAXRES resumes without an end
--  20 measure  after two full collections: the live set
local rec = __rec
local pack = table.pack
local SHAPE, BATCH, JUNK = P_SHAPE, P_BATCH, P_JUNK
local MAXRES, ARM, PAINT, HB, CONTROL = P_MAXRES, P_ARM, P_PAINT, P_HB, P_CONTROL
local MB, MS = P_MEAS_B, P_MEAS_SITE
local MARK, STOPAT, markf = P_MARK, P_STOPAT, __mark
local function mark(c) if MARK == 1 then collectgarbage('collect') markf(c) end end   -- the site pass: measure the live set at site MS after batch MB
local n = 0
local stage = "armed"
local held, count, batches = nil, 0, 0
local tfirst, ring = 0, {0, 0, 0, 0, 0}
local freeAt, totalKB = -1, -1
local nonce = "0.0000-123456"
local screen = {[15] = false, [16] = false, [17] = false, [18] = false}
-- os.clock() made deterministic: its value reaches a string.format, and a
-- run-to-run difference in a formatted string is a difference in interning.
local function clock() return 0 end
local function paint()
  local tlast = ring[1] + ring[2] + ring[3] + ring[4] + ring[5]
  screen[15] = "OCLJNONCE=" .. nonce .. " OCLJCTR=" .. n .. "        "
  screen[16] = "OCLJCAP=" .. stage .. "        "
  screen[17] = "OCLJCAPT=" .. string.format("%.4f/%.4f/%d", tfirst, tlast, batches) .. "        "
  screen[18] = "OCLJCAPF=" .. freeAt .. "/" .. totalKB .. "        "
end
local function uniq(len, i) local s = tostring(i) return string.rep("x", len - #s) .. s end
local makers = {
  record = function(i) return { name = uniq(12, i), size = i, flags = { true, false } } end,
  array = function(i) return { i, i, i, i, i, i, i, i, i, i, i, i, i, i, i, i } end,
  string = function(i) return uniq(32, i) end,
  closure = function(i) local x, y, z = i, i, i return function() return x + y + z end end,
}
local make = makers[SHAPE]
local handlers = {}      -- OpenOS event.lua's handler table: one timer slot, reused
local finished, stopped = false, false
local function measure()
  collectgarbage("collect")
  collectgarbage("collect")
  rec(20, count, batches)
  stopped = true
end
-- THE SITE PASS: two full collections just BEFORE an allocation site, in the
-- run that (in the faithful pass) is refused there: the live set a
-- collection at the refusal would have found, frames included.
--   site 1: the stage string   site 2: event.timer's record   site 3: the dispatcher's pack
local function msite(site)
  if batches == MB and MS == site then
    collectgarbage("collect")
    collectgarbage("collect")
    rec(21, count, batches)
    stopped = true
    return true
  end
  return false
end
-- event.timer(0, cb): a handler record, as OpenOS's event.register makes one
local function timer(cb)
  handlers[1] = { key = false, times = 1, callback = cb, interval = 0, timeout = 0 }
end
local step
step = function()
  mark(2)
  local t0 = clock()
  local ok, err = pcall(function()
    for k = 1, BATCH do
      mark(1)
      local o = make(count + 1)
      held[count + 1] = o
      count = count + 1
      local junk = uniq(JUNK, count) .. "!"
    end
    if CONTROL == 1 then
      stage = "filling/" .. count
      timer(step)
    end
  end)
  mark(2)
  local dt = clock() - t0
  batches = batches + 1
  if batches <= 5 then tfirst = tfirst + dt end
  ring[(batches - 1) % 5 + 1] = dt
  if ok and count < 2000000 then
    if CONTROL ~= 1 then
      if msite(1) then return end
      stage = "filling/" .. count
      if msite(2) then return end
      timer(step)
    end
  else
    if rec(1, count, batches) then measure() return end
    freeAt = 0               -- computer.freeMemory(): a Java call, nothing allocated here
    totalKB = 0
    held = nil
    stage = "done/" .. count .. "/" .. (ok and "cap" or tostring(err):gsub("[ /]", "_"))
    finished = true
    rec(6, count, batches)
  end
  if MARK == 1 and collectgarbage('count') * 1024 > P_STOPAT then finished = true end
  mark(3)
  if PAINT == 1 then
    if not pcall(paint) then if rec(3, count, batches) then measure() end end
  end
  mark(2)
end
local function heartbeat()
  n = n + 1
  if PAINT == 1 then
    if not pcall(paint) then if rec(3, count, batches) then measure() end end
  end
end
local function sandbox()
  local r = 0
  while not finished and not stopped and r < MAXRES do
    r = r + 1
    mark(5)
    local a1 = coroutine.yield()
    mark(4)               -- computer.pullSignal, packed as OpenOS packs it
    if msite(3) then break end
    local sig = pack(a1)
    if HB > 0 and r % HB == 0 then
      if not pcall(heartbeat) then if rec(7, count, batches) then measure() end stopped = true end
    else
      local h = handlers[1]
      if h then
        handlers[1] = nil
        local okc = pcall(h.callback)
        mark(4)
        if not okc then
          if rec(2, count, batches) then measure() end
          stopped = true                       -- the stall: the timer chain is broken
        end
      end
    end
  end
end
-- set up while there is room: the holder, the first timer, the coroutine
held = {}
stage = "filling/0"
timer(step)
local co = coroutine.create(sandbox)
local W = _OCLJ_WATCHDOG
local cb = function() end
function __kernel()
  mark(5)
  for r = 1, MAXRES + 2 do
    local t = (ARM == 1) and W.arm(3600, cb, true) or nil
    local res = pack(coroutine.resume(co, "timer"))
    if t then W.disarm(t) end
    if not res[1] then
      if rec(4, count, batches) then measure() end
      return
    end
    if stopped or finished or coroutine.status(co) == "dead" then return end
  end
  rec(0, count, batches)
end
