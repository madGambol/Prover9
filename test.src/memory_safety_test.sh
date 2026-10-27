#!/bin/sh
# Memory-safety regression checks.  The defects covered here corrupt or
# misuse memory without changing prover9's output, so an ordinary run
# cannot see them; each case uses a tool that can, and reports SKIP when
# that tool is not available.  Run via 'make test11' from the repo root
# (needs bin/prover9 already built -- run 'make all' first if it isn't).

P9="${1:-bin/prover9}"
if [ ! -x "$P9" ]; then
  echo "No prover9 binary at $P9 -- run 'make all' first, then 'make test11'." >&2
  exit 2
fi

# 'timeout' is not a stock macOS utility; see distinctness_test.sh.
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout 60"
else
  echo "Note: no 'timeout' command on this system -- running without the" >&2
  echo "external safety-net timeout (relying on prover9's own internal" >&2
  echo "max_seconds limit instead)." >&2
  TIMEOUT_CMD=""
fi

if command -v valgrind >/dev/null 2>&1; then
  VALGRIND=valgrind
else
  VALGRIND=""
fi

TMP="${TMPDIR:-/tmp}/memory_safety_test.$$"
mkdir "$TMP" || exit 2
trap 'rm -rf "$TMP"' 0
trap 'exit 2' 1 2 15

pass=0
fail=0
skip=0

ok() {
  printf "  PASS  %s\n" "$1"
  pass=$((pass+1))
}

bad() {
  printf "  FAIL  %s\n" "$1"
  printf '%s\n' "$2" | sed 's/^/        | /'
  fail=$((fail+1))
}

skipped() {
  printf "  SKIP  %s\n" "$1"
  printf "        (%s)\n" "$2"
  skip=$((skip+1))
}

echo "Memory-safety checks:"

# set(production) evaluates $-operators.  init_dollar_eval() used to size
# its op-code table from the symbol count and then intern the operator
# symbols, writing past the end of the table for each operator the input
# did not mention.  Nothing reads those slots back, so the output is
# right either way; valgrind reports the invalid writes.

cat > "$TMP/production.in" <<'EOF'
set(production).
assign(max_seconds, 5).
formulas(sos).
  p(1 + 1).
  q(max(3,5)).
end_of_list.
EOF

desc="set(production): \$-operator table"
out=$($TIMEOUT_CMD "$P9" -f "$TMP/production.in" 2>&1)
if ! printf '%s\n' "$out" | grep -q 'q(5)'; then
  bad "$desc" "$(printf '%s\n' "$out" | sed -n '/ERROR/,$p' | head -8)
$(printf '%s\n' "$out" | tail -5)"
elif [ -z "$VALGRIND" ]; then
  skipped "$desc" "valgrind not found; a plain build cannot see this overflow"
else
  $TIMEOUT_CMD valgrind --log-file="$TMP/production.vg" \
    "$P9" -f "$TMP/production.in" >"$TMP/production.out" 2>&1
  if ! grep -q 'q(5)' "$TMP/production.out" ||
     ! grep -q 'ERROR SUMMARY' "$TMP/production.vg"; then
    skipped "$desc" "valgrind could not run $P9"
  elif grep -q 'ERROR SUMMARY: 0 errors' "$TMP/production.vg"; then
    ok "$desc (valgrind)"
  else
    bad "$desc (valgrind)" \
        "$(sed -n '/Invalid/,$p' "$TMP/production.vg" | sed 's/^==[0-9]*== //' | head -12)"
  fi
fi

echo
echo "$pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
