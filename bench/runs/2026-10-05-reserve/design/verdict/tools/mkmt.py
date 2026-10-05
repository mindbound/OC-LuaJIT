# mkmt.py <repo mem_test.c> <out mem_test_v.c>
# The repo's mem_test.c plus the verdict design's cases (tools/w20_cases.c),
# spliced in before M9; C6b re-scoped (the kernel's burst top is now
# T + G/2 + K + hold, WALLSTATS[18], 0 on a shim without THE ADDRESS); and
# W16/W16L sharpened: an INSIDE refusal that a collection would have covered
# (live + the refused request under the top) is counted and bounded by
# W16_COVIN -- without the two-cycle verdict (negative-control 4.17
# rawverdict) a one-proof verdict counting the batch's pinned junk is served to
# the fill in its handler, which W16's outside-landing criterion no longer
# sees under THE ADDRESS.  Each anchor matched once.  newline="" (no CRLF).
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", newline="") as f:
    s = f.read()
with open(os.path.join(here, "w20_cases.c"), "r", newline="") as f:
    cases = f.read()
assert "\r" not in s and "\r" not in cases
NL = chr(10)


def splice(s, anchor, new, what):
    n = s.count(anchor)
    assert n == 1, "%s: %d" % (what, n)
    return s.replace(anchor, new, 1)


M9 = "  /* M9 -- the M state never handed over, and nothing in the shim does it" + NL
s = splice(s, M9, cases + M9, "cases")

# C6b re-scope
s = splice(s, "      double tier6 = WALL_ODSTATE(C), win6 = WALL_WIN(C), k6 = WALL_KSLICE(C);" + NL,
           "      double tier6 = WALL_ODSTATE(C), win6 = WALL_WIN(C), k6 = WALL_KSLICE(C);" + NL
           + "      double h6 = statn(C, \"_OCLJ_WALLSTATS\", 18);   /* THE ADDRESS: the hold's room; -1 before it */" + NL,
           "c6b decl")
s = splice(s, "      for (i6 = 0; i6 < 8; i6++) t6 = u0 - (long long)k6 - w_odmax(t6) / 2;   /* T + G(T)/2 + K == used */" + NL,
           "      if (h6 < 0) h6 = 0;" + NL
           + "      for (i6 = 0; i6 < 8; i6++) t6 = u0 - (long long)k6 - (long long)h6 - w_odmax(t6) / 2;   /* T + G(T)/2 + K + hold == used */" + NL,
           "c6b top")
s = splice(s,
           "      sprintf(d, \"burst tier %.0f (want 0), window %.0f (want no verdict: 0, 1, or -1 before THE WINDOW), slice %.0f; \"" + NL
           + "                 \"cap %ld = used %ld - G/2 - slice: raw push status %d (LUA_ERRMEM=%d)\"," + NL
           + "              tier6, win6, k6, (long)t6, (long)u0, rawStatus, LUA_ERRMEM);" + NL,
           "      sprintf(d, \"burst tier %.0f (want 0), window %.0f (want no verdict: 0, 1, or -1 before THE WINDOW), slice %.0f, hold %.0f; \"" + NL
           + "                 \"cap %ld = used %ld - G/2 - slice - hold: raw push status %d (LUA_ERRMEM=%d)\"," + NL
           + "              tier6, win6, k6, h6, (long)t6, (long)u0, rawStatus, LUA_ERRMEM);" + NL,
           "c6b text")

# W16/W16L: the inside-covered count.  The inside landing keeps the sandbox's
# stack as the stall does (yield 'stop'), else the live measure reads the
# returned coroutine's shrunk stack and every inside landing reads "covered".
s = splice(s, "  \"  if not ok then rec(1) return end \"" + NL,
           "  \"  if not ok then rec(1) coroutine.yield('stop') return end \"" + NL, "w16 chunk stop")
s = splice(s, "      int k, nin = 0, nstall = 0, ndown = 0, nother = 0, ncov = 0;" + NL + "      long long dmax = 0, L16, top16, off;" + NL,
           "      int k, nin = 0, nstall = 0, ndown = 0, nother = 0, ncov = 0, ncovin = 0;" + NL + "      long long dmax = 0, L16, top16, off;" + NL,
           "w16 decl")
s = splice(s, "        else if (W16_CODE == 1) nin++;" + NL + "        else {" + NL + "          if (W16_CODE == 2) nstall++; else ndown++;" + NL
           + "          if (L16 + (W16_DELTA > 0 ? (long long)W16_DELTA : dmax) <= top16) {" + NL,
           "        else if (W16_CODE == 1) { nin++; if (L16 + (W16_DELTA > 0 ? (long long)W16_DELTA : dmax) <= top16) ncovin++; }" + NL
           + "        else {" + NL + "          if (W16_CODE == 2) nstall++; else ndown++;" + NL
           + "          if (L16 + (W16_DELTA > 0 ? (long long)W16_DELTA : dmax) <= top16) {" + NL,
           "w16 count")
s = splice(s, "      sprintf(d, \"%s, %d caps, base + 384 KB + 0..%d B: inside %d, stall %d, sandbox down %d, other %d; \"" + NL
           + "                 \"outside with room after a collection for the refused request (or %lld B): %d%.180s\"," + NL
           + "              hm16 ? \"C mode\" : \"legacy\", W16_N, (W16_N - 1) * W16_STEP, nin, nstall, ndown, nother, dmax, ncov, first);" + NL,
           "      sprintf(d, \"%s, %d caps, base + 384 KB + 0..%d B: inside %d (%d with room after a collection: at most %d), stall %d, sandbox down %d, other %d; \"" + NL
           + "                 \"outside with room after a collection for the refused request (or %lld B): %d%.160s\"," + NL
           + "              hm16 ? \"C mode\" : \"legacy\", W16_N, (W16_N - 1) * W16_STEP, nin, ncovin, W16_COVIN, nstall, ndown, nother, dmax, ncov, first);" + NL,
           "w16 text")
s = splice(s, "      ok(nin > 0 && ncov == 0 && nother == 0," + NL + "         hm16 ? \"W16 no refusal outside the handler that garbage covers\"" + NL,
           "      ok(nin > 0 && ncov == 0 && nother == 0 && ncovin <= W16_COVIN," + NL + "         hm16 ? \"W16 no refusal outside the handler that garbage covers\"" + NL,
           "w16 ok")
s = splice(s, "#ifndef W16R_N" + NL,
           "#ifndef W16_COVIN" + NL + "#define W16_COVIN 999        /* inside refusals a collection would have covered: set after measuring */" + NL
           + "#endif" + NL + "#ifndef W16R_N" + NL,
           "w16 covin")
with open(dst, "w", newline="") as f:
    f.write(s)
print("wrote", dst, s.count(NL), "lines")
