#!/bin/sh
# patch-fastfunc-errmem-top.sh -- a second, separate LuaJIT function patch,
# in the shape of native/luajit/patch-penalty-scrub.sh.  NOT applied to the
# repo by this task; produced for review.
#
#     sh patch-fastfunc-errmem-top.sh <in lj_err.c> <out lj_err.c>
#
# WHAT IS WRONG.  lj_err_mem (lj_err.c:813) refreshes L->top from the frame
# only when the current function is a Lua function (curr_funcisL, :823-830).
# For a C function L->top is maintained by the C API, so that is normally
# fine -- BUT a FAST function is neither.  ff_tostring's inline number path
# (vm_x64.dasc:1370/1379-1394) sets only L->base ("Add frame since C call can
# throw", :1385) and calls lj_strfmt_num without setting L->top; L->top is
# left at a stale value that, on this trajectory, equals L->base-1.  When the
# allocator refuses the result string (lj_str_new -> lj_mem_realloc -> NULL),
# lj_err_mem pushes the ERRMEM message at that stale top with
# setstrV(L, L->top++, ...) (:831) -- writing a NaN-boxed GCstr onto the
# frame-info slot L->base-1.  lj_err_throw -> the Windows SEH handler
# lj_err_unwind_win -> err_unwind (:109) then walks that slot: its low 3 bits
# are 0, so frame_typep reads FRAME_LUA (:129), and frame_prevl dereferences
# the boxed value as a bytecode PC (bc_a(frame_pc(f)[-1]), lj_frame.h:108).
# The value is non-canonical (top bits LJ_TSTR = 0x1fffb), so the read #GPs
# and the process dies (SIGSEGV / exit 139), inside LuaJIT's own unwinder.
#
# THE FIX.  Never let lj_err_mem push the message below the current frame.
# If the current function is not a Lua function and L->top is below L->base
# (only a fast function with a stale top does this), clamp L->top up to
# L->base before the push.  err_unwind reads frame = L->base-1 and lower and
# never the slots at/above L->base, so the message is then out of its way;
# the error object is still delivered (unwindstack copies L->top-1, :94-106).
# One else-if, no new failure mode for the Lua or C paths.
#
# Anchored on the ERRMEM push, which occurs EXACTLY once, and on the
# curr_funcisL block that must immediately precede it.  No backslashes, no
# tabs in the inserted block (both have bitten this project).
set -u

[ $# -eq 2 ] || { echo "usage: patch-fastfunc-errmem-top.sh <in lj_err.c> <out lj_err.c>" >&2; exit 2; }
IN=$1; OUT=$2
[ -f "$IN" ] || { echo "patch-fastfunc-errmem-top.sh: no $IN" >&2; exit 2; }

MARK='OC-LuaJIT (native/luajit/patch-fastfunc-errmem-top.sh)'
GUARD='  } else if (LJ_UNLIKELY(L->top < L->base)) {'
PUSH='  setstrV(L, L->top++, lj_err_str(L, LJ_ERR_ERRMEM));'
SIG='LJ_NOINLINE void lj_err_mem(lua_State *L)'
CURR='  if (curr_funcisL(L)) {'

fail() { echo "patch-fastfunc-errmem-top.sh: $*" >&2; exit 1; }
count() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }

verify_patched() {
  f=$1
  [ "$(count "$MARK" "$f")" = 1 ]  || fail "$f: marker x$(count "$MARK" "$f"), expected 1"
  [ "$(count "$GUARD" "$f")" = 1 ] || fail "$f: guard x$(count "$GUARD" "$f"), expected 1"
  [ "$(count "$PUSH" "$f")" = 1 ]  || fail "$f: ERRMEM push x$(count "$PUSH" "$f"), expected 1"
  [ "$(count "$SIG" "$f")" = 1 ]   || fail "$f: lj_err_mem signature x$(count "$SIG" "$f"), expected 1"
}

# Idempotent path: an already-patched input is verified and copied.
if [ "$(count "$MARK" "$IN")" != 0 ]; then
  verify_patched "$IN"
  [ "$IN" = "$OUT" ] || cp "$IN" "$OUT"
  echo "patch-fastfunc-errmem-top.sh: $IN already patched; left as is"
  exit 0
fi

# Pristine input: the ERRMEM push is the unique splice anchor; the
# curr_funcisL block must exist (it also appears in lj_err_run, so >= 1).
[ "$(count "$PUSH" "$IN")" = 1 ] || fail "$IN: ERRMEM push x$(count "$PUSH" "$IN"), expected 1 (not the pristine lj_err.c?)"
[ "$(count "$CURR" "$IN")" -ge 1 ] || fail "$IN: '$CURR' not found"

BLOCK=${TMPDIR:-/tmp}/ff-errmem-top-block.$$
trap 'rm -f "$BLOCK"' EXIT
# The replacement for the lone "  }" that closes the curr_funcisL block and
# sits immediately above the ERRMEM push.  No tabs, no backslashes.
cat > "$BLOCK" <<'EOF'
  } else if (LJ_UNLIKELY(L->top < L->base)) {
    /* OC-LuaJIT (native/luajit/patch-fastfunc-errmem-top.sh): a fast function
    ** (e.g. ff_tostring's inline number path) can enter a throwing C call
    ** having set only L->base, leaving L->top stale below the frame.  Pushing
    ** the ERRMEM message there would overwrite the frame-info slot L->base-1
    ** with a NaN-boxed string; err_unwind would then read it as a FRAME_LUA
    ** PC and dereference a non-canonical pointer.  Never push below base. */
    L->top = L->base;
  }
EOF

# Splice: when we reach the ERRMEM push, the line we buffered must be "  }".
awk -v push="$PUSH" -v blockfile="$BLOCK" '
  function emitblock(   line) { while ((getline line < blockfile) > 0) print line; close(blockfile) }
  {
    cur = $0; sub(/\r$/, "", cur)
    if (cur == push) {
      if (prev_raw_set && prevtrim != "  }") { print "ANCHOR FAIL: line above ERRMEM push is not a lone brace: [" prevtrim "]" > "/dev/stderr"; exit 3 }
      emitblock()
      print $0
      have_prev = 0
      next
    }
    if (have_prev) print prevline
    prevline = $0; prevtrim = cur; prev_raw_set = 1; have_prev = 1
  }
  END { if (have_prev) print prevline }
' "$IN" > "$OUT" || fail "awk splice failed"

verify_patched "$OUT"
echo "patch-fastfunc-errmem-top.sh: patched $IN -> $OUT"
