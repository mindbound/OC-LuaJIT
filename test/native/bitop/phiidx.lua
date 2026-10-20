-- test/native/bitop/phiidx.lua -- the table-index fold never crosses a PHI,
-- read from the compiled traces.  The fold (native/luajit/patch-bitop-fold.sh,
-- hunk 11, simplify_conv_int_num) builds CONV int.i64 y on fleft->op1, so it
-- refuses a PHI-marked fleft: in the loop copy that op1 is a pre-roll ref.
-- Crossing anyway computes the right values (loop_unroll's "extra PHI for a
-- CONV hint" PHI-marks the pre-roll y, measured 2026-10-20 by proto-folda:
-- the PHIIDX sabotage passes t_idx, t_cnt33 and the generator), so no
-- differential test can see it; this one reads the IR.  It is also the
-- fold's p4v.lua: each loop must compile (a trace stops in the loop's
-- function, no "persistent type instability" abort, the FORL becomes JFORL)
-- and its result must equal -joff's (test/native/run-bitjit.sh, part idx,
-- compares the acc= field).  Written by proto-folda (2026-10-20).
--
--   luajit phiidx.lua          (LUA_PATH must reach the build's src/jit/vmdef.lua)
--
-- In each completed trace of the loop's function that has a LOOP, it counts
-- in the loop body (after LOOP):
--   fold   CONV int.i64 (mode 0x275): the fold fired;
--   keep   CONV int.num (0x26e) of a PHI-marked pre-roll CONV num.i64: the
--          fold declined at the PHI, as it must;
--   cross  CONV int.i64 of a pre-roll y that a PHI-marked pre-roll CONV
--          num.i64 converts: the fold crossed the PHI;
-- and in the pre-roll, crossp: a PHI-marked CONV int.i64, which a crossing
-- fold makes when its result commons with the pre-roll's own fold.
-- Each variant states what it needs (NEED); cross and crossp must be 0 in
-- all.  ctl, ctl1 and crc need fold >= 1: if no variant folds, the build has
-- no fold to check and the run says INSTRUMENT (exit 2), as on round 3's
-- build.  ctl's and crc's body fold is the loop copy re-emitting the
-- pre-roll's already-folded CONV int.i64, so the rule never runs in their
-- loop copy; ctl1's key e + 1 is narrowed, whose leaf the pre-roll emits raw
-- (narrow_conv_emit), so its body fold is the rule firing in the loop copy
-- itself, and a fold that never fires there (NOLOOPFOLD) leaves its fold at
-- 0 (verify-folda F3; crc/combine, 2026-10-20).  Every CONV int.i64 (mode
-- op2 % 1024 = 0x275) counts as the fold's, because nothing these loops run
-- emits another one.  string.buffer's #buf records a NONE-mode one (0x1275,
-- recff_sbufx_len, which this build keeps), which this count would take for
-- the fold's, and no variant uses string.buffer; the prototyped range guard,
-- rg2, emitted one too, and did not ship (2026-10-20).  An instrument shared
-- by two rules must key its count on operands, or the full op2, too.
--
-- Prints, per variant,
--   <variant>\tacc=<acc>\ttraces=<n> typeins=<n> loop=<FORL|JFORL|IFORL> fold=<n> keep=<n> cross=<n> crossp=<n> <ok|FAILED>
-- and with -joff "<variant>\tacc=<acc>\t-".  Exit 0 every variant ok (or the
-- JIT off), 1 a variant FAILED, 2 the instrument is missing.
local VARIANTS = { "ctl", "ctl1", "crc", "phi", "phi2", "phicnt", "phiint" }
local BODY = {
  ctl    = "acc = acc + T[(i * 7) & 0xff]",
  ctl1   = "acc = acc + T[((i * 7) & 0x7f) + 1]",
  crc    = "acc = T[(acc ~ i) & 0xff] ~ (acc >> 8)",
  phi    = "acc = acc + T[ep]; ep = (i * 7) & 0xff",
  phi2   = "local e = (i * 7) & 0xff; acc = acc + T[e] + T[ep]; ep = e",
  phicnt = "acc = acc + (1 << ep); ep = (i * 3) & 31",
  phiint = "acc = acc + (T[ep] or 0); ep = i | 0",
}
local NEED = {  -- the counts each variant must reach
  ctl = { fold = 1 }, ctl1 = { fold = 1 }, crc = { fold = 1 },
  phi = { keep = 1 }, phi2 = { fold = 1, keep = 1 }, phicnt = { keep = 1 },
  phiint = { keep = 1 },
}
local hasjit = type(jit) == "table" and jit.status and jit.status()
local okv, vmdef = pcall(require, "jit.vmdef")
local oku, jutil = pcall(require, "jit.util")
local function instrument(msg) print("phiidx: INSTRUMENT: " .. msg); os.exit(2) end
if hasjit and not (okv and oku) then instrument("no jit.vmdef or jit.util (set LUA_PATH to the build's src/?.lua)") end
local TYPEINS, OPS = nil, {}
if okv then
  for code, msg in pairs(vmdef.traceerr) do
    if msg == "persistent type instability" then TYPEINS = code end
  end
  if not TYPEINS then instrument("jit.vmdef has no \"persistent type instability\" trace error") end
  for o = 0, #vmdef.irnames / 6 - 1 do
    OPS[(vmdef.irnames:sub(o * 6 + 1, o * 6 + 6):gsub(" +$", ""))] = o
  end
  if not (OPS.CONV and OPS.LOOP) then instrument("jit.vmdef names no CONV or LOOP IR op") end
