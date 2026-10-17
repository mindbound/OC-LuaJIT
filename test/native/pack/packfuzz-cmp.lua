-- test/native/pack/packfuzz-cmp.lua -- compare a PUC 5.3.6 run and an "ours"
-- run of packfuzz.lua (test/native/run-packfuzz.sh runs it under PUC)
--
--   lua packfuzz-cmp.lua <puc-file> <ours-file> [max-examples-per-class]
--
-- Every line pair is one of:
--   EXACT       the canonical results are byte-identical
--   DEVIATION   differs ONLY as a decided deviation allows:
--                 round53       PUC's integer, converted to the nearest
--                               double, equals ours (R<int>~<double> tokens)
--               ('l'/'L' = 8 needs no rule here: the PUC side runs 'l' as
--                "i8", so a 4-byte 'l' on our side is an ordinary MISMATCH.
--                An unpack s[n] whose length makes 5.3.6's check wrap
--                (lstrlib.c:1518) needs none either: ours raises 5.3.6's own
--                "memory allocation error: block too big" there.)
--   SECONDARY   the unpack of a pack result whose pack line already differed
--   MISMATCH    anything else, INCLUDING a different error message: the
--               message names the check that refused (and the argument
--               number), so a wrong-reason refusal is a different
--               implementation even when both sides refuse.  Only the
--               function name inside "bad argument #n to '...'" is
--               normalised (it depends on the call path, not on pack).
--
-- exit 0  no MISMATCH and the two files describe the same cases
-- exit 1  MISMATCH, or the ours file ended early (a CRASH): at a case
--         boundary, before its closing #cov/#ops/#end lines, or mid-line
--         (its last line has no newline; packfuzz.lua ends every line with
--         one and closes the file, so only a run that died leaves that)
-- exit 2  the instrument failed: unreadable files, desynchronised case
--         streams, wrong sides, an unfinished reference, or a coverage hole
--         (an option never ran ok)

local PF, OF, MAXEX = ...
MAXEX = tonumber(MAXEX) or 3
if not PF or not OF then io.stderr:write("usage: packfuzz-cmp.lua <puc> <ours> [maxex]\n"); os.exit(2) end
local function die(code, msg) io.stdout:write("packfuzz-cmp: ", msg, "\n"); os.exit(code) end
local fp = io.open(PF, "rb") or die(2, "cannot open " .. PF)
local fo = io.open(OF, "rb") or die(2, "cannot open " .. OF)

local function parse(line)
  local id, kind, op, desc, res = line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
  if not id then return nil end
  return { id = id, kind = kind, op = op, desc = desc, res = res }
end
local function meta(line, t)
  local tag = line:match("^#(%a+)")
  if tag then t[tag] = line end
end

local counts = { EXACT = 0, DEVIATION = 0, SECONDARY = 0, MISMATCH = 0 }
local devs, classes, order = {}, {}, {}
local mpack = {}           -- case ids whose pack line mismatched
local firstmis, firstrand
local nlines = 0
local pm, om = {}, {}
local lastours

local function shape(res)
  if res:sub(1, 3) == "ok " then return "ok" end
  if res == "skip" then return "skip" end
  return (res:gsub("%d+", "N"))
