"""model.py -- the shift-exactness lemmas of OC-LuaJIT's bit operators,
checked exhaustively in a scaled model and by a 64-bit sweep.

Written 2026-10-23 under claude-tmp/oclj/shiftexact/checks/ (the checks
part of the shift-exactness round: JIT guide 3.11, "Shifts of an exact
operand", and 3.12, "x << 20, x a double: both guards stay ... the result
guard can never fail").  Revised the same day for the refute part's finding
F2 (claude-tmp/oclj/shiftexact/refute/notes.md: no script checked Lemma
BSHL10 or Lemma BAND): it now checks both lemmas of argue/argument.md
(sections 2.4 and 2.7), each with a control that must find
counterexamples.  Revised again the same day (revision 3) for the review of
the revised checks, its finding 6: two count instruments, BSHL10's check
count against its closed form and BAND's pair counts against |D_P|^2, each
with a control comparison that must differ.  NOT RUN when written or
revised; run.sh runs it.

    python -I model.py [nrand [seed]]          defaults: 200 20261023

It reads no stdin and no file, imports only sys, random and time, and
writes only to stdout.  This file holds no backslash.

DEFINITIONS.  sigbits(v) is 0 for v = 0, else the number of bits from the
lowest set bit of |v| to its highest, inclusive, so -2^(W-1), a power of
two, has 1 (the rule of test/native/bitop/xrule.lua and of verify-rg2's
probes/shiftexact.lua).  v is EXACT AT P when sigbits(v) <= P, that is
v = m * 2^e with |m| < 2^P.  An int64 is exactly a double iff it is exact
at P = 53; oclj_bit2num (native/luajit/oclj_bitop.h :101-108) accepts
exactly those, and the 64-bit sweeps check that equivalence on every value
they compute.  pmin(v) = max(sigbits(v), 1), the least P at which v is
exact.

THE MODEL.  A W-bit two's complement word, values in [-2^(W-1), 2^(W-1)),
W in 4..16, and a significand width P in 1..W; D_P is the set of values
exact at P.  For every x in D_P and every count k in 0..W-1:
  shl    x << k wrapped to W bits: x64's shl r64, cl; the IR's BSHL; the
         dialect's << (5.3.6's luaV_shiftl, oclj_shiftl, for 0 <= k < 64)
  sar    floor(x / 2^k): x64's sar; the IR's BSAR; the dialect's ~>>
         (oclj_shiftar)
and two CONTROLS, which do not preserve exactness and must be seen not to:
  lsr    the logical right shift (x mod 2^W) >> k: the IR's BSHR, the
         dialect's >> and << by a negative count
  orbit  x | (1 << k), wrapped.
Beyond them (F2):
  bshl10 x << k for EVERY x in the word, exact or not, and every count k
         with W - 1 - P <= k <= W - 1: the scaled Lemma BSHL10 (at W = 64,
         P = 53 the counts are k >= 10).  x << k is then a multiple of
         2^(W-1-P) in the word, j * 2^(W-1-P) with -2^P <= j < 2^P, so
         exact at P (j = -2^P is a power of two).
  band   x & y for every pair (x, y) in D_P x D_P, for W in 4..10 (the
         whole word squared is 4^W pairs, so W stops where it stays fast):
         the scaled Lemma BAND.
with their CONTROLS, which must find counterexamples:
  bshl10's tightness: at k = W - 2 - P, for every P in 1..W-2, some x in
         the word gives x << k outside D_P; and the witness
         x = 2^(P+1) + 1, taken as a W-bit word (it wraps only at
         P = W - 2, to -2^(W-1) + 1), gives -2^(W-2-P) * (2^(P+1) - 1),
         exactly P + 1 significant bits (at W = 64, P = 53 it is the
         argument's (2^54 + 1) << 9)
  bor    x | y on the same pairs as band: 2^P | 1 = 2^P + 1 has P + 1 bits
         whenever 2^P is in the word, that is at every P <= W - 2.
THE LEMMAS.  (L1) x in D_P implies shl(x, k) in D_P.  (L2) x in D_P
implies sar(x, k) in D_P.  (L3, BSHL10) for every x in the word and every
k with W - 1 - P <= k <= W - 1, shl(x, k) is in D_P.  (L4, BAND) x and y
in D_P imply x & y in D_P.  "mono" counts, for shl, sar, lsr and orbit,
the stronger fact sigbits(y) <= pmin(x), and for band and bor the fact
sigbits(r) <= max(pmin(x), pmin(y)); each is its lemma for every P at
once: a violation is a failure at P = pmin(x) (or the max), and a failure
at some P is a violation, so an op's mono is 0 iff its fails are (an
instrument check below).
A PROOF SKETCH, for the proof part to check, not relied on here [I].
(L1) Let x = m * 2^e, m odd, and y = shl(x, k) != 0.  y = x * 2^k mod 2^W,
so its lowest set bit is t = e + k < W.  If x * 2^k is in range, y is it,
with x's significand.  If not, |m| * 2^t >= 2^(W-1), so sigbits(x) =
bitlength(|m|) >= W - t; and |y| <= 2^(W-1) with lowest set bit t gives
sigbits(y) <= W - t.  (L2) If k <= e, y = m * 2^(e-k).  Else, with
s = k - e >= 1 and L = bitlength(|m|): for m > 0, y = m >> s has at most
L - s bits; for m < 0, |y| = ceil(|m| / 2^s) <= 2^(L-s) (or 1), so at most
L bits.  (L3) above.  (L4) the argument's section 2.7 with 64 read as W
and 53 as P.  None of the proofs uses a particular P, so each holds for
every P.  At P >= W - 1 every value in range is exact (|v| < 2^(W-1) has at
most W - 1 bits, and -2^(W-1) has 1), so those P are vacuous: no op can
fail there, and the controls are required to fail at every P <= W - 2.

THE PATHS.
  1. The fast path, every W in 4..16: one pass over every x in the word and
     every k, a histogram of (pmin(x), sigbits(y)) per op and W, from which
     every (W, P) count follows.  Its ops are spelled with Python's << and
     >> (fast_ops).  The same pass histograms sigbits(x << k) per (W, k)
     over every x in the word, from which every (W, P) count of BSHL10
     follows (1b).
  1c. BAND and bor, every W in 4..10: every pair (x, y) in the word, a
     histogram of (max(pmin(x), pmin(y)), sigbits(r)) per op and W, from
     which every (W, P) count over D_P x D_P follows.  Spelled with
     Python's & and | on signed values.
  2. The instruments.  D_P built by construction ({m * 2^e : |m| < 2^P} in
     range) must equal {x : pmin(x) <= P} for every W in 4..16 and P in
     1..W.  For W <= 10 a literal path walks D_P as constructed, computes
     each op by a second spelling (* and //, op_shl..op_orbit), compares
     every value with the fast path's and its per-(W, P, op) counts with
     the fast path's histogram.  Every result must lie in the word.  For
     BSHL10: every (W, k) row of its histogram must hold 2^W values; for
     W <= 10 a literal walk of every P, every k from W - 1 - P and every x
     by op_shl must give the histogram's counts; the witness must agree in
     both spellings and have exactly P + 1 bits; and at every W in 4..16
     the total check count must equal 2^W * (W(W+3)/2 - 1) (for P <= W - 1
     there are P + 1 counts, for P = W there are W, each over the 2^W
     words), with the control that the same formula at W + 1 must differ.
     For BAND and bor, W 4..8: a literal walk of D_P x D_P as constructed,
     by a second spelling (unsigned masks, op_band and op_bor), must give
     the histogram's counts and values; and at every W in 4..10 and P in
     1..W the histogram's pairs[P] must equal |D_P|^2 (construct_d's size
     squared), with the control that |D_(P-1)|^2 must differ from pairs[P]
     at every P in 2..W-1 (2^P - 1 is in D_P and not in D_(P-1)).
  3. The 64-bit sweep, P = 53: operands m * 2^e for m in {0, +-1, +-3,
     +-(2^52 - 1), +-(2^52 + 1), +-(2^53 - 1)} and nrand seeded random m
     (|m| < 2^53, random bit length 1..53, random sign), every e with x in
     [-2^63, 2^63), every k in 0..63.  Each op is computed twice, by a
     literal Python translation of oclj_bitop.h's oclj_shiftl and
     oclj_shiftar as oclj_bitop64 calls them (BC_BSHL: shiftl(x, k); BC_BSAR:
     shiftar(x, k); BC_BSHR: shiftl(x, -k)) and by the model's ops at
     W = 64, which must agree; exactness by sigbits(y) <= 53 and by
     oclj_bit2num's round trip (float(), which rounds to nearest even as
     cvtsi2sd does in the default mode), which must agree.
  3b. The second 64-bit sweep (F2).  BSHL10: 14 boundary int64 values (0,
     1, -1, 3, 2^63 - 1, -2^63, -2^63 + 1, +-(2^53 + 1), +-(2^54 + 1),
     2^62 + 1, 0x5555555555555555 and 0xAAAAAAAAAAAAAAAA as int64) and
     4 * nrand seeded random 64-bit patterns (random.Random(seed + 1); most
     are outside D, which is the lemma's point), every k in 10..63, by
     oclj_shiftl and by Python's << wrapped; its control is k = 9 on the
     same values, with the witness (2^54 + 1) << 9 (54 bits).  BAND: every
     ordered pair of the boundary operands (the 320 values m * 2^e of the
     first 11 m above) and 50 * nrand seeded random pairs of the sweep's
     operands (random.Random(seed + 2)), by Python's & and by unsigned
     masks; bor, its control, on the same pairs.

OUTPUT, in order (one line each):
  model.py nrand <n> seed <s> python <version>
  model W <w> <op> checks <n> fails <n> vacfails <n> mono <n> ctlcover <a>/<b>
      checks: the (P, x, k) triples, x in D_P, P in 1..W; fails: those whose
      result is not exact at P; vacfails: fails at P >= W - 1 (must be 0);
      ctlcover, controls only: the P <= W - 2 with a counterexample, of W - 2
  model total <op> checks <n> fails <n> mono <n>
  LEMMA COUNTEREXAMPLE ...   (only if a lemma fails: one per op and W)
  control <op> first counterexample W <w> P <p> x <x> k <k> y <y> sigbits(y) <s>
  model W <w> bshl10 checks <n> fails <n> vacfails <n> tight <a>/<b> witness <c>/<b>
      checks: the (P, k, x) triples, every x in the word, P in 1..W, k from
      max(0, W-1-P) to W-1; tight: the P <= W - 2 whose k = W - 2 - P has a
      result outside D_P in the histogram; witness: those at which the
      witness leaves D_P
  model total bshl10 checks <n> fails <n>
  control bshl10-tight first witness W <w> P <p> x <x> k <k> y <y> sigbits(y) <s>
  model W <w> band|bor checks <n> fails <n> vacfails <n> mono <n> ctlcover <a>/<b>|-
      checks: the (P, x, y) triples, x and y in D_P, P in 1..W
  model total band|bor checks <n> fails <n> mono <n>
  control bor first counterexample W <w> P <p> x <x> y <y> r <r> sigbits(r) <s>
  instrument ... (ten lines)
  sweep64 operands <n> m <n> pairs-per-op <n>
  instrument ... (two lines)
  sweep64 <op> pairs <n> fails <n> mono <n> first <...>
  sweep64 bshl10 operands <n> boundary <n> outside-D <n> pairs <n> fails <n> first <...>
  sweep64 bshl9 control pairs <n> fails <n> first <...> witness x <x> k 9 y <y> sigbits(y) <s>
  sweep64 band boundary-operands <n> pairs <n> (boundary <n>, random <n>) fails <n> mono <n> first <...>
  sweep64 bor control pairs <n> fails <n> mono <n> first <...>
  instrument the second sweep: ...
  time ...
  VERDICT PASS | VERDICT FAIL: ... | VERDICT PROVED NOTHING: ...
EXIT: 0 PASS; 1 FAIL (a counterexample to L1, L2, L3 or L4, printed
loudly); 2 PROVED NOTHING (a control found no counterexample where it
must: lsr, orbit, bor, BSHL10's tightness or the sweep's k = 9; or an
instrument check failed; or a bad argument).
EXPECTED [I, not run]: shl and sar fails 0 and mono 0 at every W and in the
sweep; lsr and orbit ctlcover (W-2)/(W-2) at every W, vacfails 0, and fails
> 0 in the sweep (lsr: x = -1, k = 1 gives 2^63 - 1, 63 bits; orbit:
x = 2^53 - 1 with e = 1, k = 0 gives 2^54 - 1, 54 bits).  bshl10 fails 0 at
every W, checks 2^W * (W(W+3)/2 - 1) (208 at W = 4, 9895936 at W = 16),
tight and witness (W-2)/(W-2), the first witness W 4 P 1 x 5 k 1 y -6
sigbits(y) 2.  band fails 0 and mono 0 at every W in 4..10; bor ctlcover
(W-2)/(W-2), fails > 0 and mono > 0.  In the second sweep at the defaults:
bshl10 operands 814 (14 boundary), outside-D about 804 (9 of the boundary
values, and all but about 5 of the 800 random patterns: a random 64-bit
pattern is in D with probability 12 * 2^-11), pairs 814 * 54 = 43956,
fails 0; bshl9 pairs 814, fails > 0, witness y -9223372036854775296
sigbits(y) 54; band boundary-operands 320, pairs 320 * 320 + 50 * 200 =
112400, fails 0, mono 0; bor fails > 0 (2^53 | 1).  Every instrument 0;
among them the check-count formula 0 of 13 W differ, its control equal at
0; BAND's and bor's pairs[P] against |D_P|^2 0 of 98 differ (2 ops times
the 49 (W, P) of W 4..10), the control equal at 0 of 70 (2 times the 35 P
in 2..W-1).
"""

