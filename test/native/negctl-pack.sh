#!/bin/sh
# =====================================================================
# negctl-pack.sh -- PROVE that run-pack.sh and run-packfuzz.sh have teeth.
#
#   OCLJ_BUILD=<build dir used by build-native.sh>  sh test/native/negctl-pack.sh
#
# Requires build-native.sh to have run first, on THIS platform, and a built
# PUC Lua 5.3.6 (run-packfuzz.sh's reference; OCLJ_LUA53).  It copies the
# build's LuaJIT tree and objects into a fresh work directory
# ($OCLJ_BUILD/negctl-pack/<stamp>-<pid>; nothing else is written), and then,
# one arm at a time, rebuilds only lib_string.o (and the archive and
# luajit.exe that contain it) from a sabotaged copy of
# native/luajit/oclj_strpack.c -- each sabotage ONE line, anchored and
# asserted to occur exactly once -- and runs both suites against it:
#
#   canon       the real file: both suites must PASS (the positive control)
#   each other  must be CAUGHT: at least one suite exits 1, neither exits 2
#
# There are 28 sabotage arms, then the unregistered arm below.  The last four
# isolate decided behaviour no earlier arm does: D6WIDE drops pk_unpackint's
# refusal of a 9- to 16-byte field whose extra bytes are not a sign
# extension; JUNS reads an unsigned field of 8 bytes or more (J, I8, L, T,
# I9..I16) unsigned, without 5.3.6's wrap to a negative integer; TIESAWAY
# rounds the ties between 2^53 and 2^62 away from zero, not to even (D1);
# D4OFFBY1 makes D4 an off-by-one (> for >=), which only pack_test.c's PT7
# sees: a result of exactly LJ_MAX_STR bytes, packed under its cap.
#
# Every sabotage is memory-safe by construction: each one refuses more,
# computes a different value, or skips a check whose input is still bounded
# downstream; none touches a bound that guards a read or a write (unpack's
# general check, the s[n] payload check's no-wrap form, the z search's bound,
# pass 2's pk_room).  KSTR536 restores 5.3.6's wrapping s[n] check, and is
# safe only because LuaJIT's lj_str_new refuses any length of LJ_MAX_STR or
# more before it reads (lj_str.c:317, :352-353): every length that wraps is
# above 2^64 - 2^31.  PASS2 makes pass 2 ask for one byte more than pass 1
# measured, and pk_room refuses it before the block is overrun.  D6WIDE
# skips a refusal of bytes that unpack's general check has already bounded.
# D4OFFBY1 lets a result of exactly LJ_MAX_STR bytes on to lua_newuserdata,
# whose LJ_MAX_UDATA check admits it (lj_api.c:752) and whose allocation
# pack_test.c's 64 MiB cap refuses before the system allocator is called
# (lj52_alloc); on luajit.exe, which has no cap, it would be a 2 GB block
# written within its bounds, and no case packs that total there (the fuzzer
# keeps pack's c at 2^20 or less).
#
# The last arm, unregistered, compiles the PRISTINE lib_string.c from the
# pinned checkout (OCLJ_LUAJIT): string.pack is then simply missing, as on
# every build before 2026-10-17.
#
# OCLJ_NEGCTL_ARMS (default empty: every arm) runs only the arms it names,
# separated by spaces or commas.  canon always runs; the unregistered arm
# runs only when named.  A name that is no arm is a setup failure (exit 2).
# A selected run proves only the arms it ran, and its last line says so.
#
# Exit 0 iff canon passes and every other arm is caught; 1 otherwise; 2 if
# the control could not be set up.  NEGCTL_FUZZ_CASES (default 2000) sizes
# the fuzzer per arm: its ~240 fixed edge cases catch every arm the fuzzer
# catches, except LJCOERCE, which only the random cases' hostile string
# arguments reach (2026-10-17: MISMATCH 0 at 0 random cases, 10 at 2000).
# Of the four newest arms, measured at 0 and at 2000 random cases, D4OFFBY1
# is caught by neither (pack_test.c PT7 catches it), the other three by both.
# =====================================================================
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${OCLJ_LUAJIT:=$OCLJ_REPO/prototype/watchdog/luajit}"
: "${NEGCTL_FUZZ_CASES:=2000}"
: "${OCLJ_NEGCTL_ARMS:=}"
: "${JOBS:=4}"

