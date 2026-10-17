-- bench/oc/compat.lua -- 32-bit bit operations, PINNED and OBSERVABLE.
--
-- This is bench/compat.lua with one behavioural change, and the change is the
-- whole point of the file.
--
-- THE TRAP.  bench/compat.lua picks its implementation with
--     M.is_luajit = (type(jit) == "table")
-- and takes LuaJIT's `bit` library when that is true, PUC's native operators
-- when false.  Inside an OpenComputers sandbox `jit` is nil -- machine.lua
-- never exposes it -- so the same file silently takes the OTHER branch than it
-- takes standalone.  The two branches are not equivalent in cost: measured
-- 2.7x apart interpreted (1.206 s vs 0.442 s).  Left alone, an in-machine
-- number would have been compared against a standalone number computed by a
-- different implementation, and the difference would have been reported as a
-- property of the VM.
--
-- WHY OPERATORS AND NOT bit32.  The sandbox does provide bit32, and it is the
-- obvious choice -- and it is the wrong one for a benchmark.  Our shim
-- registers bit32 with luaL_register, so its entries are plain lua_CFunctions;
-- LuaJIT gives those ffid FF_C, which maps to recff_nyi, so the recorder
-- cannot inline them.  Every single bit32 call becomes a trace stitch: exit,
-- C call, re-enter.  Over a SHA-256 block that is >1000 stitches.  Measuring
-- that would be measuring our bit32 binding, not the compiler.
--
-- The operator branch compiles natively on our VM.  The vendored LuaJIT is a
-- fork with bitwise operator syntax (lj_parse.c maps `& | ~ << >>` to
-- BC_BAND/BOR/BXOR/BSHL/BSHR) and lj_record.c records those opcodes directly.
-- Measured: streaming sha256 at 0.053 s via operators against 0.050 s via
-- LuaJIT's own BitOp -- same digest, same order of magnitude, no stitching.
--
-- SO: probe for operator support once, take it when present, and RECORD WHICH
-- PATH WAS TAKEN so the results row can carry it.  A future build without
-- operator syntax degrades to bit32 -- slow but correct -- with a visible
-- marker, instead of failing to parse.
--
-- THE ROTATE MASKS ITS LEFT PIECE BEFORE THE `|`.  It is
--     (a >> n) | ((a << (32 - n)) & 0xFFFFFFFF)
-- and not the usual 5.3 idiom, ((a >> n) | (a << (32 - n))) & 0xFFFFFFFF,
-- whose `|` joins the two pieces into up to 64 - n significant bits before
-- the mask can drop them.  Since round 3 our fork computes 5.3's operators
-- on int64 and raises "result of '<op>' has more than 53 significant bits
-- (mask each operand to 32 bits first)" for a result no double holds
-- (README, "Lua dialect"), so the idiom raises for right rotations by 1-10:
-- at SHA-256's own counts 2, 6 and 7, for 82-99% of random words.  It
-- stopped sha256 on the first round-3 build, standalone and in-machine
-- alike, with "result of '|' has more than 53 significant bits" (that build
-- had no hint yet).  Masked first, both pieces stay below 2^32 and so does
-- their `|`.
-- Same digest as the idiom's on PUC 5.3.6 and 5.4 and on the round-2 32-bit
-- build, and the published one on round 3, JIT on and off (2026-10-17).

local M = {}

M.unpack = table.unpack or unpack

-- Probe rather than sniff the VM.  `load` returns nil on a syntax error, so
-- this asks the only question that matters -- "does this VM parse bitwise
-- operators" -- instead of inferring it from the presence of a global that
-- the sandbox strips.
local opsrc = [[
  return
    function(a, b) return (a & b) & 0xFFFFFFFF end,
    function(a, b) return (a | b) & 0xFFFFFFFF end,
    function(a, b) return (a ~ b) & 0xFFFFFFFF end,
    function(a) return (~a) & 0xFFFFFFFF end,
    function(a, n) return (a << n) & 0xFFFFFFFF end,
    function(a, n) return (a & 0xFFFFFFFF) >> n end,
    function(a, n)
      a = a & 0xFFFFFFFF
      if n == 0 then return a end
      return (a >> n) | ((a << (32 - n)) & 0xFFFFFFFF)
    end
]]

local ok, f = pcall(load, opsrc, "compat-bitops")
if ok and f then
  M.path = "operators"
  M.band, M.bor, M.bxor, M.bnot, M.lshift, M.rshift, M.rrotate = f()
elseif bit32 then
  -- Correct but slow on our VM: every call stitches the trace.  The marker is
  -- what stops a run taken on this path being compared with one taken on the
  -- other.
  M.path = "bit32-STITCHED"
  M.band, M.bor, M.bxor, M.bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
  M.lshift, M.rshift, M.rrotate = bit32.lshift, bit32.rshift, bit32.rrotate
else
  error("compat: no bitwise operators and no bit32 -- cannot run", 0)
end

-- tohex32: print 32-bit values only through this (or after norm()), because
-- LuaJIT's BitOp returns SIGNED values where PUC's masked ops return unsigned.
-- They are congruent mod 2^32, so sums agree, but raw prints would not.
function M.norm(x) return x % 4294967296 end
function M.tohex32(x) return string.format("%08x", x % 4294967296) end

return M
