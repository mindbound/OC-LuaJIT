#!/bin/sh
# patchcheck2.sh <fresh dir> -- the two-site patch script's own fail-first checks.
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
P=$REPO/native/luajit/patch-fastfunc-errmem-top.sh
D=$1
[ -e "$D" ] && { echo "REFUSING: $D exists"; exit 99; }
mkdir -p "$D"; cd "$D" || exit 1
PR=$REPO/prototype/watchdog/luajit/src/lj_err.c
res() { if [ "$1" = "$2" ]; then echo "OK   $3 (exit $1)"; else echo "BAD  $3 (exit $1, want $2)"; fi; }
EP='  setstrV(L, L->top++, lj_err_str(L, LJ_ERR_ERRERR));'
MP='  setstrV(L, L->top++, lj_err_str(L, LJ_ERR_ERRMEM));'

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

# lj_err_mem's site
sed 's/^    L->top = L->base;$/    L->top = L->base - 1;/' b.c > m1.c
sh "$P" m1.c m1o.c > o4.txt 2>&1; res $? 1 "both assignments altered refused"; cat o4.txt
awk -v mp="$MP" '{ sub(/\r$/, "") } $0 == mp { print "  (void)0;" } { print }' "$PR" > m2.c
sh "$P" m2.c m2o.c > o5.txt 2>&1; res $? 1 "ERRMEM push not under the brace refused"; cat o5.txt
[ -e m2o.c ] && echo "BAD  m2o.c written" || echo "OK   no output written"
awk -v mp="$MP" '{ sub(/\r$/, "") } { print } $0 == mp { print "  lj_err_throw(L, LUA_ERRMEM);"; print "  }"; print mp }' "$PR" > m3.c
sh "$P" m3.c m3o.c > o6.txt 2>&1; res $? 1 "duplicated ERRMEM anchor refused"; cat o6.txt
awk '{ sub(/\r$/, "") } $0 == "  lj_err_throw(L, LUA_ERRMEM);" && !done { print "  lj_err_throw(L, LUA_ERRRUN);"; done = 1; next } { print }' "$PR" > m4.c
sh "$P" m4.c m4o.c > o7.txt 2>&1; res $? 1 "ERRMEM throw replaced refused"; cat o7.txt

# lj_err_err's site
awk -v ep="$EP" '{ sub(/\r$/, "") } $0 == ep { print "  (void)0;" } { print }' "$PR" > m5.c
sh "$P" m5.c m5o.c > o8.txt 2>&1; res $? 1 "ERRERR push not first refused"; cat o8.txt
awk '{ sub(/\r$/, "") } $0 == "  lj_err_throw(L, LUA_ERRERR);" && !done { print "  lj_err_throw(L, LUA_ERRRUN);"; done = 1; next } { print }' "$PR" > m6.c
sh "$P" m6.c m6o.c > o9.txt 2>&1; res $? 1 "ERRERR throw replaced refused"; cat o9.txt
# a patched file with lj_err_err's clamp taken out (the first GUARD and its assignment)
awk '$0 == "  if (LJ_UNLIKELY(L->top < L->base))" && !done { getline; done = 1; next } { print }' b.c > m7.c
grep -c 'L->top < L->base' m7.c
sh "$P" m7.c m7o.c > o10.txt 2>&1; res $? 1 "patched file missing the lj_err_err clamp refused"; cat o10.txt
# a patched file with lj_err_mem's clamp moved after its push
awk -v mp="$MP" 'p == 1 && $0 == mp { print; print g1; print g2; p = 2; next } $0 == "  if (LJ_UNLIKELY(L->top < L->base))" && n++ == 1 { g1 = $0; getline; g2 = $0; p = 1; next } { print }' b.c > m8.c
grep -n -A3 'LJ_ERR_ERRMEM));' m8.c | head -5
sh "$P" m8.c m8o.c > o11.txt 2>&1; res $? 1 "lj_err_mem clamp after the push refused"; cat o11.txt
# the investigator's else-if form (same marker, different guard text): refused, not taken as patched
cp /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/crash/patch-fastfunc-errmem-top.sh old.sh
sh old.sh "$PR" m9.c > /dev/null 2>&1
sh "$P" m9.c m9o.c > o12.txt 2>&1; res $? 1 "the investigator's else-if output refused"; cat o12.txt
ls
