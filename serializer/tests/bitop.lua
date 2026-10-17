-- bitop.lua — the 64-bit bitwise operators as eris sees them.  Our LuaJIT
-- computes & | ~ << >> ~>> and unary ~ as Lua 5.3.6 does on int64
-- (native/luajit/oclj_bitop.h), returns the double that equals the result,
-- and raises "result of '<op>' has more than 53 significant bits (mask each
-- operand to 32 bits first)" when there is none.  Nothing new reaches _G, so
-- nothing new is a permanent; what a blob carries is BYTECODE whose meaning
-- changed: the parser folds constant operands into the dumped prototype's
-- constants (1 << 62 is 2^62 there, not upstream's 1 << 30), and a restored
-- thread runs the same operators again.  This file freezes a coroutine
-- mid-loop inside a compiled bit-operator trace, persists and restores it,
-- and checks that it resumes to the uninterrupted result, that its folded
-- constants came back as 64-bit results, and that an inexact result still
-- raises, with that whole message, after the restore.  The expected values
-- are PUC Lua 5.3.6's (Windows and Linux agree), never this build's own.
-- The cross-build half (a blob that crossed the change) is the fingerprint's
-- word, token "bit64", and BCDUMP_VERSION 0x80: tests/fingerprint.lua.
-- Run via the test harness: serializer/erislj_test[.exe] tests/bitop.lua

local pass, fail = 0, 0
local function ok(cond, name, detail)
  if cond then pass = pass + 1 else
    fail = fail + 1
    io.write("  FAIL: ", name, detail and ("  -- " .. tostring(detail)) or "", "\n")
  end
end

-- The perms walk PersistenceAPI does over _G (two levels, sorted by name, the
-- first name wins), as tests/m3.lua and tests/strpack.lua build it.
local function build_perms()
  local perms, uperms, cand = {}, {}, { { _G, "_G" } }
  for k, v in pairs(_G) do
    local t = type(v)
    if t == "function" or t == "table" then
      cand[#cand + 1] = { v, "_G." .. tostring(k) }
      if t == "table" and v ~= _G then
        for k2, v2 in pairs(v) do
          local t2 = type(v2)
          if t2 == "function" or t2 == "table" then
            cand[#cand + 1] = { v2, "_G." .. tostring(k) .. "." .. tostring(k2) }
          end
        end
      end
    end
  end
  table.sort(cand, function(a, b) return a[2] < b[2] end)
  for _, e in ipairs(cand) do
    if perms[e[1]] == nil then perms[e[1]] = e[2]; uperms[e[2]] = e[1] end
  end
  return perms, uperms
end

-- Every operation in the loop has at most 53 significant bits, so none
-- raises: x is masked to 53 bits, and masked to 40 before it is shifted by
-- 13; i << 40 stays below 2^53 for i < 8192.  The loop compiles to one
-- looping trace well before the first yield (luajit -jv on the same loop:
-- "[TRACE 1 ... loop]", no abort).  After it: four constant expressions the
-- parser folds (each exact, and each different under upstream's 32-bit
-- BitOp: 1073741824, 2097151, -1, 0), and two that raise.  1 << 62 | 1 has no
-- double, so the parser folds 1 << 62 alone, leaves the '|' to run time, and
-- the run time raises; v >> 1 is a logical shift, so for v = -5000 it is
-- 2^63 - 2500, 61 significant bits.
local function body(n)
  local x, h = 0x123456789, 0
  for i = 1, n do
    x = (((x & 0xffffffffff) << 13) ~ (x >> 7) ~ i) & 0x1fffffffffffff
    h = h ~ (x >> 21) ~ (i << 40)
    if i % 1000 == 0 then coroutine.yield(i) end
  end
  local okc, ec = pcall(function() return 1 << 62 | 1 end)
  local okv, ev = pcall(function(v) return v >> 1 end, -n)
  return x, h, 1 << 62, ~0 >> 11, ~(2^53 - 1), -2^63 | 0, okc, ec, okv, ev
end
local NRET = 10
local function run(co, ...)
  local r = { coroutine.resume(co, ...) }
  while r[1] and coroutine.status(co) == "suspended" do r = { coroutine.resume(co) } end
  return r
end
local function show(r)
  local s = {}
  for i = 2, NRET + 1 do s[#s + 1] = tostring(r[i]) end
  return table.concat(s, " ")
end

print("-- the uninterrupted run computes Lua 5.3.6's results")
local want = run(coroutine.create(body), 5000)
-- PUC Lua 5.3.6 (bench/vendor/lua-5.3.6, and a Linux build) prints
-- x=8245983005562532 h=5497560713767387 for this loop at n = 5000.
ok(want[1] and want[2] == 8245983005562532 and want[3] == 5497560713767387,
   "x and h equal PUC 5.3.6's (8245983005562532, 5497560713767387)",
   want[1] and string.format("%.17g %.17g", want[2], want[3]) or want[2])

print("-- a coroutine frozen mid-loop resumes after a restore to the same results")
local co = coroutine.create(body)
local okr, at = coroutine.resume(co, 5000)
okr, at = coroutine.resume(co)              -- now frozen at i = 2000, inside the loop
ok(okr and at == 2000, "the coroutine is suspended mid-loop at i = 2000", tostring(okr) .. " " .. tostring(at))
local perms, uperms = build_perms()
local okp, blob = pcall(eris.persist, perms, co)
ok(okp and type(blob) == "string", "the frozen coroutine persists", okp and #blob or blob)
if okp then
  local oku, co2 = pcall(eris.unpersist, uperms, blob)
  ok(oku and type(co2) == "thread" and coroutine.status(co2) == "suspended",
     "it restores as a suspended thread", oku and coroutine.status(co2) or co2)
  if oku and type(co2) == "thread" then
    local got = run(co2)
    local same = got[1] == true and want[1] == true
    for i = 2, NRET + 1 do same = same and got[i] == want[i] end
    ok(same, "resumed to the end, it returns what the uninterrupted run returns",
       show(got) .. " / want " .. show(want))
    ok(got[1] and got[4] == 2^62 and got[5] == 2^53 - 1 and got[6] == -2^53 and got[7] == -2^63,
       "its folded constants are 64-bit results: 1 << 62, ~0 >> 11, ~(2^53 - 1), -2^63 | 0",
       string.format("%s %s %s %s", tostring(got[4]), tostring(got[5]), tostring(got[6]), tostring(got[7])))
    -- The whole message, hint included, ends the error string: only the
    -- "chunk:line: " prefix may come before it.
    local function inexact(e, op)
      local m = "result of '" .. op .. "' has more than 53 significant bits"
             .. " (mask each operand to 32 bits first)"
      return type(e) == "string" and #e > #m and e:sub(-#m) == m
    end
    ok(got[1] and got[8] == false and inexact(got[9], "|")
         and got[10] == false and inexact(got[11], ">>"),
       "an inexact result still raises, with its hint, unfolded (1 << 62 | 1) and at run time (-n >> 1)",
       string.format("%s %s / %s %s", tostring(got[8]), tostring(got[9]), tostring(got[10]), tostring(got[11])))
  end
end

print()
if fail == 0 then
  print(string.format("BITOP RESULT: ALL %d TESTS PASS", pass))
else
  print(string.format("BITOP RESULT: %d passed, %d FAILED", pass, fail))
end
return fail