import sys
import random
import time

WMIN = 4
WMAX = 16
WLIT = 10
WBAND = 10
WBLIT = 8
P64 = 53
DEFAULT_NRAND = 200
DEFAULT_SEED = 20261023
NAMES = ("shl", "sar", "lsr", "orbit")
LEMMA = {"shl": True, "sar": True, "lsr": False, "orbit": False}
NAMES2 = ("band", "bor")
LEMMA2 = {"band": True, "bor": False}
NBOUND = 11
MAXLIST = 5
MASK64 = (1 << 64) - 1
TOP = 1 << 63


def sigbits(v):
    if v == 0:
        return 0
    a = -v if v < 0 else v
    low = (a & -a).bit_length() - 1
    return (a >> low).bit_length()


def pmin(v):
    s = sigbits(v)
    return s if s > 0 else 1


# The fast path's spelling: Python's shifts, the wrap as (v + h) mod 2^W - h.
def fast_ops(x, ux, k, hi, m):
    return (((x << k) + hi) % m - hi,
            x >> k,
            ((ux >> k) + hi) % m - hi,
            ((ux | (1 << k)) + hi) % m - hi)


# The literal path's spelling: products and floor division.
def wrap(v, w):
    h = 1 << (w - 1)
    return (v + h) % (1 << w) - h


