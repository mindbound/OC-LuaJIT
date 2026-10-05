#!/bin/sh
# native/luajit/patch-fastfunc-errmem-top.sh -- the second function of LuaJIT
# we change (two places in lj_err.c: lj_err_mem and lj_err_err).
#
#     sh native/luajit/patch-fastfunc-errmem-top.sh <in lj_err.c> <out lj_err.c>
#
# <in> and <out> may name the SAME file: build-native.sh patches the build
# copy in place, after re-copying the PRISTINE lj_err.c over it, exactly as it
# does for native/luajit/patch-penalty-scrub.sh (whose header explains why the
# build never relies on the "already patched" path below).
#
# WHAT IS WRONG.  When the allocator refuses, lj_err_mem (lj_err.c:813) pushes
# the "not enough memory" message at L->top and throws.  It refreshes L->top
# from the frame first only when the running function is a Lua function
# (curr_funcisL, :823-830); a C function keeps L->top right through the C API.
# A FAST function is neither.  tostring's inline number path (vm_x64.dasc
# :1370-1394) stores L->base and not L->top before it calls lj_strfmt_num
# (":1385  Add frame since C call can throw"), and so do string.char and
# string.sub (->fff_newstr, :1967-1974, lj_str_new) and string.reverse, lower
# and upper (ffstring_op, :2043-2066); the fallback and GC-step paths (:2190,
# :2242) store both.  If that call's allocation is refused, L->top is whatever
# the last C call left there, which can be BELOW the fast function's frame;
# on the crashing trajectory it is exactly L->base-1.  The push then writes a
# NaN-boxed string over that frame slot (the frame link, with LJ_FR2),
# err_unwind (lj_err.c:109) reads it as a Lua frame's saved PC and
# dereferences it (frame_prevl, lj_frame.h:108): an access violation inside
# LuaJIT's own unwinder.  In a game that is the whole JVM gone, not a machine
# error.  Found 2026-10-05 by the hermetic capacity probe under the
# collector-at-the-wall work, root-caused and verified by two analysts
# (bench/runs/2026-10-05-window/crash/).
#
# INSIDE AN ERROR HANDLER it is worse.  L->status is LUA_ERRERR for the whole
# run of an xpcall message handler (lj_err.c:900), and there lj_err_mem hands
# straight to lj_err_err (:815-816), which pushes its own message at L->top
# (:806-810) with neither the refresh nor anything else -- for a Lua function
# too.  A handler that formats the error is exactly what runs right after a
# refusal.  lj_err_stkov reaches lj_err_err the same way (:913-914).
#
# THE FIX.  Never push the message below the current frame: right before each
# of the two pushes, if L->top < L->base, set L->top = L->base.  err_unwind
# walks frames at L->base-1 and below, so the message is out of its way, and
# the error object still reaches the handler (unwindstack copies L->top-1).
# In lj_err_mem it is a no-op for Lua functions (the refresh above leaves
# L->top at or above L->base) and for C functions (their top is never below
# their base).  The evidence is a census (bench/runs/2026-10-05-errmem/): the
# same driver and shim crashed on 1 653 of 4 608 caps with no fix and on 0 of
# 4 096 with the investigator's form of the lj_err_mem clamp; this script's
# output, in the shipped libluajit.a, on 0 of 2 048 with every output line
# identical to that form's.
#
# Anchored, refusing otherwise, on the whole 4-line body of lj_err_err and on
# lj_err_mem's last three statements -- the brace closing the curr_funcisL
# block, the ERRMEM push and the throw -- which must be CONSECUTIVE and occur
# exactly once; verified by content afterwards rather than trusted.  The
# inserted blocks contain NO backslashes and NO tabs on purpose: they are
# spliced by awk from here-documents, and both have bitten this project.
set -u

[ $# -eq 2 ] || { echo "usage: patch-fastfunc-errmem-top.sh <in lj_err.c> <out lj_err.c>" >&2; exit 2; }
IN=$1
OUT=$2
[ -f "$IN" ] || { echo "patch-fastfunc-errmem-top.sh: no $IN" >&2; exit 2; }

# The lines that identify a patched file.  MARK and GUARD occur once per
# site (2); the rest exactly once.
MARK='OC-LuaJIT (native/luajit/patch-fastfunc-errmem-top.sh)'
GUARD='  if (LJ_UNLIKELY(L->top < L->base))'
ESIG='LJ_NORET LJ_NOINLINE static void lj_err_err(lua_State *L)'
EPUSH='  setstrV(L, L->top++, lj_err_str(L, LJ_ERR_ERRERR));'
ETHROW='  lj_err_throw(L, LUA_ERRERR);'
SIG='LJ_NOINLINE void lj_err_mem(lua_State *L)'
PUSH='  setstrV(L, L->top++, lj_err_str(L, LJ_ERR_ERRMEM));'
THROW='  lj_err_throw(L, LUA_ERRMEM);'

fail() { echo "patch-fastfunc-errmem-top.sh: $*" >&2; exit 1; }
count() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }

