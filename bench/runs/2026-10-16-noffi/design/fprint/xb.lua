-- xb.lua: cross-build probe. XB_MODE=save writes blobs; XB_MODE=load reads them.
-- Blobs: plain = {1,2,3,"x"}; spk = a table whose spkey closure flips a
-- permanent sentinel on restore; ffi = a closure with a 1LL constant (only
-- when this build lexes 1LL).
local mode = os.getenv("XB_MODE")
local dir = os.getenv("XB_DIR")
local function wr(name, s) local f = assert(io.open(dir .. "/" .. name, "wb")); f:write(s); f:close() end
local function rd(name) local f = io.open(dir .. "/" .. name, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local v, fp, fmt, feat = eris.version()
io.write("version=", tostring(v), " fp=", tostring(fp), " fplen=", #tostring(fp), " fmt=", tostring(fmt), " 4th=", tostring(feat), "\n")

local sentinel = {}
local perms = { [sentinel] = "sentinel", [_G] = "G" }
local uperms = { sentinel = sentinel, G = _G }

if mode == "save" then
  wr("plain.blob", eris.persist({}, { 1, 2, 3, "x" }))
  local mt = { __persist = function(self)
    return function(o)
      local s = sentinel
      s.hit = (s.hit or 0) + 1
      o.restored = true
      setmetatable(o, { tag = 'restored' })
      return o
    end
  end }
  local t = setmetatable({}, mt)
  wr("spk.blob", eris.persist(perms, { t }))
  local f = load("return function(x) return x + 1LL end")
  if f then
    local g = f()
    local ok, b = pcall(eris.persist, perms, g)
    io.write("persist 1LL closure: ok=", tostring(ok), " bytes=", ok and #b or tostring(b), "\n")
    if ok then wr("ffi.blob", b) end
  else
    io.write("this build does not lex 1LL\n")
  end
  io.write("saved\n")
  return 0
end

if mode == "load" then
  local p = rd("plain.blob")
  local ok, r = pcall(eris.unpersist, {}, p)
  io.write("plain: ok=", tostring(ok), " ", ok and ("n=" .. #r .. " r[4]=" .. tostring(r[4])) or tostring(r), "\n")
  local s = rd("spk.blob")
  sentinel.hit = nil
  ok, r = pcall(eris.unpersist, uperms, s)
  io.write("spk: ok=", tostring(ok), " ", ok and ("restored=" .. tostring(r[1] and r[1].restored)) or tostring(r), " sentinel.hit=", tostring(sentinel.hit), "\n")
  local fb = rd("ffi.blob")
  if fb then
    ok, r = pcall(eris.unpersist, uperms, fb)
    io.write("ffi: ok=", tostring(ok), " ", ok and ("g(41)=" .. tostring(r(41))) or tostring(r), "\n")
  end
  return 0
end
error("XB_MODE must be save or load")
