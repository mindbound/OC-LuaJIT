-- test/native/bitop/reword.lua -- a filter, stdin to stdout: Lua 5.3.6's word
-- order of the bitwise type error to LuaJIT's, and CRLF to LF.  Nothing else
-- changes.
--   "attempt to perform bitwise operation on a table value (local 't')"
--   -> "attempt to perform bitwise operation on local 't' (a table value)"
-- LuaJIT names the operand before the type in every operator error
-- (LJ_ERR_BADOPRT, lj_errmsg.h); round 3 keeps that shape with 5.3's verb
-- (U5, decided 2026-10-17), so the .expect files carry LuaJIT's order and
-- run-bitop.sh part 2 rewords PUC's output with this before comparing.  The
-- other two messages ("number (local 'x') has no integer representation" and
-- "result of '>>' has more than 53 significant bits (mask each operand to 32
-- bits first)", X's text on PUC) read the same on both.
-- Runs on luajit.exe or any Lua 5.1-5.3; prints the count to stderr.
local s = io.read("*a")
s = s:gsub(string.char(13, 10), string.char(10))
local n
s, n = s:gsub("attempt to perform bitwise operation on a (%a+) value %((%a+) '([^']*)'%)",
  "attempt to perform bitwise operation on %2 '%3' (a %1 value)")
io.write(s)
io.stderr:write("reword.lua: ", n, " messages reworded\n")
