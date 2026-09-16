-- rig.lua -- kernel-mirror rig for the "registry rebuild" design.
--
-- Mirrors build/native/kernel/machine.lua's chunk-local slot order exactly:
--   :753   local sandbox                         LOW slot (holds every OS object)
--   :1075  local wrapUserdata, wrapSingleUserdata, unwrapUserdata, wrappedUserdataMeta
--   :1091  local wrappedUserdata = setmetatable({}, wrappedUserdataMeta)   SPECIAL
--   :1136  local userdataWrapper                 the proxy metatable
--   :1174  local userdataCallback
--   :1189  function wrapSingleUserdata
--   :1571  return pcallTimeoutCheck(pcall(main)) -- chunk frame stays live
--
-- RIG_MODE=orig  : OC's shipped recipes (per-proxy __persist closure calling
--                  wrapSingleUserdata, registry recipe returning an empty table)
-- RIG_MODE=snap  : the design under test: proxies are plain tables (no
--                  __persist on userdataWrapper); the registry's own recipe
--                  carries a {proxy -> {className, nbt}} snapshot as a CLOSED
--                  upvalue and rebuilds the registry from it.
-- RIG_VARIANT=inflight : additionally make the registry reachable from INSIDE a
--                  proxy record, so the recipe sees an in-flight key (L2(b)).
--
-- The host Value is a real userdata (newproxy) so a leak of one into the
-- graph is REFUSED by the serializer rather than silently persisted.

local MODE = os.getenv("RIG_MODE") or "snap"
local VARIANT = os.getenv("RIG_VARIANT") or "plain"
NHANDLES = tonumber(os.getenv("RIG_HANDLES") or "2")
print(("rig: mode=%s variant=%s"):format(MODE, VARIANT))

local fails = 0
local function ok(cond, what, extra)
  if cond then print("  ok   " .. what)
  else fails = fails + 1; print("  FAIL " .. what .. "  -- " .. tostring(extra)) end
end

-------------------------------------------------------------------- host stub
-- Stands in for UserdataAPI: save/load/apply/methods/dispose. Values are raw
-- userdata; their host state lives in a side table the serializer never sees.
local hostinfo = setmetatable({}, { __mode = "k" })
local counters = { loads = 0, saves = 0, disposes = 0 }
userdata = {
  open = function(id)
    local v = newproxy(true)
    hostinfo[v] = { class = "li.cil.oc.server.component.FileSystem$HandleValue", id = id, fresh = false }
    return v
  end,
  save = function(v)
    counters.saves = counters.saves + 1
    local i = hostinfo[v]
    if not i then error("userdata.save: not a host value: " .. tostring(v), 0) end
    return i.class, "NBT[" .. i.id .. "]"
  end,
  load = function(className, nbt)
    counters.loads = counters.loads + 1
    if type(className) ~= "string" or type(nbt) ~= "string" then
      error("userdata.load: bad arguments", 0)
    end
    local v = newproxy(true)
    hostinfo[v] = { class = className, id = nbt:match("^NBT%[(.*)%]$"), fresh = true }
    return v
  end,
  methods = function(v) return { read = true, close = true } end,
  apply = function(v, ...)
    local i = hostinfo[v]
    if not i then return false, "no host value" end
    return true, i.id, i.fresh
  end,
  dispose = function(v) counters.disposes = counters.disposes + 1 end,
}
COUNTERS = counters