fail() { echo "NEGCTL-PACK SETUP FAIL: $*" >&2; exit 2; }

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) OCLJ_OS=windows ; PICFLAG= ;;
  Linux)   OCLJ_OS=linux  ; PICFLAG=-fPIC ;;
  Darwin)  OCLJ_OS=darwin ; PICFLAG=-fPIC ;;
  *) fail "unsupported host system $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  OCLJ_ARCH=x86_64  ;;
  aarch64|arm64) OCLJ_ARCH=aarch64 ;;
  *) fail "unsupported machine $(uname -m)" ;;
esac
PLATFORM="$OCLJ_OS-$OCLJ_ARCH"
SRCTREE=$OCLJ_BUILD/luajit-$PLATFORM
SRCOBJ=$OCLJ_BUILD/obj-$PLATFORM
CANON_C=$OCLJ_REPO/native/luajit/oclj_strpack.c
[ -f "$SRCTREE/src/libluajit.a" ] || fail "no $SRCTREE/src/libluajit.a -- run build-native.sh first (on THIS platform)"
[ -f "$SRCOBJ/lj52shim.o" ] && [ -f "$SRCOBJ/eris_lj.o" ] || fail "no $SRCOBJ/lj52shim.o or eris_lj.o -- run build-native.sh first"
[ -f "$CANON_C" ] || fail "no $CANON_C"
cmp -s "$CANON_C" "$SRCTREE/src/oclj_strpack.c" \
  || fail "$SRCTREE/src/oclj_strpack.c is not $CANON_C: rebuild with build-native.sh before proving anything about it"
[ -f "$OCLJ_LUAJIT/src/lib_string.c" ] || fail "no $OCLJ_LUAJIT/src/lib_string.c (the unregistered arm's pristine file; set OCLJ_LUAJIT)"
command -v make >/dev/null 2>&1 || fail "no make on PATH"

rebuild() {  # rebuild <log>: lib_string.o, the archive and luajit.exe
  rm -f "$W/lib_string.o"
  make -C "$W" BUILDMODE=static XCFLAGS="$PICFLAG" Q= -j"$JOBS" > "$1" 2>&1
}
# sabotage <old line> <new text>: one exact line of the canonical file, which
# must occur exactly once; ENVIRON, so no awk escape processing.
sabotage() {
  OLD=$1 NEW=$2 awk '
    $0 == ENVIRON["OLD"] { print ENVIRON["NEW"]; n++; next }
    { print }
    END { exit n == 1 ? 0 : 1 }' "$CANON_C" > "$W/oclj_strpack.c"
}
runsuites() {  # runsuites <arm dir>: sets RP and RF to the two exit codes
  OCLJ_BUILD=$WB OCLJ_REPO=$OCLJ_REPO OCLJ_PACK_OUT=$1/pack sh "$SELF_DIR/run-pack.sh" > "$1/run-pack.log" 2>&1
  RP=$?
  OCLJ_BUILD=$WB OCLJ_REPO=$OCLJ_REPO OCLJ_PACKFUZZ_OUT=$1/fuzz OCLJ_PACKFUZZ_CASES=$NEGCTL_FUZZ_CASES \
    sh "$SELF_DIR/run-packfuzz.sh" > "$1/run-packfuzz.log" 2>&1
  RF=$?
}
# wanted <name>: true when no selection was given, or it names the arm.
wanted() {
  [ -z "$NSEL" ] && return 0
  case " $NSEL " in *" $1 "*) return 0 ;; esac
  return 1
}
# arm <name> <old line> <new text>   (name canon: no sabotage)
arm() {
  name=$1
  if [ "$LISTONLY" = 1 ]; then ALLARMS="$ALLARMS $name"; return 0; fi
  [ "$name" = canon ] || wanted "$name" || return 0
  d=$WORK/$name
  mkdir -p "$d" || fail "cannot create $d"
  if [ "$name" = canon ]; then
    cp -p "$CANON_C" "$W/oclj_strpack.c"
  elif ! sabotage "$2" "$3"; then
    echo "[negctl-pack] $name: BROKEN ARM -- its anchor line does not occur exactly once in $CANON_C"
    printf '%-12s %-9s %-9s %s\n' "$name" - - "BROKEN (anchor)" >> "$SUMMARY"; bad=1; return
  fi
  if ! rebuild "$d/build.log"; then
    echo "[negctl-pack] $name: BROKEN ARM -- the sabotaged file does not build (log: $d/build.log)"
    tail -5 "$d/build.log" | sed 's/^/  | /'
    printf '%-12s %-9s %-9s %s\n' "$name" - - "BROKEN (build)" >> "$SUMMARY"; bad=1; return
  fi
  runsuites "$d"
  parts=$(grep -E '^(FAIL|PASS) ' "$d/run-pack.log" | awk '$1 == "FAIL" { id = $2; sub(/:$/, "", id); printf "%s%s", sep, id; sep = "," }')
  if [ "$name" = canon ]; then
    if [ "$RP" = 0 ] && [ "$RF" = 0 ]; then v="PASS (both suites pass)"; else v="FAIL (the canonical file must pass)"; bad=1; fi
  elif [ "$RP" = 2 ] || [ "$RF" = 2 ]; then
    v="FAIL (a suite proved nothing: run-pack $RP, packfuzz $RF)"; bad=1
  elif [ "$RP" = 1 ] || [ "$RF" = 1 ]; then
    v="PASS (caught${parts:+ by $parts}$( [ "$RF" = 1 ] && echo ' + fuzzer'))"
  else
    v="FAIL (NOT CAUGHT)"; bad=1
  fi
  echo "[negctl-pack] $name: run-pack $RP, packfuzz $RF -- $v"
  printf '%-12s %-9s %-9s %s\n' "$name" "$RP" "$RF" "$v" >> "$SUMMARY"
}

