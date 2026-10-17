-- test/native/bitop/bitfuzz-cmp.lua -- comparator for bitfuzz.lua (run it
-- under PUC 5.3.6).  Written by the round-3 "tests" investigator
-- (r3/tests/proto, 2026-10-17); U1-B's classes and the hot-U gate by role C2
-- of the round-3 implementation.
--
--   lua bitfuzz-cmp.lua <puc-file> <ours-file> [<ours-file> ...] [strict] [hotmin=<0..1>] [maxex=<n>]
--
-- Every tuple of every ours file, in each of its modes (K V P H U), must equal
-- the reference REF (PUC 5.3.6 with every bitwise result passed through U1-B's
-- rule: its double if exact, else "result of '<op>' has more than 53
-- significant bits (mask each operand to 32 bits first)").  Classes per tuple:
--   EXACT      REF == RAW: the rule plays no part, ours equals 5.3.6 itself
--   INEXACT    REF ~= RAW: an operator's result has more than 53 significant
--              bits, REF is E:INEXACT (bitfuzz.lua's X changes a result only
--              by raising), and the decided rule decides this tuple
--   MISMATCH   any mode differs from REF, or H's repetitions disagree
-- Errors compare by kind (INEXACT:<op>, NOINT, TYPE:<type>, LOAD,
-- OTHER:<text>); "strict" also compares the type error's verb ("bitwise
-- operation" vs LuaJIT's "arithmetic").
--
-- exit 0  no MISMATCH
-- exit 1  MISMATCH, or an ours file ended early (no #end: a crash).  Each
--         ours file is scanned for its #end line BEFORE any tuple is read:
--         a crash leaves the file cut wherever the C runtime last flushed
--         its buffer, often inside a T line, and a cut line read as a tuple
--         would end the run as desynchronised (2) or as a Lua error in this
--         comparator (review of 2026-10-17: 75 cuts of a JIT-on file at 4 KiB
--         steps gave 14 x 2 and 55 tracebacks).  A file without #end is
--         CRASH and is not compared; a T line with a missing field is a
--         mismatch, never an error here.
-- exit 2  the instrument failed: desynchronised files, PUC's minimal-paren
--         print differs from its full print, PUC's literal path differs from
--         its runtime path, or a JIT-on ours file compiled traces for fewer
--         than hotmin of its cases' H loops or of its U loops (H or U then
--         tested only the interpreter).  hotmin defaults to 0.25: under U1-B
--         the recorder aborts every trace whose recording iteration meets a
--         raising result (oclj_bitop_rec.c, LJ_TRERR_BADTYPE), and the
--         reference build r3/b/bB compiled 40-44% of the H loops and 51-53% of
--         the U loops over seeds 1-5; the same build with the recorder
--         refusing every bit operator compiled 5-7% and 5-6% (2026-10-17).
--         U1-A's prototype compiled 61%, which the old default of 0.5 suited.
local args = { ... }
local pucf, oursf, strict, hotmin, maxex = args[1], {}, false, 0.25, 3
for i = 2, #args do
  local a = args[i]
  if a == "strict" then strict = true
  elseif a:match("^hotmin=") then hotmin = tonumber(a:match("=(.*)"))
  elseif a:match("^maxex=") then maxex = tonumber(a:match("=(.*)"))
  else oursf[#oursf + 1] = a end
end
local function die(code, msg) print("bitfuzz-cmp: " .. msg); os.exit(code) end
if not pucf or #oursf == 0 then die(2, "usage: bitfuzz-cmp.lua <puc> <ours>...") end
if not hotmin then die(2, "hotmin= needs a number") end

local function split(line)
  local t = {}
  for f in (line .. "\t"):gmatch("([^\t]*)\t") do t[#t + 1] = f end
  return t
end
-- A missing field (nil) reads as "<missing>", which equals no result.
local function norm(r)
  if r == nil then return "<missing>" end
  if strict then return r end
  return (r:gsub("^(E:TYPE:%a+):%a+$", "%1"))
end
local function shape(r)
  if r == nil then return "<missing>" end
  if r:sub(1, 1) == "N" then return "num" end
  return (r:gsub("^(E:%a+).*$", "%1"))
end

-- read the PUC file once.  "ref=ours:<file>" instead takes ANOTHER ours run as
-- the reference, mode by mode (each mode against the same mode there): the
-- self-differential that shows which mode catches a one-line sabotage.
local selfref = pucf:match("^ref=ours:(.*)$")
local P, cases, pcov = {}, {}, nil
local instr = {}
for line in io.lines(selfref or pucf) do
  local k = line:sub(1, 1)
  if k == "C" then local f = split(line); cases[f[2]] = f[3]
  elseif k == "T" and selfref then
    local o = split(line)
    P[#P + 1] = { "T", o[2], "", o[4], o[4], o[4], o[4], modes = { K = o[3], V = o[4], P = o[5], H = o[6], U = o[7] } }
  elseif k == "T" then
    local f = split(line)
    P[#P + 1] = f
    if f[5] ~= f[6] and #instr < 5 then instr[#instr + 1] = "printer: " .. cases[f[2]:match("^(%d+)")] .. " RAW " .. f[5] .. " RAWMIN " .. f[6] end
    if f[4] ~= f[7] and #instr < 5 then instr[#instr + 1] = "literal path: " .. cases[f[2]:match("^(%d+)")] .. " [" .. f[3] .. "] REF " .. f[4] .. " REFK " .. f[7] end
  elseif line:match("^#end") then pcov = true end
end
if not pcov then die(2, "the PUC file has no #end: the reference did not finish") end
if #instr > 0 then die(2, "INSTRUMENT: PUC disagrees with itself (the generator's printer is wrong):\n  " .. table.concat(instr, "\n  ")) end

local nexact, ninex, nicomp, kinds = 0, 0, 0, {}
for _, f in ipairs(P) do
  if f[4] == f[5] then nexact = nexact + 1 else ninex = ninex + 1 end
  if f[4]:sub(1, 2) == "E:" and f[5]:sub(1, 1) == "N" then nicomp = nicomp + 1 end
  local s = shape(f[4]); kinds[s] = (kinds[s] or 0) + 1
end
local ks = {}
for s, n in pairs(kinds) do ks[#ks + 1] = s .. " " .. n end
table.sort(ks)
print(string.format("reference: %d tuples, EXACT %d, INEXACT %d (of them 5.3.6 computes a number: %d); REF results: %s (%s)",
  #P, nexact, ninex, nicomp, table.concat(ks, ", "), pucf))
-- X changes a result only by raising, so REF ~= RAW exactly where REF is
-- E:INEXACT; anything else means the reference's rule is not the rule.
if not selfref and ninex ~= (kinds["E:INEXACT"] or 0) then
  die(2, string.format("INSTRUMENT: %d tuples have REF ~= RAW but %d have REF E:INEXACT: the reference's X is not U1-B's rule",
    ninex, kinds["E:INEXACT"] or 0))
end

local worst = 0
local MODES = { "K", "V", "P", "H", "U" }
for _, of in ipairs(oursf) do
  -- #end first: a file that a crash cut is CRASH, and none of its lines is
  -- read as a tuple.
  local ended, nT = false, 0
  for line in io.lines(of) do
    if line:match("^#end") then ended = true elseif line:sub(1, 1) == "T" then nT = nT + 1 end
  end
  if not ended then
    print(string.format("%s: CRASH: no #end -- the run died (%d T lines, not compared)", of, nT))
    print("  => FAIL")
    worst = 1
    goto nextfile
  end
  local i, cov = 0, nil
  local nmis, nmisI, nmode, classes, order = 0, 0, {}, {}, {}
  for _, m in ipairs(MODES) do nmode[m] = 0 end
  for line in io.lines(of) do
    local k = line:sub(1, 1)
    if k == "T" then
      i = i + 1
      local o, p = split(line), P[i]
      if not p or o[2] ~= p[2] then die(2, of .. ": desynchronised at tuple " .. i .. " (" .. tostring(o[2]) .. " vs " .. tostring(p and p[2]) .. ")") end
      local bad = false
      for mi, m in ipairs(MODES) do
        local got = o[2 + mi]
        local ref = p.modes and p.modes[m] or p[4]
        if not (m == "U" and got == "-") and norm(got) ~= norm(ref) then
          bad = true; nmode[m] = nmode[m] + 1
          local key = m .. " " .. shape(ref) .. "->" .. shape(got)
          if not classes[key] then classes[key] = { n = 0, ex = {} }; order[#order + 1] = key end
          local c = classes[key]; c.n = c.n + 1
          if #c.ex < maxex then
            c.ex[#c.ex + 1] = string.format("%s  with [%s]  want %s (5.3.6 exact %s)  got %s",
              cases[p[2]:match("^(%d+)")], p[3], ref, p[5], got)
          end
        end
      end
      if o[8] ~= "-" then
        bad = true
        local key = "H drift (repetitions disagree)"
        if not classes[key] then classes[key] = { n = 0, ex = {} }; order[#order + 1] = key end
        local c = classes[key]; c.n = c.n + 1
        if #c.ex < maxex then c.ex[#c.ex + 1] = cases[p[2]:match("^(%d+)")] .. " [" .. p[3] .. "] last " .. tostring(o[6]) .. " vs " .. tostring(o[8]) end
      end
      if bad then nmis = nmis + 1; if p[4] ~= p[5] then nmisI = nmisI + 1 end end
    elseif line:match("^#cov") then cov = line end
  end
  local rc = 0
  local hc, nc, hu, nu = 0, 1, 0, 1
  if cov then
    hc, nc = cov:match("hotcases (%d+)/(%d+)"); hc, nc = tonumber(hc), tonumber(nc)
    hu, nu = cov:match("hotU (%d+)/(%d+)"); hu, nu = tonumber(hu), tonumber(nu)
  end
  print(string.format("%s: %d tuples, MISMATCH %d (of them INEXACT in the reference: %d); by mode K %d V %d P %d H %d U %d",
    of, i, nmis, nmisI, nmode.K, nmode.V, nmode.P, nmode.H, nmode.U))
  if cov then print("  " .. cov) end
  if i ~= #P then print("  INSTRUMENT: " .. i .. " tuples vs the reference's " .. #P); rc = 2
  elseif nmis > 0 then rc = 1
  elseif cov and cov:match("jit on") and (hc < hotmin * nc or hu < hotmin * nu) then
    print(string.format("  INSTRUMENT: traces compiled in %d of %d cases' H loops and %d of %d U loops (one is < %.0f%%): the JIT was barely tested",
      hc, nc, hu, nu, hotmin * 100)); rc = 2
  end
  if nmis > 0 then
    print("  MISMATCH classes (mode want->got: count):")
    table.sort(order, function(a, b) return classes[a].n > classes[b].n end)
    for _, key in ipairs(order) do
      print(string.format("    %-28s %d", key, classes[key].n))
      for _, e in ipairs(classes[key].ex) do print("        " .. e) end
    end
  end
  print("  => " .. (rc == 0 and "PASS" or rc == 1 and "FAIL" or "PROVED NOTHING"))
  if rc == 1 then worst = 1 elseif rc == 2 and worst == 0 then worst = 2 end
  ::nextfile::
end
os.exit(worst)