-- Brain-style perms: flatten _G sorted (userdata.* is in here, as in OC).
local function build_perms()
  local perms, uperms = {}, {}
  local cand = {}
  local function offer(v, n) cand[#cand + 1] = { v, n } end
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
  return perms, uperms
end
local P, U = build_perms()

------------------------------------------------------------- kernel mirror
local function kernel_chunk()
  local sandbox                                                    -- :753
  local wrapUserdata, wrapSingleUserdata, unwrapUserdata, wrappedUserdataMeta -- :1075

  if MODE == "orig" then
    wrappedUserdataMeta = {                                        -- :1077
      __mode = "k",
      __persist = function()                                       -- :1083
        return function()
          return setmetatable({}, wrappedUserdataMeta)
        end
      end
    }
  else
    wrappedUserdataMeta = {
      __mode = "k",
      -- THE DESIGN. Everything the returned closure reads at load time is
      -- inside its own record (snap, meta as CLOSED upvalues: this frame is
      -- dead by the time the serializer writes the closure) or a permanent
      -- (userdata.load, setmetatable, pairs, type, error).
      __persist = function(self)
        local snap, meta = {}, wrappedUserdataMeta
        for proxy, data in pairs(self) do
          local className, nbt = userdata.save(data)
          snap[proxy] = { className, nbt }
        end
        return function()
          local registry = setmetatable({}, meta)
          for proxy, rec in pairs(snap) do
            if type(proxy) ~= "table" or type(rec) ~= "table"
               or type(rec[1]) ~= "string" or type(rec[2]) ~= "string" then
              error("userdata registry snapshot is malformed", 0)
            end
            registry[proxy] = userdata.load(rec[1], rec[2])
          end
          return registry
        end
      end
    }
  end
  local wrappedUserdata = setmetatable({}, wrappedUserdataMeta)   -- :1091

  local function processResult(result)
    result = wrapUserdata(result)
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
  end
  local function udinvoke(f, data, ...)                            -- :1130
    if data == nil then
      error("userdata proxy has no host value (dropped by save or dispose)", 2)
    end
    local args = table.pack(...)
    args = unwrapUserdata(args)
    local result = table.pack(f(data, table.unpack(args)))
    args = nil
    return processResult(result)
  end

  local userdataWrapper = {                                        -- :1136
    __index = function(self, ...)
      return udinvoke(userdata.apply, wrappedUserdata[self], ...)
    end,
    __gc = function(self)
      local data = wrappedUserdata[self]
      wrappedUserdata[self] = nil
      userdata.dispose(data)
    end,
    __metatable = "userdata",
    __tostring = function(self)
      return tostring(select(2, pcall(tostring, wrappedUserdata[self])))
    end
  }
  if MODE == "orig" then
    userdataWrapper.__persist = function(self)                     -- :1156
      local className, nbt = userdata.save(wrappedUserdata[self])
      return function()
        return wrapSingleUserdata(userdata.load(className, nbt))   -- :1162
      end
    end
  end

  local userdataCallback = {                                       -- :1174
    __call = function(self, ...)
      local methods = userdata.methods(wrappedUserdata[self.proxy])
      for name in pairs(methods) do
        if name == self.name then
          return udinvoke(userdata.apply, wrappedUserdata[self.proxy], name, ...)
        end
      end
      error("no such method", 1)
    end,
  }

  function wrapSingleUserdata(data)                                -- :1189
    for k, v in pairs(wrappedUserdata) do
      if v == data then return k end
    end
    local proxy = { type = "userdata" }
    local methods = userdata.methods(data)
    for method in pairs(methods) do
      proxy[method] = setmetatable({ name = method, proxy = proxy }, userdataCallback)
    end
    wrappedUserdata[proxy] = data
    if VARIANT == "inflight" then
      -- Makes the registry reachable from INSIDE this proxy's record, so the
      -- registry recipe runs while this proxy's record is still being built.
      rawset(proxy, "__reg", wrappedUserdata)
    end
    return setmetatable(proxy, userdataWrapper)
  end

  function wrapUserdata(values)
    local processed = {}
    local function wrapRecursively(value)
      if type(value) == "table" then
        if not processed[value] then
          processed[value] = true
          for k, v in pairs(value) do value[k] = wrapRecursively(v) end
        end
      elseif type(value) == "userdata" then
        return wrapSingleUserdata(value)
      end
      return value
    end
    return wrapRecursively(values)
  end

  function unwrapUserdata(values)
    local processed = {}
    local function unwrapRecursively(value)
      if wrappedUserdata[value] then return wrappedUserdata[value] end
      if type(value) == "table" then
        if not processed[value] then
          processed[value] = true
          for k, v in pairs(value) do value[k] = unwrapRecursively(v) end
        end
      end
      return value
    end
    return unwrapRecursively(values)
  end

  sandbox = {}

  local function main()                                            -- :1532
    -- The "OS": a coroutine that opens a handle (bin/lua.lua:10 shape), pins
    -- it (boot/01_process.lua:81-88), keeps a second reference, and yields.
    local os_co = coroutine.create(function()
      local h = wrapUserdata({ userdata.open("file1") })[1]
      local h2 = NHANDLES >= 2 and wrapUserdata({ userdata.open("file2") })[1] or nil
      sandbox.process = { handles = { h, h2 } }
      sandbox.alias = h
      local n = 0
      while true do
        n = n + 1
        coroutine.yield("pull", n)
      end
    end)
    assert(coroutine.resume(os_co))
    -- The sync-call shape: invoke yields a closure over unwrapUserdata/wrapUserdata
    -- (machine.lua:1116-1122). Yield one out so the harness can persist it
    -- separately, exactly as NativeLuaArchitecture.save does with index 2.
    local args = { sandbox.alias }
    local synccall = function()
      args = unwrapUserdata(args)
      local result = { true, hostinfo_probe(args[1]) }
      args = nil
      return wrapUserdata(result)
    end
    coroutine.yield("synccall", synccall)
    while true do
      local r = table.pack(coroutine.resume(os_co))
      coroutine.yield("sandbox", sandbox, r[3])
    end
  end
  local function pcallTimeoutCheck(...) return ... end
  return pcallTimeoutCheck(pcall(main))                            -- :1571
end

-- A probe the sync-call closure can reach as a global (a permanent), which
-- reports whether it received a real host value or a leftover proxy table.
function hostinfo_probe(v)
  if type(v) == "userdata" then return "host:" .. tostring(hostinfo[v] and hostinfo[v].id) end
  return "NOT-UNWRAPPED:" .. type(v)
end
P[hostinfo_probe] = "_G.hostinfo_probe"; U["_G.hostinfo_probe"] = hostinfo_probe

------------------------------------------------------------------ the run
local co = coroutine.create(kernel_chunk)
local a, tag, synccall = coroutine.resume(co)
assert(a and tag == "synccall", tostring(tag))
local b, tag2, sb0, n0 = coroutine.resume(co)
assert(b and tag2 == "sandbox", tostring(tag2))
print(("pre-save: os tick=%d handles=%d loads=%d"):format(n0, #sb0.process.handles, counters.loads))

local function countstr(s, needle)
  local n, pos = 0, 1
  while true do local a, b_ = s:find(needle, pos, true); if not a then return n end; n, pos = n + 1, b_ + 1 end
end

-- Kernel blob (index 1)
local okp, blob = pcall(eris.persist, P, co)
ok(okp, "persist(kernel) succeeds", blob)
if not okp then print("FAILS: " .. fails); return fails end
print(("  kernel blob: %d bytes, HandleValue x%d"):format(#blob, countstr(blob, "HandleValue")))
ok(countstr(blob, "HandleValue") >= 1, "f1b anti-vacuity: blob carries the class name")

-- Stack blob (index 2), separate persist call as in NativeLuaArchitecture.save
local oks, blob2 = pcall(eris.persist, P, synccall)
ok(oks, "persist(synccall closure) succeeds", blob2)
if oks then print(("  stack blob: %d bytes (kernel pulled in: %s)"):format(#blob2, tostring(#blob2 > #blob / 2))) end

-- Restore the kernel
local loads_before = counters.loads
local oku, co2 = pcall(eris.unpersist, U, blob)
ok(oku, "unpersist(kernel) succeeds", co2)
if not oku then print("FAILS: " .. fails); return fails end
ok(type(co2) == "thread" and coroutine.status(co2) == "suspended", "restored kernel is a suspended thread")
print(("  userdata.load calls during unpersist: %d"):format(counters.loads - loads_before))
ok(counters.loads - loads_before == NHANDLES, "exactly one host load per persisted proxy", counters.loads - loads_before)

local c, tag3, sb, n1 = coroutine.resume(co2)
ok(c and tag3 == "sandbox", "restored kernel resumes at its yield", tag3)
ok(n1 == n0 + 1, "OS coroutine continued from its counter", tostring(n1))
local h = sb and sb.alias
ok(type(h) == "table" and getmetatable(h) == "userdata", "proxy restored with __metatable 'userdata'")
ok(sb and sb.process.handles[1] == h, "two references to the proxy restore to ONE object")
local okc, id, fresh = pcall(function() return h.read() end)
ok(okc, "proxy.method() reaches a host value after restore", id)
ok(id == "file1" and fresh == true, "the host value is the one rebuilt from (className, nbt)", tostring(id) .. "/" .. tostring(fresh))
if NHANDLES >= 2 then
  ok(sb and sb.process.handles[2] ~= h, "distinct proxies stay distinct")
  local okc2, id2 = pcall(function() return sb.process.handles[2].read() end)
  ok(okc2 and id2 == "file2", "second proxy reaches ITS host value", tostring(id2))
end

-- Oracle: persist -> unpersist -> persist -> unpersist
local okp2, blobB = pcall(eris.persist, P, co2)
ok(okp2, "second persist (of the restored graph) succeeds", blobB)
if okp2 then
  local oku2, co3 = pcall(eris.unpersist, U, blobB)
  ok(oku2, "second unpersist succeeds", co3)
  if oku2 then
    local d, t4, sb3 = coroutine.resume(co3)
    local okc3, id3, fresh3 = pcall(function() return sb3.alias.read() end)
    ok(d and okc3 and id3 == "file1", "proxy live after a second round trip", tostring(id3))
  end
end

-- The stack blob: the sync-call closure restored on its own, then called.
if oks then
  local oku3, sc = pcall(eris.unpersist, U, blob2)
  ok(oku3, "unpersist(stack blob) succeeds", sc)
  if oku3 then
    local okcall, res = pcall(sc)
    ok(okcall, "restored sync-call closure runs", res)
    if okcall then print("  sync-call saw: " .. tostring(res and res[2])) end
  end
end

print(("counters: loads=%d saves=%d disposes=%d"):format(counters.loads, counters.saves, counters.disposes))
print("FAILS: " .. fails)
return fails
