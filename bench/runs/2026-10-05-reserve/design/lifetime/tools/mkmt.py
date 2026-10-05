# mkmt.py <repo mem_test.c> <out mem_test_lt.c>
# The design's new cases, spliced into a COPY of test/native/mem_test.c just
# before its M9 epilogue (nothing of the 81 checks changes):
#   W20  THE RESERVE'S SIZE: a fill that never saw its refusal holds at most
#        LJ52_GC_RSV + the window past the heap that refusal found.  W16R's
#        program (the step's handler absorbs the first refusal, the fill goes
#        on), recording used at both refusals.  MUST FAIL on the shipped shim
#        (the second chance buys G/2: 16 KB at the floor).
#   W20L the same on the legacy (dropin) path.
#   W21  THE RESERVE'S SIZE IS ENOUGH: a recovery that formats 32 lines (2 KB
#        kept) with 100 garbage strings between them, still holding its data
#        across the cycles that costs, then drops and carries on.  MUST FAIL
#        with no room past the refusal (the R0 control: the handler is refused
#        mid-recovery) and with a 1 KB reserve.
# Python writes with newline="".
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", newline="") as f:
    s = f.read()
assert "\r" not in s

CHUNKS = r'''
/* W20's program (design "lifetime", 2026-10-05): W16R's -- the step's own
 * handler absorbs the first refusal and the fill goes on with its data kept,
 * as a refusal the probe's paint or the JIT recorder absorbed lets it -- with
 * the heap recorded at BOTH refusals (rec 10 at the first, before anything
 * else allocates; rec 1 at the second).  What the second chance bought is
 * used_2 - used_1. */
static const char *W20_CHUNK =
  "local rec, held, count, stage, slot, nfail = __w20rec, {}, 0, 'filling/0', {}, 0 "
  "__w20h = held "
  "local function uniq(len, i) local s = tostring(i) return string.rep('x', len - #s) .. s end "
  "local step "
  "step = function() "
  "  local ok = pcall(function() "
  "    for k = 1, 100 do "
  "      count = count + 1 held[count] = uniq(32, count) "
  "      local junk = uniq(24, count) .. '!' "
  "    end "
  "  end) "
  "  if not ok then "
  "    nfail = nfail + 1 "
  "    if nfail == 1 then rec(10, count) end "
  "    if nfail >= 2 then rec(1, count) held = nil __w20h = nil return end "
  "  end "
  "  stage = 'filling/' .. count "
  "  slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 } "
  "end "
  "slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 } "
  "local co = coroutine.create(function() "
  "  for r = 1, 400 do "
  "    local sig = table.pack(coroutine.yield()) "
  "    local hd = slot[1] "
  "    if not hd then return end "
  "    slot[1] = nil "
  "    if not pcall(hd.callback) then rec(2, count) coroutine.yield('stop') return end "
  "  end "
  "end) "
  "local cb = function() end "
  "__w20k = function() "
  "  for r = 1, 402 do "
  "    local t = _OCLJ_WATCHDOG.arm(3600, cb, true) "
  "    local res = table.pack(coroutine.resume(co, 'timer')) "
  "    _OCLJ_WATCHDOG.disarm(t) "
  "    if not res[1] then rec(3, count) return end "
  "    if res[2] == 'stop' or coroutine.status(co) == 'dead' then return end "
  "  end "
  "end";
static long long W20_U[16];
static long long W20_C[16];
static double W20_T[16];
static int W20_N[16];
static FakeState *W20_S;       /* the legacy path keeps the figure on the Java side */
static int w20_rec(lua_State *L) {
  int code = (int)lua_tointeger(L, 1);
  if (code < 0 || code > 15) return 0;
  if (W20_N[code]++ == 0) {
    W20_U[code] = W20_S ? j_used(L, W20_S) : j_core_used(L);
    W20_C[code] = (long long)lua_tonumber(L, 2);
    W20_T[code] = statn(L, "_OCLJ_WALLSTATS", 14);   /* the tier's credit; -1 before it */
  }
  return 0;
}
#ifndef W20_N_CAPS
#define W20_N_CAPS 8
#endif
#define W20_RSV 4096          /* FIXED, as W19's 11 KB is: a shim that grows the reserve fails here */

/* W21's sandbox: a fill of live tables (W17's) inside pcall until refused;
 * then, STILL HOLDING, the recovery a real program makes before it drops:
 * 16 kept lines, 100 garbage strings (the cycles THE CADENCE runs on them
 * are the proofs the reserve has to survive), 16 more kept lines -- about
 * 2 KB kept, 8 KB granted -- then the drop, then new data. */
static const char *W21_CHUNK =
  "local h, n, m = __w21h, 0, {} "
  "local co = coroutine.create(function() "
  "  local ok = pcall(function() while n < 200000 do n = n + 1 h[n] = {n} end end) "
  "  if ok then coroutine.yield(-1) return end "
  "  for i = 1, 16 do m[i] = string.format('%s: line %d of the report, still held', 'not enough memory', i) end "
  "  for i = 1, 100 do local junk = string.format('%d', i) .. ' garbage between the lines of the report' end "
  "  for i = 17, 32 do m[i] = string.format('%s: line %d of the report, still held', 'not enough memory', i) end "
  "  __w21h = nil h = nil "
  "  local s = string.rep('y', 256) "
  "  local t = {1, 2, 3} "
  "  coroutine.yield(#m * 1000000 + #s * 100 + #t) "
  "end) "
  "local t = _OCLJ_WATCHDOG.arm(3600, function() end, true) "
  "local okr, r = coroutine.resume(co) "
  "_OCLJ_WATCHDOG.disarm(t) "
  "__w21 = okr and r or -2";
'''