armlist() {
arm canon '' ''
arm LONG4 \
  "    case 'l': *size = PK_SZINT; return pk_Kint;   /* LJ: D2, 8 everywhere */" \
  "    case 'l': *size = 4; return pk_Kint;  /* SABOTAGE LONG4: sizeof(long) on Win64 */"
arm REFUSE53 \
  '        lua_pushnumber(L, (lua_Number)res);  /* LJ: D1, the nearest double */' \
  '        if (res > ((pk_Int)1 << 53) || res < -((pk_Int)1 << 53)) luaL_error(L, "%d-byte integer does not fit into a Lua number", size); lua_pushnumber(L, (lua_Number)res);  /* SABOTAGE REFUSE53 */'
arm ROUNDDOWN \
  '        lua_pushnumber(L, (lua_Number)res);  /* LJ: D1, the nearest double */' \
  '        { double d_ = (double)res; if (d_ >= 9223372036854775808.0 || (res >= 0 && (pk_Int)d_ > res) || (res < 0 && (pk_Int)d_ < res)) d_ = __builtin_nextafter(d_, 0.0); lua_pushnumber(L, d_); }  /* SABOTAGE ROUNDDOWN: toward zero */'
arm CHECKINT \
  '      if (pk_flt2int(n, &i)) return i;' \
  '      if (n == n && n >= -9223372036854775808.0 && n < 9223372036854775808.0) return (pk_Int)n;  /* SABOTAGE CHECKINT: truncates */'
arm U32 \
  '          luaL_argcheck(L, (pk_Uns)n < ((pk_Uns)1 << (size * PK_NB)),' \
  '          luaL_argcheck(L, (pk_Uns)(uint32_t)n < ((pk_Uns)1 << (size * PK_NB)),  /* SABOTAGE U32: the shim'"'"'s lua_Unsigned */'
arm NOOVF \
  '          luaL_argcheck(L, -lim <= n && n < lim, arg, "integer overflow");' \
  '          (void)lim;  /* SABOTAGE NOOVF */'
arm SLEN \
  '        luaL_argcheck(L, size >= (int)sizeof(size_t) ||' \
  '        luaL_argcheck(L, 1 ||  /* SABOTAGE SLEN */'
arm ZEROS \
  '        luaL_argcheck(L, memchr(s, 0, len) == NULL, arg,' \
  '        luaL_argcheck(L, 1, arg,  /* SABOTAGE ZEROS */'
arm POW2 \
  "    if ((align & (align - 1)) != 0)  /* is 'align' not a power of 2? */" \
  '    if (0)  /* SABOTAGE POW2 */'
arm NOPRINT \
  '      if (opt >= 0x20 && opt <= 0x7e)' \
  "      if (1)  /* SABOTAGE NOPRINT: LuaJIT's raw %c */"
arm ORDER54 \
  '    luaL_argcheck(L, totalsize <= PK_MAXSIZE - (size_t)size, 1,' \
  '    if (opt == pk_Kstring || opt == pk_Kzstr) luaL_argerror(L, 1, "variable-length format");  /* SABOTAGE ORDER54 */
    luaL_argcheck(L, totalsize <= PK_MAXSIZE - (size_t)size, 1,'
arm NOMARK \
  '  lua_pushnil(L);' \
  '  /* SABOTAGE NOMARK: no nil mark */'
arm NONAME \
  '  if (luaL_getmetafield(L, arg, "__name") && lua_type(L, -1) == LUA_TSTRING)' \
  '  if (0)  /* SABOTAGE NONAME */'
arm LJCOERCE \
  '    if (pk_str2int(s, len, pi)) return 1;' \
  "    if (0 && pk_str2int(s, len, pi)) return 1;  /* SABOTAGE LJCOERCE: LuaJIT's scanner only */"
arm PADARG \
  '        if (o != NULL) *pk_room(o, 1) = (char)PK_PADBYTE;' \
  "        if (o != NULL) *pk_room(o, 1) = (char)PK_PADBYTE; arg++;  /* SABOTAGE PADARG: 'x' takes an argument */"
arm GETNUM \
  '    } while (pk_digit(pk_peek(h, *fmt)) && a <= ((int)PK_MAXSIZE - 9)/10);' \
  '    } while (pk_digit(pk_peek(h, *fmt)) && a < ((int)PK_MAXSIZE - 9)/10);  /* SABOTAGE GETNUM */'
arm POSCLIP \
  '  else if (0u - (size_t)pos > len) return 0;' \
  "  else if (0u - (size_t)pos > len) return 1;  /* SABOTAGE POSCLIP: 5.4's posrelatI */"
arm I16NEG \
  '  if (neg && size > PK_SZINT) {  /* negative number need sign extension? */' \
  '  if (0 && neg && size > PK_SZINT) {  /* SABOTAGE I16NEG */'
arm XCAP \
  '    if (align > h->maxalign)  /* enforce maximum alignment */' \
  "    if (opt != pk_Kpaddalign && align > h->maxalign)  /* SABOTAGE XCAP: 'X' not capped by '!' */"
arm Z54 \
  '        size_t len = z != NULL ? (size_t)(z - (data + pos)) : ld - pos;' \
  "        size_t len; luaL_argcheck(L, z != NULL, 2, \"unfinished string for format 'z'\"); len = (size_t)(z - (data + pos));  /* SABOTAGE Z54 */"
arm KSTR54 \
  '            { lua_pushliteral(L, "memory allocation error: block too big"); lua_error(L); }' \
  "            luaL_argerror(L, 2, \"data string too short\");  /* SABOTAGE KSTR54: 5.4's text */"
arm KSTR536 \
  '        if (len > (pk_Uns)(ld - pos - (size_t)size)) {' \
  "        if (pos + len + size > ld) {  /* SABOTAGE KSTR536: 5.3.6's check, which wraps */"
arm PASS2 \
  '          char *buff = pk_room(o, len + 1);' \
  '          char *buff = pk_room(o, len + 2);  /* SABOTAGE PASS2: pass 2 asks for one byte more */'
arm DOUBLEBUF \
  '  o.b = o.cap <= sizeof(sbuf) ? sbuf : (char *)lua_newuserdata(L, o.cap);' \
  '  o.b = o.cap <= sizeof(sbuf) ? sbuf : (lua_newuserdata(L, o.cap), (char *)lua_newuserdata(L, o.cap));  /* SABOTAGE DOUBLEBUF */'
arm D6WIDE \
  '        luaL_error(L, "%d-byte integer does not fit into Lua Integer", size);' \
  '        (void)L;  /* SABOTAGE D6WIDE: a wide field that does not fit is kept */'
arm JUNS \
  '        lua_pushnumber(L, (lua_Number)res);  /* LJ: D1, the nearest double */' \
  '        lua_pushnumber(L, (opt == pk_Kuint && size >= PK_SZINT) ? (lua_Number)(pk_Uns)res : (lua_Number)res);  /* SABOTAGE JUNS: J and I8 read unsigned, no wrap */'
arm TIESAWAY \
  '        lua_pushnumber(L, (lua_Number)res);  /* LJ: D1, the nearest double */' \
  '        { double d_ = (double)res; if (res > ((pk_Int)1 << 53) && res < ((pk_Int)1 << 62)) { pk_Int n_ = (pk_Int)d_; pk_Int u_ = (pk_Int)__builtin_nextafter(d_, 1e300); if (n_ < res && u_ - res == res - n_) d_ = (double)u_; } lua_pushnumber(L, d_); }  /* SABOTAGE TIESAWAY: ties away from zero */'
arm D4OFFBY1 \
  '  if (total >= PK_MAXOUT)' \
  '  if (total > PK_MAXOUT)  /* SABOTAGE D4OFFBY1 */'
}

# The selection, checked against the arm list before anything is copied: a
# name that is no arm would otherwise select nothing and pass.
LISTONLY=1; ALLARMS=; armlist; LISTONLY=0
NSEL=
set -f
for a in $(printf '%s' "$OCLJ_NEGCTL_ARMS" | tr ',' ' '); do
  case " $ALLARMS unregistered " in
    *" $a "*) NSEL="$NSEL $a" ;;
    *) fail "OCLJ_NEGCTL_ARMS names '$a', which is no arm (arms:$ALLARMS unregistered)" ;;
  esac
