rcof() {
  case $1 in
    bitop) echo "$R_bitop" ;; fuzz) echo "$R_fuzz" ;; gen|floor|fix1|idx|sel|nc) echo "$R_bitjit" ;; genrg2) echo "$R_genrg2" ;;
    security) echo "$R_security" ;; gate) echo "$R_gate" ;; stage4) echo "$R_stage4" ;; *) echo - ;;
  esac
}
check() {
  rc=$(rcof "${2%%:*}")
  [ "$rc" = 2 ] && return 2
  [ "$rc" = 1 ] || return 1
  case $2 in
    bitop|fuzz|stage4) return 0 ;;
    bitop:t_ops|bitop:t_fold|bitop:t_sar) grep -q "^FAIL ${2#bitop:} (j" "$1/bitop.log" ;;
    bitop:coerce) grep -q '^FAIL coerce_agree (' "$1/bitop.log" ;;
    bitop:t_ops-str) strcase "$1" ;;
    fuzz:[KVPHU]) fuzzmode "$1" "${2#fuzz:}" ;;
    gen) grep -q '^seed [0-9]*: FAIL' "$1/bitjit.log" ;;
    floor:t_rec) grep -q '^FAIL t_rec seed' "$1/bitjit.log" ;;
    floor:t_rec-counts) grep -q '^FAIL t_rec seed [0-9]* (counts)' "$1/bitjit.log" ;;
    floor:t_jit2) grep -q '^FAIL t_jit2 (' "$1/bitjit.log" ;;
    floor:t_jit2/*) jit2loop "$1/bitjit/floor" "${2#floor:t_jit2/}" ;;
    fix1) grep -q '^FAIL fix1' "$1/bitjit.log" ;;
    idx:t_idx) grep -q '^FAIL t_idx (' "$1/bitjit.log" ;;
    idx:t_cnt33) grep -q '^FAIL t_cnt33 (' "$1/bitjit.log" ;;
    idx:t_idx2) grep -q '^FAIL t_idx2 (' "$1/bitjit.log" ;;
    idx:phiidx) grep -q '^FAIL phiidx' "$1/bitjit.log" ;;
    sel:t_select) grep -q '^FAIL t_select (' "$1/bitjit.log" ;;
    sel:kmax) grep -q '^FAIL t_select-kmax' "$1/bitjit.log" ;;
    nc:t_numconv) grep -q '^FAIL t_numconv (' "$1/bitjit.log" ;;
    nc:ncir) grep -q '^FAIL ncir (' "$1/bitjit.log" ;;
    genrg2) grep -q '^seed [0-9]*: FAIL' "$1/bitjit-rg2.log" ;;
    security:FF12) grep -q '^FAIL FF12 ' "$1/security.log" ;;
    gate:dump) gatedump "$1" ;;
    *) return 1 ;;
  esac
}
