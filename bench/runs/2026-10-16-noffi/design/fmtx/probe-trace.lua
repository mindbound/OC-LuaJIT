-- probe-trace.lua: for each loop shape, what the trace compiler does with it.
-- Every shape is its own load()ed chunk (its own prototype, kept alive), run
-- hot, with jit.attach watching "trace" events.  Verdicts:
--   LOOP     a root trace started in the shape and closed as a loop, and no
--            trace in the shape stitched or aborted
--   STITCH   some trace in the shape ended with linktype "stitch"
--   ABORT    some trace in the shape aborted (reason printed)
--   NONE     no trace started (the instrument is broken: N is too small)
-- Usage: luajit probe-trace.lua   (LUA_PATH must reach this build's jit/*.lua)
local jutil = require("jit.util")
local vmdef = require("jit.vmdef")
local format = string.format

local function fmtfunc(func, pc)
  local fi = jutil.funcinfo(func, pc)
  if fi.loc then return fi.loc
  elseif fi.ffid then return vmdef.ffnames[fi.ffid]
  else return "(?)" end
end
local function fmterr(err, info)
  if type(err) == "number" then
    if type(info) == "function" then info = fmtfunc(info) end
    local f = vmdef.traceerr[err]
    if f == "NYI: bytecode %s" then
      local oidx = 6 * info
      info = vmdef.bcnames:sub(oidx + 1, oidx + 6)
    end
    err = format(f, info)
  end
  return err
end

local EV
local function onTrace(what, tr, func, pc, otr, oex)
  if not EV then return end
  local e = { what = what, tr = tr, loc = fmtfunc(func, pc) }
  if what == "start" then
    e.parent = otr; e.exit = oex
  elseif what == "abort" then
    e.err = fmterr(otr, oex)
  elseif what == "stop" then
    local info = jutil.traceinfo(tr)
    e.link = info.link; e.linktype = info.linktype
  end
  EV[#EV + 1] = e
end
jit.attach(onTrace, "trace")

local N = 20000
local SHAPES = {
  { "int-for %02x",        [[local n = 0 for i = 1, N do n = n + #string.format("%02x", i) end return n]] },
  { "int-for %5d",         [[local n = 0 for i = 1, N do n = n + #string.format("%5d", i) end return n]] },
  { "int-for %X",          [[local n = 0 for i = 1, N do n = n + #string.format("%X", i) end return n]] },
  { "int-for %u",          [[local n = 0 for i = 1, N do n = n + #string.format("%u", i) end return n]] },
  { "int-for %o",          [[local n = 0 for i = 1, N do n = n + #string.format("%o", i) end return n]] },
  { "int-for %+.3i",       [[local n = 0 for i = 1, N do n = n + #string.format("%+.3i", i) end return n]] },
  { "bit.band %04x",       [[local n = 0 for i = 1, N do n = n + #string.format("%04x", bit.band(i, 0xfff)) end return n]] },
  { "byte hexdump %02x",   [[local s = string.rep("OC-LuaJIT", 8) local n = 0
                               for i = 1, N do n = n + #string.format("%02x", s:byte(i % #s + 1)) end return n]] },
  { "helper return %02x",  [[local function hex(b) return string.format("%02x", b) end
                               local n = 0 for i = 1, N do n = n + #hex(i) end return n]] },
  { "uuid-ish multi",      [[local n = 0 for i = 1, N do
                               n = n + #string.format("%08x-%04x-%04x", i, bit.band(i, 0xffff), bit.rshift(i, 4)) end return n]] },
  { "buffer putf %02x",    [[local buf = require("string.buffer").new() local n = 0
                               for i = 1, N do buf:reset() buf:putf("%02x", i) n = n + #buf end return n]] },
  -- controls: compiled in every build, before and after
  { "CTRL int-for %d",     [[local n = 0 for i = 1, N do n = n + #string.format("%d", i) end return n]] },
  { "CTRL num %02x",       [[local t = {} for j = 1, 64 do t[j] = j * 3 end local n = 0
                               for i = 1, N do n = n + #string.format("%02x", t[i % 64 + 1]) end return n]] },
  { "CTRL int-for %c",     [[local n = 0 for i = 1, N do n = n + #string.format("%c", 65 + i % 26) end return n]] },
}

local keep = {}
io.write(format("%s  %s\n", jit.version, table.concat({ jit.status() }, " ", 2)))
for _, sh in ipairs(SHAPES) do
  local name, src = sh[1], sh[2]
  local fn = assert(load("local N = ... " .. src, "=" .. name))
  keep[#keep + 1] = fn
  EV = {}
  local r = fn(N)
  local ev = EV
  EV = nil
  local started, loop, stitch, abort, notes = 0, false, false, false, {}
  for _, e in ipairs(ev) do
    if e.what == "start" then
      started = started + 1
    elseif e.what == "stop" then
      if e.linktype == "stitch" then stitch = true end
      if e.linktype == "loop" then loop = true end
      notes[#notes + 1] = format("T%d:%s", e.tr, e.linktype)
    elseif e.what == "abort" then
      abort = true
      notes[#notes + 1] = format("abort(%s)", e.err)
    end
  end
  local verdict = started == 0 and "NONE" or stitch and "STITCH" or abort and "ABORT" or loop and "LOOP" or "OTHER"
  io.write(format("%-7s %-22s result=%-7s %s\n", verdict, name, tostring(r), table.concat(notes, " ")))
end
jit.attach(onTrace)
