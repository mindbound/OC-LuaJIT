-- strpack.lua — string.pack, string.packsize and string.unpack as eris sees
-- them.  Our LuaJIT's string library carries the three (Lua 5.3.6's,
-- native/luajit/oclj_strpack.c, registered in lib_string.c), so they are
-- three more C functions within reach of _G: permanents, which a blob holds
-- by NAME.  This file checks that the three are C functions, that the _G walk
-- offers exactly one name for each, and that a consumer-shaped coroutine
-- holding them as upvalues survives a persist and restore mid-loop and comes
-- back holding this state's own functions.  With any one of the three left
-- out of perms that name everything else, the same coroutine is refused: each
-- is reached, and eris cannot write it by value.
-- The cross-build half (a blob that crossed the change) is the fingerprint's
-- word, token "pack1": tests/fingerprint.lua.
-- Run via the test harness: serializer/erislj_test[.exe] tests/strpack.lua

local pass, fail = 0, 0
local function ok(cond, name, detail)
  if cond then pass = pass + 1 else
    fail = fail + 1
    io.write("  FAIL: ", name, detail and ("  -- " .. tostring(detail)) or "", "\n")
  end
end

-- The perms walk PersistenceAPI does over _G (two levels, sorted by name, the
-- first name wins), as tests/m3.lua builds it.  cand is every (value, name)
-- the walk offers before the first name wins: uperms keeps one name per value
-- by construction, so only cand can show a second name.
local function build_perms()
  local perms, uperms, cand = {}, {}, {}
  local function offer(v, name) cand[#cand + 1] = { v, name } end
  offer(_G, "_G")
  for k, v in pairs(_G) do
    local t = type(v)
    if t == "function" or t == "table" then
      offer(v, "_G." .. tostring(k))
      if t == "table" and v ~= _G then
        for k2, v2 in pairs(v) do
          local t2 = type(v2)
          if t2 == "function" or t2 == "table" then
            offer(v2, "_G." .. tostring(k) .. "." .. tostring(k2))
          end
        end
      end
    end
  end
  table.sort(cand, function(a, b) return a[2] < b[2] end)
  for _, e in ipairs(cand) do
    if perms[e[1]] == nil then perms[e[1]] = e[2]; uperms[e[2]] = e[1] end
  end
  return perms, uperms, cand
end

print("-- the string library carries the three as C functions, and the walk names each once")
local P, U, S = string.pack, string.unpack, string.packsize
ok(type(P) == "function" and type(U) == "function" and type(S) == "function",
   "string.pack, string.unpack and string.packsize are functions",
   type(P) .. "/" .. type(U) .. "/" .. type(S))
if type(P) ~= "function" or type(U) ~= "function" or type(S) ~= "function" then
  print()
  print(string.format("STRPACK RESULT: %d passed, %d FAILED (nothing else to test)", pass, fail))
  return fail
end
do
  local wP, wU, wS = debug.getinfo(P, "S").what, debug.getinfo(U, "S").what, debug.getinfo(S, "S").what
  ok(wP == "C" and wU == "C" and wS == "C",
     "they are C functions (debug.getinfo(f, 'S').what == 'C')",
     tostring(wP) .. "/" .. tostring(wU) .. "/" .. tostring(wS))
end
local perms, uperms, cand = build_perms()
ok(perms[P] == "_G.string.pack" and perms[U] == "_G.string.unpack" and perms[S] == "_G.string.packsize",
   "the perms walk names them _G.string.pack/unpack/packsize",
   tostring(perms[P]) .. " " .. tostring(perms[U]) .. " " .. tostring(perms[S]))
do
  local n, names = 0, {}
  for _, e in ipairs(cand) do
    if e[1] == P or e[1] == U or e[1] == S then n = n + 1; names[#names + 1] = e[2] end
  end
  ok(n == 3, "no alias: each of the three has exactly one name", n .. ": " .. table.concat(names, " "))
end

print("-- a coroutine holding them as upvalues, frozen mid-loop, resumes after a restore")
-- Plan9k-shaped work: pack a record, unpack it, accumulate; yield between the
-- pack and the unpack, so the frozen frame holds a packed string too.
local function maker(pack, unpack, packsize)
  return function(n)
    local acc, sz = 0, packsize("<i4 I2 d")
    for i = 1, n do
      local rec = pack("<i4 I2 d s1", -i, i * 3, i / 4, ("x"):rep(i % 5))
      coroutine.yield(i)
      local a, b, c, s, nx = unpack("<i4 I2 d s1", rec)
      acc = acc + a + b + c + #s + nx + sz
    end
    return acc
  end
end
local function run_plain(n)
  local co = coroutine.create(maker(P, U, S))
  local okr, v = coroutine.resume(co, n)
  while okr and coroutine.status(co) == "suspended" do okr, v = coroutine.resume(co) end
  return okr and v or ("ERR " .. tostring(v))
end
local want = run_plain(7)
local co = coroutine.create(maker(P, U, S))
local okr, at = coroutine.resume(co, 7)
okr, at = coroutine.resume(co)
okr, at = coroutine.resume(co)              -- now frozen at i = 3, between pack and unpack
ok(okr and at == 3, "the coroutine is suspended mid-loop", tostring(okr) .. " " .. tostring(at))
local okp, blob = pcall(eris.persist, perms, co)
ok(okp and type(blob) == "string", "a suspended coroutine holding the three persists", okp and #blob or blob)
-- The same coroutine with perms that name everything but one of the three,
-- for each of the three.  Everything else it reaches (its closure's
-- environment _G, coroutine.yield in its frame) stays named, and with the
-- full perms it persisted just above, so a refusal here is that one function,
-- which eris cannot write by value: a C function.  ({} as the perms would be
-- refused for any suspended coroutine, pack or no pack.)
do
  local refused, got = 0, {}
  for _, f in ipairs({ P, U, S }) do
    local p2 = {}
    for k, v in pairs(perms) do p2[k] = v end
    p2[f] = nil
    local okb, bare = pcall(eris.persist, p2, co)
    if not okb and tostring(bare):find("cannot persist a C function by value", 1, true) ~= nil then
      refused = refused + 1
    end
    got[#got + 1] = okb and "persisted" or tostring(bare)
  end
  ok(okp and refused == 3,
     "with perms naming all but one of the three, the same coroutine is refused, for each (C functions)",
     (okp and "" or "the full perms did not persist, so nothing is isolated; ") .. table.concat(got, " | "))
end
if okp then
  local oku, co2 = pcall(eris.unpersist, uperms, blob)
  ok(oku and type(co2) == "thread" and coroutine.status(co2) == "suspended",
     "it restores as a suspended thread", oku and coroutine.status(co2) or co2)
  if oku and type(co2) == "thread" then
    -- the restored closure's upvalues are this state's own functions: find
    -- the frame of the Lua function maker returned and read its upvalues
    local same = 0
    for lv = 0, 3 do
      local f = debug.getinfo(co2, lv, "f")
      if f and f.func and debug.getinfo(f.func, "S").what == "Lua" then
        local here = 0
        for i = 1, 8 do
          local name, v = debug.getupvalue(f.func, i)
          if name == nil then break end
          if v == P or v == U or v == S then here = here + 1 end
        end
        if here > same then same = here end
      end
    end
    ok(same == 3, "the restored frame's upvalues are this state's string.pack/unpack/packsize", same)
    local r, v = coroutine.resume(co2)
    while r and coroutine.status(co2) == "suspended" do r, v = coroutine.resume(co2) end
    ok(r and v == want, "resumed to the end, it computes what an uninterrupted run computes",
       tostring(v) .. " vs " .. tostring(want))
  end
  -- A build without the three (the uperms lack their names) cannot restore it.
  local u2 = {}
  for k, v in pairs(uperms) do u2[k] = v end
  u2["_G.string.pack"], u2["_G.string.unpack"], u2["_G.string.packsize"] = nil, nil, nil
  local okx, ex = pcall(eris.unpersist, u2, blob)
  ok(not okx and tostring(ex):find("unknown permanent", 1, true) ~= nil,
     "restored where the names are unknown, it is refused (\"unknown permanent\")", ex)
end

print()
if fail == 0 then
  print(string.format("STRPACK RESULT: ALL %d TESTS PASS", pass))
else
  print(string.format("STRPACK RESULT: %d passed, %d FAILED", pass, fail))
end
return fail
