"""t4-tree.py <fresh dest>: T4's census tree, a scratch copy of round/repo's
test/native at <dest>/test/native whose run-bitjit.sh option lists each
hold the default and at least two side-trace sets (he1 = -Ohotloop=1
-Ohotexit=1, ts1 = -Otryside=1 -Ohotexit=2), never shipped:
  GENOPTS  (gen)            + ts1        (it had jon and he1)
  RECOPTS  (t_rec)          + he1 ts1    (it had jon, hl1, ms0)
  JIT2OPTS (t_jit2, t_rg2)  + ts1        (it had jon and he1)
  IDXOPTS  (idx)            + ts1x       (ts1's flags under another name:
           SELOPTS, which sel and nc run, begins with IDXOPTS and already
           holds ts1, so they run those flags twice; NCIROPTS has he1, ts1)
Every other line is unchanged; each replaced text occurs exactly once.
Writes bytes.  No backslashes."""
import os
import shutil
import sys

SRC = "C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/test/native"
dest = sys.argv[1]
if os.path.exists(dest):
    sys.exit("REFUSING: " + dest + " exists")
T = os.path.join(dest, "test", "native")
shutil.copytree(SRC, T)
p = os.path.join(T, "run-bitjit.sh")
t = open(p, "rb").read().decode("utf-8")
Q = chr(34)
HE1 = "he1:-Ohotloop=1_-Ohotexit=1"
TS1 = "ts1:-Otryside=1_-Ohotexit=2"
MUT = [
    ("GENOPTS=" + Q + "jon hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0 " + HE1 + " noloop:-O3_-O-loop" + Q,
     "GENOPTS=" + Q + "jon hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0 " + HE1 + " noloop:-O3_-O-loop " + TS1 + Q),
    ("RECOPTS=" + Q + "jon hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0" + Q,
     "RECOPTS=" + Q + "jon hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0 " + HE1 + " " + TS1 + Q),
    ("JIT2OPTS=" + Q + "jon O0:-O0 O1:-O1 hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0 " + HE1 + Q,
     "JIT2OPTS=" + Q + "jon O0:-O0 O1:-O1 hl1:-O3_-Ohotloop=1 ms0:-Omaxside=0 " + HE1 + " " + TS1 + Q),
    (" nocse:-O3_-O-cse" + Q + chr(10),
     " nocse:-O3_-O-cse ts1x:-Otryside=1_-Ohotexit=2" + Q + chr(10)),
]
for old, new in MUT:
    assert t.count(old) == 1, old + ": " + str(t.count(old))
    t = t.replace(old, new)
assert t.count("ts1x:") == 1
with open(p, "wb") as f:
    f.write(t.encode("utf-8"))
print("census tree written:", T)
