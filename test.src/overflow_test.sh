#!/bin/sh
# Regression tests for fixed-size buffers that overflowed on a long
# command-line argument or input token.  Each case runs a program with
# an over-long argument and checks that it exits normally with its
# full message; the unfixed programs abort or crash instead.  Run via
# 'make test9' from the repo root (needs bin/ already built -- run
# 'make all' first if it isn't).

BIN="${1:-bin}"
if [ ! -x "$BIN/prover9" ]; then
  echo "No prover9 binary in $BIN -- run 'make all' first, then 'make test9'." >&2
  exit 2
fi

# 'timeout' is not a stock macOS utility; it is only a safety net here
# (see distinctness_test.sh), so run without it if it is missing.
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout 30"
else
  TIMEOUT_CMD=""
fi

ulimit -c 0 2>/dev/null   # the unfixed programs abort; no core files

TMP="${TMPDIR:-/tmp}/overflow_test.$$"
mkdir "$TMP" || exit 2
trap 'rm -rf "$TMP"' 0
trap 'exit 2' 1 2 15
OUT="$TMP/out"

# repeat N: a string of N 'z's (N a multiple of 10)
repeat() {
  awk -v n="$1" 'BEGIN { for (i = 0; i < n; i += 10) printf "zzzzzzzzzz" }'
}

LONG=$(repeat 300)
LONG4000=$(repeat 4000)

pass=0
fail=0

# check DESC RC TEXT INPUT CMD...: pass if CMD, reading INPUT, exits
# with RC and its output contains TEXT.
check() {
  desc="$1"; want_rc="$2"; want="$3"; in="$4"; shift 4
  $TIMEOUT_CMD "$@" < "$in" > "$OUT" 2>&1
  rc=$?
  if [ "$rc" -eq "$want_rc" ] && grep -F -- "$want" "$OUT" >/dev/null; then
    printf "  PASS  %s\n" "$desc"
    pass=$((pass+1))
  else
    printf "  FAIL  %s (exit %s, expected %s)\n" "$desc" "$rc" "$want_rc"
    tail -n 3 "$OUT" | cut -c1-100 | sed 's/^/        | /'
    fail=$((fail+1))
  fi
}

echo "Long-argument and long-token overflow tests:"

# M2: the missing-file message was formatted into char[100].
check "prover9 -f <300-char missing file>" 1 \
  "read_all_input, file $LONG not found" /dev/null "$BIN/prover9" -f "$LONG"
check "mace4 -f <300-char missing file>" 1 \
  "read_all_input, file $LONG not found" /dev/null "$BIN/mace4" -f "$LONG"
check "prover9 -f <4000-char missing file>" 1 \
  "read_all_input, file $LONG4000 not found" /dev/null "$BIN/prover9" -f "$LONG4000"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
