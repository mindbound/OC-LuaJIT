awk -F'|' '/^#/ || /^[ \t]*$/ { next }
  { why = "" }
  NF != 4 { why = "not 4 fields" }
  why == "" && $1 != "conformance" && $1 != "conf-extra" { why = "unknown script" }
  why == "" && $2 != "any" && $2 != "windows" && $2 != "linux" { why = "unknown platform" }
  why == "" && $4 != "DEV1" && $4 != "DEV2" && $4 != "RESID" && $4 != "RESID-scan" { why = "unknown class" }
  why == "" && (($3 ~ /^DEV1 / && $4 != "DEV1") || ($3 ~ /^DEV2 / && $4 != "DEV2") ||
                ($3 ~ /^RESID/ && $4 !~ /^RESID/) || ($4 ~ /^RESID/ && $3 !~ /^RESID/)) { why = "the id and the class disagree" }
  why != "" { print "line " NR ", " why ": " $0 }'
