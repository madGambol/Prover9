#!/bin/sh
# Regression tests for max_megs.  Each case gives mace4 or prover9 a
# small max_megs and an input that needs far more memory, in a place
# the limit used to miss, and checks that the program stops with its
# max_megs exit status.  Run via 'make test13' from the repo root
# (needs bin/ already built -- run 'make all' first if it isn't).

BIN="${1:-bin}"
if [ ! -x "$BIN/mace4" ] || [ ! -x "$BIN/prover9" ]; then
  echo "No mace4/prover9 binaries in $BIN -- run 'make all' first, then 'make test13'." >&2
  exit 2
fi

# 'timeout' is not a stock macOS utility; it is only a safety net here
# (see distinctness_test.sh), so run without it if it is missing.
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout 60"
else
  TIMEOUT_CMD=""
fi

# A build without these fixes can try to take many gigabytes, so cap
# the address space of every run at 1 GB where the system allows it.
# Each input also sets max_seconds, which bounds a run where it does not.
VMEM=1000000
if ! (ulimit -v $VMEM) 2>/dev/null; then
  echo "Note: 'ulimit -v' is not available here -- running without the" >&2
  echo "address-space cap (relying on each input's max_seconds instead)." >&2
  VMEM=""
fi

ulimit -c 0 2>/dev/null

TMP="${TMPDIR:-/tmp}/memory_limit_test.$$"
mkdir "$TMP" || exit 2
trap 'rm -rf "$TMP"' 0
trap 'exit 2' 1 2 15
OUT="$TMP/out"

pass=0
fail=0

# check DESC RC TEXT CMD...: pass if CMD exits with RC and its output
# (stdout and stderr) contains TEXT.
check() {
  desc="$1"; want_rc="$2"; want="$3"; shift 3
  ( if [ -n "$VMEM" ]; then ulimit -v $VMEM; fi
    exec $TIMEOUT_CMD "$@" ) < /dev/null > "$OUT" 2>&1
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

# vars N: x1,x2,...,xN
vars() {
  awk -v n="$1" 'BEGIN { for (i = 1; i <= n; i++) printf "%sx%d", (i > 1 ? "," : ""), i }'
}

echo "max_megs regression cases:"

# Mace4 allocates the cell table, Domain_size^arity cells per symbol,
# with safe_malloc(), so it must be checked against max_megs before it
# is allocated.  q/22 at domain size 2 is about 330 MB.
cat > "$TMP/cells.in" <<END
assign(max_megs, 100).
assign(max_seconds, 5).
clear(negprop).
formulas(sos).
q($(vars 22)).
end_of_list.
END
check "mace4: cell table larger than max_megs" 7 "over max_megs" \
  "$BIN/mace4" -f "$TMP/cells.in"

# The negprop index is a tree of (Domain_size+1)^arity pointers per
# value of each symbol, also from safe_calloc().  For r/15 at domain
# size 2 it is about 330 MB, against a cell table of under 3 MB.
cat > "$TMP/negprop.in" <<END
assign(max_megs, 50).
assign(max_seconds, 5).
formulas(sos).
r($(vars 15)).
end_of_list.
END
check "mace4: negprop index larger than max_megs" 7 "negprop index" \
  "$BIN/mace4" -f "$TMP/negprop.in"

# Control: without the index the same problem fits, and has a model.
(echo "clear(negprop)."; cat "$TMP/negprop.in") > "$TMP/no_negprop.in"
check "mace4: same input, clear(negprop) (control)" 0 "Exiting with 1 model" \
  "$BIN/mace4" -f "$TMP/no_negprop.in"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
