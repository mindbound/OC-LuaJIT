-- Does a drop that lands MID incremental cycle (proxies already marked =
-- floating garbage) shift the userdata's finalization one cycle later than
-- a witness built at the drop?  reg-alive (A) vs reg-dead (B) witnesses.
local fin = 0
local function mkudata()
  local u = newproxy(true)
  getmetatable(u).__gc = function() fin = fin + 1 end
  return u
end
local regA, witA, witB
local function mkwitness()
  regA = setmetatable({}, {__mode = "k"})
  witA = setmetatable({}, {__mode = "v"})
  local v = {} regA[{}] = v witA[1] = v
  local reg = setmetatable({}, {__mode = "k"})   -- dies when we return
  witB = setmetatable({}, {__mode = "v"})
  local v2 = {} reg[{}] = v2 witB[1] = v2
end
local function st(w) return w[1] ~= nil and "present" or "cleared" end
local ballast = {}
for i = 1, 30000 do ballast[i] = {i} end
local found = {}
for k = 0, 400 do
  fin = 0
  local wrapped = setmetatable({}, {__mode = "k"})
  local held = {}
  for i = 1, 16 do local p = {type = "userdata"} wrapped[p] = mkudata() held[i] = p end
  collectgarbage("collect")
  collectgarbage("collect")
  local done = false
  for s = 1, k do if collectgarbage("step", 0) then done = true break end end
  if not done then
    held = nil
    mkwitness()
    local n = 0
    repeat n = n + 1 until collectgarbage("step", 0) or n > 100000
    local r0 = string.format("inc-end: fin=%d A=%s B=%s", fin, st(witA), st(witB))
    collectgarbage("collect")
    local r1 = string.format("full1: fin=%d A=%s B=%s", fin, st(witA), st(witB))
    collectgarbage("collect")
    local r2 = string.format("full2: fin=%d A=%s B=%s", fin, st(witA), st(witB))
    local key = r0 .. " | " .. r1 .. " | " .. r2
    if not found[key] then found[key] = k print("k=" .. k .. "  " .. key) end
  end
  wrapped = nil
end
