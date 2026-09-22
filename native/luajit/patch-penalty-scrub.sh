#!/bin/sh
# native/luajit/patch-penalty-scrub.sh -- the ONE function of LuaJIT we change.
#
#     sh native/luajit/patch-penalty-scrub.sh <in lj_func.c> <out lj_func.c>
#
# <in> and <out> may name the SAME file: build-native.sh patches the build
# copy in place.  An already-patched input is verified and left alone (exit
# 0), never patched twice -- but that verification covers only four marker
# lines, so it must NOT be what a build relies on: a hand-edited or stale
# block between the markers would pass it.  build-native.sh therefore
# re-copies the PRISTINE lj_func.c over the build copy before every run of
# this script, so the build always takes the patch path below on upstream
# text; the idempotent path is for hand use and for the output check.
#
# WHAT IS WRONG.  LuaJIT's trace-abort penalty cache, J->penalty[64]
# (lj_jit.h, PENALTY_SLOTS / PENALTY_MIN 72 / PENALTY_MAX 60000), is keyed by
# the raw ADDRESS of a loop-head bytecode (penalty_pc, lj_trace.c).  Each
# abort at a cached pc doubles its value, and past PENALTY_MAX blacklist_pc
# rewrites the head to ILOOP/IFORL/IITERL: that loop runs interpreted for the
# rest of the prototype's life.  The cache is reset by exactly one thing,
# the memset in lj_trace_flushall; a prototype's death, lj_func_freeproto,
# is a bare lj_mem_free.  With a libc heap (our machine allocator is CRT
# realloc/free, native/lj52shim.c lj52_alloc) the freed block goes straight
# back to the next same-size load(), so a FRESH prototype INHERITS the DEAD
# one's penalty slots.  A program re-run from the same source -- a shell
# loop, a REPL, an OS re-loading a program, the harness's encore -- doubles
# the inherited values with its own ordinary nested-loop aborts (LLEAVE /
# LINNER, lj_record.c) and on the 8th-11th re-load its loop heads are
# blacklisted on their first abort; it then runs ~6x slower forever, on every
# re-load at that address.  The persist-side lj_trace_flushall the serializer
# used to do was masking this at save cadence.  Established 2026-09-22
# (docs/research/persistence-clean-slate.md's flush-cost bisect, two
# analysts, standalone reproduction); test/native/penalty_test.c is the
# regression test and reproduces it on an unpatched libluajit.a.
#
# THE FIX.  In lj_func_freeproto, before the block is freed: for each of the
# PENALTY_SLOTS slots, if its pc lies in [proto_bc(pt), proto_bc(pt) +
# pt->sizebc) then set it to NULL.  penalty_pc compares slot pcs against a
# real pc and a NULL never matches one, so a cleared slot is simply reusable
# by the round-robin.  64 pointer compares per prototype death.  Blacklisting
# WITHIN a live prototype is untouched (penalty_test.c's positive control
# shows a loop that always aborts still gets ILOOP/IFORL).
#
# WHY A PATCH STEP AND NOT A FORK.  The pinned LuaJIT tree
# (prototype/watchdog/luajit, upstream 1ee778a4 + the CHECKHOOK patch) is
# COPIED to build/native/luajit-<platform> and built there; the checkout is
# never dirtied.  The project already patches an external source this way on
# a build-dir copy -- native/jnlua/patch-resume-error.sh -- and this is the
# same shape: anchored on context that occurs EXACTLY ONCE in the file, the
# whole 4-line body of lj_func_freeproto, refusing otherwise, and verified
# by content afterwards rather than trusted.  build-native.sh then greps the
# copy make is about to compile for the scrub BEFORE make runs, and checks
# lj_func.o was rebuilt from it afterwards.
#
# The inserted block contains NO backslashes and NO tabs on purpose: it is
# spliced by awk from a here-document, and both have bitten this project.
set -u

[ $# -eq 2 ] || { echo "usage: patch-penalty-scrub.sh <in lj_func.c> <out lj_func.c>" >&2; exit 2; }
IN=$1
OUT=$2
[ -f "$IN" ] || { echo "patch-penalty-scrub.sh: no $IN" >&2; exit 2; }

# The three lines that identify a patched file, each expected EXACTLY once.
MARK='OC-LuaJIT (native/luajit/patch-penalty-scrub.sh)'
SCRUB='        setmref(J->penalty[i].pc, NULL);'
SIG='void LJ_FASTCALL lj_func_freeproto(global_State *g, GCproto *pt)'
FREE='  lj_mem_free(g, pt, pt->sizept);'

fail() { echo "patch-penalty-scrub.sh: $*" >&2; exit 1; }
count() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }

# The block goes between the opening brace and the lj_mem_free.  It is a
# separate file so awk can splice it verbatim (awk -v would reinterpret
# escapes; there are none, but the point is not to rely on that).
BLOCK=${TMPDIR:-/tmp}/penalty-scrub-block.$$
trap 'rm -f "$BLOCK"' EXIT
cat > "$BLOCK" <<'EOF'
#if LJ_HASJIT
  /* OC-LuaJIT (native/luajit/patch-penalty-scrub.sh): scrub this prototype's
  ** entries from the trace-abort penalty cache before its memory is freed.
  ** J->penalty[] is keyed by the raw ADDRESS of a loop-head bytecode and is
  ** otherwise reset only by lj_trace_flushall, so with a libc heap the freed
  ** block goes to the next load() and the FRESH prototype inherits the DEAD
  ** one's penalty values: its own ordinary aborts then double them, and
  ** blacklist_pc rewrites its loop heads to ILOOP/IFORL a few re-loads later.
  ** A NULL pc matches nothing in penalty_pc, so a cleared slot is just free.
  */
  {
    jit_State *J = G2J(g);
    const BCIns *bc = proto_bc(pt);
    const BCIns *bcend = bc + pt->sizebc;
    uint32_t i;
    for (i = 0; i < PENALTY_SLOTS; i++) {
      const BCIns *pc = mref(J->penalty[i].pc, const BCIns);
      if (pc >= bc && pc < bcend)
        setmref(J->penalty[i].pc, NULL);
    }
  }