end
local function okdiff(op, a, b)
  local ta, tb = {}, {}
  for w in a:gmatch("%S+") do ta[#ta + 1] = w end
  for w in b:gmatch("%S+") do tb[#tb + 1] = w end
  if #ta ~= #tb then return "ok/ok: " .. #ta - 1 .. " vs " .. #tb - 1 .. " values" end
  for i = 2, #ta do
    if ta[i] ~= tb[i] then
      local function cls(w)
        if w:match("^s%d") then return "str" elseif w:match("^R") then return "R-int" end
        return "num"
      end
      local last = (op == "unpack" and i == #ta) and " (the next-position value)" or ""
      return "ok/ok: value " .. (i - 1) .. " " .. cls(ta[i]) .. " vs " .. cls(tb[i]) .. last
    end
  end
  return "ok/ok: ?"
end

local function classify(p, o)
  if p.res == o.res then return "EXACT" end
  if p.res:find("R", 1, true) then
    local pr = p.res:gsub("R%-?%d+~(%S+)", "%1")
    if pr == o.res then return "DEVIATION", "round53" end
  end
  local base = p.id:match("^(%d+)%a$")
  if p.op == "unpack" and p.desc:find(" d=packed", 1, true) and base and mpack[base] then
    return "SECONDARY"
  end
  local key
  if p.res:sub(1, 3) == "ok " and o.res:sub(1, 3) == "ok " then key = p.op .. " | " .. okdiff(p.op, p.res, o.res)
  else key = p.op .. " | puc " .. shape(p.res) .. " | ours " .. shape(o.res) end
  return "MISMATCH", key
end

-- ours is read with "L" (the line and its newline; PUC 5.3 has it), so a
-- last line cut before its newline is told apart from a whole one
local function readours()
  local l = fo:read("L")
  if l == nil then return nil, false end
  if l:sub(-1) ~= "\n" then return l, true end
  return l:sub(1, -2), false
end

-- ours ended early (the host died or the script raised): ONE CRASH, at the
-- puc line ours never reached.  The rest of the puc file is then drained for
-- its closing #cov/#ops/#end lines, so the reference is still judged
-- finished (or not) by its own #end line.
local crashed, uncompared = false, 0
local function crash(lp, how, oursline)
  local ismeta = (lp:sub(1, 1) == "#")
  local p = (not ismeta) and parse(lp) or nil
  local where = ismeta and ("its " .. (lp:match("^#%a+") or "#?") .. " line") or ("case " .. (p and p.id or "?"))
  counts.MISMATCH = counts.MISMATCH + 1
  local key = "CRASH | ours output " .. how .. " " .. where
  classes[key] = { n = 1, kinds = {}, ex = { { lp, oursline } } }
  order[#order + 1] = key
  firstmis = firstmis or (p and p.id) or where
  if p and not firstrand then firstrand = tonumber(p.id:match("^(%d+)%a$")) end
  crashed = true
  if ismeta then meta(lp, pm) else uncompared = 1 end
  for l in fp:lines() do
    if l:sub(1, 1) == "#" then meta(l, pm) else uncompared = uncompared + 1 end
  end
end

while true do
  local lp = fp:read("*l")
  local lo, cut = readours()
  if not lp and not lo then break end
  if not lp then
    die(2, "puc file ended before ours (" .. tostring(lo) .. ")")
  elseif not lo then
    crash(lp, "ends before", "(no line: ours output ended; last ours line: " .. tostring(lastours) .. ")")
    break
  elseif cut then
    crash(lp, "ends mid-line at", lo .. "   (no newline: the ours file was cut here)")
    break
  elseif lp:sub(1, 1) == "#" then
    meta(lp, pm)
    if lo:sub(1, 1) ~= "#" then die(2, "desync: puc has meta line '" .. lp .. "', ours has '" .. lo .. "'") end
    meta(lo, om)
  else
    local p, o = parse(lp), parse(lo)
    if not p or not o then die(2, "unparseable line:\n  " .. lp .. "\n  " .. lo) end
    if p.id ~= o.id or p.kind ~= o.kind or p.op ~= o.op or p.desc ~= o.desc then
      die(2, "desync (the generator drew different cases on the two VMs):\n  puc:  " .. lp .. "\n  ours: " .. lo)
    end
    lastours = lo
    nlines = nlines + 1
    local c, sub = classify(p, o)
    counts[c] = counts[c] + 1
    if c == "DEVIATION" then devs[sub] = (devs[sub] or 0) + 1
    elseif c == "MISMATCH" then
      if p.op == "pack" then local b = p.id:match("^(%d+)%a$"); if b then mpack[b] = true end end
      firstmis = firstmis or p.id
      if not firstrand then firstrand = tonumber(p.id:match("^(%d+)%a$")) end
      local cl = classes[sub]
      if not cl then cl = { n = 0, kinds = {}, ex = {} }; classes[sub] = cl; order[#order + 1] = sub end
      cl.n = cl.n + 1
      cl.kinds[p.kind] = (cl.kinds[p.kind] or 0) + 1
      if #cl.ex < MAXEX then cl.ex[#cl.ex + 1] = { lp, lo } end
    end
  end
end

-- the instrument's own checks
if not pm.begin or not om.begin then die(2, "missing #begin line") end
if not pm.begin:find("side=puc", 1, true) then die(2, "first file is not side=puc: " .. pm.begin) end
if not om.begin:find("side=ours", 1, true) then die(2, "second file is not side=ours: " .. om.begin) end
local function strip(b) return (b:gsub(" side=%S+", ""):gsub(" vm=.*$", "")) end
if strip(pm.begin) ~= strip(om.begin) then die(2, "different runs: " .. pm.begin .. " / " .. om.begin) end
if nlines == 0 and not crashed then die(2, "no cases compared") end
local profile = pm.begin:match("profile=(%S+)") or "?"
local ncases = tonumber(pm.begin:match(" n=(%d+)") or "0")
local function secs(m) return m and tonumber(m:match("secs=([%d.]+)")) end
local ps, os_ = secs(pm["end"]), secs(om["end"])

io.stdout:write(pm.begin:gsub("^#begin side=puc ", "packfuzz-cmp: "), "\n")
io.stdout:write(string.format("  lines %d: EXACT %d, DEVIATION %d, SECONDARY %d, MISMATCH %d\n",
  nlines, counts.EXACT, counts.DEVIATION, counts.SECONDARY, counts.MISMATCH))
local dl = {}
for k, v in pairs(devs) do dl[#dl + 1] = k .. " " .. v end
table.sort(dl)
if #dl > 0 then io.stdout:write("  deviations: ", table.concat(dl, ", "), "\n") end
if crashed then io.stdout:write("  ours ended early: ", uncompared, " puc case line(s) from the CRASH on were not compared\n") end
if ps and os_ and ncases > 0 then
  io.stdout:write(string.format("  generator+calls: puc %.2f s (%.0f cases/s), ours %.2f s (%.0f cases/s)\n",
    ps, ncases / math.max(ps, 1e-3), os_, ncases / math.max(os_, 1e-3)))
end
if pm.ops then io.stdout:write("  puc  ", pm.ops:sub(2), "\n") end
if om.ops then io.stdout:write("  ours ", om.ops:sub(2), "\n") end
if pm.cov then io.stdout:write("  puc  ", pm.cov:sub(2), "\n") end

-- coverage gate: on a run big enough to expect it, every option character
-- must have run successfully at least once on the reference side
local hole
if pm.cov and (profile == "default" or profile == "long") and ncases >= 500 then
  for name, n in pm.cov:gmatch("(%S+)=(%d+)") do
    if tonumber(n) == 0 then hole = (hole and hole .. " " or "") .. name end
  end
end
-- an unfinished run: the reference's is an instrument failure (exit 2 below);
-- ours is a CRASH (the host died or the script raised) unless already listed
-- (the loop lists it whenever the puc file goes on past ours' last line)
if not om["end"] and not crashed then
  counts.MISMATCH = counts.MISMATCH + 1
  local key = "CRASH | the ours run has no #end line (host died or the script raised)"
  classes[key] = { n = 1, kinds = {}, ex = {} }
  order[#order + 1] = key
end
local unfinished = not pm["end"]

if counts.MISMATCH > 0 then
  io.stdout:write(string.format("  first MISMATCH at %s; first in a random case: %s\n", tostring(firstmis), tostring(firstrand)))
  table.sort(order, function(a, b) return classes[a].n > classes[b].n end)
  io.stdout:write("MISMATCH classes (" .. #order .. "):\n")
  for _, k in ipairs(order) do
    local cl = classes[k]
    local kl = {}
    for kk, vv in pairs(cl.kinds) do kl[#kl + 1] = kk .. "=" .. vv end
    table.sort(kl)
    io.stdout:write(string.format("  [%d] %s   {%s}\n", cl.n, k, table.concat(kl, " ")))
    for _, e in ipairs(cl.ex) do
      io.stdout:write("      puc:  ", e[1], "\n      ours: ", e[2], "\n")
    end
  end
end
if unfinished then die(2, "the puc run did not finish (no #end line): the reference or the generator failed") end
if hole then die(2, "coverage hole: no successful call ever used option(s): " .. hole) end
if counts.MISMATCH > 0 then os.exit(1) end
os.exit(0)
