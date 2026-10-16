-- bench.lua: hot-loop cost of string.format integer conversions, one build.
-- Each arm is its own load()ed chunk; arms are run round-robin R times inside
-- the process and the best (minimum) time per arm is printed, plus each arm's
-- ratio to the same-run reference of its group:
--   A   plain "%d" of an int, 256 distinct results: compiles to the same TOSTR
--       in every build; reference for B C D E F K
--   A2  plain "%d" of the loop index, every result a NEW string: reference
--       for B2 (string creation and GC dominate these)
-- The driver interleaves processes of different builds.  Unpinned:
-- indicative, not a pinned figure.
--   luajit bench.lua <scale> <R> [verdict]
local SCALE = tonumber(arg[1]) or 1
local R = tonumber(arg[2]) or 5
local VERDICT = arg[3] == "verdict"
local ARMS = {
  { "A",  10e6, nil, [[for i = 1, N do n = n + #string.format("%d", i % 256) end]] },
  { "B",  10e6, 1,   [[for i = 1, N do n = n + #string.format("%02x", i % 256) end]] },
  { "C",  10e6, 1,   [[for i = 1, N do n = n + #string.format("%5d", i % 256) end]] },
  { "D",  10e6, 1,   [[for i = 1, N do n = n + #string.format("%#o", i % 256) end]] },
  { "E",  10e6, 1,   [[local s = string.rep("OC-LuaJIT", 7) .. "!"
                       for i = 1, N do n = n + #string.format("%02x", s:byte(i % 64 + 1)) end]] },
  { "F",  10e6, 1,   [[for i = 1, N do local b = i % 256
                       n = n + #string.format("%02x%02x-%04X", b, bit.band(b, 15), bit.bxor(b, 0x5a)) end]] },
  { "K",  10e6, 1,   [[local t = {} for j = 1, 256 do t[j] = j - 1 end
                       for i = 1, N do n = n + #string.format("%02x", t[i % 256 + 1]) end]] },
  { "A2",  2e6, nil, [[for i = 1, N do n = n + #string.format("%d", i) end]] },
  { "B2",  2e6, 8,   [[for i = 1, N do n = n + #string.format("%02x", i) end]] },
}
local fns, best, check = {}, {}, {}
for k, a in ipairs(ARMS) do
  fns[k] = assert(load("local N = ... local n = 0 " .. a[4] .. " return n", "=" .. a[1]))
  best[k] = math.huge
end

if VERDICT then
  local jutil = require("jit.util")
  local ev
  jit.attach(function(what, tr) if ev and what == "stop" then ev[#ev + 1] = jutil.traceinfo(tr).linktype end end, "trace")
  local out = {}
  for k, a in ipairs(ARMS) do
    ev = {}
    fns[k](20000)
    out[#out + 1] = a[1] .. ":" .. table.concat(ev, "+")
    ev = nil
  end
  io.write(table.concat(out, " "), "\n")
  return
end

for r = 1, R do
  for k, a in ipairs(ARMS) do
    collectgarbage()
    local t0 = os.clock()
    local n = fns[k](a[2] * SCALE)
    local t = os.clock() - t0
    if t < best[k] then best[k] = t end
    if check[k] and check[k] ~= n then error("arm " .. a[1] .. " result changed") end
    check[k] = n
  end
end
local out = {}
for k, a in ipairs(ARMS) do
  local ref = a[3] and best[a[3]] or best[k]
  out[#out + 1] = string.format("%s=%.4f/%.3f", a[1], best[k], best[k] / ref)
end
io.write(table.concat(out, " "), "\n")
