# mklend2.py -- the sketch of mklend.py, refined: lend every crossing until the
# cycle the first one armed is PROVEN, up to LEND_MAX bytes in all (a table and
# its hash part are two allocator calls with no checkpoint between).
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, newline="").read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new, 1)
rep("  int           gc_canlend;    /* SKETCH: one crossing may be lent            */",
    "  int           gc_canlend;    /* SKETCH: crossings may be lent               */\n  long long     gc_lentbytes;  /* SKETCH: lent since the last proof           */")
rep("  if (!M->gc_canlend || delta > LJ52_GC_LENDMAX || M->L == NULL || total <= 0) return 0;",
    "  if (!M->gc_canlend || M->gc_lentbytes + delta > LJ52_GC_LENDMAX || M->L == NULL || total <= 0) return 0;")
rep("  M->gc_canlend = 0;\n  if (M->gc_armed) M->gc_armby = LJ52_ARM_WALL;",
    "  M->gc_lentbytes += delta;\n  if (M->gc_armed) M->gc_armby = LJ52_ARM_WALL;")
rep("      M->gc_canlend = used <= total +", "      M->gc_lentbytes = 0;\n      M->gc_canlend = used <= total +")
open(dst, "w", newline="").write(s)
print("ok")