#endif
EOF
NBLOCK=$(wc -l < "$BLOCK" | tr -d ' ')
[ "$(count "$MARK" "$BLOCK")" = 1 ] && [ "$(count "$SCRUB" "$BLOCK")" = 1 ] \
  || fail "internal: the block does not carry its own markers exactly once"

# Verify a file carries the scrub exactly once, INSIDE lj_func_freeproto,
# ahead of the free.  Used for the idempotent path and for the output.
verify_patched() {
  f=$1
  [ "$(count "$MARK" "$f")" = 1 ]  || fail "$f: marker present $(count "$MARK" "$f") times, expected 1"
  [ "$(count "$SCRUB" "$f")" = 1 ] || fail "$f: scrub line present $(count "$SCRUB" "$f") times, expected 1"
  [ "$(count "$SIG" "$f")" = 1 ]   || fail "$f: lj_func_freeproto signature present $(count "$SIG" "$f") times, expected 1"
  [ "$(count "$FREE" "$f")" = 1 ]  || fail "$f: lj_mem_free(g, pt, pt->sizept) present $(count "$FREE" "$f") times, expected 1"
  # Order: signature, then the scrub, then the free, then the closing brace,
  # with nothing else of ours in between.  awk reports the order it saw.
  ORDER=$(awk -v sig="$SIG" -v scrub="$SCRUB" -v free="$FREE" '
    { sub(/\r$/, "") }
    $0 == sig   { o = o "S" }
    $0 == scrub { o = o "P" }
    $0 == free  { o = o "F" }
    END { print o }' "$f")
  [ "$ORDER" = "SPF" ] || fail "$f: the scrub is not inside lj_func_freeproto ahead of the free (order seen: $ORDER, want SPF)"
}

# --- already patched?  verify, copy if asked, and say so ------------------
if grep -q -F -- "$MARK" "$IN"; then
  verify_patched "$IN"
  if [ "$IN" != "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")" || exit 1
    cp "$IN" "$OUT" || fail "cannot copy $IN to $OUT"
  fi
  echo "patch-penalty-scrub.sh: $(basename "$OUT")  already carries the penalty scrub (verified: marker, scrub and free each exactly once, in order) -- unchanged"
  exit 0
fi

# --- patch ------------------------------------------------------------------
mkdir -p "$(dirname "$OUT")" || exit 1
TMP=$OUT.tmp.$$
trap 'rm -f "$BLOCK" "$TMP"' EXIT

# CRLF stripped before anything is matched (the pinned tree checks out CRLF
# on Windows; MSYS awk hides that and gawk on Linux does not).  The output is
# LF; gcc does not care and the checks below diff with --strip-trailing-cr.
awk -v sig="$SIG" -v free="$FREE" -v block="$BLOCK" '
  { sub(/\r$/, "") }
  # The four lines must be CONSECUTIVE; any other line resets the match.
  st == 0 && $0 == sig  { st = 1; print; next }
  st == 1 && $0 == "{"  { st = 2; print; next }
  st == 2 && $0 == free {
    while ((getline l < block) > 0) print l
    close(block)
    print; subs++; st = 3; next
  }
  st == 3 && $0 == "}"  { st = 0; print; next }
  { st = 0; print }
  END {
    if (subs != 1) {
      printf("patch-penalty-scrub.sh: expected the 4-line lj_func_freeproto body exactly once, matched %d\n", subs) > "/dev/stderr"
      exit 1
    }
  }
' "$IN" > "$TMP" || fail "refusing -- has lj_func_freeproto in lj_func.c changed shape?"

# VERIFY, RATHER THAN TRUST THE AWK.
verify_patched "$TMP"
NL_IN=$(wc -l < "$IN" | tr -d ' ')
NL_OUT=$(wc -l < "$TMP" | tr -d ' ')
[ "$NL_OUT" = "$((NL_IN + NBLOCK))" ] || fail "line count: $NL_IN in + $NBLOCK block != $NL_OUT out"
ADDED=$(diff --strip-trailing-cr "$IN" "$TMP" | grep -c '^>' || true)
REMOVED=$(diff --strip-trailing-cr "$IN" "$TMP" | grep -c '^<' || true)
[ "$ADDED" = "$NBLOCK" ] && [ "$REMOVED" = "0" ] \
  || { diff --strip-trailing-cr "$IN" "$TMP" | head -40 >&2; fail "expected exactly $NBLOCK added and 0 removed lines, got $ADDED added / $REMOVED removed"; }

mv -f "$TMP" "$OUT" || fail "cannot write $OUT"
trap 'rm -f "$BLOCK"' EXIT
echo "patch-penalty-scrub.sh: $(basename "$OUT")  $NBLOCK lines inserted into lj_func_freeproto (of $NL_OUT), 0 removed; scrub verified by content"
