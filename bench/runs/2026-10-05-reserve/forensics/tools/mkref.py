# mkref.py <repo lj52shim.c> <out lj52shim.c>
# Make the REFUSAL-FORENSICS copy of lj52shim.c (THE WINDOW, 3186e87).
# The approach of the design round's mkinstr.py/mkring.py: anchored splices,
# each asserted to match exactly once, no branch of the shim's logic changed.
# What is added:
#   - the record types (frag_types.c), before the lj52_mem struct;
#   - oc_* fields at the END of lj52_mem (frag_fields.c);
#   - prototypes after the struct (frag_protos.c);
#   - oclj_ref_pre/post around BOTH calls into lj52_gc_refused (C mode, legacy);
#   - oclj_arm_note at the end of lj52_gc_arm;
#   - oclj_prf_pre/post at the top and end of lj52_gc_pressure's proof branch;
#   - oclj_ref_init after M->L is set in lj52_newstate;
#   - the hook definitions (frag_hooks.c) just before THE FLUSH.
# Python writes with newline="" (no CRLF); the output is checked for CRs.
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", newline="") as f:
    s = f.read()
assert "\r" not in s, "source has CRs"


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

assert "\r" not in s
with open(dst, "w", newline="") as f:
    f.write(s)
print("wrote %s (%d bytes, %d lines)" % (dst, len(s), s.count("\n")))
