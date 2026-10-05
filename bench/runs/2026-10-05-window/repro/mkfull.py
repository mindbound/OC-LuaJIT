# mkfull.py -- a third instrumented copy (from mkinstr.py's output): a FULL
# log of every C-mode allocator call's delta (frees negative), for the PUC-like
# model on LuaJIT's own trajectory.  Logic unchanged.  Repo untouched.
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, newline="").read()
DECL = """
/* ---- REPRO FULL LOG (not in the repo) ---- */
long long *oclj_log = 0;
long long oclj_logcap = 0, oclj_logn = 0;
"""
anchor = "/* ---- REPRO INSTRUMENT (not in the repo) ---- */"
assert s.count(anchor) == 1
s = s.replace(anchor, DECL + anchor, 1)
old = """  if (M->csync) {
    int acct = M->accounting && M->total > 0;"""
new = """  if (M->csync) {
    int acct = M->accounting && M->total > 0;
    if (acct && oclj_log && oclj_logn < oclj_logcap) oclj_log[oclj_logn++] = delta;"""
assert s.count(old) == 1
s = s.replace(old, new, 1)
open(dst, "w", newline="").write(s)
print("ok")
