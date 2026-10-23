"""ffnegctl.py <fresh dest>: a scratch copy of round/repo's test/native at
<dest>/test/native with two mutations, for one negctl-bitop.sh call that
must fail twice: (1) cseir.lua's compiled results doctored (impl-tests'
ir-doctor text: a JIT run appends "9" to every result), so canon, whose
catcher list now holds cse, must FAIL with cseir failing; (2) CSEFWD's
catchers changed from 'cse:t_csefwd cse:cseir' to 'nc:t_numconv', a check
that cannot see it, so the arm must read NOT CAUGHT.  Each mutation replaces
an exact text that occurs exactly once.  Writes bytes.  No backslashes."""
import os
import shutil
import sys

SRC = "C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/test/native"
dest = sys.argv[1]
if os.path.exists(dest):
    sys.exit("REFUSING: " + dest + " exists")
T = os.path.join(dest, "test", "native")
shutil.copytree(SRC, T)
MUT = [
    ("bitop/cseir.lua",
     '  local line = C.name .. TAB .. "r=" .. table.concat(d, ",")',
     '  local line = C.name .. TAB .. "r=" .. table.concat(d, ",") .. (LIB and "9" or "")'),
    ("negctl-bitop.sh",
     "arm CSEFWD lj_opt_fold.c 'cse:t_csefwd cse:cseir'",
     "arm CSEFWD lj_opt_fold.c 'nc:t_numconv'"),
]
for rel, old, new in MUT:
    p = os.path.join(T, rel)
    t = open(p, "rb").read().decode("utf-8")
    assert t.count(old) == 1, rel + ": " + str(t.count(old))
    with open(p, "wb") as f:
        f.write(t.replace(old, new).encode("utf-8"))
    print("mutated", rel)
