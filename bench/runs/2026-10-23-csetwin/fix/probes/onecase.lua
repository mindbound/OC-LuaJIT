-- onecase.lua <t_csefwd.lua path> <case name> -- the fixer's probe: run one
-- case of t_csefwd's list (loaded as loadfile(...)("cases"), which runs
-- nothing) three times, as t_csefwd runs it, printing each completed
-- trace's number and its parent (jit.attach "start"/"stop").  Forward-order
-- cases only (t_csefwd holds no other).  Value-level; no backslash here.
local path, name = ...
local M = assert(loadfile(path))("cases")
local C
for _, c in ipairs(M.CASES) do if c.name == name then C = c end end
assert(C, "no case " .. tostring(name))
local f = assert(load(C.src, "=case-" .. C.name))
local started = {}
if jit and jit.attach then
  jit.attach(function(what, tr, func, pc, otr, oex)
    if what == "start" then started[tr] = otr and (otr .. "/" .. tostring(oex)) or "root"
    elseif what == "stop" and func == f then print("stop " .. tr .. " parent " .. tostring(started[tr]))
    elseif what == "abort" and func == f then print("abort " .. tostring(tr) .. " " .. tostring(otr) .. " " .. tostring(oex)) end
  end, "trace")
end
local unpack = unpack or table.unpack
for call = 1, 3 do
  local O, BO = {}, {}
  for k = 1, C.n do O[k] = 0; BO[k] = 0 end
  local n = f(O, BO, C.S, unpack(C.args or {}))
  local bad = 0
  for k = 1, n do if O[k] ~= C.ref(k) then bad = bad + 1 end end
  print("call " .. call .. " n=" .. n .. " bad=" .. bad)
end
