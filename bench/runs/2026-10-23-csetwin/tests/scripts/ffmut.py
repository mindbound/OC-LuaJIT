# ffmut.py <case> <dest dir> -- a scratch copy of impl-tests' test/native
# (run-bitjit.sh and bitop/, the round's versions) at <dest>/test/native with
# one mutation, for fail-first runs of run-bitjit.sh's part cse.  Each
# mutation replaces an exact text that must occur exactly once in its file.
# No mutation writes a reverse-order case: the text-check mutations change
# the checks' search strings, never a case's text (the user's decision D2).
# Writes bytes (LF), refuses an existing <dest>.
import sys, os, shutil

T = "C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests"
NL = chr(10)
F, I, R = "bitop/t_csefwd.lua", "bitop/cseir.lua", "bitop/t_cserev.lua"
CALLS = '    calls[call] = fmt("n=%d bad=%d bbad=%d dig=%.17g bdig=%.17g", n, cb, cbb, dig(O, n), dig(BO, n)) ..'
MUT = {
    # t_csefwd's own reference wrong in one case: -joff exits 1
    "fwd-joffref": (F, 'src = iloop(1, c0("~i")),' + NL + '    ref = function(k) return -k - 1 end },',
                       'src = iloop(1, c0("~i")),' + NL + '    ref = function(k) return -k - 2 end },'),
    # t_csefwd's JIT output doctored (call 2 of every case): differs from -joff
    "fwd-doctor": (F, CALLS, CALLS.replace("calls[call] = fmt(", 'calls[call] = (LIB and call == 2 and "X" or "") .. fmt(')),
    # t_csefwd with the JIT switched off inside it: the coverage gate
    "fwd-jitoff": (F, "local MODE = ..." + NL, 'local MODE = ...; if jit and MODE ~= "cases" then jit.off() end' + NL),
    # t_csefwd's pairs never counted: the coverage gate
    "fwd-nopairs": (F, "if c.served + c.split > 0 then cov.pairs = cov.pairs + 1 end",
                       "if c.served + c.split > 999 then cov.pairs = cov.pairs + 1 end"),
    # t_csefwd's producer-first check cannot find a producer (its search string)
    "fwd-textcheck": (F, 'local pa, pc = C.src:find("local a = ", 1, true)',
                         'local pa, pc = C.src:find("local zz = ", 1, true)'),
    # cseir's compiled results doctored
    "ir-doctor": (I, '  local line = C.name .. TAB .. "r=" .. table.concat(d, ",")',
                     '  local line = C.name .. TAB .. "r=" .. table.concat(d, ",") .. (LIB and "9" or "")'),
    # cseir's summary line not printed
    "ir-nosummary": (I, '  print(fmt("cseir: %d of %d cases ok', '  local _ = (fmt("cseir: %d of %d cases ok'),
    # cseir told CSE is off: its refusal in every set
    "ir-nocse": (I, "  if not FLAG.cse then instrument(", "  FLAG.cse = nil" + NL + "  if not FLAG.cse then instrument("),
    # the reader never counts split (cseir, t_csefwd and t_cserev share it)
    "ir-nosplit": (I, "      if e[1] > 0 and e[2] > 0 then c.split = c.split + 1 end",
                      "      if false then c.split = c.split + 1 end"),
    # the reader's i64slot counts NUM refs instead (design 4.3's fail-first)
    "ir-numslot": (I, "if r > 0 and I[r] and I[r].t == I64 then c.i64slot = c.i64slot + 1 end",
                      "if r > 0 and I[r] and I[r].t == 14 then c.i64slot = c.i64slot + 1 end"),
    # the reader never counts served
    "ir-noserved": (I, "      return (x and x.t ~= I64 and KIND[x.o] and (x.o ~= OPS.ADD or x.r2 ~= nil)) and true or false",
                       "      return false"),
    # cseir never counts a judged pair: the runner's default-run gate
    "ir-nojudge": (I, "    if judged then njudged = njudged + 1 end", "    if judged then njudged = njudged + 0 end"),
    # t_cserev's compiled values doctored
    "rev-doctor": (R, '  local line = C.name .. TAB .. table.concat(calls, ";")',
                      '  local line = C.name .. TAB .. table.concat(calls, ";") .. (LIB and "9" or "")'),
    # t_cserev's -joff values doctored (LuaJIT with the JIT off only)
    "rev-joffdoctor": (R, '  local line = C.name .. TAB .. table.concat(calls, ";")',
                          '  local line = C.name .. TAB .. table.concat(calls, ";") .. ((jit and not LIB) and "9" or "")'),
    # t_cserev's PUC output doctored (no jit table there)
    "rev-pucdoctor": (R, '    line = line .. TAB .. "-"', '    line = line .. TAB .. (jit and "-" or "-x")'),
    # t_cserev's summary line not printed
    "rev-nosummary": (R, '  print(fmt("t_cserev: %d of %d cases ok', '  local _ = (fmt("t_cserev: %d of %d cases ok'),
    # t_cserev judges no reverse case (as if narrowing were off)
    "rev-nonarrow": (R, "  local needs = FLAG.fold and FLAG.cse and FLAG.narrow" + NL,
                        "  local needs = FLAG.fold and FLAG.cse and FLAG.narrow and false" + NL),
    # t_cserev's slot-shape check fires on its own string cases (its search string)
    "rev-textcheck": (R, 'if src:find("bit.", 1, true)', 'if src:find("string.", 1, true)'),
    # a missing suite file
    "nofile": (I, None, None),
}

def main():
    case, dest = sys.argv[1], sys.argv[2]
    if case not in MUT:
        print("unknown case; one of " + ", ".join(sorted(MUT)))
        return 1
    if os.path.exists(dest):
        print("REFUSING: %s exists" % dest)
        return 1
    tn = os.path.join(dest, "test", "native")
    os.makedirs(tn)
    shutil.copy2(os.path.join(T, "test/native/run-bitjit.sh"), tn)
    shutil.copytree(os.path.join(T, "test/native/bitop"), os.path.join(tn, "bitop"))
    fn, old, new = MUT[case]
    p = os.path.join(tn, fn)
    if old is None:
        os.remove(p)
        print("%s: removed %s" % (case, fn))
        return 0
    s = open(p, "rb").read().decode("latin-1")
    if s.count(old) != 1:
        print("REFUSED: %r occurs %d times in %s" % (old[:50], s.count(old), fn))
        return 1
    s = s.replace(old, new)
    with open(p, "wb") as f:
        f.write(s.encode("latin-1"))
    print("%s: %s mutated" % (case, fn))
    return 0

sys.exit(main())
