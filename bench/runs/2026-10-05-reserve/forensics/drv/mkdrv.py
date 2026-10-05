# mkdrv.py <lj_repro.c> <lj_ref.c>
# The hermetic driver, unchanged in what it runs, plus (only when the
# environment variable OCLJ_REFLOG is set) one stderr line per probe event,
# in the same stream as the shim's OCLJREF| lines and wrapcp.c's OCLJCP|
# lines, so their order is the true order:
#   OCLJRUN| shape= off= base= cap=      before the kernel is called
#   OCLJEV|  code= count= batches= used=  every __rec (and the driver's code 5)
#   OCLJRING| n= cap=                    the shim's refusal ring at the end
# No Lua allocation is added: the lines are written from C.
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", newline="") as f:
    s = f.read()
assert "\r" not in s


def splice(s, anchor, new, what):
    n = s.count(anchor)
    assert n == 1, "%s: %d" % (what, n)
    return s.replace(anchor, new, 1)


s = splice(s, "static int LEGACY = 0;\n",
           "static int LEGACY = 0;\n"
           "static int REFLOG = 0;\n"
           "extern const void *oclj_refring(long long *n, int *cap);\n",
           "globals")
s = splice(s, "  e->code = code; e->count = (long long)lua_tointeger(L, 2); e->used = j_used(L); e->batches = (long long)lua_tointeger(L, 3);\n  fill_ref(e);\n",
           "  e->code = code; e->count = (long long)lua_tointeger(L, 2); e->used = j_used(L); e->batches = (long long)lua_tointeger(L, 3);\n  fill_ref(e);\n"
           "  if (REFLOG) { fprintf(stderr, \"OCLJEV| code=%d count=%lld batches=%lld used=%lld\\n\", code, e->count, e->batches, e->used); fflush(stderr); }\n",
           "c_rec")
s = splice(s, "  if (getenv(\"OCLJ_LEGACY\")) LEGACY = atoi(getenv(\"OCLJ_LEGACY\"));\n",
           "  if (getenv(\"OCLJ_LEGACY\")) LEGACY = atoi(getenv(\"OCLJ_LEGACY\"));\n"
           "  if (getenv(\"OCLJ_REFLOG\")) REFLOG = 1;\n",
           "main env")
s = splice(s, "      WS.total = (jint)cap; if (!LEGACY) lj52_mem_settotal(W, cap);\n      st = lua_pcall(W, 0, 0, 0);\n",
           "      WS.total = (jint)cap; if (!LEGACY) lj52_mem_settotal(W, cap);\n"
           "      if (REFLOG) { fprintf(stderr, \"OCLJRUN| shape=%s off=%ld base=%lld cap=%lld\\n\", shapes[si], off, base, cap); fflush(stderr); }\n"
           "      st = lua_pcall(W, 0, 0, 0);\n",
           "run start")
s = splice(s, "        e->code = 5; e->count = -1; e->batches = -1; e->used = j_used(W); fill_ref(e);\n",
           "        e->code = 5; e->count = -1; e->batches = -1; e->used = j_used(W); fill_ref(e);\n"
           "        if (REFLOG) { fprintf(stderr, \"OCLJEV| code=5 count=-1 batches=-1 used=%lld\\n\", e->used); fflush(stderr); }\n",
           "code 5")
s = splice(s, "      clear_javastate(W);\n      lua_close(W);\n",
           "      if (REFLOG) { long long rn; int rc; (void)oclj_refring(&rn, &rc); fprintf(stderr, \"OCLJRING| n=%lld cap=%d\\n\", rn, rc); fflush(stderr); }\n"
           "      clear_javastate(W);\n      lua_close(W);\n",
           "ring")
assert "\r" not in s
with open(dst, "w", newline="") as f:
    f.write(s)
print("wrote", dst)
