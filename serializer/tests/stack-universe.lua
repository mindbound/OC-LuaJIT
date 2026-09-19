-- stack-universe.lua -- the sync-call save shape: ONE reference space or TWO.
--
-- OC persists a running computer as two roots in two eris.persist calls, each
-- with its own reference space (NativeLuaArchitecture.save :396-437, load
-- :349-394): the kernel coroutine at stack index 1, and, while the state stack
-- holds a SynchronizedCall / SynchronizedReturn, the closure or result table at
-- index 2. The closure yielded by machine.lua's invoke (:1116-1124) captures
-- args and target (invoke's locals) and unwrapUserdata / wrapUserdata (chunk
-- locals): four OPEN upvalues into the kernel coroutine's stack.
--
-- Persisted on its own, an open upvalue whose owner is not in the reference
-- table makes p_function (eris_lj.c:651, elj_find_owner_any :543) chase the
-- owner through every live thread and write the kernel INTO the stack blob: a
-- second kernel universe, a second registry, a second host Value per proxy.
-- Stock Eris writes the same upvalues by value: a second universe in
-- closed-copy form, with its own silent mode (U4).
--
-- The candidate fix (U2, U3): persist {thread, closure} in ONE call, so the
-- closure's open upvalues find the thread already in the reference table and
-- go out as TAG_UPVALOPEN(thread, slot) into the SAME blob, aliasing the
-- restored kernel's frame exactly as they alias the live one.
--
-- The kernel mirror keeps machine.lua's chunk-local slot order and its shipped
-- shell-fill recipes (:1077-1091 registry, :1156-1164 proxy, :1213 wrapUserdataInto)
-- and yields from inside invoke under userdataCallback.__call, as the kernel does.
--
--   U1  the defect: two calls. Asserted AS THE DEFECT -- a documented, permanently
--       reproducible measurement, not a target. It is WHY the Architecture bundles
--       the roots (LuaJITArchitecture.java / OcljArch.scala save+load): the fix
--       lives there, not in the serializer, and this case is the record of what
--       it fixes. (It was first written asserting the correct behaviour, a
--       permanently-red control; that version could never join the suite.)
--       U1r  the same for the SynchronizedReturn shape (a result table at index 2).
--   U2  the fix: one call, {thread, closure}; same observables as a never-saved run.
--       U2r  the same for {thread, result table}.
--   U3  two rounds of the combined shape: one thread, no growth.
--   U4  stock-shape control: upvalues written by value; the silent mode, printed.
--
-- Standalone: ./erislj_test.exe tests/stack-universe.lua     (prints FAILS: N)
-- Expected on 1a9e8e17: FAILS: 0. U1/U1r go red if the two-call shape ever stops
-- producing the second universe -- a serializer change the Architecture's
-- bundling would not need, but a change in the measurement all the same.

NHANDLES = 2
COUNTERS = { loads = 0, saves = 0 }

------------------------------------------------------------------ host stub
-- Stands in for UserdataAPI. A host Value is a real userdata (newproxy) so a
-- leak of one into a blob is REFUSED by the serializer, never silently copied.
local hostinfo = setmetatable({}, { __mode = "k" })
function hostinfo_probe(v)
  if type(v) == "userdata" then return "host:" .. tostring(hostinfo[v] and hostinfo[v].id) end
  return "NOT-UNWRAPPED:" .. type(v)
end
userdata = {
  open = function(id)
    local v = newproxy(true)
    hostinfo[v] = { class = "li.cil.oc.server.component.FileSystem$HandleValue", id = id }
    return v
  end,
  save = function(v)
    COUNTERS.saves = COUNTERS.saves + 1
    local i = hostinfo[v]
    if not i then error("userdata.save: not a host value: " .. tostring(v), 0) end
    return i.class, "NBT[" .. i.id .. "]"
  end,
  load = function(className, nbt)
    COUNTERS.loads = COUNTERS.loads + 1
    if type(className) ~= "string" or type(nbt) ~= "string" then error("userdata.load: bad arguments", 0) end
    local v = newproxy(true)
    hostinfo[v] = { class = className, id = nbt:match("^NBT%[(.*)%]$") }
    return v
  end,
  -- direct = false: every call is a SynchronizedCall (FileSystem.read past its
  -- per-tick budget, or any non-direct callback).
  methods = function(v) return { read = false, close = false } end,
  apply = function(v, ...) return true, hostinfo[v] and hostinfo[v].id end,
  dispose = function(v) end,
  -- The host side of the SynchronizedCall (target.invoke in the closure):
  -- reports what unwrapUserdata made of its first argument, and returns a
  -- fresh host Value, the shape of every call that returns a handle.
  invoke = function(v, name, ...) return true, hostinfo_probe(v), userdata.open("file3") end,
}