CASES = r'''
  /* ---- W20 / W20L: THE RESERVE'S SIZE (design "lifetime") -------------- */
  /* A refusal the program never saw used to open G/2 more past the cap for
   * it (16 KB at the floor, 256 KB at 8 MB).  Now the reserve is
   * LJ52_GC_RSV past the heap the refusal found, so a fill that goes on
   * after an absorbed refusal is refused again within that plus the window.
   * Fail-first: the shipped shim reads used_2 about G past the cap. */
  {
    int round, k, nsc = 0, nin = 0, nout = 0, nother = 0, nbad = 0, nbought = 0;
    long long creepmax = 0, creepsum = 0, objsum = 0, cap20, base20, S20;
    lua_State *X;
    FakeState XS;
    char dd[600], first20[200];
    for (round = 0; round < 2; round++) {
      int hm20 = round == 0;
      nsc = nin = nout = nother = nbad = nbought = 0; creepmax = creepsum = objsum = 0; first20[0] = 0;
      for (k = 0; k < W20_N_CAPS; k++) {
        long long off = (long long)k * 512;
        X = w_newstate(&XS, 64 * 1024 * 1024, hm20);
        if (!X) { printf("  FAIL  W20: no state\n"); return 1; }
        runstr(X, "jit.off() __w20k = false");
        lua_pushcfunction(X, w20_rec);
        lua_setglobal(X, "__w20rec");
        if (runstr(X, W20_CHUNK) != 0) { printf("  FAIL  W20: the chunk: %s\n", errtop(X)); return 1; }
        lua_settop(X, 0);
        lua_gc(X, LUA_GCCOLLECT, 0);
        lua_gc(X, LUA_GCCOLLECT, 0);
        settle_gc(X);
        lua_getglobal(X, "__w20k");
        base20 = j_used(X, &XS);
        cap20 = base20 + 384 * 1024 + off;
        S20 = cap20 + w_odmax(cap20) / 2;
        memset(W20_N, 0, sizeof W20_N); memset(W20_U, 0, sizeof W20_U); memset(W20_C, 0, sizeof W20_C);
        W20_S = &XS;
        w_setcap(X, &XS, cap20, hm20);
        st = lua_pcall(X, 0, 0, 0);
        w_setcap(X, &XS, 64 * 1024 * 1024, hm20);
        lua_settop(X, 0);
        if (st != 0 || W20_N[10] == 0) nother++;
        else {
          int c2 = W20_N[1] ? 1 : W20_N[2] ? 2 : W20_N[3] ? 3 : 0;
          long long u1 = W20_U[10], u2 = c2 ? W20_U[c2] : -1, lim;
          nsc++;
          if (c2 == 1) nin++; else if (c2) nout++; else nother++;
          if (c2) {
            long long creep = u2 - u1;
            lim = (u1 > S20 ? u1 : S20) + W20_RSV + 4096;
            creepsum += creep; objsum += W20_C[c2] - W20_C[10];
            if (creep > creepmax) creepmax = creep;
            if (creep > 1024) nbought++;
            if (u2 > lim) {
              nbad++;
              if (first20[0] == 0)
                sprintf(first20, "; first over: cap %lld, used %lld at the first refusal, %lld at the second (%+lld, %lld objects), the bound %lld",
                        cap20, u1, u2, creep, W20_C[c2] - W20_C[10], lim);
            }
          }
        }
        clear_javastate(X);
        lua_close(X);
      }
      sprintf(dd, "%s, %d caps: second chance in %d, its end inside %d / outside %d / other %d; what it bought: "
                  "mean %+lld B (%lld objects), max %+lld B; past the bound (max(used_1, cap + G/2) + %d + the window): %d%.190s",
              hm20 ? "C mode" : "legacy", W20_N_CAPS, nsc, nin, nout, nother,
              nsc ? creepsum / (nsc ? nsc : 1) : 0, nsc ? objsum / nsc : 0, creepmax, W20_RSV, nbad, first20);
      ok(nsc == W20_N_CAPS && nother == 0 && nbad == 0 && nbought >= W20_N_CAPS / 2,
         hm20 ? "W20 a refusal the program never saw opens one window of reserve, not G/2"
              : "W20L the same on the legacy (dropin) path", dd);
    }
  }

  /* ---- W21: THE RESERVE'S SIZE is enough for a recovery that holds ----- */
  /* The reserve exists so that "catch, format, drop" works although the
   * cycles between the catch and the drop find the data still held.  A
   * program that formats a 32-line report (2 KB kept, 8 KB granted) while
   * holding, then drops, must carry on.  Fail-first: with no room past the
   * refusal (LJ52_GC_RSV 0) the handler is refused inside its own report;
   * with 1 KB too. */
  {
    lua_State *X;
    FakeState XS;
    long long cap21;
    int r21;
    char dd[400];
    X = w_newstate(&XS, 64 * 1024 * 1024, 1);
    if (!X) { printf("  FAIL  W21: no state\n"); return 1; }
    runstr(X, "jit.off() __w21 = 0");
    lua_createtable(X, 8192, 0);
    lua_setglobal(X, "__w21h");
    lua_gc(X, LUA_GCCOLLECT, 0);
    lua_gc(X, LUA_GCCOLLECT, 0);
    settle_gc(X);
    lua_settop(X, 0);
    cap21 = j_used(X, &XS) + 256 * 1024;
    w_setcap(X, &XS, cap21, 1);
    st = runstr(X, W21_CHUNK);
    w_setcap(X, &XS, 64 * 1024 * 1024, 1);
    lua_getglobal(X, "__w21");
    r21 = (int)lua_tointeger(X, -1);
    lua_pop(X, 1);
    sprintf(dd, "cap %lld, G %lld: status %d, result %d (32 lines, 256 B, 3 slots = 32025603)", cap21, w_odmax(cap21), st, r21);
    ok(st == 0 && r21 == 32025603, "W21 a recovery that holds across the cycles its report costs", dd);
    clear_javastate(X);
    lua_close(X);
  }

'''

a = "static int main_unused_marker_never_matches;"  # placeholder to keep structure clear
# 1. the chunks and recorders go before main()
a = "int main(void) {\n"
n = s.count(a)
assert n == 1, n
s = s.replace(a, CHUNKS + "\n" + a, 1)
# 2. the cases go before the M9 epilogue
a = "  /* M9 -- the M state never handed over, and nothing in the shim does it\n"
n = s.count(a)
assert n == 1, n
s = s.replace(a, CASES + a, 1)
assert "\r" not in s
with open(dst, "w", newline="") as f:
    f.write(s)
print("wrote", dst, s.count("\n"), "lines")
