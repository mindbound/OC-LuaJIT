#!/bin/sh
# native/jnlua/patch-resume-error.sh -- the ONE line of jnlua.c we change.
#
#     sh native/jnlua/patch-resume-error.sh <in.c> <out.c>
#
# WHAT IS WRONG.  OC-JNLua's lua_1resume (jnlua.c, "lua_resume()") resumes
# the coroutine T from the Java-visible state L and, when the resume fails,
# calls throw(L, status).  throw builds the Java exception from the TOP OF L
# (it pushes throw_protected and lua_insert()s it under the top value), but
# the error object is on T -- lua_resume leaves it there -- and the top of L
# is whatever L had there: the coroutine object itself.  So every error that
# escapes a resumed coroutine surfaces in Java as
#
#     LuaRuntimeException: thread: 0x000001c2f4a6b2c8
#
# and OpenComputers' "kernel panic" log line, which prints exactly that
# exception, never says what the kernel died of.  ("JNLua converts the
# coroutine to a string immediately", as machine.lua's own comment puts it.)
#
# THE FIX is one line: before throw(L, status), move T's error object onto L
# if there is one and L has room for it.  throw then reports the message
# ("too long without yielding", the kernel's actual error) instead of the
# thread.  Nothing else changes: the LUA_OK/LUA_YIELD arm above it already
# xmoves results the same way, the exception class is still chosen from
# `status`, and the thread stays on L where it was.
#
# WHY A PATCH STEP AND NOT A FORK.  build-native.sh's whole claim is that the
# OC-JNLua CHECKOUT is untouched -- it asserts git status on jnlua.c -- and
# the additive variant already rewrites two macro values on a build-dir COPY
# through repack.sh.  This is the same shape: applied to a copy, for BOTH
# variants (the dropin compiled the checkout directly until now; it gets a
# copy too), anchored on context that occurs EXACTLY ONCE in the file, and
# refusing otherwise.  throw(L, status) itself appears four times in jnlua.c;
# the anchor is the sequence inside lua_1resume that no other site has:
#
#         nresults = lua_gettop(T);          (once in the file)
#             lua_xmove(T, L, nresults);     (once in the file)
#         default:                           (the one that follows the two above)
#             throw(L, status);              <- the line replaced
#
# The replacement is ONE LINE for ONE LINE, so the file's line numbers do not
# move -- build-native.sh's warning allowlist pins jnlua.c's two pre-existing
# warnings BY LINE (:623 and :1666), and repack.sh keeps the same property for
# the same reason.  The verification below checks all of it: exactly one
# substitution, the patched text present exactly once, the same number of
# throw(L, status) sites as the input, the same number of lines, and a diff
# of exactly two lines (< and >).
set -u

[ $# -eq 2 ] || { echo "usage: patch-resume-error.sh <in.c> <out.c>" >&2; exit 2; }
IN=$1
OUT=$2
[ -f "$IN" ] || { echo "patch-resume-error.sh: no $IN" >&2; exit 2; }

# jnlua.c indents with tabs: four for the statement inside the switch.
TAB=$(printf '\t')
OLD="$TAB$TAB$TAB$TAB"'throw(L, status);'
# Braces around the one-statement body ON PURPOSE: gcc's -Wmisleading-
# indentation (in -Wall) flags `if (c) a(); b();` on one line, and that would
# be a warning outside build-native.sh's allowlist, i.e. a refused build.  The
# braced form is not flagged (checked, gcc 15.2, 2026-09-22).
NEW="$TAB$TAB$TAB$TAB"'if (lua_gettop(T) > 0 && checkstack(L, 1)) { lua_xmove(T, L, 1); } throw(L, status); /* OC-LuaJIT: report T'"'"'s error object, not the top of L (native/jnlua/patch-resume-error.sh) */'

mkdir -p "$(dirname "$OUT")" || exit 1

# CRLF stripped before anything is matched, for the reason repack.sh gives:
# the checkout is CRLF, MSYS awk hides that and gawk on Linux does not.
awk -v old="$OLD" -v new="$NEW" '
  { sub(/\r$/, "") }
  # A small state machine over the unique context.  Each step must follow
  # the previous one within a few lines (the real sequence spans 8), so a
  # stray "default:" elsewhere in the file can never advance it.
  st > 0 && ++gap > 8            { st = 0 }
  /^\t\t\t\tnresults = lua_gettop\(T\);$/      { st = 1; gap = 0; print; next }
  st == 1 && /^\t\t\t\t\tlua_xmove\(T, L, nresults\);$/ { st = 2; gap = 0; print; next }
  st == 2 && /^\t\t\tdefault:$/                 { st = 3; gap = 0; print; next }
  st == 3 && $0 == old           { print new; subs++; st = 0; next }
  { print }
  END {
    if (subs != 1) {
      printf("patch-resume-error.sh: expected exactly one anchored throw(L, status) inside lua_1resume, got %d\n", subs) > "/dev/stderr"
      exit 1
    }
  }
' "$IN" > "$OUT" || {
  echo "patch-resume-error.sh: refusing -- has lua_1resume in jnlua.c changed shape?" >&2
  rm -f "$OUT"; exit 1
}

# VERIFY, RATHER THAN TRUST THE AWK.
fail() { echo "patch-resume-error.sh: $*" >&2; rm -f "$OUT"; exit 1; }
[ "$(grep -c -F -- "$NEW" "$OUT")" = 1 ] || fail "the patched line is not present exactly once"
NT_IN=$(grep -c -F 'throw(L, status);' "$IN")
NT_OUT=$(grep -c -F 'throw(L, status);' "$OUT")
[ "$NT_IN" = "$NT_OUT" ] || fail "throw(L, status) sites changed: $NT_IN in, $NT_OUT out"
NL_IN=$(wc -l < "$IN" | tr -d ' ')
NL_OUT=$(wc -l < "$OUT" | tr -d ' ')
[ "$NL_IN" = "$NL_OUT" ] || fail "line count changed: $NL_IN in, $NL_OUT out -- the warning allowlist pins line numbers"
DIFFLINES=$(diff --strip-trailing-cr "$IN" "$OUT" 2>/dev/null | grep -c "^[<>]")
[ "$DIFFLINES" = "2" ] || { diff --strip-trailing-cr "$IN" "$OUT" | head -20 >&2; fail "expected exactly 2 diff lines (1 changed line, < and >), got $DIFFLINES"; }

echo "patch-resume-error.sh: $(basename "$OUT")  1 line changed (of $NL_OUT), $NT_OUT throw(L, status) sites as before"