local function build_perms()
  local perms, uperms = {}, {}
  local function add(v, name) if perms[v] == nil then perms[v] = name; uperms[name] = v end end
  add(_G, "_G")
  for k, v in pairs(_G) do
    local t = type(v)
    if t == "function" or t == "table" then
      add(v, "_G." .. tostring(k))
      if t == "table" and v ~= _G then
        for k2, v2 in pairs(v) do
          local t2 = type(v2)
          if t2 == "function" or t2 == "table" then add(v2, "_G." .. tostring(k) .. "." .. tostring(k2)) end
        end
      end
    end
  end
  return perms, uperms
end
local P, U = build_perms()
local fails = 0
local function ok(c, what, extra) if c then print("  ok   " .. what) else fails = fails + 1; print("  FAIL " .. what .. "  -- " .. tostring(extra)) end end

------------------------------------------------------------- kernel mirror
-- No upvalues: everything it names is a global (a permanent) or its own local,
-- so the coroutine's graph is exactly the kernel's, nothing of this harness.
local function kernel_chunk()
  local sandbox                                                              -- :753
  local wrapUserdata, wrapSingleUserdata, unwrapUserdata, wrappedUserdataMeta, wrapUserdataInto -- :1075
  wrappedUserdataMeta = {                                                    -- :1077
    __mode = "k",
    __persist = function()
      return function(self) setmetatable(self, wrappedUserdataMeta) end       -- :1088 shell-fill
    end
  }
  local wrappedUserdata = setmetatable({}, wrappedUserdataMeta)              -- :1091

  local function processResult(result)                                       -- :1093
    result = wrapUserdata(result)
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
  end

  local function invoke(target, direct, ...)                                 -- :1101
    local result
    if not result then
      local args = table.pack(...)                                           -- :1115
      -- machine.lua: result = select(1, coroutine.yield(function() ... end)).
      -- The literal is yielded inline, as there: nothing in the kernel names
      -- it. The harness resumes with ("result", tbl). U4 first resumes with
      -- ("selfpersist", perms, closure): the kernel persists the closure from
      -- INSIDE its own thread, which writes every upvalue open into that thread
      -- by value (eris_lj.c:655-657) -- the one rule stock Eris applies to all.
      local cmd, arg, arg2 = coroutine.yield(function()                      -- :1116
        args = unwrapUserdata(args)
        local result = table.pack(target.invoke(table.unpack(args, 1, args.n)))
        args = nil
        result = wrapUserdata(result)
        return result
      end)
      while cmd == "selfpersist" do
        cmd, arg, arg2 = coroutine.yield("stackblob", eris.persist(arg, arg2))
      end
      if cmd ~= "result" then error("kernel mirror: unexpected resume " .. tostring(cmd), 0) end
      result = arg
    end
    return processResult(result)
  end

  local function udinvoke(f, data, ...)                                      -- :1130
    local args = table.pack(...)
    args = unwrapUserdata(args)
    local result = table.pack(f(data, table.unpack(args)))
    args = nil
    return processResult(result)
  end

  local userdataWrapper = {                                                  -- :1139
    __index = function(self, ...) return udinvoke(userdata.apply, wrappedUserdata[self], ...) end,
    __gc = function(self)
      local data = wrappedUserdata[self]
      wrappedUserdata[self] = nil
      userdata.dispose(data)
    end,
    __persist = function(self)                                               -- :1156
      local className, nbt = userdata.save(wrappedUserdata[self])
      return function(proxy) wrapUserdataInto(proxy, userdata.load(className, nbt)) end
    end,
    __metatable = "userdata",
    __tostring = function(self) return tostring(select(2, pcall(tostring, wrappedUserdata[self]))) end,
  }
  local userdataCallback = {                                                 -- :1174
    __call = function(self, ...)
      local methods = userdata.methods(wrappedUserdata[self.proxy])
      for name, direct in pairs(methods) do
        if name == self.name then return invoke(userdata, direct, self.proxy, name, ...) end
      end
      error("no such method", 1)
    end,
  }
  function wrapSingleUserdata(data)                                          -- :1189
    for k, v in pairs(wrappedUserdata) do if v == data then return k end end
    local proxy = { type = "userdata" }
    for method in pairs(userdata.methods(data)) do
      proxy[method] = setmetatable({ name = method, proxy = proxy }, userdataCallback)
    end
    wrappedUserdata[proxy] = data
    return setmetatable(proxy, userdataWrapper)
  end
  function wrapUserdataInto(proxy, data)                                     -- :1213
    proxy.type = "userdata"
    for method in pairs(userdata.methods(data)) do
      proxy[method] = setmetatable({ name = method, proxy = proxy }, userdataCallback)
    end
    wrappedUserdata[proxy] = data
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
  -- For the harness: a closure over the SAME chunk slots the sync closure
  -- captures, so debug.upvalueid can say whether two closures share one open
  -- upvalue (one thread) or hold two (two threads).
  sandbox.report = function() return unwrapUserdata, wrapUserdata, wrappedUserdata end

  local function main()                                                      -- :1532
    -- The OS: opens two handles (bin/lua.lua:10 shape), keeps them, ticks.
    local os_co = coroutine.create(function()
      local h = wrapUserdata({ userdata.open("file1") })[1]
      local h2 = wrapUserdata({ userdata.open("file2") })[1]
      sandbox.process = { handles = { h, h2 } }
      sandbox.alias = h
      local n = 0
      while true do n = n + 1; coroutine.yield("pull", n) end
    end)
    assert(coroutine.resume(os_co))
    -- h.read(): userdataCallback.__call -> invoke -> the sync-call yield.
    local probe, v = sandbox.alias.read()
    -- What the kernel does with a sync result: processResult wrapped it and
    -- handed it to user code; when user code passes it back to any callback,
    -- unwrapUserdata(args) must turn it into the host Value again.
    sandbox.last = {
      probe = probe,                                  -- what the closure's unwrapUserdata made of the arg
      kind = type(v),
      registered = wrappedUserdata[v] ~= nil,         -- does THIS kernel's registry know the result?
      back = hostinfo_probe(unwrapUserdata({ v })[1]), -- what the host would receive
    }
    while true do
      local r = table.pack(coroutine.resume(os_co))
      coroutine.yield("sandbox", sandbox, r[3])
    end
  end
  local function pcallTimeoutCheck(...) return ... end
  return pcallTimeoutCheck(pcall(main))                                      -- :1571 (chunk frame stays live)
