#!/bin/sh
# fixture-r3.sh <outdir> -- regenerate serializer/tests/fixtures/forin-identity.blob with the NEW round-3
# serializer host (built against build/native's round-3 archive): the three dumps' version bytes move
# 0x02 -> 0x80, nothing else (run-forin.sh:96-98; design F14).  Written to <outdir> first and compared with
# the repo's fixture by compat's cmp_forin.py; the copy over the repo's fixture is a separate, later step.
# Expected: 'DIAGBLOB bytes=636 body=516'; cmp: lengths 516 516, 8 differing bytes, 3 at a dump's version
# byte (128 vs 2), the rest inside the masked frame-link payload.
set -u
REPO=/c/Users/astro/Downloads/OC-LuaJIT
OUT=$1
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd)
cd "$REPO/serializer" || exit 98
export PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
rm -f erislj_test.exe erislj_test
make CC=gcc erislj_test.exe > "$OUT/host-build.log" 2>&1; echo "host-build exit=$?" >> "$OUT/summary.txt"
md5sum erislj_test.exe tests/fixtures/forin-identity.blob eris_lj.c eris_lj.h > "$OUT/inputs.md5"
./erislj_test.exe tests/fingerprint.lua 2>&1 | grep -E 'VM features|serializer|GG_State' > "$OUT/banner.txt"
ELJ_MODE=diagblob ELJ_BLOB="$OUT/forin-identity.blob" ./erislj_test.exe tests/forin.lua > "$OUT/diagblob.log" 2>&1
echo "diagblob exit=$?" >> "$OUT/summary.txt"
python -I C:/Users/astro/Downloads/OC-LuaJIT/bench/runs/2026-10-17-bitop/scripts/cmp_forin.py "$OUT/forin-identity.blob" tests/fixtures/forin-identity.blob > "$OUT/cmp.txt" 2>&1
echo "cmp exit=$?" >> "$OUT/summary.txt"
md5sum "$OUT/forin-identity.blob" >> "$OUT/inputs.md5"
cat "$OUT/summary.txt" "$OUT/banner.txt" "$OUT/diagblob.log" "$OUT/cmp.txt"