# The blocks go right before each push.  Separate files so awk splices them
# verbatim.
BLOCK=${TMPDIR:-/tmp}/fastfunc-errmem-top-block.$$
EBLOCK=${TMPDIR:-/tmp}/fastfunc-errmem-top-eblock.$$
trap 'rm -f "$BLOCK" "$EBLOCK"' EXIT
cat > "$BLOCK" <<'EOF'
  /* OC-LuaJIT (native/luajit/patch-fastfunc-errmem-top.sh): never push the
  ** message below the current frame.  A fast function is neither a Lua nor a
  ** C function: tostring's inline number path, string.char, sub, reverse,
  ** lower and upper store L->base but not L->top before a C call that
  ** allocates, so when that allocation is refused the refresh above is
  ** skipped and L->top can be stale below the frame.  The push would write
  ** the message over the frame link at L->base-1, which err_unwind then
  ** dereferences as a saved PC.  A no-op for Lua and C functions.
  */
  if (LJ_UNLIKELY(L->top < L->base))
    L->top = L->base;
EOF
cat > "$EBLOCK" <<'EOF'
  /* OC-LuaJIT (native/luajit/patch-fastfunc-errmem-top.sh): the same clamp
  ** as in lj_err_mem, for a refusal inside an error handler (no refresh). */
  if (LJ_UNLIKELY(L->top < L->base))
    L->top = L->base;
EOF
NBLOCK=$(wc -l < "$BLOCK" | tr -d ' ')
NEBLOCK=$(wc -l < "$EBLOCK" | tr -d ' ')
for b in "$BLOCK" "$EBLOCK"; do
  [ "$(count "$MARK" "$b")" = 1 ] && [ "$(count "$GUARD" "$b")" = 1 ] \
    || fail "internal: a block does not carry its own markers exactly once"
done