end

------------------------------------------------------------------ helpers
-- The kernel's first yield hands out the sync closure alone, exactly the
-- value OC's runThreaded finds at stack index 2 and files as a SynchronizedCall.
local function build()
  local co = coroutine.create(kernel_chunk)
  local a, closure = coroutine.resume(co)
  assert(a and type(closure) == "function", tostring(closure))
  return co, closure
end
-- (found, value) of the named local anywhere on a suspended thread's stack.
local function frame_local(th, name)
  for level = 1, 32 do
    if not debug.getinfo(th, level, "S") then return false end
    local i = 1
    while true do
      local n, v = debug.getlocal(th, level, i)
      if n == nil then break end
      if n == name then return true, v end
      i = i + 1
    end
  end
  return false
end
local function upvalue(f, name)
  for i = 1, 64 do
    local n, v = debug.getupvalue(f, i)
    if n == nil then return nil end
    if n == name then return i, v end
  end
end
-- Does the closure alias the kernel's frame, or a second thread's?
local function aliasing(co, sc)
  local ia = upvalue(sc, "unwrapUserdata")
  local _, sb = frame_local(co, "sandbox")
  local ib = upvalue(sb.report, "unwrapUserdata")
  local same_uv = debug.upvalueid(sc, ia) == debug.upvalueid(sb.report, ib)
  local _, uvargs = upvalue(sc, "args")
  local _, frargs = frame_local(co, "args")
  local _, cu = upvalue(sc, "unwrapUserdata")
  local _, creg = upvalue(cu, "wrappedUserdata")
  local kreg = select(3, sb.report())
  return same_uv, rawequal(uvargs, frargs), rawequal(creg, kreg), creg, kreg
end
local function fmt_alias(same_uv, same_args, same_reg)
  return ("upvalue-id=%s args-slot=%s registry=%s"):format(tostring(same_uv), tostring(same_args), tostring(same_reg))
end
-- Hand the sync result to the kernel; run it to its next sandbox yield.
local function finish(co, res)
  local okr, tag, sb, tick = coroutine.resume(co, "result", res)
  if not okr then return nil, tag end
  if tag ~= "sandbox" then return nil, "unexpected yield " .. tostring(tag) end
  return sb.last, tick