def op_shl(x, k, w):
    return wrap(x * (2 ** k), w)


def op_sar(x, k, w):
    return x // (2 ** k)


def op_lsr(x, k, w):
    return wrap((x % (2 ** w)) // (2 ** k), w)


def op_orbit(x, k, w):
    return wrap((x % (2 ** w)) | (2 ** k), w)


LIT_OPS = (op_shl, op_sar, op_lsr, op_orbit)


# BAND's and bor's second spelling: on the unsigned W-bit patterns.
def op_band(x, y, w):
    return wrap((x % (2 ** w)) & (y % (2 ** w)), w)


def op_bor(x, y, w):
    return wrap((x % (2 ** w)) | (y % (2 ** w)), w)


# oclj_bitop.h, literally, on uint64 bit patterns (x given as a signed int).
def u2s(u):
    return u - (1 << 64) if u >= TOP else u


def c_shiftl(x, y):
    u = x & MASK64
    if y < 0:
        if y <= -64:
            return 0
        return u2s(u >> (-y))
    if y >= 64:
        return 0
    return u2s((u << y) & MASK64)


def c_shiftar(x, y):
    u = x & MASK64
    if y < 0:
        return 0 if y <= -64 else u2s((u << (-y)) & MASK64)
    if y >= 64:
        return u2s(MASK64) if u >= TOP else 0
    if u >= TOP:
        return u2s(~((~u & MASK64) >> y) & MASK64)
    return u2s(u >> y)


def c_ops(x, k):
    return (c_shiftl(x, k),               # BC_BSHL: oclj_shiftl(x, c)
            c_shiftar(x, k),              # BC_BSAR: oclj_shiftar(x, c)
            c_shiftl(x, -k),              # BC_BSHR: oclj_shiftl(x, -c)
            u2s((x & MASK64) | (1 << k)))  # BC_BOR with 1 << k


def bit2num_ok(i):
    # oclj_bit2num: (double)i, refused at 2^63 or above, then (int64_t)n == i.
    n = float(i)
    if n >= 9223372036854775808.0:
        return False
    return int(n) == i


def per_p(h, w):
    # From h[px][sy]: pairs[P] and fails[P] for P in 1..w.
    pairs = [0] * (w + 1)
    fails = [0] * (w + 1)
    for p in range(1, w + 1):
        tp = 0
        tf = 0
        for px in range(1, p + 1):
            row = h[px]
            tp += sum(row)
            tf += sum(row[p + 1:])
        pairs[p] = tp
        fails[p] = tf
    return pairs, fails


def mono_of(h, w):
    mono = 0
    for q in range(1, w + 1):
        mono += sum(h[q][q + 1:])
    return mono


def model_fast():
    hist = {}
    firsts = {}
    hks = {}
    rangeerr = 0
    for w in range(WMIN, WMAX + 1):
        lo = -(1 << (w - 1))
        hi = 1 << (w - 1)
        m = 1 << w
        sig = [sigbits(v) for v in range(lo, hi)]
        hs = [[[0] * (w + 1) for _ in range(w + 1)] for _ in NAMES]
        hk = [[0] * (w + 1) for _ in range(w)]
        fs = [None] * len(NAMES)
        for x in range(lo, hi):
            px = sig[x - lo] or 1
            ux = x % m
            for k in range(w):
                ys = fast_ops(x, ux, k, hi, m)
                for j in range(4):
                    y = ys[j]
                    if y < lo or y >= hi:
                        rangeerr += 1
                        continue
                    sy = sig[y - lo]
                    hs[j][px][sy] += 1
                    if j == 0:
                        hk[k][sy] += 1
                    if sy > px and fs[j] is None:
                        fs[j] = (x, k, y, px, sy)
        for j, name in enumerate(NAMES):
            hist[(w, name)] = hs[j]
            firsts[(w, name)] = fs[j]
        hks[w] = hk
    return hist, firsts, rangeerr, hks


# BSHL10 at (W, P): every x in the word, every k from max(0, W-1-P) to W-1.
def bshl10_counts(hk, w):
    n = 1 << w
    checks = [0] * (w + 1)
    fails = [0] * (w + 1)
    for p in range(1, w + 1):
        for k in range(max(0, w - 1 - p), w):
            checks[p] += n
            fails[p] += sum(hk[k][p + 1:])
    return checks, fails


# BSHL10's tightness at (W, P), P in 1..W-2: k = W-2-P.
def bshl10_tight(hk, w):
    hi = 1 << (w - 1)
    m = 1 << w
    goth = 0
    gotw = 0
    wmis = 0
    wbits = 0
    first = None
    for p in range(1, w - 1):
        k = w - 2 - p
        if sum(hk[k][p + 1:]) > 0:
            goth += 1
        x = wrap(2 ** (p + 1) + 1, w)
        y = ((x << k) + hi) % m - hi
        if y != op_shl(x, k, w):
            wmis += 1
        s = sigbits(y)
        if s > p:
            gotw += 1
            if first is None:
                first = (p, x, k, y, s)
        if s != p + 1:
            wbits += 1
    return goth, gotw, wmis, wbits, first


def find_bshl10(w, p):
    lo = -(1 << (w - 1))
    hi = 1 << (w - 1)
    for k in range(max(0, w - 1 - p), w):
        for x in range(lo, hi):
            y = op_shl(x, k, w)
            if sigbits(y) > p:
                return x, k, y
    return 0, 0, 0


def model_band():
    hist = {}
    firsts = {}
    rangeerr = 0
    for w in range(WMIN, WBAND + 1):
        lo = -(1 << (w - 1))
        hi = 1 << (w - 1)
        sig = [sigbits(v) for v in range(lo, hi)]
        pv = [(v, sig[v - lo] or 1) for v in range(lo, hi)]
        hb = [[0] * (w + 1) for _ in range(w + 1)]
        ho = [[0] * (w + 1) for _ in range(w + 1)]
        fb = None
        fo = None
        for x, px in pv:
            for y, py in pv:
                q = px if px >= py else py
                a = x & y
                o = x | y
                if a < lo or a >= hi or o < lo or o >= hi:
                    rangeerr += 1
                    continue
                sa = sig[a - lo]
                so = sig[o - lo]
                hb[q][sa] += 1
                ho[q][so] += 1
                if sa > q and fb is None:
                    fb = (x, y, a, q, sa)
                if so > q and fo is None:
                    fo = (x, y, o, q, so)
        hist[(w, "band")] = hb
        hist[(w, "bor")] = ho
        firsts[(w, "band")] = fb
        firsts[(w, "bor")] = fo
    return hist, firsts, rangeerr


def construct_d(w, p):
    lo = -(1 << (w - 1))
    hi = 1 << (w - 1)
    d = set()
    for mm in range(-(2 ** p) + 1, 2 ** p):
        e = 0
        while True:
            x = mm * (2 ** e)
            if x < lo or x >= hi:
                break
            d.add(x)
            if mm == 0:
                break
            e += 1
    return d


def model_instruments(hist):
    dmis = 0
    dn = 0
    litmis = 0
    litn = 0
    valmis = 0
    valn = 0
    for w in range(WMIN, WMAX + 1):
        lo = -(1 << (w - 1))
        hi = 1 << (w - 1)
        m = 1 << w
        pm = [pmin(v) for v in range(lo, hi)]
        pp = {}
        for name in NAMES:
            pp[name] = per_p(hist[(w, name)], w)
        for p in range(1, w + 1):
            d = construct_d(w, p)
            f = set(v for v in range(lo, hi) if pm[v - lo] <= p)
            dn += 1
            if d != f:
                dmis += 1
            if w > WLIT:
                continue
            lp = [0, 0, 0, 0]
            lf = [0, 0, 0, 0]
            for x in sorted(d):
                ux = x % m
                for k in range(w):
                    fy = fast_ops(x, ux, k, hi, m)
                    for j in range(4):
                        y = LIT_OPS[j](x, k, w)
                        valn += 1
                        if y != fy[j]:
                            valmis += 1
                        lp[j] += 1
                        if sigbits(y) > p:
                            lf[j] += 1
            for j, name in enumerate(NAMES):
                pairs, fails = pp[name]
                litn += 1
                if lp[j] != pairs[p] or lf[j] != fails[p]:
                    litmis += 1
    return dmis, dn, litmis, litn, valmis, valn


def bshl10_instruments(hks):
    rowbad = 0
    rown = 0
    litmis = 0
    litn = 0
    valmis = 0
    valn = 0
    for w in range(WMIN, WMAX + 1):
        hk = hks[w]
        for k in range(w):
            rown += 1
            if sum(hk[k]) != (1 << w):
                rowbad += 1
        if w > WLIT:
            continue
        lo = -(1 << (w - 1))
        hi = 1 << (w - 1)
        m = 1 << w
        checks, fails = bshl10_counts(hk, w)
        for p in range(1, w + 1):
            lc = 0
            lf = 0
            for k in range(max(0, w - 1 - p), w):
                for x in range(lo, hi):
                    y = op_shl(x, k, w)
                    valn += 1
                    if y != ((x << k) + hi) % m - hi:
                        valmis += 1
                    lc += 1
                    if sigbits(y) > p:
                        lf += 1
            litn += 1
            if lc != checks[p] or lf != fails[p]:
                litmis += 1
    return rowbad, rown, litmis, litn, valmis, valn


# BAND's and bor's pair counts against |D_P|^2, every W in 4..10 and P in
# 1..W; the control compares pairs[P] with |D_(P-1)|^2 for P in 2..W-1,
# where D_(P-1) is a proper subset of D_P (2^P - 1 is in the word and has P
# bits), so every one of those comparisons must differ.
def band_pairs_instruments(bhist):
    bad = 0
    n = 0
    ctlsame = 0
    ctln = 0
    for w in range(WMIN, WBAND + 1):
        sizes = [0] + [len(construct_d(w, p)) for p in range(1, w + 1)]
        for name in NAMES2:
            pairs, _ = per_p(bhist[(w, name)], w)
            for p in range(1, w + 1):
                n += 1
                if pairs[p] != sizes[p] ** 2:
                    bad += 1
                if 2 <= p <= w - 1:
                    ctln += 1
                    if pairs[p] == sizes[p - 1] ** 2:
                        ctlsame += 1
    return bad, n, ctlsame, ctln


def band_instruments(bhist):
    litmis = 0
    litn = 0
    valmis = 0
    valn = 0
    for w in range(WMIN, WBLIT + 1):
        pb = per_p(bhist[(w, "band")], w)
        po = per_p(bhist[(w, "bor")], w)
        for p in range(1, w + 1):
            d = sorted(construct_d(w, p))
            lp = 0
            lfb = 0
            lfo = 0
            for x in d:
                for y in d:
                    a = op_band(x, y, w)
                    o = op_bor(x, y, w)
                    valn += 2
                    if a != (x & y):
                        valmis += 1
                    if o != (x | y):
                        valmis += 1
                    lp += 1
                    if sigbits(a) > p:
                        lfb += 1
                    if sigbits(o) > p:
                        lfo += 1
            litn += 2
            if lp != pb[0][p] or lfb != pb[1][p]:
                litmis += 1
            if lp != po[0][p] or lfo != po[1][p]:
                litmis += 1
    return litmis, litn, valmis, valn


def sweep64(nrand, seed):
    rng = random.Random(seed)
    ms = [0, 1, -1, 3, -3, (1 << 52) - 1, -((1 << 52) - 1), (1 << 52) + 1,
          -((1 << 52) + 1), (1 << 53) - 1, -((1 << 53) - 1)]
    for _ in range(nrand):
        bits = rng.randint(1, 53)
        mm = rng.getrandbits(bits) | (1 << (bits - 1))
        if rng.getrandbits(1):
            mm = -mm
        ms.append(mm)
    xs = []
    seen = set()
    for mm in ms:
        for e in range(64):
            x = mm * (2 ** e)
            if -TOP <= x < TOP and x not in seen:
                seen.add(x)
                xs.append(x)
    st = {}
    ex = {}
    for name in NAMES:
        st[name] = [0, 0, 0]
        ex[name] = []
    cmis = 0
    fmis = 0
    notd = 0
    m = 1 << 64
    for x in xs:
        px = pmin(x)
        if px > P64:
            notd += 1
        ux = x % m
        for k in range(64):
            cy = c_ops(x, k)
            my = fast_ops(x, ux, k, TOP, m)
            for j, name in enumerate(NAMES):
                y = cy[j]
                if y != my[j]:
                    cmis += 1
                s = sigbits(y)
                exact = s <= P64
                if exact != bit2num_ok(y):
                    fmis += 1
                rec = st[name]
                rec[0] += 1
                if not exact:
                    rec[1] += 1
                    if len(ex[name]) < MAXLIST:
                        ex[name].append((x, k, y, px, s))
                if s > px:
                    rec[2] += 1
    return xs, ms, st, ex, cmis, fmis, notd


def bshl10_boundary():
    return [0, 1, -1, 3, TOP - 1, -TOP, -TOP + 1, (1 << 53) + 1, -((1 << 53) + 1),
            (1 << 54) + 1, -((1 << 54) + 1), (1 << 62) + 1,
            u2s(0x5555555555555555), u2s(0xAAAAAAAAAAAAAAAA)]


# One BAND pair and its bor control: st[name] = [pairs, fails, mono];
# cnt = [spellings that differ, sigbits-vs-double disagreements, values].
def band_pair(x, y, st, ex, cnt):
    q = max(pmin(x), pmin(y))
    a = x & y
    o = x | y
    ux = x & MASK64
    uy = y & MASK64
    cnt[2] += 2
    if a != u2s(ux & uy):
        cnt[0] += 1
    if o != u2s(ux | uy):
        cnt[0] += 1
    for name, r in (("band", a), ("bor", o)):
        s = sigbits(r)
        exact = s <= P64
        if exact != bit2num_ok(r):
            cnt[1] += 1
        rec = st[name]
        rec[0] += 1
        if not exact:
            rec[1] += 1
            if len(ex[name]) < MAXLIST:
                ex[name].append((x, y, r, s))
        if s > q:
            rec[2] += 1


def sweep64_more(nrand, seed, xs, ms):
    m = 1 << 64
    r10 = random.Random(seed + 1)
    x10 = bshl10_boundary()
    nb10 = len(x10)
    for _ in range(4 * nrand):
        x10.append(u2s(r10.getrandbits(64)))
    st = {}
    ex = {}
    for name in ("bshl10", "bshl9", "band", "bor"):
        st[name] = [0, 0, 0]
        ex[name] = []
    cnt = [0, 0, 0]
    outd = 0
    for x in x10:
        if pmin(x) > P64:
            outd += 1
        for k in range(9, 64):
            y = c_shiftl(x, k)
            cnt[2] += 1
            if y != ((x << k) + TOP) % m - TOP:
                cnt[0] += 1
            s = sigbits(y)
            exact = s <= P64
            if exact != bit2num_ok(y):
                cnt[1] += 1
            name = "bshl9" if k == 9 else "bshl10"
            rec = st[name]
            rec[0] += 1
            if not exact:
                rec[1] += 1
                if len(ex[name]) < MAXLIST:
                    ex[name].append((x, k, y, s))
    wx = (1 << 54) + 1
    wy = c_shiftl(wx, 9)
    ws = sigbits(wy)
    bset = []
    seen = set()
    for mm in ms[:NBOUND]:
        for e in range(64):
            x = mm * (2 ** e)
            if -TOP <= x < TOP and x not in seen:
                seen.add(x)
                bset.append(x)
    notd = 0
    for x in bset:
        if pmin(x) > P64:
            notd += 1
    for x in bset:
        for y in bset:
            band_pair(x, y, st, ex, cnt)
    rp = random.Random(seed + 2)
    nrp = 50 * nrand
    for _ in range(nrp):
        x = xs[rp.randrange(len(xs))]
        y = xs[rp.randrange(len(xs))]
        if pmin(x) > P64 or pmin(y) > P64:
            notd += 1
        band_pair(x, y, st, ex, cnt)
    return {"nx10": len(x10), "nb10": nb10, "outd": outd, "st": st, "ex": ex,
            "cmis": cnt[0], "fmis": cnt[1], "nval": cnt[2], "wx": wx, "wy": wy,
            "ws": ws, "nbset": len(bset), "nbpairs": len(bset) * len(bset),
            "nrp": nrp, "notd": notd}


def main(argv):
    if len(argv) > 3:
        print("VERDICT PROVED NOTHING: usage: python -I model.py [nrand [seed]]")
        return 2
    try:
        nrand = int(argv[1]) if len(argv) > 1 else DEFAULT_NRAND
        seed = int(argv[2]) if len(argv) > 2 else DEFAULT_SEED
    except ValueError:
        print("VERDICT PROVED NOTHING: nrand and seed must be whole numbers")
        return 2
    if nrand < 0 or nrand > 100000:
        print("VERDICT PROVED NOTHING: nrand must be from 0 to 100000")
        return 2
    t0 = time.time()
    print("model.py nrand %d seed %d python %s" % (nrand, seed, sys.version.split()[0]))
    fail = []
    nothing = []

    print("== 1. the scaled model: W %d..%d, P 1..W, every x in D_P, every k in 0..W-1 ==" % (WMIN, WMAX))
    hist, firsts, rangeerr, hks = model_fast()
    totals = {}
    for name in NAMES:
        totals[name] = [0, 0, 0]
    ctlfirst = {}
    for w in range(WMIN, WMAX + 1):
        for name in NAMES:
            h = hist[(w, name)]
            pairs, fails = per_p(h, w)
            checks = sum(pairs[1:])
            nfail = sum(fails[1:])
            vac = fails[w - 1] + fails[w]
            mono = mono_of(h, w)
            if LEMMA[name]:
                cover = "-"
            else:
                got = sum(1 for p in range(1, w - 1) if fails[p] > 0)
                cover = "%d/%d" % (got, w - 2)
                if got != w - 2:
                    nothing.append("control %s found no counterexample at some P <= W-2 for W %d (%s)" % (name, w, cover))
            print("model W %d %s checks %d fails %d vacfails %d mono %d ctlcover %s" % (w, name, checks, nfail, vac, mono, cover))
            t = totals[name]
            t[0] += checks
            t[1] += nfail
            t[2] += mono
            if vac != 0:
                nothing.append("%s failed at a vacuous P (W %d): the model is wrong" % (name, w))
            if (nfail == 0) != (mono == 0):
                nothing.append("%s at W %d: fails %d but mono %d (they must be zero together)" % (name, w, nfail, mono))
            fx = firsts[(w, name)]
            if fx is not None:
                x, k, y, px, sy = fx
                if LEMMA[name]:
                    print("LEMMA COUNTEREXAMPLE model %s W %d P %d x %d k %d y %d sigbits(x) %d sigbits(y) %d" % (name, w, px, x, k, y, sigbits(x), sy))
                elif name not in ctlfirst:
                    ctlfirst[name] = (w, px, x, k, y, sy)
    for name in NAMES:
        t = totals[name]
        print("model total %s checks %d fails %d mono %d" % (name, t[0], t[1], t[2]))
        if LEMMA[name] and (t[1] > 0 or t[2] > 0):
            fail.append("the model's %s breaks %s (fails %d, mono %d)" % (name, "L1" if name == "shl" else "L2", t[1], t[2]))
        if not LEMMA[name] and t[1] == 0:
            nothing.append("control %s found no counterexample in the model" % name)
    for name in NAMES:
        if name in ctlfirst:
            w, p, x, k, y, sy = ctlfirst[name]
            print("control %s first counterexample W %d P %d x %d k %d y %d sigbits(y) %d" % (name, w, p, x, k, y, sy))
    t1 = time.time()

    print("== 1b. Lemma BSHL10 in the scaled model: W %d..%d, P 1..W, every x in the word, every k from W-1-P to W-1 ==" % (WMIN, WMAX))
    tb = [0, 0]
    tfirst = None
    wmis_all = 0
    wbits_all = 0
    nwit = 0
    nchkbad = 0
    nchkctl = 0
    nchkn = 0
    for w in range(WMIN, WMAX + 1):
        hk = hks[w]
        checks, fails = bshl10_counts(hk, w)
        nchk = sum(checks[1:])
        nfail = sum(fails[1:])
        # The count instrument: 2^W * (W(W+3)/2 - 1); its control, the
        # formula at W + 1, must differ from the count.
        nchkn += 1
        if nchk != (1 << w) * (w * (w + 3) // 2 - 1):
            nchkbad += 1
        if nchk == (1 << (w + 1)) * ((w + 1) * (w + 4) // 2 - 1):
            nchkctl += 1
        vac = fails[w - 1] + fails[w]
        goth, gotw, wmis, wbits, first = bshl10_tight(hk, w)
        wmis_all += wmis
        wbits_all += wbits
        nwit += w - 2
        print("model W %d bshl10 checks %d fails %d vacfails %d tight %d/%d witness %d/%d" % (w, nchk, nfail, vac, goth, w - 2, gotw, w - 2))
        tb[0] += nchk
        tb[1] += nfail
        if vac != 0:
            nothing.append("bshl10 failed at a vacuous P (W %d): the model is wrong" % w)
        if goth != w - 2 or gotw != w - 2:
            nothing.append("control bshl10-tight found no counterexample at some P <= W-2 for W %d (histogram %d/%d, witness %d/%d)" % (w, goth, w - 2, gotw, w - 2))
        if tfirst is None and first is not None:
            tfirst = (w,) + first
        if nfail > 0:
            for p in range(1, w + 1):
                if fails[p] > 0:
                    x, k, y = find_bshl10(w, p)
                    print("LEMMA COUNTEREXAMPLE model bshl10 W %d P %d x %d k %d y %d sigbits(x) %d sigbits(y) %d" % (w, p, x, k, y, sigbits(x), sigbits(y)))
                    break
    print("model total bshl10 checks %d fails %d" % (tb[0], tb[1]))
    if tb[1] > 0:
        fail.append("the model's bshl10 breaks L3 (BSHL10) (fails %d)" % tb[1])
    if tfirst is not None:
        w, p, x, k, y, s = tfirst
        print("control bshl10-tight first witness W %d P %d x %d k %d y %d sigbits(y) %d" % (w, p, x, k, y, s))
    else:
        nothing.append("control bshl10-tight: no witness left D_P at any W")
    t2 = time.time()

    print("== 1c. Lemma BAND in the scaled model: W %d..%d, P 1..W, every pair in D_P x D_P (the whole word squared) ==" % (WMIN, WBAND))
    bhist, bfirsts, brange = model_band()
    btot = {}
    for name in NAMES2:
        btot[name] = [0, 0, 0]
    bctl = None
    for w in range(WMIN, WBAND + 1):
        for name in NAMES2:
            h = bhist[(w, name)]
            pairs, fails = per_p(h, w)
            checks = sum(pairs[1:])
            nfail = sum(fails[1:])
            vac = fails[w - 1] + fails[w]
            mono = mono_of(h, w)
            if LEMMA2[name]:
                cover = "-"
            else:
                got = sum(1 for p in range(1, w - 1) if fails[p] > 0)
                cover = "%d/%d" % (got, w - 2)
                if got != w - 2:
                    nothing.append("control %s found no counterexample at some P <= W-2 for W %d (%s)" % (name, w, cover))
            print("model W %d %s checks %d fails %d vacfails %d mono %d ctlcover %s" % (w, name, checks, nfail, vac, mono, cover))
            t = btot[name]
            t[0] += checks
            t[1] += nfail
            t[2] += mono
            if vac != 0:
                nothing.append("%s failed at a vacuous P (W %d): the model is wrong" % (name, w))
            if (nfail == 0) != (mono == 0):
                nothing.append("%s at W %d: fails %d but mono %d (they must be zero together)" % (name, w, nfail, mono))
            fx = bfirsts[(w, name)]
            if fx is not None:
                x, y, r, q, s = fx
                if LEMMA2[name]:
                    print("LEMMA COUNTEREXAMPLE model band W %d P %d x %d y %d r %d sigbits(r) %d" % (w, q, x, y, r, s))
                elif bctl is None:
                    bctl = (w, q, x, y, r, s)
    for name in NAMES2:
        t = btot[name]
        print("model total %s checks %d fails %d mono %d" % (name, t[0], t[1], t[2]))
        if LEMMA2[name] and (t[1] > 0 or t[2] > 0):
            fail.append("the model's band breaks L4 (BAND) (fails %d, mono %d)" % (t[1], t[2]))
        if not LEMMA2[name] and t[1] == 0:
            nothing.append("control %s found no counterexample in the model" % name)
    if bctl is not None:
        w, q, x, y, r, s = bctl
        print("control bor first counterexample W %d P %d x %d y %d r %d sigbits(r) %d" % (w, q, x, y, r, s))
    t3 = time.time()

    print("== 2. instruments ==")
    dmis, dn, litmis, litn, valmis, valn = model_instruments(hist)
    print("instrument D_P by construction against max(sigbits, 1) <= P: %d of %d (W, P) differ" % (dmis, dn))
    print("instrument literal path against fast path (W %d..%d): %d of %d (W, P, op) counts differ, %d of %d values differ" % (WMIN, WLIT, litmis, litn, valmis, valn))
    print("instrument results outside the word: %d" % rangeerr)
    if dmis or litmis or valmis or rangeerr or dn == 0 or litn == 0 or valn == 0:
        nothing.append("an instrument of the model failed (D %d, counts %d, values %d, range %d)" % (dmis, litmis, valmis, rangeerr))
    rowbad, rown, blitmis, blitn, bvalmis, bvaln = bshl10_instruments(hks)
    print("instrument BSHL10 histogram rows holding 2^W values (W %d..%d, every k): %d of %d rows wrong" % (WMIN, WMAX, rowbad, rown))
    print("instrument BSHL10 literal walk against the histogram (W %d..%d): %d of %d (W, P) counts differ, %d of %d values differ" % (WMIN, WLIT, blitmis, blitn, bvalmis, bvaln))
    print("instrument BSHL10 witness: the two spellings differ at %d, sigbits(y) other than P + 1 at %d, of %d (W, P)" % (wmis_all, wbits_all, nwit))
    if rowbad or blitmis or bvalmis or wmis_all or wbits_all or rown == 0 or blitn == 0 or bvaln == 0 or nwit == 0:
        nothing.append("an instrument of BSHL10 failed (rows %d, counts %d, values %d, witness spellings %d, witness bits %d)" % (rowbad, blitmis, bvalmis, wmis_all, wbits_all))
    print("instrument BSHL10 checks against 2^W * (W(W+3)/2 - 1) (W %d..%d): %d of %d W differ; the formula at W + 1 equals the count at %d (must be 0)" % (WMIN, WMAX, nchkbad, nchkn, nchkctl))
    if nchkbad or nchkctl or nchkn == 0:
        nothing.append("an instrument of BSHL10's check count failed (formula %d of %d W, control equal at %d)" % (nchkbad, nchkn, nchkctl))
    pbad, pn, pctlsame, pctln = band_pairs_instruments(bhist)
    print("instrument BAND and bor pairs[P] against |D_P|^2 (W %d..%d, every P): %d of %d differ; |D_(P-1)|^2 equals pairs[P] at %d of %d P in 2..W-1 (must be 0)" % (WMIN, WBAND, pbad, pn, pctlsame, pctln))
    if pbad or pctlsame or pn == 0 or pctln == 0:
        nothing.append("an instrument of BAND's pair counts failed (|D_P|^2 %d of %d, control equal at %d of %d)" % (pbad, pn, pctlsame, pctln))
    alitmis, alitn, avalmis, avaln = band_instruments(bhist)
    print("instrument BAND and bor literal walk of D_P x D_P against the histogram (W %d..%d): %d of %d (W, P, op) counts differ, %d of %d values differ" % (WMIN, WBLIT, alitmis, alitn, avalmis, avaln))
    print("instrument BAND and bor results outside the word: %d" % brange)
    if alitmis or avalmis or brange or alitn == 0 or avaln == 0:
        nothing.append("an instrument of BAND failed (counts %d, values %d, range %d)" % (alitmis, avalmis, brange))
    t4 = time.time()

    print("== 3. the 64-bit sweep: P %d, W 64, every k in 0..63 ==" % P64)
    xs, ms, st, ex, cmis, fmis, notd = sweep64(nrand, seed)
    print("sweep64 operands %d m %d pairs-per-op %d" % (len(xs), len(ms), len(xs) * 64))
    print("instrument oclj_bitop.h's shifts against the model's ops: %d of %d values differ" % (cmis, len(xs) * 64 * 4))
    print("instrument sigbits(y) <= 53 against oclj_bit2num's round trip: %d of %d disagree; operands not exact: %d" % (fmis, len(xs) * 64 * 4, notd))
    if cmis or fmis or notd or not xs:
        nothing.append("an instrument of the sweep failed (c-vs-model %d, sigbits-vs-double %d, operands %d)" % (cmis, fmis, notd))
    for name in NAMES:
        pairs, nfail, mono = st[name]
        firstx = "-"
        if ex[name]:
            x, k, y, px, s = ex[name][0]
            firstx = "x %d k %d y %d sigbits(y) %d" % (x, k, y, s)
        print("sweep64 %s pairs %d fails %d mono %d first %s" % (name, pairs, nfail, mono, firstx))
        if LEMMA[name]:
            for x, k, y, px, s in ex[name]:
                print("LEMMA COUNTEREXAMPLE sweep64 %s x %d k %d y %d sigbits(x) %d sigbits(y) %d" % (name, x, k, y, px, s))
            if nfail > 0 or mono > 0:
                fail.append("the sweep's %s breaks %s (fails %d, mono %d)" % (name, "L1" if name == "shl" else "L2", nfail, mono))
        elif nfail == 0:
            nothing.append("control %s found no counterexample in the 64-bit sweep" % name)
    t5 = time.time()

    print("== 3b. the second 64-bit sweep: BSHL10 (k 10..63, any int64 x) and BAND, P %d ==" % P64)
    r = sweep64_more(nrand, seed, xs, ms)
    st2 = r["st"]
    ex2 = r["ex"]
    rec = st2["bshl10"]
    firstx = "-"
    if ex2["bshl10"]:
        x, k, y, s = ex2["bshl10"][0]
        firstx = "x %d k %d y %d sigbits(y) %d" % (x, k, y, s)
    print("sweep64 bshl10 operands %d boundary %d outside-D %d pairs %d fails %d first %s" % (r["nx10"], r["nb10"], r["outd"], rec[0], rec[1], firstx))
    for x, k, y, s in ex2["bshl10"]:
        print("LEMMA COUNTEREXAMPLE sweep64 bshl10 x %d k %d y %d sigbits(x) %d sigbits(y) %d" % (x, k, y, sigbits(x), s))
    if rec[1] > 0:
        fail.append("the sweep's bshl10 breaks L3 (BSHL10) (fails %d)" % rec[1])
    rec = st2["bshl9"]
    firstx = "-"
    if ex2["bshl9"]:
        x, k, y, s = ex2["bshl9"][0]
        firstx = "x %d k %d y %d sigbits(y) %d" % (x, k, y, s)
    print("sweep64 bshl9 control pairs %d fails %d first %s witness x %d k 9 y %d sigbits(y) %d" % (rec[0], rec[1], firstx, r["wx"], r["wy"], r["ws"]))
    if rec[1] == 0 or r["ws"] != 54:
        nothing.append("control bshl9 found no counterexample in the 64-bit sweep (fails %d, witness bits %d, must be 54)" % (rec[1], r["ws"]))
    rec = st2["band"]
    firstx = "-"
    if ex2["band"]:
        x, y, v, s = ex2["band"][0]
        firstx = "x %d y %d r %d sigbits(r) %d" % (x, y, v, s)
    print("sweep64 band boundary-operands %d pairs %d (boundary %d, random %d) fails %d mono %d first %s" % (r["nbset"], rec[0], r["nbpairs"], r["nrp"], rec[1], rec[2], firstx))
    for x, y, v, s in ex2["band"]:
        print("LEMMA COUNTEREXAMPLE sweep64 band x %d y %d r %d sigbits(x) %d sigbits(y) %d sigbits(r) %d" % (x, y, v, sigbits(x), sigbits(y), s))
    if rec[1] > 0 or rec[2] > 0:
        fail.append("the sweep's band breaks L4 (BAND) (fails %d, mono %d)" % (rec[1], rec[2]))
    rec = st2["bor"]
    firstx = "-"
    if ex2["bor"]:
        x, y, v, s = ex2["bor"][0]
        firstx = "x %d y %d r %d sigbits(r) %d" % (x, y, v, s)
    print("sweep64 bor control pairs %d fails %d mono %d first %s" % (rec[0], rec[1], rec[2], firstx))
    if rec[1] == 0:
        nothing.append("control bor found no counterexample in the 64-bit sweep")
    print("instrument the second sweep: the two spellings differ at %d of %d values; sigbits(y) <= 53 against oclj_bit2num's round trip disagree at %d; BAND operands not exact %d; BSHL10 operands outside D %d (must be > 0)" % (r["cmis"], r["nval"], r["fmis"], r["notd"], r["outd"]))
    if r["cmis"] or r["fmis"] or r["notd"] or r["outd"] == 0 or r["nval"] == 0 or r["nbset"] == 0:
        nothing.append("an instrument of the second sweep failed (spellings %d, sigbits-vs-double %d, BAND operands %d, BSHL10 operands outside D %d)" % (r["cmis"], r["fmis"], r["notd"], r["outd"]))
    t6 = time.time()
    print("time model %.1f s bshl10 %.1f s band %.1f s instruments %.1f s sweep %.1f s sweep2 %.1f s" % (t1 - t0, t2 - t1, t3 - t2, t4 - t3, t5 - t4, t6 - t5))

    if fail:
        extra = ""
        if nothing:
            extra = " (and: " + "; ".join(nothing) + ")"
        print("VERDICT FAIL: " + "; ".join(fail) + extra)
        return 1
    if nothing:
        print("VERDICT PROVED NOTHING: " + "; ".join(nothing))
        return 2
    print("VERDICT PASS: L1 (shl) and L2 (sar) hold in every case checked, in the model for W %d..%d and every P, and in the 64-bit sweep at P 53; L3 (BSHL10) holds for every x in the word and every k from W-1-P, W %d..%d, and in the sweep for k 10..63; L4 (BAND) holds on every pair in D_P x D_P, W %d..%d, and in the sweep; every control found counterexamples where it must: lsr, orbit and bor at every non-vacuous (W, P) and in the sweep, BSHL10's tightness at k = W-2-P for every P <= W-2 and every W, and k = 9 in the sweep" % (WMIN, WMAX, WMIN, WMAX, WMIN, WBAND))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
