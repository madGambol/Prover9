#!/bin/sh
# Regression tests for TPTP input, through both of its readers:
# tptp_to_ladr, whose translation is read back by prover9 and mace4, and
# the native reader in prover9, fof-prover9 and mace4 -tptp.  Each case
# checks what the input means, not just its text: a problem must prove
# what the TPTP says, and must not prove what it does not -- for the
# second kind, mace4 must also find the countermodel.  Run via
# 'make test8' from the repo root (needs bin/ already built -- run
# 'make all' first if it isn't).

BIN="${1:-bin}"
for prog in tptp_to_ladr prover9 fof-prover9 mace4; do
  if [ ! -x "$BIN/$prog" ]; then
    echo "No $prog binary in $BIN -- run 'make all' first, then 'make test8'." >&2
    exit 2
  fi
done
BIN=$(cd "$BIN" && pwd)

# 'timeout' is not a stock macOS utility (see distinctness_test.sh).  It
# is only a safety net here: every prover9 and mace4 run below has its
# own -t limit.
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout 30"
else
  echo "Note: no 'timeout' command on this system -- running without the" >&2
  echo "external safety-net timeout (relying on the programs' own -t" >&2
  echo "limits instead)." >&2
  TIMEOUT_CMD=""
fi

W="${TMPDIR:-/tmp}/tptp_translate_test.$$"
rm -rf "$W"
mkdir "$W" || exit 2
trap 'rm -rf "$W"' 0
trap 'exit 1' 1 2 15

pass=0
fail=0

# mk FILE LINE... -- write a test input, one argument per line
mk() {
  f="$1"; shift
  printf '%s\n' "$@" > "$W/$f"
}

# result DESC EXPECTED GOT
result() {
  if [ "$3" = "$2" ]; then
    printf "  PASS  %-50s (%s)\n" "$1" "$3"
    pass=$((pass+1))
  else
    printf "  FAIL  %-50s expected %s, got %s\n" "$1" "$2" "${3:-<none>}"
    fail=$((fail+1))
  fi
}

# The first SZS status word on stdin.
szs() {
  sed -n 's/.*SZS status \([A-Za-z]*\).*/\1/p' | head -n 1
}

# translate FILE.p -- tptp_to_ladr FILE.p > FILE.in, run in $W so that
# include() paths resolve there.
translate() {
  (cd "$W" && $TIMEOUT_CMD "$BIN/tptp_to_ladr" < "$1" > "${1%.p}.in" 2>&1)
}

# text DESC FILE.p STRING -- the translation must contain STRING
text() {
  if translate "$2" && grep -F -- "$3" "$W/${2%.p}.in" >/dev/null; then
    got=present
  else
    got=absent
  fi
  result "$1" present "$got"
}

# The exit reason prover9 or mace4 reports on stdin: max_proofs,
# sos_empty, max_models, exhausted, max_seconds, ...
reason() {
  sed -n 's/.* exit (\([a-z_]*\)).*/\1/p' | head -n 1
}

# ladr DESC FILE.p REASON -- translate, then run prover9 on the
# translation: REASON is max_proofs (proved) or sos_empty (not provable).
# For sos_empty, mace4 must also find a countermodel of the translation:
# no proof is not enough on its own.
ladr() {
  if ! translate "$2"; then
    result "$1" "$3" "translation-failed"
    return
  fi
  got=$(cd "$W" && $TIMEOUT_CMD "$BIN/prover9" -t 5 \
          -f "${2%.p}.in" < /dev/null 2>&1 | reason)
  if [ "$3" = sos_empty ] && [ "$got" = sos_empty ]; then
    m=$(cd "$W" && $TIMEOUT_CMD "$BIN/mace4" -t 5 -N 6 \
          -f "${2%.p}.in" < /dev/null 2>&1 | reason)
    [ "$m" = max_models ] || got="sos_empty,but-mace4:${m:-<none>}"
  fi
  result "$1" "$3" "$got"
}

# native DESC FILE.p STATUS -- prover9's own TPTP reader
native() {
  got=$(cd "$W" && $TIMEOUT_CMD "$BIN/prover9" -t 5 "$2" < /dev/null 2>&1 | szs)
  result "$1" "$3" "$got"
}

# native_mace4 DESC FILE.p STATUS -- mace4's TPTP mode (the same reader)
native_mace4() {
  got=$(cd "$W" && $TIMEOUT_CMD "$BIN/mace4" -tptp -t 5 -N 6 \
          -f "$2" < /dev/null 2>&1 | szs)
  result "$1" "$3" "$got"
}

echo "TPTP input matrix:"

# T4: "~" applied to a quantified formula without parentheses.  The
# parser binds the "~" to the quantifier prefix, and tptp_to_ladr used to
# drop both the negation and the quantifier: "~ ! [X] : p(X)" became
# "p(X)", the opposite of what it says.
mk neg.p      'fof(t,axiom, ~ ! [X] : p(X) ).'
mk neg2.p     'fof(a1,axiom, ~ ! [X] : p(X) ).' \
              'fof(c1,conjecture, ? [X] : ~ p(X) ).'
mk negex.p    'fof(a1,axiom, ~ ? [X] : p(X) ).' \
              'fof(c1,conjecture, ! [X] : ~ p(X) ).'
mk negnest.p  'fof(a1,axiom, ! [X] : ~ ? [Y] : q(X,Y) ).' \
              'fof(c1,conjecture, ~ q(a,b) ).'
mk negneg.p   'fof(a1,axiom, ~ ~ ? [X] : p(X) ).' \
              'fof(c1,conjecture, p(c) ).'
mk neginv.p   'fof(a1,axiom, ~ ! [X] : p(X) ).' \
              'fof(c1,conjecture, p(c) ).'
text   "T4a ~![X]:p(X) translates to -(all X p(X))" neg.p '-(all X p(X))'
ladr   "T4b ~![X]:p(X) |- ?[X]:~p(X)"              neg2.p    max_proofs
ladr   "T4c ~?[X]:p(X) |- ![X]:~p(X)"              negex.p   max_proofs
ladr   "T4d ![X]:~?[Y]:q(X,Y) |- ~q(a,b)"          negnest.p max_proofs
ladr   "T4e ~~?[X]:p(X) |/- p(c)"                  negneg.p  sos_empty
ladr   "T4f ~![X]:p(X) |/- p(c) (was unsound)"     neginv.p  sos_empty
native "T4g native: ~![X]:p(X) |- ?[X]:~p(X)"      neg2.p    Theorem
native "T4h native: ![X]:~?[Y]:q(X,Y) |- ~q(a,b)"  negnest.p Theorem
native "T4i native: ~![X]:p(X) |/- p(c)"           neginv.p  GaveUp
native_mace4 "T4j mace4 -tptp: ~![X]:p(X) |/- p(c)" neginv.p CounterSatisfiable

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
