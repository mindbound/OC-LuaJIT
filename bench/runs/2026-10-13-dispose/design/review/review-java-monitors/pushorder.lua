-- Emulates the design's pushJavaObjectRaw override for ONE Value per trial.
-- Its only userdata u1 is dead-but-unfinalized when Java re-pushes the same
-- Value. "super.push" = newproxy (an allocation: a GC step may run pending
-- finalizers INSIDE it). Mode "after" = the design (count++ after super);
-- mode "before" = the proposed change (count++ before super). A hit = the
-- Value's count reached 0 (=> dispose) while its re-push was in flight, so
-- the new userdata would wrap a disposed Value. Per-trial state, so a late
-- finalizer from an earlier trial cannot touch this trial's count.
local mode = arg[1] or "after"
if arg[2] == "armed" then collectgarbage("setpause", 100); collectgarbage("setstepmul", 0) end
local hits, zeros = 0, 0
local function push(st)               -- super.pushJavaObjectRaw(v)
  local u = newproxy(true)
  getmetatable(u).__gc = function()
    st.count = st.count - 1
    if st.count == 0 then
      zeros = zeros + 1
      if st.inside then hits = hits + 1 end
    end
  end
  return u
end
local keep = {}
for trial = 1, 3000 do
  local st = {count = 0, inside = false}
  local u1 = push(st); st.count = st.count + 1   -- first push, counted
  u1 = nil                                       -- its proxy died; userdata now garbage
  for i = 1, (trial % 61) do local t = {i, i, i} end   -- collector progresses
  st.inside = true
  if mode == "before" then st.count = st.count + 1 end
  local u2 = push(st)                            -- re-push of the SAME Value
  if mode == "after" then st.count = st.count + 1 end
  st.inside = false
  keep[trial % 8 + 1] = u2                       -- u2 stays live a while
end
print(mode, arg[2] or "default", "re-pushes where the count hit 0 inside super.push:", hits, " total zero-crossings:", zeros)
