-- probe-diff.lua: differential test of string.format, compiled vs interpreted,
-- in ONE build.  Every case is generated as source and load()ed TWICE: fj runs
-- with the JIT on (hot loop, so most iterations run in a trace), fi runs with
-- jit.off(fi, true) (its prototype is never recorded; asserted).  Their output
-- arrays must be equal element by element.  The JIT side's trace verdict is
-- recorded per case (LOOP / STITCH / ABORT / NONE, as in probe-trace.lua), and
-- a hash of the JIT side's outputs is written to <outfile> so builds can be
-- compared with each other.
--   luajit probe-diff.lua <outfile>      (LUA_PATH must reach jit/*.lua)
local jutil = require("jit.util")
local vmdef = require("jit.vmdef")
local format = string.format
local OUTFILE = assert(arg[1], "usage: probe-diff.lua <outfile>")

-- trace events ----------------------------------------------------------------
local function fmterr(err, info)
  if type(err) == "number" then
    if type(info) == "function" then
      local fi = jutil.funcinfo(info)
      info = fi.loc or (fi.ffid and vmdef.ffnames[fi.ffid]) or "?"
    end
    local f = vmdef.traceerr[err]
    if f == "NYI: bytecode %s" then
      local oidx = 6 * info
      info = vmdef.bcnames:sub(oidx + 1, oidx + 6)
    end
    err = format(f, info)
  end
  return err
end
local EV
local function onTrace(what, tr, func, pc, otr, oex)
  if not EV then return end
  local e = { what = what, tr = tr }
  if what == "abort" then e.err = fmterr(otr, oex)
  elseif what == "stop" then e.linktype = jutil.traceinfo(tr).linktype end
  EV[#EV + 1] = e
end
jit.attach(onTrace, "trace")
local function verdict(ev)
  local started, loop, stitch, abort, why = 0, false, false, false, nil
  for _, e in ipairs(ev) do
    if e.what == "start" then started = started + 1
    elseif e.what == "stop" then
      if e.linktype == "stitch" then stitch = true end
      if e.linktype == "loop" then loop = true end
    elseif e.what == "abort" then abort = true; why = why or e.err end
  end
  if started == 0 then return "NONE", 0 end
  if stitch then return "STITCH", started end
  if abort then return "ABORT", started, why end
  if loop then return "LOOP", started end
  return "OTHER", started
end

-- the matrix ------------------------------------------------------------------
-- formats: { format, number of operands }
local FMTS = {}
local function add(list, n) for _, f in ipairs(list) do FMTS[#FMTS + 1] = { f, n or 1 } end end
add{ "%d", "%i", "%5d", "%-5d|", "%05d", "%+d", "% d", "%.3d", "%.0d", "%+.3d",
     "%-+8.3d|", "% 05d", "%+05i", "%99d", "%.99d" }
add{ "%u", "%5u", "%+u", "%x", "%X", "%02x", "%08X", "%#x", "%#X", "%#10x",
     "%-#10x|", "%.0x", "%#.0x", "%.5x", "%#.5x", "%o", "%#o", "%#.0o", "%.0o",
     "%5o", "%-8o|", "%#08x", "%+x", "% x", "%-05x|", "%#.3o", "%#99X" }
add{ "%c", "%5c", "%-3c|" }
add{ "%g", "%.3f", "%a", "%.14g" }
add({ "id=%d hex=%04x oct=%#o" }, 3)
add({ "%x%X%o%u%d%i%c" }, 7)

-- operand sources.  kind "int": expressions the recorder narrows to an int
-- (expected; probe-trace.lua and the noffi build's STITCH verdicts show which
-- really are).  kind "k": a constant in the loop body.  "tbl"/"str": a
-- number-/string-typed table load.
local SRC = {}
local function src(kind, name, expr, lo, hi) SRC[#SRC + 1] = { kind = kind, name = name, expr = expr, lo = lo, hi = hi } end
src("int", "i",            "i",                          -1000, 1000)
src("int", "lshift22",     "bit.lshift(i, 22)",          -1000, 1000)
src("int", "bxor7fff",     "bit.bxor(i, 0x7fffffff)",    -1000, 1000)
src("int", "bnot",         "bit.bnot(i)",                -1000, 1000)
src("int", "byte",         "sbyte(S, i % 256 + 1)",      -1000, 1000)
src("int", "neg",          "-i",                         -1000, 1000)
src("int", "mod7",         "i % 7 - 3",                  -1000, 1000)
src("int", "nearmax",      "i + 0x7ffffe00",             -1000, 1000)
src("int", "tobitmul",     "bit.tobit(i * 2654435761)",  -1000, 1000)
src("int", "len",          "#S - i",                     -1000, 1000)
for _, k in ipairs{ "0", "1", "-1", "255", "-255", "32767", "-32768", "100000",
                    "2147483647", "-2147483648", "4294967295", "4294967296",
                    "9007199254740993", "9223372036854775807", "-9223372036854775808",
                    "18446744073709551615", "1e300", "0.5", "-0.5", "-0.0", "0/0",
                    "1/0", "-1/0", "2^63", "-(2^63)", "2^64", "2^53+1" } do
  src("k", "k:" .. k, "(" .. k .. ")", 1, 600)
end
local V = { 0.5, -0.5, 1.5, -1.5, 2.5, 255.9, -255.9, -0.0, 0/0, -(0/0), 1/0, -1/0,
            2^31, 2^31 + 0.5, -2^31 - 1, 2^32, 2^32 - 1, -2^32, 2^53, 2^53 + 2, -2^53,
            2^62, 1.5 * 2^62, 2^63 - 1024, 2^63, -2^63, 2^63 + 2048, 1e19, 2^64 - 2048,
            2^64, -2^64, 1e300, -1e300, 5e-324, 4294967295.5, 0, 1, -1, 7, -7,
            2147483647, -2147483648 }
local SV = { "255", " 0x10 ", "1e2", "-7", "0x7fffffff", "  -0 ", "1e300", "2.5",
             "0x1p4", "-0x10", "4294967296", "9223372036854775808" }
src("tbl", "tbl", "V[(i - 1) % #V + 1]",  1, #V * 25)
src("str", "str", "SV[(i - 1) % #SV + 1]", 1, #SV * 60)

-- error cases: { format, argument list source }, run under pcall.  The last
-- two start with an int-typed operand, so the patched branch is recorded
-- before the bad operand is reached.
local ERRS = {
  { "%x", '"abc"' }, { "%x", "nil" }, { "%x", "{}" }, { "%x", "true" }, { "%x", "" },
  { "%5d", '"x"' }, { "%5d", '""' }, { "%x", '"inf"' }, { "%x", '"nan"' }, { "%x", '"1LL"' },
  { "%o", "print" }, { "%c", '"abc"' }, { "%y", "i" }, { "%100x", "i" }, { "%.100x", "i" },
  { "%", "i" }, { "%-", "i" }, { "%#5.3", "i" }, { "%x %x", "i, nil" }, { "%02x%5d", "i, {}" },
}

local HEAD = "local S, V, SV = ... local format, bit, sbyte = string.format, bit, string.byte local out, k = {}, 0 "
local function gen_ok(f, nargs, s)
  local args = {}
  for j = 1, nargs do args[j] = s.expr end
  return HEAD .. format("for i = %d, %d do k = k + 1 out[k] = format(%q, %s) end return out",
                        s.lo, s.hi, f, table.concat(args, ", "))
end
local function gen_err(f, a)
  return HEAD .. format("for i = 1, 600 do local ok, e = pcall(format, %q%s) k = k + 1 out[k] = tostring(ok) .. '|' .. tostring(e) end return out",
                        f, a == "" and "" or ", " .. a)
end

local S = {}
for b = 0, 255 do S[#S + 1] = string.char((b * 7 + 3) % 256) end
S = table.concat(S)

local function fnv(out)
  local h = -2128831035
  for k = 1, #out do
    local s = out[k]
    for j = 1, #s do
      h = bit.bxor(h, s:byte(j)); h = bit.tobit(bit.lshift(h, 24) + h * 403)
    end
    h = bit.tobit(bit.lshift(h, 24) + h * 403)  -- separator (byte 0)
  end
  return bit.tohex(h)
end

local keep, rows = {}, {}
local nmis, ncase, nfi_traced = 0, 0, 0
local tally = {}
local function run(id, kind, code)
  ncase = ncase + 1
  local fj = assert(load(code, "=" .. id))
  local fi = assert(load(code, "=" .. id))
  jit.off(fi, true)
  keep[#keep + 1] = fj; keep[#keep + 1] = fi
  EV = {}
  local oj = fj(S, V, SV)
  local evj = EV
  EV = {}
  local oi = fi(S, V, SV)
  local evi = EV
  EV = nil
  jit.flush()
  local v, nstart, why = verdict(evj)
  if #evi > 0 then nfi_traced = nfi_traced + 1 end
  local bad = (#oj ~= #oi) and -1 or nil
  if not bad then
    for k = 1, #oj do if oj[k] ~= oi[k] then bad = k; break end end
  end
  if bad then
    nmis = nmis + 1
    io.write(format("MISMATCH %s at %s: jit=%q interp=%q\n", id, tostring(bad),
                    tostring(oj[bad]), tostring(oi[bad])))
  end
  local key = kind .. " " .. v
  tally[key] = (tally[key] or 0) + 1
  rows[#rows + 1] = format("%s\t%s\t%s\t%d\t%s", id, v, fnv(oj), #oj, why or "")
end

for _, fm in ipairs(FMTS) do
  for _, s in ipairs(SRC) do
    run(format("%s @ %s", fm[1], s.name), s.kind, gen_ok(fm[1], fm[2], s))
  end
end
for _, e in ipairs(ERRS) do
  run(format("ERR %s (%s)", e[1], e[2]), "err", gen_err(e[1], e[2]))
end
jit.attach(onTrace)

local fh = assert(io.open(OUTFILE, "wb"))
fh:write(table.concat(rows, "\n"), "\n")
fh:close()
local keys = {}
for k in pairs(tally) do keys[#keys + 1] = k end
table.sort(keys)
io.write(format("%s: %d cases, %d mismatches, %d interpreted runs that traced (must be 0)\n",
                jit.version, ncase, nmis, nfi_traced))
for _, k in ipairs(keys) do io.write(format("  %-14s %d\n", k, tally[k])) end
