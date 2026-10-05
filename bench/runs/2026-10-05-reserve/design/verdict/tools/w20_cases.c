  /* ==== THE ADDRESS (the "verdict" design): W20-W24 ======================= */
  /* Each runs as the sandbox (a coroutine resumed under the watchdog's arm,
   * W17's setup: the sandbox's tops, no kernel slice), with a pre-sized
   * holder so that every held object is one TNEW, check first.  Two handlers
   * share the thread: A, the fill, which holds its data under pcall(A); and
   * B, another protected call that allocates and drops -- the capacity
   * probe's pcall(paint), OpenOS's dispatcher.  _OCLJ_WALLSTATS is read from
   * Lua by select(): a C function pushing numbers, nothing allocated. */
  {
    static const char *WV_HEAD =
      "local h, n, W, cap = __wvh, 0, _OCLJ_WALLSTATS, __wvcap "
      "local function win() return (select(12, W())) end "
      "local function peak() return (select(2, W())) end "
      "local function tier() return (select(3, W())) end "
      "local Bn, Bok, Aok, Aerr, msg, w2, bh = 0, true, nil, nil, '', -1, {} "
      /* A: 'open' fills until a growth was lent past S, then holds one 1 KB
       * string so the live set stands clear of S for the verdict; 'fill'
       * fills on.  One function, so both phases are one handler. */
      "local function A(mode) "
      "  if mode == 'open' then "
      "    while n < 200000 do n = n + 1 h[n] = {n} "
      "      if win() >= 1 then n = n + 1 h[n] = string.rep('z', 1024) return 'open' end end "
      "  else while n < 200000 do n = n + 1 h[n] = {n} end end end "
      "local function A2() while n < 200000 do n = n + 1 h[n] = {n} end end "   /* W24: another handler, the same data */
      "local function B() local t = {Bn, Bn, Bn} Bn = Bn + 1 end "
      "local function Bhold() local t = {Bn, Bn, Bn} bh[#bh + 1] = t Bn = Bn + 1 end "
      "local function Bverdict() "          /* B allocates until the verdict stands */
      "  for i = 1, 400 do if not pcall(B) then Bok = false return end if win() == 2 then return end end end "
      "local function Bto(target) "         /* B holds data until od_peak reaches target */
      "  for i = 1, 4000 do if peak() >= target then return end if not pcall(Bhold) then Bok = false return end end end "
      "local function tail() "               /* W8's tail: format while held, drop, carry on */
      "  if not Aok then msg = 'err: ' .. tostring(Aerr) end "
      "  h = nil __wvh = nil bh = nil "
      "  local s = string.rep('y', 256) local t = {1, 2, 3} "
      "  return '|' .. tostring(Aok) .. '|' .. msg .. '|' .. #s .. '|' .. #t end "
      "local co = coroutine.create(function() ";
    static const char *WV_FOOT =
      "end) "
      "__wvk = -1 "
      "local t = _OCLJ_WATCHDOG.arm(3600, function() end, true) "
      "local okr, r = coroutine.resume(co) "
      "if okr and r == 'kernel' then "       /* W22: the kernel allocates at depth 0, then resumes */
      "  _OCLJ_WATCHDOG.disarm(t) "
      "  __wvk = pcall(__wvmk, 11 * 1024 / 8) and 1 or 0 "
      "  t = _OCLJ_WATCHDOG.arm(3600, function() end, true) "
      "  okr, r = coroutine.resume(co) "
      "end "
      "_OCLJ_WATCHDOG.disarm(t) "
      "if not okr then __wv = 'sandbox died: ' .. tostring(r) end";
    /* W20: A opens the window; B brings the verdict and goes on allocating
     * with it standing (held); A's own next crossing meets it. */
    static const char *W20_BODY =
      "  local ok1, r1 = pcall(A, 'open') "
      "  if not ok1 or r1 ~= 'open' then __wv = 'A-early:' .. tostring(r1) return end "
      "  Bverdict() w2 = win() "
      "  for i = 1, 8 do if not pcall(B) then Bok = false end end "
      "  Aok, Aerr = pcall(A, 'fill') "
      "  __wv = (Bok and 'B-held' or 'B-REFUSED') .. '|w2=' .. w2 .. tail() ";
    /* W21: as W20 to the standing verdict, then B holds data up to 400 B
     * under the hold's ceiling; a hot allocation-free loop is recorded and
     * the recorder's own request past that ceiling is refused: it must open
     * nothing, and A's own next crossing must still meet the verdict. */
    static const char *W21_BODY =
      "  local ok1, r1 = pcall(A, 'open') "
      "  if not ok1 or r1 ~= 'open' then __wv = 'A-early:' .. tostring(r1) return end "
      "  Bverdict() w2 = win() "
      "  Bto(__wvtarget) "
      "  local pk1, tier1, ref1 = peak(), tier(), (select(4, _OCLJ_GCSTATS())) "
      "  jit.on() "
      "  local function H() local s = 0 for i = 1, 400 do s = s + (i * 3) % 7 end return s end "
      "  local okh = pcall(H) "
      "  jit.off() "
      "  local tier2, ref2 = tier(), (select(4, _OCLJ_GCSTATS())) "
      "  Aok, Aerr = pcall(A, 'fill') "
      "  __wv = (Bok and 'B-held' or 'B-REFUSED') .. '|w2=' .. w2 .. '|pk1=' .. pk1 .. '|tier1=' .. tier1 "
      "    .. '|recref=' .. (ref2 - ref1) .. '|tier2=' .. tier2 .. '|okh=' .. tostring(okh) .. tail() ";
    /* W22: the hold's room, and the kernel's room past it: with the verdict
     * standing B holds data 2 KB past the window (held, not refused); the
     * kernel then makes its 11 KB table at depth 0 (granted); A's own
     * crossing meets the verdict. */
    static const char *W22_BODY =
      "  local ok1, r1 = pcall(A, 'open') "
      "  if not ok1 or r1 ~= 'open' then __wv = 'A-early:' .. tostring(r1) return end "
      "  Bverdict() w2 = win() "
      "  Bto(__wvtarget2) "
      "  local pk1, tier1 = peak(), tier() "
      "  coroutine.yield('kernel') "
      "  Aok, Aerr = pcall(A, 'fill') "
      "  __wv = (Bok and 'B-held' or 'B-REFUSED') .. '|w2=' .. w2 .. '|pk1=' .. pk1 .. '|tier1=' .. tier1 .. '|k=' .. __wvk .. tail() ";
    /* W23: B makes the first growths past the cap and HOLDS them (so no proof
     * under the cap resets the vote); A then grows past S and holds the
     * data: the verdict must be A's, by the vote overtaking B's lead. */
    static const char *W23_BODY =
      "  local ok0 = pcall(function() while n < 200000 and collectgarbage('count') * 1024 < cap - 1024 do n = n + 1 h[n] = {n} end end) "
      "  for i = 1, 96 do if not pcall(Bhold) then Bok = false end end "
      "  Aok, Aerr = pcall(A, 'fill') "
      "  __wv = (Bok and 'B-ok' or 'B-REFUSED') .. '|' .. tostring(ok0) .. tail() ";
    /* W24: the program's growth moves to another of its own handlers after
     * the window opened: it is refused later -- the hold's room -- but its
     * recovery must be intact (a regression guard: the first draft of this
     * design killed this sandbox). */
    static const char *W24_BODY =
      "  local ok1, r1 = pcall(A, 'open') "
      "  if not ok1 or r1 ~= 'open' then __wv = 'A-early:' .. tostring(r1) return end "
      "  Aok, Aerr = pcall(A2) "
      "  __wv = 'switch' .. tail() ";
    /* W25: a standing verdict survives the proofs that collected garbage
     * demotes: with the verdict standing, B alternates a 2.5 KB garbage string
     * (dropped) and a held table, twenty times (1 KB of held data).  Each
     * proof then finds most of "the bytes since the previous proof" dead and
     * gone; a verdict demoted to "open" by that arithmetic makes B's next
     * 5 KB transient meet the plain ceiling (B refused), a standing one keeps
     * it held in the hold's room.  Then A's own crossing meets the verdict. */
    static const char *W25_BODY =
      "  local ok1, r1 = pcall(A, 'open') "
      "  if not ok1 or r1 ~= 'open' then __wv = 'A-early:' .. tostring(r1) return end "
      "  Bverdict() w2 = win() "
      "  local function Bg() local g = string.rep('g', 2560) local t = {Bn, Bn, Bn} bh[#bh + 1] = t Bn = Bn + #g end "
      "  for i = 1, 20 do if not pcall(Bg) then Bok = false break end end "
      "  local w3 = win() "
      "  Aok, Aerr = pcall(A, 'fill') "
      "  __wv = (Bok and 'B-held' or 'B-REFUSED') .. '|w2=' .. w2 .. '|w3=' .. w3 .. tail() ";
    const char *bodies[6] = { W20_BODY, W21_BODY, W22_BODY, W23_BODY, W24_BODY, W25_BODY };
    const char *names[6] = {
      "W20 THE ADDRESS: a verdict waits for its addressee",
      "W21 THE ADDRESS: the recorder's refusal opens nothing",
      "W22 THE ADDRESS: the hold's room, and the kernel's past it",
      "W23 THE ADDRESS: the addressee is who grows, not who crossed",
      "W24 THE ADDRESS: a handler switch keeps its recovery",
      "W25 THE ADDRESS: a standing verdict survives a proof" };
    FakeState WSv;
    int wv;
    for (wv = 0; wv < 6; wv++) {
      lua_State *Wv;
      long long capv, Gv, lendv, holdv;
      int stv, pass = 0;
      double refv0, refv1, peakv, holdsv, recrefv, failv;
      char src[5120], dv[760];
      const char *res;
      Wv = w_newstate(&WSv, 64 * 1024 * 1024, 1);
      if (!Wv) { printf("  FAIL  %s: no state\n", names[wv]); return 1; }
      runstr(Wv, "jit.off() __wv = 'unset'");
      lua_createtable(Wv, 8192, 0);            /* the holder, pre-sized: never grown */
      lua_setglobal(Wv, "__wvh");
      lua_pushcfunction(Wv, w19_mk);
      lua_setglobal(Wv, "__wvmk");
      lua_gc(Wv, LUA_GCCOLLECT, 0);
      lua_gc(Wv, LUA_GCCOLLECT, 0);
      settle_gc(Wv);
      lua_settop(Wv, 0);
      capv = j_used(Wv, &WSv) + 256 * 1024;
      Gv = w_odmax(capv);
      lendv = (long long)WALL_LEND(Wv);
      if (lendv < 0) lendv = 0;                /* a shim before THE WINDOW */
      holdv = (long long)statn(Wv, "_OCLJ_WALLSTATS", 18);
      if (holdv < 0) holdv = 0;                /* a shim before THE ADDRESS */
      lua_pushnumber(Wv, (lua_Number)capv);
      lua_setglobal(Wv, "__wvcap");
      lua_pushnumber(Wv, (lua_Number)(Gv / 2 + lendv + holdv - 400));   /* W21: B's target, od_peak */
      lua_setglobal(Wv, "__wvtarget");
      lua_pushnumber(Wv, (lua_Number)(Gv / 2 + lendv + 2048));          /* W22: 2 KB past the window */
      lua_setglobal(Wv, "__wvtarget2");
      sprintf(src, "%s%s%s", WV_HEAD, bodies[wv], WV_FOOT);
      w_setcap(Wv, &WSv, capv, 1);
      refv0 = GC_REFUSALS(Wv);
      stv = runstr(Wv, src);
      w_setcap(Wv, &WSv, 64 * 1024 * 1024, 1);
      refv1 = GC_REFUSALS(Wv) - refv0;
      peakv = WALL_ODPEAK(Wv);
      holdsv = statn(Wv, "_OCLJ_WALLSTATS", 14);     /* -1 on a shim without THE ADDRESS */
      recrefv = statn(Wv, "_OCLJ_WALLSTATS", 15);
      failv = statn(Wv, "_OCLJ_WALLSTATS", 19);
      if (stv != 0) res = errtop(Wv);
      else { lua_getglobal(Wv, "__wv"); res = lua_tostring(Wv, -1); if (!res) res = "(nil)"; }
      switch (wv) {
      case 0:  /* B held with the verdict standing; A refused; one refusal; the tail works */
        pass = stv == 0 && strstr(res, "B-held|w2=2|false|err: not enough memory|256|3") == res
               && refv1 == 1 && holdsv >= 9;
        break;
      case 1: {  /* B's held data reached the hold's room (pk1, read before the hot loop) and no
                  * further; the recorder was refused at least once and the tier stayed BURST
                  * through it; A still refused, with its recovery */
        const char *q = strstr(res, "|pk1=");
        double pk1 = q ? atof(q + 5) : -1;
        pass = stv == 0 && strstr(res, "B-held|w2=2|") == res && strstr(res, "|tier1=0|") != NULL
               && strstr(res, "|tier2=0|") != NULL && strstr(res, "|recref=0|") == NULL
               && strstr(res, "|false|err: not enough memory|256|3") != NULL
               && pk1 >= (double)(Gv / 2 + lendv + holdv - 400) && pk1 <= (double)(Gv / 2 + lendv + holdv);
        break;
      }
      case 2:  /* B went 2 KB past the window unrefused; the kernel's 11 KB table granted; A refused, recovered */
        pass = stv == 0 && strstr(res, "B-held|w2=2|") == res && strstr(res, "|tier1=0|k=1|false|err: not enough memory|256|3") != NULL
               && refv1 == 1 && peakv >= (double)(Gv / 2 + lendv + 2048);
        break;
      case 3:  /* A's verdict within half the window, one refusal, the tail works */
        pass = stv == 0 && strstr(res, "B-ok|true|false|err: not enough memory|256|3") == res
               && refv1 == 1 && peakv > (double)(Gv / 2) && peakv <= (double)(Gv / 2) + lendv / 2.0;
        break;
      case 4:  /* refused once, by the hold's ceiling at the latest (od_peak then includes the
                * recovery's own allocations in the reserve tier: 1 KB allowed), recovery intact */
        pass = stv == 0 && strstr(res, "switch|false|err: not enough memory|256|3") == res
               && refv1 == 1 && peakv <= (double)(Gv / 2 + lendv + holdv + 1024);
        break;
      case 5:  /* B held throughout (never met the plain ceiling), the verdict still standing after; A refused, recovered */
        pass = stv == 0 && strstr(res, "B-held|w2=2|w3=2|false|err: not enough memory|256|3") == res
               && refv1 == 1;
        break;
      }
      sprintf(dv, "cap %ld, G %ld, window %ld, hold %ld: status %d, '%.120s'; refusals +%.0f, od_peak %.0f (G/2 %ld), holds %.0f, recorder refusals %.0f, hold ceilings %.0f",
              (long)capv, (long)Gv, (long)lendv, (long)holdv, stv, res, refv1, peakv, (long)(Gv / 2), holdsv, recrefv, failv);
      lua_settop(Wv, 0);
      ok(pass, names[wv], dv);
      clear_javastate(Wv);
      lua_close(Wv);
    }
  }

