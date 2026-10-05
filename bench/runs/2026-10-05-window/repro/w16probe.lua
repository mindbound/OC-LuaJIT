-- w16probe.lua -- the W16 program (w16_chunk.c.txt) in the drivers' probe
-- form, so the same program runs on stock PUC 5.2.4 (puc_repro) and on the
-- shim (lj_repro): __kernel, __rec(code, count, batches); P_CONTROL = 1 moves
-- the stage string and the timer record INSIDE the batch's handler.
local rec, held, count, stage, slot = __rec, {}, 0, 'filling/0', {}
local CONTROL = P_CONTROL
__w16h = held
local function uniq(len, i) local s = tostring(i) return string.rep('x', len - #s) .. s end
local step
step = function()
  local ok = pcall(function()
    for k = 1, 100 do
      count = count + 1 held[count] = uniq(32, count)
      local junk = uniq(24, count) .. '!'
    end
    if CONTROL == 1 then
      stage = 'filling/' .. count
      slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 }
    end
  end)
  if not ok then rec(1, count, 0) return end
  if CONTROL ~= 1 then
    stage = 'filling/' .. count
    slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 }
  end
end
slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 }
local co = coroutine.create(function()
  for r = 1, 400 do
    local sig = table.pack(coroutine.yield())
    local hd = slot[1]
    if not hd then return end
    slot[1] = nil
    if not pcall(hd.callback) then rec(2, count, 0) return end
  end
end)
local cb = function() end
local W = _OCLJ_WATCHDOG
function __kernel()
  for r = 1, 402 do
    local t = W and W.arm(3600, cb, true)
    local res = table.pack(coroutine.resume(co, 'timer'))
    if t then W.disarm(t) end
    if not res[1] then rec(4, count, 0) return end
    if coroutine.status(co) == 'dead' then return end
  end
end
