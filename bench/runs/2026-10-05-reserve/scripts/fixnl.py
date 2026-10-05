import sys
p = "C:/Users/astro/Downloads/OC-LuaJIT/test/native/OcljSmoke.scala"
s = open(p, encoding="utf-8", newline="").read()
broken = '      |        io.stderr:write(tb, "\n")\n'
fixed = '      |        io.stderr:write(tb, "\\n")\n'
n = s.count(broken)
assert n == 1, ("broken occurrences", n)
s = s.replace(broken, fixed, 1)
open(p, "w", encoding="utf-8", newline="").write(s)
# re-extract the probe and parse it
i = s.index("val CapacityAutorunLua: String =")
j = s.index('""".stripMargin', i)
body = s[s.index('"""', i) + 3 : j]
lines = []
for ln in body.split("\n"):
    k = ln.find("|")
    lines.append(ln[k+1:] if k >= 0 else ln)
lua = "\n".join(lines).replace("%%SHAPE%%", "record").replace("%%BATCH%%", "10").replace("%%JUNK%%", "24").replace("%%RECOVER%%", "1")
open("C:/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/R/probe-extract2.lua", "w", newline="").write(lua)
print("fixed; CRs:", s.count("\r"))
