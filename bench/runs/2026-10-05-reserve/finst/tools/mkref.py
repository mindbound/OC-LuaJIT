# mkref.py <repo lj52shim.c> <out lj52shim.c>
# Make the REFUSAL-FORENSICS copy of lj52shim.c over THE RESERVE'S SIZE (the
# final native/lj52shim.c, md5 28a8f091).  The forensics' mkref.py
# (sc/forensics/tools, written for THE WINDOW's 9b912f60) with:
#   - the fragments of THIS directory (frag-from-forensics.py derives them from
#     the forensics' and says what changed: oclj_credit reads the tier through
#     lj52_gc_rsvcredit and the HOOK_VMEVENT guard; the OCLJREF line carries
#     rsv0= rsv= tier=; oclj_rsv_note prints OCLJXP| at the sizing);
#   - splice 9, new: oclj_rsv_note at the end of the sizing block in
#     lj52_gc_refused, after gc_rsv is set.
# Every one of the forensics' eight anchors still matches the final source
# exactly once (asserted below; none was changed).  The approach is the
# design round's: anchored splices, each asserted to match exactly once, no
# branch of the shim's logic changed.  What is added:
#   - the record types (frag_types.c), before the lj52_mem struct;
#   - oc_* fields at the END of lj52_mem (frag_fields.c);
#   - prototypes after the struct (frag_protos.c);
#   - oclj_ref_pre/post around BOTH calls into lj52_gc_refused (C mode, legacy);
#   - oclj_arm_note at the end of lj52_gc_arm;
#   - oclj_prf_pre/post at the top and end of lj52_gc_pressure's proof branch;
#   - oclj_ref_init after M->L is set in lj52_newstate;
#   - oclj_rsv_note at the sizing block (THE RESERVE'S SIZE);
#   - the hook definitions (frag_hooks.c) just before THE FLUSH.
# Python writes with newline="" (no CRLF); the output is checked for CRs.
import hashlib
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    raw = f.read()
print("source %s md5 %s" % (src, hashlib.md5(raw).hexdigest()))
s = raw.decode("utf-8")
assert "\r" not in s, "source has CRs"
assert "lj52_gc_rsvcredit" in s and "M->gc_rsv = over + LJ52_GC_RSV;" in s, \
    "not THE RESERVE'S SIZE's source: no lj52_gc_rsvcredit / sizing block"


def frag(name):
    with open(os.path.join(here, name), "r", newline="") as f:
        t = f.read()
    assert "\r" not in t, name
    return t


def splice(s, anchor, new, what):
    n = s.count(anchor)
    assert n == 1, "%s: anchor found %d times" % (what, n)
    return s.replace(anchor, new, 1)


# 1. types before the struct
a = "typedef struct lj52_mem {\n"
s = splice(s, a, frag("frag_types.c") + "\n" + a, "types")

# 2. fields at the end of the struct, 3. prototypes after it
a = "  long long     gc_flushbytes;    /* GCtrace metadata unlinked, cumulative    */\n} lj52_mem;\n"
s = splice(s, a,
           "  long long     gc_flushbytes;    /* GCtrace metadata unlinked, cumulative    */\n"
           + frag("frag_fields.c") + "} lj52_mem;\n" + frag("frag_protos.c"),
           "fields")

# 4a. the C-mode refusal
a = ("      M->gc_refdelta = delta;\n"
     "      lj52_gc_refused(M, M->total, M->used);\n"
     "      return NULL;                      /* -> lj_err_mem -> LUA_ERRMEM */\n")
s = splice(s, a,
           "      M->gc_refdelta = delta;\n"
           "      oclj_ref_pre(M, M->total, M->used, delta, 0);\n"
           "      lj52_gc_refused(M, M->total, M->used);\n"
           "      oclj_ref_post(M);\n"
           "      return NULL;                      /* -> lj_err_mem -> LUA_ERRMEM */\n",
           "C-mode refusal")

# 4b. the legacy refusal
a = ("    M->gc_refdelta = delta;\n"
     "    lj52_gc_refused(M, total, used);\n"
     "    return NULL;                        /* -> lj_err_mem -> LUA_ERRMEM */\n")
s = splice(s, a,
           "    M->gc_refdelta = delta;\n"
           "    oclj_ref_pre(M, total, used, delta, 1);\n"
           "    lj52_gc_refused(M, total, used);\n"
           "    oclj_ref_post(M);\n"
           "    return NULL;                        /* -> lj_err_mem -> LUA_ERRMEM */\n",
           "legacy refusal")

# 5. every arm
a = "  M->gc_armedcalls = 0;\n  M->gc_arms++;\n}\n"
s = splice(s, a, "  M->gc_armedcalls = 0;\n  M->gc_arms++;\n  oclj_arm_note(M, why);\n}\n", "arm")

# 6. every proof
a = "    if (g->gc.currentwhite != M->gc_white && g->gc.state == LJ52_GCS_PAUSE) {\n"
s = splice(s, a, a + "      oclj_prf_pre(M);\n", "proof top")
a = "        M->gc_flush_wanted = 1;\n    } else {\n"
s = splice(s, a, "        M->gc_flush_wanted = 1;\n      oclj_prf_post(M, total, used);\n    } else {\n",
           "proof end")

# 7. the switch, read once per state
a = "    M->L = L;                            /* the watchdog hooks this thread */\n"
s = splice(s, a, a + "    oclj_ref_init(M);\n", "newstate")

# 8. the hook definitions, after the collector and before THE FLUSH
a = "/* THE FLUSH, at the safe point.  Called by lj52_wd_arm on the Lua thread --\n"
s = splice(s, a, frag("frag_hooks.c") + a, "hooks")

# 9. THE RESERVE'S SIZE: the sizing block, after gc_rsv is set (lj52_gc_refused)
a = ("    M->gc_rsv = over + LJ52_GC_RSV;               /* clamped to G where it is read */\n"
     "  }\n"
     "  M->gc_odstate = LJ52_OD_RESERVE;\n")
s = splice(s, a,
           "    M->gc_rsv = over + LJ52_GC_RSV;               /* clamped to G where it is read */\n"
           "    oclj_rsv_note(M, total, used);\n"
           "  }\n"
           "  M->gc_odstate = LJ52_OD_RESERVE;\n",
           "sizing")

assert "\r" not in s
with open(dst, "w", newline="") as f:
    f.write(s)
with open(dst, "rb") as f:
    print("wrote %s (%d bytes, %d lines, md5 %s)" % (dst, len(s), s.count("\n"), hashlib.md5(f.read()).hexdigest()))