end
local M_INTNUM, M_NUMI64, M_INTI64 = 622, 469, 629  -- (dst<<5)|src: INT 19, NUM 14, I64 21

-- The loop counts of trace tr (nil if it has no LOOP).
local function scan(tr)
  local nins = jutil.traceinfo(tr).nins
  local ir = {}
  local loop
  for ref = 1, nins do
    local _, ot, op1, op2 = jutil.traceir(tr, ref)
    if not ot then break end
    local o, t = math.floor(ot / 256), ot % 256
    ir[ref] = { o = o, phi = math.floor(t / 64) % 2 == 1, op1 = op1, mode = op2 % 1024 }
    if o == OPS.LOOP then loop = ref end
  end
  if not loop then return nil end
  local function isconv(r, mode) local x = ir[r]; return x and x.o == OPS.CONV and x.mode == mode end
  local phiy = {}  -- y converted by a PHI-marked pre-roll CONV num.i64
  local c = { fold = 0, keep = 0, cross = 0, crossp = 0 }
  for ref = 1, loop - 1 do
    local x = ir[ref]
    if isconv(ref, M_NUMI64) and x.phi then phiy[x.op1] = true end
    if isconv(ref, M_INTI64) and x.phi then c.crossp = c.crossp + 1 end
  end
  for ref = loop + 1, nins do
    local x = ir[ref]
    if isconv(ref, M_INTI64) then
      c.fold = c.fold + 1
      if x.op1 > 0 and x.op1 < loop and phiy[x.op1] then c.cross = c.cross + 1 end
    elseif isconv(ref, M_INTNUM) and x.op1 > 0 and x.op1 < loop and
           isconv(x.op1, M_NUMI64) and ir[x.op1].phi then
      c.keep = c.keep + 1
    end
  end
  return c
end

local cur, stops, typeins, cnt = nil, 0, 0, nil
if hasjit then
  jit.attach(function(what, tr, func, pc, code)
    if what == "stop" and func == cur then
      stops = stops + 1
      local c = scan(tr)
      if c then for k, v in pairs(c) do cnt[k] = cnt[k] + v end end
    elseif what == "abort" and code == TYPEINS then typeins = typeins + 1 end
  end, "trace")
end
-- The name of f's loop opcode (the only FORL family instruction in f).
local function loopop(f)
  for pc = 1, 10000 do
    local ins = jutil.funcbc(f, pc)
    if not ins then break end
    local op = ins % 256
    local name = vmdef.bcnames:sub(op * 6 + 1, op * 6 + 6):gsub(" +$", "")
    if name:match("FORL$") then return name end
  end
  return "none"
end

local T = {}
for k = 0, 255 do T[k] = (k * 2654435761) % 4294967296 end
local nbad, anyfold = 0, false
for _, v in ipairs(VARIANTS) do
  local f = assert(load([[
    local n, T = ...
    local acc, ep = 0, 0
    for i = 1, n do ]] .. BODY[v] .. [[ end
    return acc
  ]], "=phiidx-" .. v))
  cur, stops, typeins, cnt = f, 0, 0, { fold = 0, keep = 0, cross = 0, crossp = 0 }
  local a
  for _ = 1, 3 do a = f(100000, T) end
  cur = nil
  local line = string.format("%s\tacc=%.17g", v, a)
  if hasjit then
    local op = loopop(f)
    local ok = stops >= 1 and typeins == 0 and op == "JFORL" and cnt.cross == 0 and cnt.crossp == 0
    for k, need in pairs(NEED[v]) do if cnt[k] < need then ok = false end end
    if cnt.fold > 0 then anyfold = true end
    if not ok then nbad = nbad + 1 end
    line = line .. string.format("\ttraces=%d typeins=%d loop=%s fold=%d keep=%d cross=%d crossp=%d %s",
      stops, typeins, op, cnt.fold, cnt.keep, cnt.cross, cnt.crossp, ok and "ok" or "FAILED")
  else
    line = line .. "\t-"
  end
  print(line)
end
if hasjit then
  if not anyfold then instrument("no loop body holds a CONV int.i64: this build has no table-index fold to check") end
  print(string.format("phiidx: %d of %d variants compiled with the fold where it belongs and never across a PHI", #VARIANTS - nbad, #VARIANTS))
end
os.exit(nbad == 0 and 0 or 1)
