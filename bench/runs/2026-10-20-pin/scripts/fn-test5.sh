#!/bin/sh
# fn-test5.sh <build-native.sh> <fresh work dir> <link maker: ln|junction> -- round 4's
# fn-test.sh (pin4/impl/scripts/fn-test.sh: the preflight's physpath, pathkey and inside,
# extracted from the script by their markers, 17 cases), plus round 5's cases for a pair of
# directories that do not exist yet below an existing one (T4), and the documented cost of
# pathkey's "?" (a false refusal).  With "junction" the caller makes <W>/x/link first.
# Each case prints PASS or FAIL against its expected answer; the last line counts them.
# Written with a file tool: no heredocs, no backslashes.
S=$1; W=$2; LM=$3
F=$W/fns.sh
mkdir -p "$W/y/sub" "$W/x" "$W/Bäu/dist" "$W/xy" "$W/n4" || exit 98
[ "$LM" = ln ] && [ ! -e "$W/x/link" ] && ln -s "$W/y/sub" "$W/x/link"
awk '/^(physpath|pathkey|inside)[(][)] [{]/ { if ($0 ~ /[}][[:space:]]*$/) { print; next } f = 1 }
  f { print } f && /^[}]/ { f = 0 }' "$S" > "$F"
LC_ALL=C; export LC_ALL
. "$F"
P=0; N=0
want() { # want <yes|no> <label> <command...>
  w=$1; l=$2; shift 2
  if "$@"; then g=yes; else g=no; fi
  if [ "$g" = "$w" ]; then P=$((P + 1)); echo "PASS $l ($g)"; else N=$((N + 1)); echo "FAIL $l (got $g, want $w)"; fi
}
WP=$(CDPATH= cd -P -- "$W" && pwd -P)
echo "physpath x/link/.. = $(physpath "$W/x/link/..")  (want $WP/y)"
want yes "physpath resolves x/link/.. to y" [ "$(physpath "$W/x/link/..")" = "$WP/y" ]
want yes "physpath x/link/../new = y/new" [ "$(physpath "$W/x/link/../new")" = "$WP/y/new" ]
want yes "physpath new/../x/link = y/sub" [ "$(physpath "$W/new/../x/link")" = "$WP/y/sub" ]
want yes "y/sub inside y" inside "$WP/y/sub" "$WP/y"
want yes "y inside y" inside "$WP/y" "$WP/y"
want no "y inside y/sub" inside "$WP/y" "$WP/y/sub"
want no "x inside xy (prefix trap)" inside "$WP/x" "$WP/xy"
want no "xy inside x (prefix trap)" inside "$WP/xy" "$WP/x"
want yes "y/sub inside x/link (link)" inside "$WP/y/sub" "$WP/x/link"
want yes "y/sub/new inside x/link (link, new tail)" inside "$WP/y/sub/new" "$WP/x/link"
want yes "y/sub inside X/LINK (ASCII case)" inside "$WP/y/sub" "$WP/X/LINK"
want yes "BÄU/dist inside Bäu/dist (non-ASCII case, exists)" inside "$WP/BÄU/dist" "$WP/Bäu/dist"
want yes "BÄU/new inside Bäu/new (non-ASCII case, neither exists)" inside "$WP/BÄU/new" "$WP/Bäu/new"
want yes "new/a inside NEW (ASCII case, neither exists)" inside "$WP/new/a" "$WP/NEW"
want no "new2 inside new (neither exists)" inside "$WP/new2" "$WP/new"
want no "y inside x/link/new (b missing below a link)" inside "$WP/y" "$WP/x/link/new"
want yes "y/sub/new/deeper inside x/link/new (both missing below one dir)" inside "$WP/y/sub/new/deeper" "$WP/x/link/new"
# round 5
want yes "T4: n4/BÄU/dist inside n4/Bäu/dist (non-ASCII case, neither Bäu nor BÄU exists)" inside "$WP/n4/BÄU/dist" "$WP/n4/Bäu/dist"
want yes "T4: n4/Bäu/dist inside n4/BÄU/dist (the other way)" inside "$WP/n4/Bäu/dist" "$WP/n4/BÄU/dist"
want no "n4/Bau/dist inside n4/Bäu/dist (ASCII a against a two-byte letter, neither exists)" inside "$WP/n4/Bau/dist" "$WP/n4/Bäu/dist"
want yes "documented cost: n4/Böu/dist inside n4/Bäu/dist (another letter, as many bytes, neither exists: a false refusal)" inside "$WP/n4/Böu/dist" "$WP/n4/Bäu/dist"
echo "pathkey Bäu=$(pathkey Bäu) BÄU=$(pathkey BÄU) Böu=$(pathkey Böu)"
echo "physpath/inside: $P passed, $N failed"