done
set +f
[ -n "$OCLJ_NEGCTL_ARMS" ] && [ -z "$NSEL" ] && fail "OCLJ_NEGCTL_ARMS is set but names no arm"

WORK=$OCLJ_BUILD/negctl-pack/$(date -u +%Y%m%dT%H%M%SZ)-$$
WB=$WORK/build/native
mkdir -p "$WB/obj-$PLATFORM" || fail "cannot create $WORK"
cp -rp "$SRCTREE" "$WB/" || fail "cannot copy $SRCTREE"
cp -p "$SRCOBJ/lj52shim.o" "$SRCOBJ/eris_lj.o" "$WB/obj-$PLATFORM/" || fail "cannot copy the objects"
W=$WB/luajit-$PLATFORM/src
cp -p "$W/lib_string.c" "$WORK/lib_string.patched.c" || fail "cannot save lib_string.c"
echo "[negctl-pack] work dir $WORK"
[ -n "$NSEL" ] && echo "[negctl-pack] OCLJ_NEGCTL_ARMS:$NSEL, and canon, which always runs -- not the full sweep"

bad=0
SUMMARY=$WORK/summary.txt
printf '%-12s %-9s %-9s %s\n' arm run-pack packfuzz verdict > "$SUMMARY"

armlist

# --- unregistered: the pristine lib_string.c, the canonical oclj_strpack.c -----
if wanted unregistered; then
  name=unregistered
  d=$WORK/$name
  mkdir -p "$d"
  cp -p "$CANON_C" "$W/oclj_strpack.c"
  cp -f "$OCLJ_LUAJIT/src/lib_string.c" "$W/lib_string.c" || fail "cannot copy the pristine lib_string.c"
  if make -C "$W" BUILDMODE=static XCFLAGS="$PICFLAG" Q= -j"$JOBS" > "$d/build.log" 2>&1; then
    runsuites "$d"
    if [ "$RP" = 1 ] && [ "$RF" = 1 ]; then v="PASS (both suites fail: string.pack missing)"
    else v="FAIL (run-pack $RP, packfuzz $RF: want 1 and 1)"; bad=1; fi
  else
    v="BROKEN (build)"; bad=1; RP=-; RF=-
  fi
  echo "[negctl-pack] $name: run-pack $RP, packfuzz $RF -- $v"
  printf '%-12s %-9s %-9s %s\n' "$name" "$RP" "$RF" "$v" >> "$SUMMARY"
  # The work tree is left as the last arm built it (unregistered); the patched
  # lib_string.c it started from is $WORK/lib_string.patched.c.
fi

echo
cat "$SUMMARY"
if [ -n "$NSEL" ]; then
  if [ "$bad" = 0 ]; then
    echo "NEGCTL-PACK: PASS FOR THE SELECTED ARMS ONLY (selected:$NSEL; canon passes; each selected sabotage is caught; results: $WORK)"
    exit 0
  fi
  echo "NEGCTL-PACK: FAIL (selected arms only:$NSEL; results: $WORK)"
  exit 1
fi
if [ "$bad" = 0 ]; then
  echo "NEGCTL-PACK: PASS (canon passes; every sabotage is caught; results: $WORK)"
  exit 0
fi
echo "NEGCTL-PACK: FAIL (results: $WORK)"
exit 1