# Verify a file carries the clamp exactly twice: inside lj_err_err directly
# ahead of its push, and inside lj_err_mem directly ahead of its push.  Used
# for the idempotent path and for the output.
verify_patched() {
  f=$1
  [ "$(count "$MARK" "$f")" = 2 ]  || fail "$f: marker present $(count "$MARK" "$f") times, expected 2"
  [ "$(count "$GUARD" "$f")" = 2 ] || fail "$f: clamp present $(count "$GUARD" "$f") times, expected 2"
  [ "$(count "$ESIG" "$f")" = 1 ]  || fail "$f: lj_err_err signature present $(count "$ESIG" "$f") times, expected 1"
  [ "$(count "$EPUSH" "$f")" = 1 ] || fail "$f: the ERRERR push present $(count "$EPUSH" "$f") times, expected 1"
  [ "$(count "$SIG" "$f")" = 1 ]   || fail "$f: lj_err_mem signature present $(count "$SIG" "$f") times, expected 1"
  [ "$(count "$PUSH" "$f")" = 1 ]  || fail "$f: the ERRMEM push present $(count "$PUSH" "$f") times, expected 1"
  # Order: lj_err_err's signature (E), a clamp (G), its assignment on the
  # very next line (A), the ERRERR push (Q) and its throw (R) on the two lines
  # after; then lj_err_mem's signature (S), a clamp, its assignment, the
  # ERRMEM push (P) and its throw (T) likewise.  awk reports what it saw.
  ORDER=$(awk -v esig="$ESIG" -v epush="$EPUSH" -v ethrow="$ETHROW" \
              -v sig="$SIG" -v guard="$GUARD" -v push="$PUSH" -v throw="$THROW" '
    { sub(/\r$/, "") }
    $0 == esig  { o = o "E" }
    $0 == sig   { o = o "S" }
    $0 == guard { o = o "G"; g = NR }
    g && NR == g + 1 && $0 == "    L->top = L->base;" { o = o "A" }
    g && NR == g + 2 && $0 == epush  { o = o "Q" }
    g && NR == g + 3 && $0 == ethrow { o = o "R" }
    g && NR == g + 2 && $0 == push   { o = o "P" }
    g && NR == g + 3 && $0 == throw  { o = o "T" }
    END { print o }' "$f")
  [ "$ORDER" = "EGAQRSGAPT" ] || fail "$f: the clamps are not directly ahead of the two pushes (order seen: $ORDER, want EGAQRSGAPT)"
}

# --- already patched?  verify, copy if asked, and say so ------------------
if grep -q -F -- "$MARK" "$IN"; then
  verify_patched "$IN"
  if [ "$IN" != "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")" || exit 1
    cp "$IN" "$OUT" || fail "cannot copy $IN to $OUT"
  fi
  echo "patch-fastfunc-errmem-top.sh: $(basename "$OUT")  already carries both top clamps (verified: markers, clamps and pushes counted, in order) -- unchanged"
  exit 0
fi

# --- patch ------------------------------------------------------------------
mkdir -p "$(dirname "$OUT")" || exit 1
TMP=$OUT.tmp.$$
trap 'rm -f "$BLOCK" "$EBLOCK" "$TMP"' EXIT

# CRLF stripped before anything is matched (the pinned tree checks out CRLF on
# Windows); the output is LF.  lj_err_err: its signature, "{", the push and
# the throw must be consecutive; the block goes before the push.  lj_err_mem:
# the brace closing curr_funcisL, the push and the throw must be consecutive;
# the block goes before the push (the brace is held back one line so the push
# can be checked against it, and the throw is checked on the line after).
awk -v esig="$ESIG" -v epush="$EPUSH" -v ethrow="$ETHROW" -v eblock="$EBLOCK" \
    -v sig="$SIG" -v push="$PUSH" -v throw="$THROW" -v block="$BLOCK" '
  function die(msg) { printf("patch-fastfunc-errmem-top.sh: %s\n", msg) > "/dev/stderr"; bad = 1; exit 1 }
  { sub(/\r$/, "") }
  est == 1 { if ($0 != "{") die("lj_err_err: the line after its signature is not an opening brace: [" $0 "]"); est = 2; print; next }
  est == 2 {
    if ($0 != epush) die("lj_err_err: its first statement is not the ERRERR push: [" $0 "]")
    while ((getline l < eblock) > 0) print l
    close(eblock)
    print; esubs++; est = 3; next
  }
  est == 3 { if ($0 != ethrow) die("lj_err_err: the line after the ERRERR push is not the throw: [" $0 "]"); est = 0; print; next }
  st == 3 { if ($0 != throw) die("the line after the ERRMEM push is not the throw: [" $0 "]"); st = 0; print; next }
  $0 == esig { est = 1; print; next }
  $0 == sig { st = 1; print; next }
  st == 1 && $0 == "}" { st = 0; print; next }
  st == 1 && $0 == push {
    if (prev != "  }") die("the line above the ERRMEM push is not the brace closing curr_funcisL: [" prev "]")
    while ((getline l < block) > 0) print l
    close(block)
    print; subs++; st = 3; next
  }
  { prev = $0; print }
  END {
    if (bad) exit 1
    if (esubs != 1 || subs != 1) {
      printf("patch-fastfunc-errmem-top.sh: expected each push exactly once, matched lj_err_err %d, lj_err_mem %d\n", esubs, subs) > "/dev/stderr"
      exit 1
    }
  }
' "$IN" > "$TMP" || fail "refusing -- have lj_err_err or lj_err_mem in lj_err.c changed shape?"

# VERIFY, RATHER THAN TRUST THE AWK.
verify_patched "$TMP"
NADD=$((NBLOCK + NEBLOCK))
NL_IN=$(wc -l < "$IN" | tr -d ' ')
NL_OUT=$(wc -l < "$TMP" | tr -d ' ')
[ "$NL_OUT" = "$((NL_IN + NADD))" ] || fail "line count: $NL_IN in + $NADD blocks != $NL_OUT out"
ADDED=$(diff --strip-trailing-cr "$IN" "$TMP" | grep -c '^>' || true)
REMOVED=$(diff --strip-trailing-cr "$IN" "$TMP" | grep -c '^<' || true)
[ "$ADDED" = "$NADD" ] && [ "$REMOVED" = "0" ] \
  || { diff --strip-trailing-cr "$IN" "$TMP" | head -40 >&2; fail "expected exactly $NADD added and 0 removed lines, got $ADDED added / $REMOVED removed"; }

mv -f "$TMP" "$OUT" || fail "cannot write $OUT"
trap 'rm -f "$BLOCK" "$EBLOCK"' EXIT
echo "patch-fastfunc-errmem-top.sh: $(basename "$OUT")  $NEBLOCK lines into lj_err_err and $NBLOCK into lj_err_mem (of $NL_OUT), 0 removed; clamps verified by content"