end
local function fmt_last(l, err)
  if not l then return "(kernel did not report: " .. tostring(err) .. ")" end
  return ("probe=%s kind=%s registered=%s back=%s"):format(tostring(l.probe), l.kind, tostring(l.registered), tostring(l.back))
end
local function loads_during(f, ...)
  local before = COUNTERS.loads
  local okc, r = pcall(f, ...)
  return okc, r, COUNTERS.loads - before
end

-- The never-saved run: what every restored run must reproduce.
local CONTROL
do
  local co, sc = build()
  local l0 = COUNTERS.loads
  local last, err = finish(co, sc())
  CONTROL = fmt_last(last, err)
  print("control (never saved): " .. CONTROL .. ("; loads=%d"):format(COUNTERS.loads - l0))
end

------------------------------------------------------------------------------
print("-- U1: the defect, documented. persist(kernel) then persist(closure): two calls, two reference spaces (OC's save)")
do
  local co, sc = build()
  local okp1, blob1 = pcall(eris.persist, P, co)
  ok(okp1, "U1 persist(kernel)", blob1)
  local okp2, blob2 = pcall(eris.persist, P, sc)
  ok(okp2, "U1 persist(closure)", blob2)
  if okp1 and okp2 then
    print(("  [U1] kernel blob %d bytes, stack blob %d bytes (kernel pulled in: %s)"):format(#blob1, #blob2, tostring(#blob2 > #blob1 / 2)))
    local oku1, co2, l1 = loads_during(eris.unpersist, U, blob1)
    ok(oku1, "U1 unpersist(kernel)", co2)
    local oku2, sc2, l2 = loads_during(eris.unpersist, U, blob2)
    ok(oku2, "U1 unpersist(closure)", sc2)
    if oku1 and oku2 then
      local same_uv, same_args, same_reg = aliasing(co2, sc2)
      print(("  [U1] userdata.load calls: kernel restore %d, stack restore %d, for %d persisted proxies"):format(l1, l2, NHANDLES))
      print("  [U1] closure aliases the restored kernel: " .. fmt_alias(same_uv, same_args, same_reg))
      local okc, res = pcall(sc2)
      ok(okc, "U1 restored closure runs", res)
      local _, frargs = frame_local(co2, "args")
      local last, err = finish(co2, res)
      print("  [U1] after the call: invoke's args slot in the kernel = " .. tostring(frargs) .. "; kernel sees " .. fmt_last(last, err))
      -- DOCUMENTED DEFECT, not a target. Every line below asserts that the
      -- two-call shape DOES produce the second universe. The fix is not in the
      -- serializer: the Architecture persists {thread, closure} in ONE call (U2)
      -- precisely because these five observations hold.
      ok(#blob2 > #blob1 / 2, "U1 [defect] the stack blob carries the kernel (kernel-sized)", #blob2)
      ok(l1 + l2 == 2 * NHANDLES, "U1 [defect] TWO host loads per persisted proxy: each blob restores its own kernel", l1 + l2)
      ok(not same_uv and not same_args and not same_reg,
         "U1 [defect] the restored closure aliases a SECOND kernel, not the one at index 1", fmt_alias(same_uv, same_args, same_reg))
      ok(frargs ~= nil, "U1 [defect] the closure's args=nil cleared the second thread's slot; the kernel's still holds the args table", tostring(frargs))
      ok(last ~= nil and last.registered == false and last.back == "NOT-UNWRAPPED:table",
         "U1 [defect] the sync result is a proxy the kernel's registry does NOT know: the silent mode", fmt_last(last, err))
    end
  end
end

print("-- U1r: the same defect, documented, for the SynchronizedReturn shape: a result table at index 2")
do
  local co, sc = build()
  local res = sc()                                    -- the call ran on the server thread; the kernel has not consumed it
  local okp1, blob1 = pcall(eris.persist, P, co)
  local okp2, blob2 = pcall(eris.persist, P, res)
  ok(okp1 and okp2, "U1r persist(kernel), persist(result table)", okp1 and blob2 or blob1)
  if okp1 and okp2 then
    print(("  [U1r] kernel blob %d bytes, stack blob %d bytes (kernel pulled in: %s)"):format(#blob1, #blob2, tostring(#blob2 > #blob1 / 2)))
    local oku1, co2, l1 = loads_during(eris.unpersist, U, blob1)
    local oku2, res2, l2 = loads_during(eris.unpersist, U, blob2)
    ok(oku1 and oku2, "U1r unpersist both", oku1 and res2 or co2)
    if oku1 and oku2 then
      local last, err = finish(co2, res2)
      print(("  [U1r] userdata.load calls: kernel restore %d, stack restore %d, for %d persisted proxies; kernel sees %s"):format(l1, l2, NHANDLES + 1, fmt_last(last, err)))
      -- DOCUMENTED DEFECT, as U1: the result table's wrapUserdata metatable chain
      -- reaches the kernel's registry, so the stack blob carries the kernel again.
      ok(#blob2 > #blob1 / 2, "U1r [defect] the stack blob carries the kernel (kernel-sized)", #blob2)
      ok(l1 + l2 == 2 * NHANDLES + 1, "U1r [defect] the two kept handles load twice, the result once: 2N+1 loads for N+1 proxies", l1 + l2)
      ok(last ~= nil and last.registered == false and last.back == "NOT-UNWRAPPED:table",
         "U1r [defect] the returned proxy is one the kernel's registry does NOT know: the silent mode", fmt_last(last, err))
    end
  end
end

------------------------------------------------------------------------------
print("-- U2: the fix. ONE persist of {kernel, closure}: one reference space")
do
  local co, sc = build()
  local okk, kblob = pcall(eris.persist, P, co)       -- size reference only
  local okp, blob = pcall(eris.persist, P, { co, sc })
  ok(okp, "U2 persist({kernel, closure})", blob)
  if okp and okk then
    print(("  [U2] combined blob %d bytes = kernel-only blob %d + %d for the closure"):format(#blob, #kblob, #blob - #kblob))
    local oku, t, l = loads_during(eris.unpersist, U, blob)
    ok(oku, "U2 unpersist", t)
    if oku then
      ok(type(t) == "table" and type(t[1]) == "thread" and coroutine.status(t[1]) == "suspended" and type(t[2]) == "function",
         "U2 t[1] is the suspended kernel, t[2] the closure (push to indices 1 and 2)")
      local same_uv, same_args, same_reg = aliasing(t[1], t[2])
      print(("  [U2] userdata.load calls: %d for %d persisted proxies"):format(l, NHANDLES))
      print("  [U2] closure aliases the restored kernel: " .. fmt_alias(same_uv, same_args, same_reg))
      local okc, res = pcall(t[2])
      ok(okc, "U2 restored closure runs", res)
      local _, frargs = frame_local(t[1], "args")
      local last, err = finish(t[1], res)
      local got = fmt_last(last, err)
      print("  [U2] after the call: invoke's args slot in the kernel = " .. tostring(frargs) .. "; kernel sees " .. got)
      ok(l == NHANDLES, "U2 exactly one host load per persisted proxy", l)
      ok(same_uv, "U2 closure's unwrapUserdata upvalue is the kernel's own chunk slot (rawequal upvalue id)")
      ok(same_args, "U2 closure's args upvalue is invoke's frame slot in the kernel")
      ok(same_reg, "U2 closure's registry IS the kernel's registry")
      ok(frargs == nil, "U2 the closure's args=nil cleared the kernel's frame slot", tostring(frargs))
      ok(got == CONTROL, "U2 call + resume gives the never-saved result", got)
    end
  end
end

print("-- U2r: the fix for the SynchronizedReturn shape: {kernel, result table}")
do
  local co, sc = build()
  local res = sc()
  local okp, blob = pcall(eris.persist, P, { co, res })
  ok(okp, "U2r persist({kernel, result table})", blob)
  if okp then
    local oku, t, l = loads_during(eris.unpersist, U, blob)
    ok(oku, "U2r unpersist", t)
    if oku then
      local last, err = finish(t[1], t[2])
      local got = fmt_last(last, err)
      print(("  [U2r] userdata.load calls: %d for %d persisted proxies; kernel sees %s"):format(l, NHANDLES + 1, got))
      ok(l == NHANDLES + 1, "U2r exactly one host load per persisted proxy", l)
      ok(got == CONTROL, "U2r resume with the restored result gives the never-saved result", got)
    end
  end
end

------------------------------------------------------------------------------
print("-- U3: two rounds of the combined shape: one thread, no growth")
do
  local co, sc = build()
  local okA, blobA = pcall(eris.persist, P, { co, sc })
  ok(okA, "U3 round 1 persist", blobA)
  if okA then
    local okuA, t = pcall(eris.unpersist, U, blobA)
    ok(okuA, "U3 round 1 unpersist", t)
    if okuA then
      local okB, blobB = pcall(eris.persist, P, { t[1], t[2] })
      ok(okB, "U3 round 2 persist (of the restored pair, untouched)", blobB)
      if okB then
        local okuB, t2, l = loads_during(eris.unpersist, U, blobB)
        ok(okuB, "U3 round 2 unpersist", t2)
        print(("  [U3] round 1 blob %d bytes, round 2 blob %d bytes (delta %d); loads on round 2: %d"):format(#blobA, #blobB, #blobB - #blobA, l))
        ok(math.abs(#blobB - #blobA) <= 8, "U3 blob size stable across rounds (no second universe accreting)", #blobB - #blobA)
        if okuB then
          ok(l == NHANDLES, "U3 still one host load per proxy after two rounds", l)
          local same_uv, same_args, same_reg = aliasing(t2[1], t2[2])
          ok(same_uv and same_args and same_reg, "U3 closure still aliases the (twice-restored) kernel", fmt_alias(same_uv, same_args, same_reg))
          local okc, res = pcall(t2[2])
          local last, err = okc and finish(t2[1], res)
          local got = fmt_last(last, err or res)
          print("  [U3] kernel sees " .. got)
          ok(got == CONTROL, "U3 call + resume after two rounds gives the never-saved result", got)
        end
      end
    end
  end
end

------------------------------------------------------------------------------
print("-- U4: stock-shape control. The closure's upvalues written BY VALUE, persisted separately")
-- Stock Eris has no thread chase: an open upvalue goes out like a closed one.
-- eris_lj.c:655-657 applies exactly that rule when the owning thread is the
-- one running persist, so the kernel persists the closure ITSELF (resumed with
-- "selfpersist"): args, target, unwrapUserdata, wrapUserdata, and through them
-- wrappedUserdata, wrappedUserdataMeta, wrapUserdataInto, userdataWrapper all
-- leave as values. Same live kernel as U1-U3; only the write rule differs.
do
  local co, sc = build()
  local okp1, blob1 = pcall(eris.persist, P, co)     -- index 1, suspended, as before
  ok(okp1, "U4 control: persist(kernel)", blob1)
  local okr, tag, blob2 = coroutine.resume(co, "selfpersist", P, sc)
  ok(okr and tag == "stackblob" and type(blob2) == "string", "U4 control: the kernel persisted its own sync closure", okr and tag or tag)
  if okp1 and okr and type(blob2) == "string" then
    print(("  [U4] kernel blob %d bytes, stack blob %d bytes (kernel pulled in: %s)"):format(#blob1, #blob2, tostring(#blob2 > #blob1 / 2)))
    ok(#blob2 < #blob1 / 2, "U4 control: the stack blob does not carry the kernel (stock's shape)", #blob2)
    local oku1, co2, l1 = loads_during(eris.unpersist, U, blob1)
    local oku2, sc2, l2 = loads_during(eris.unpersist, U, blob2)
    ok(oku1 and oku2, "U4 control: unpersist both", oku1 and sc2 or co2)
    if oku1 and oku2 then
      local same_uv, same_args, same_reg, creg, kreg = aliasing(co2, sc2)
      print(("  [U4] userdata.load calls: kernel restore %d, stack restore %d (the args proxy, loaded again into a COPY registry)"):format(l1, l2))
      print("  [U4] closure aliases the restored kernel: " .. fmt_alias(same_uv, same_args, same_reg))
      local okc, res = pcall(sc2)
      ok(okc, "U4 control: closed-copy closure runs", res)
      local rp = okc and res[3]
      print(("  [U4] the sync result's proxy: in the copy's registry=%s, in the kernel's registry=%s"):format(tostring(okc and creg[rp] ~= nil), tostring(okc and kreg[rp] ~= nil)))
      local last, err = finish(co2, res)
      print("  [U4] kernel sees " .. fmt_last(last, err))
      ok(l2 == 1 and not same_reg, "U4 control: a second registry, holding a second Value for the args proxy", l2)
      ok(okc and creg[rp] ~= nil and kreg[rp] == nil, "U4 control: the result proxy is registered only in the copy")
      ok(last ~= nil and last.registered == false and last.back == "NOT-UNWRAPPED:table",
         "U4 control: the kernel's unwrapUserdata hands the host a plain table (the silent mode)", fmt_last(last, err))
    end
  end
end

print(("counters: loads=%d saves=%d"):format(COUNTERS.loads, COUNTERS.saves))
print("FAILS: " .. fails)
return fails
