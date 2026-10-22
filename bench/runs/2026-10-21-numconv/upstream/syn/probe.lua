-- probe.lua: which LuaJIT 3.0 syntax backports a build accepts.  Each
-- case is compiled with load() (string source, chunk name "=c") and, when
-- it compiles, run under pcall; the line printed is the case name, then
-- "ok <results>" or "SYNTAX <message>" or "RUNTIME <message>".
local cases = {
  -- empty statements / semicolons anywhere (0218af7, after our pin)
  { "semicolon-stmt", "local a = 1;; ; return a" },
  { "return-double-semi", "return 1;;" },
  { "return-semi", "return 1;" },
  { "continue", "local s = 0 for i = 1, 5 do if i == 3 then continue end s = s + i end return s" },
  { "continue-semi", "local s = 0 for i = 1, 5 do if i == 3 then continue; end s = s + i end return s" },
  -- line number directive (c41d727, after our pin)
  { "linedir", "local x = 1\n# 100 \"foo.lua\"\nerror('here')" },
  { "linedir-nostr", "local x = 1\n# 200\nerror('here')" },
  { "linedir-first", "# 50\nerror('here')" },
  { "hash-first-line", "# a comment line\nreturn 1" },
  { "shebang-first-line", "#!/bin/lua\nreturn 1" },
  { "hash-length-line", "local t = {1, 2, 3}\nlocal n =\n#t\nreturn n" },
  { "hash-digit-line", "local n =\n#5\nreturn n" },
  -- backports already at our pin (1ee778a4), for reference
  { "continue-as-name", "local continue = 7 return continue" },
  { "const", "const x = 5 return x" },
  { "const-assign", "const x = 5 x = 6 return x" },
  { "const-as-name", "local const = 3 return const" },
  { "short-func", "local f = |a, b| -> a + b local g = x -> x * 2 return f(2, 3), g(4)" },
  { "underscore-num", "return 1_000_000" },
  { "ternary", "local a = 5 return a > 3 ? 'big' : 'small'" },
  { "nil-coalesce", "local a return a ?? 9" },
  { "safe-nav", "local t = {a = {b = 5}} return t?.a?.b, t?.x?.b" },
  { "customary-ops", "return !false, true && false, nil || 3, 1 != 2" },
  { "compound", "local a, s = 5, 'x' a += 2 s ..= 'y' return a, s" },
}
local function pk(...) return select('#', ...), {...} end
for _, c in ipairs(cases) do
  local f, err = load(c[2], "=c")
  local out
  if not f then
    out = "SYNTAX " .. tostring(err)
  else
    local n, r = pk(pcall(f))
    if r[1] then
      local t = {}
      for i = 2, n do t[#t + 1] = tostring(r[i]) end
      out = "ok " .. table.concat(t, " ")
    else
      out = "RUNTIME " .. tostring(r[2])
    end
  end
  print(c[1] .. ": " .. out)
end
