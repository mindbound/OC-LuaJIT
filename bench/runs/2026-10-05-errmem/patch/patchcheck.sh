#!/bin/sh
# patchcheck.sh -- the patch script's own fail-first checks, in a fresh dir.
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
P=$REPO/native/luajit/patch-fastfunc-errmem-top.sh
D=$1
[ -e "$D" ] && { echo "REFUSING: $D exists"; exit 99; }
mkdir -p "$D"; cd "$D" || exit 1
PR=$REPO/prototype/watchdog/luajit/src/lj_err.c
res() { if [ "$1" = "$2" ]; then echo "OK   $3 (exit $1)"; else echo "BAD  $3 (exit $1, want $2)"; fi; }

cp "$PR" a.c
sh "$P" a.c b.c > o1.txt 2>&1; res $? 0 "pristine -> b.c"; cat o1.txt
printf 'CR in b.c: '; tr -cd '\r' < b.c | wc -c
printf 'CR in pristine: '; tr -cd '\r' < "$PR" | wc -c
diff --strip-trailing-cr "$PR" b.c
cp "$PR" c.c
sh "$P" c.c c.c > o2.txt 2>&1; res $? 0 "in place"; cat o2.txt
cmp b.c c.c && echo "OK   in place == out of place"
sh "$P" b.c d.c > o3.txt 2>&1; res $? 0 "idempotent"; cat o3.txt
cmp b.c d.c && echo "OK   idempotent output unchanged"
# Mangling 1: the clamp's assignment altered on an already-patched file.
sed 's/^    L->top = L->base;$/    L->top = L->base - 1;/' b.c > m1.c
grep -c 'L->base - 1;' m1.c
sh "$P" m1.c m1o.c > o4.txt 2>&1; res $? 1 "mangled assignment refused"; cat o4.txt
# Mangling 2: a pristine file whose push is not preceded by the brace.
awk '{ sub(/\r$/, "") } $0 == "  setstrV(L, L->top++, lj_err_str(L, LJ_ERR_ERRMEM));" { print "  (void)0;" } { print }' "$PR" > m2.c
sh "$P" m2.c m2o.c > o5.txt 2>&1; res $? 1 "push not under the brace refused"; cat o5.txt
[ -e m2o.c ] && echo "BAD  m2o.c written" || echo "OK   no output written"
# Mangling 3: a pristine file with the push duplicated (two anchors).
awk '{ sub(/\r$/, "") } { print } $0 == "  setstrV(L, L->top++, lj_err_str(L, LJ_ERR_ERRMEM));" { print "  lj_err_throw(L, LUA_ERRMEM);"; print "  }"; print "  setstrV(L, L->top++, lj_err_str(L, LJ_ERR_ERRMEM));" }' "$PR" > m3.c
sh "$P" m3.c m3o.c > o6.txt 2>&1; res $? 1 "duplicated anchor refused"; cat o6.txt
# Mangling 4: the throw after the push replaced.
awk '{ sub(/\r$/, "") } $0 == "  lj_err_throw(L, LUA_ERRMEM);" && !done { print "  lj_err_throw(L, LUA_ERRRUN);"; done = 1; next } { print }' "$PR" > m4.c
sh "$P" m4.c m4o.c > o7.txt 2>&1; res $? 1 "throw replaced refused"; cat o7.txt
# Mangling 5: an already-patched file with the clamp moved after the push.
awk '{ sub(/\r$/, "") } { print }' b.c | awk 'p == 1 && $0 ~ /^  setstrV\(L, L->top\+\+/ { print; print g1; print g2; p = 2; next } $0 == "  if (LJ_UNLIKELY(L->top < L->base))" { g1 = $0; getline; g2 = $0; p = 1; next } { print }' > m5.c
grep -n -A3 'LJ_ERR_ERRMEM));' m5.c | head -5
sh "$P" m5.c m5o.c > o8.txt 2>&1; res $? 1 "clamp after the push refused"; cat o8.txt
ls
