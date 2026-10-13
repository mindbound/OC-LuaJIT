-- Kernel shape: wrapped = weak-key {proxy -> raw udata}; raw udata has __gc.
-- Witness A (harness.md): reg kept alive, reg[{}]=v, wit[1]=v (weak value).
-- Witness B (reg NOT kept alive): only wit2 holds v2 weakly, reg2 is a dead local.
local fin = 0
local wrapped = setmetatable({}, {__mode = "k"})
local held = {}
for i = 1, 16 do
  local u = newproxy(true)
  getmetatable(u).__gc = function() fin = fin + 1 end
  local proxy = {type = "userdata"}
  wrapped[proxy] = u
  held[i] = proxy
end
held = nil
local reg = setmetatable({}, {__mode = "k"})
local wit = setmetatable({}, {__mode = "v"})
do local v = {} reg[{}] = v wit[1] = v end
local wit2 = setmetatable({}, {__mode = "v"})
do
  local reg2 = setmetatable({}, {__mode = "k"})
  local v2 = {} reg2[{}] = v2 wit2[1] = v2
end
local function n(t) local c = 0 for _ in pairs(t) do c = c + 1 end return c end
for c = 1, 4 do
  collectgarbage("collect")
  print(string.format("collect %d: finalized=%d wrapped=%d witA=%s witB(reg dead)=%s",
    c, fin, n(wrapped), tostring(wit[1] ~= nil and "present" or "cleared"),
    tostring(wit2[1] ~= nil and "present" or "cleared")))
end
