-- fingerprint.lua — a blob whose build fingerprint differs is refused BY THE
-- FINGERPRINT, before a single object is restored.  m1.lua covers the magic,
-- the checksum and the format byte; nothing fed a mismatched fingerprint.
-- Run via the test harness: serializer/erislj_test[.exe] tests/fingerprint.lua

local pass, fail = 0, 0
local function ok(cond, name, detail)
  if cond then pass = pass + 1 else
    fail = fail + 1
    io.write("  FAIL: ", name, detail and ("  -- " .. tostring(detail)) or "", "\n")
  end
end

local bit = require("bit")
local CRCT = { 0x00000000,0x1DB71064,0x3B6E20C8,0x26D930AC,0x76DC4190,0x6B6B51F4,
               0x4DB26158,0x5005713C,0xEDB88320,0xF00F9344,0xD6D6A3E8,0xCB61B38C,
               0x9B64C2B0,0x86D3D2D4,0xA00AE278,0xBDBDF21C }
local function crc32(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do
    c = bit.bxor(c, s:byte(i))
    c = bit.bxor(bit.rshift(c, 4), CRCT[bit.band(c, 0xf) + 1])
    c = bit.bxor(bit.rshift(c, 4), CRCT[bit.band(c, 0xf) + 1])
  end
  return bit.bnot(c)
end
local function seal(b)
  local c = crc32(b)
  return b .. string.char(bit.band(c, 0xff), bit.band(bit.rshift(c, 8), 0xff),
                          bit.band(bit.rshift(c, 16), 0xff),
                          bit.band(bit.rshift(c, 24), 0xff))
end

print("-- the VM-features word")
local _, fp, _, feat = eris.version()
ok(type(feat) == "string" and #feat > 0, "eris.version() returns the VM-features word", feat)
feat = type(feat) == "string" and feat or ""
ok(#feat > 0 and fp:sub(-#feat - 1) == "|" .. feat, "the word is the fingerprint's last field", fp)
ok(feat:match("^ffi[01]%.lua5[12]%.gc[36][24]%.fr[12]%.dn[01]%.[lb]e%.p[36][24]%.pack[01]$") ~= nil,
   "the word has the documented shape", feat)
ok(#fp <= 255, "the fingerprint fits the header's u8 length", #fp)
-- The pack token is read from oclj_features.h; string.pack comes from the
-- archive's lib_string.c.  This host opens the archive's own string library
-- (luaL_openlibs), so the two must agree here as they must in the DLL.
local packtok = feat:match("%.(pack[01])$")
ok(packtok == (type(string.pack) == "function" and type(string.unpack) == "function"
               and type(string.packsize) == "function" and "pack1" or "pack0"),
   "the pack token agrees with this archive's string library",
   tostring(packtok) .. " vs string.pack " .. type(string.pack))

-- A blob whose restore would CHANGE state: a __persist recipe bumps a
-- permanent sentinel when it runs, and recipes run only after the whole body
-- has parsed.  A refused blob must leave the sentinel nil.
local sentinel = {}
local perms = { [sentinel] = "sentinel", [_G] = "G" }
local uperms = { sentinel = sentinel, G = _G }
local mt = { __persist = function()
  return function(o)
    sentinel.hit = (sentinel.hit or 0) + 1
    setmetatable(o, { restored = true })
    return o
  end
end }
local blob = eris.persist(perms, { setmetatable({}, mt), keep = "x" })
local fplen = blob:byte(5)
ok(blob:sub(6, 5 + fplen) == fp, "the blob carries this build's fingerprint")
local body = blob:sub(6 + fplen, -5)   -- the value record alone; CRC dropped

-- Same body under another fingerprint, CRC re-sealed: the fingerprint is the
-- ONLY thing wrong with it.
local function reheader(newfp)
  return seal(blob:sub(1, 4) .. string.char(#newfp) .. newfp .. body)
end
local base = fp:sub(1, #fp - #feat)    -- everything up to and including the last '|'

print("-- control: the surgery itself is sound")
do
  sentinel.hit = nil
  local okc, r = pcall(eris.unpersist, uperms, reheader(fp))
  ok(okc and type(r) == "table" and r.keep == "x" and sentinel.hit == 1,
     "re-sealed under this build's own fingerprint, the blob restores and its recipe runs",
     okc and sentinel.hit or r)
end

print("-- every token flipped is refused by the fingerprint, nothing restored")
local FLIP = { ffi0 = "ffi1", ffi1 = "ffi0", lua52 = "lua51", lua51 = "lua52",
               gc64 = "gc32", gc32 = "gc64", fr2 = "fr1", fr1 = "fr2",
               dn0 = "dn1", dn1 = "dn0", le = "be", be = "le", p64 = "p32", p32 = "p64",
               pack1 = "pack0", pack0 = "pack1" }
local toks = {}
for t in feat:gmatch("[^.]+") do toks[#toks + 1] = t end
ok(#toks == 8, "eight tokens", #toks)
for i = 1, #toks do
  local other = {}
  for j = 1, #toks do other[j] = toks[j] end
  other[i] = FLIP[toks[i]] or (toks[i] .. "x")
  local word = table.concat(other, ".")
  sentinel.hit = nil
  local ok_, err = pcall(eris.unpersist, uperms, reheader(base .. word))
  err = tostring(err)
  ok(not ok_ and err:find("build fingerprint mismatch: VM features differs", 1, true)
       and err:find(word, 1, true) and err:find(feat, 1, true) and sentinel.hit == nil,
     "token " .. toks[i] .. " -> " .. other[i] .. " refused by the fingerprint, state unchanged",
     ok_ and ("RESTORED, sentinel.hit=" .. tostring(sentinel.hit)) or err)
end

print("-- a fingerprint WITHOUT the word (the pre-word layout) is refused")
do
  sentinel.hit = nil
  local ok_, err = pcall(eris.unpersist, uperms, reheader(base:sub(1, -2)))
  err = tostring(err)
  ok(not ok_ and err:find("VM features differs (blob ''", 1, true) and sentinel.hit == nil,
     "a three-field fingerprint is refused naming the missing word, state unchanged",
     ok_ and "RESTORED" or err)
end

print("-- the refusal precedes the checksum")
do
  sentinel.hit = nil
  local t1 = toks[1] or ""
  local bad = reheader(base .. (FLIP[t1] or (t1 .. "x")) .. feat:sub(#t1 + 1))
  bad = bad:sub(1, -2) .. string.char((bad:byte(-1) + 1) % 256)   -- and a bad CRC
  local ok_, err = pcall(eris.unpersist, uperms, bad)
  ok(not ok_ and tostring(err):find("fingerprint", 1, true) and sentinel.hit == nil,
     "a mismatched fingerprint is named even when the CRC is also wrong", err)
end

print()
if fail == 0 then
  print(string.format("FINGERPRINT RESULT: ALL %d TESTS PASS", pass))
else
  print(string.format("FINGERPRINT RESULT: %d passed, %d FAILED", pass, fail))
end
return fail
