#!/usr/bin/env bash
# Tests for ledger.py. Works on copies in a scratch dir, never on the real ledger.
# Usage: test_ledger.sh [ledger.md]   (optionally also round-trips a copy of a real ledger)
set -u

here="$(cd "$(dirname "$0")" && pwd)"
ledger="$here/ledger.py"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
f="$scratch/ledger.md"
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }
L() { python3 "$ledger" -f "$f" "$@"; }

# expect <name> <exit code> <command...>: runs the command, checks its exit code
expect() {
  local name="$1" want="$2"; shift 2
  "$@" >"$scratch/out" 2>"$scratch/err"
  local got=$?
  if [ "$got" -eq "$want" ]; then pass "$name"; else fail "$name: exit $got, want $want ($(cat "$scratch/err"))"; fi
}
# unchanged <name>: the ledger equals the snapshot taken before the last command
unchanged() { if cmp -s "$f" "$scratch/before"; then pass "$1 leaves the file unchanged"; else fail "$1 changed the file"; fi; }
snapshot() { cp "$f" "$scratch/before"; }
row() { grep -F "| $1 |" "$f"; }

cat >"$f" <<'EOF'
# Supervisor ledger

| id | repo | branch | worktree | agent | stage | commit | CI | next action |
|---|---|---|---|---|---|---|---|---|
| a-one | a | one | worktrees/a/one | implementer | implementing | — | — | wait for report |
| b-two | b | two | — | planner (queued) | planned | — | — | spawn later |
| dup | c | x | — | — | planned | — | — | — |
| dup | c | y | — | — | planned | — | — | — |

## Task graph

- notes below the table | with a pipe, untouched
EOF

# set
snapshot
expect "set two fields" 0 L set a-one stage="review 1" next-action="reviewer on abc123"
[ "$(row a-one)" = "| a-one | a | one | worktrees/a/one | implementer | review 1 | — | — | reviewer on abc123 |" ] \
  && pass "set writes the row" || fail "set row: $(row a-one)"
[ "$(diff "$scratch/before" "$f" | grep -c '^[<>]')" -eq 2 ] && pass "set touches only that row" || fail "set touched other lines"
expect "set field names are case-insensitive" 0 L set a-one CI=12345 Next_Action=watch
[ "$(row a-one)" = "| a-one | a | one | worktrees/a/one | implementer | review 1 | — | 12345 | watch |" ] \
  && pass "case-insensitive set" || fail "case-insensitive set row: $(row a-one)"
expect "set empty value" 0 L set a-one CI=
row a-one | grep -qF "| — | — | watch |" && pass "empty value becomes —" || fail "empty value: $(row a-one)"

# show
expect "show" 0 L show b-two
grep -qx "stage: planned" "$scratch/out" && pass "show prints fields" || fail "show output: $(cat "$scratch/out")"

# add
expect "add" 0 L add c-three repo=c branch=three stage=planned
[ "$(grep -n '^| c-three |' "$f" | cut -d: -f1)" = "9" ] && pass "add appends after the last row" || fail "add position"
[ "$(row c-three)" = "| c-three | c | three | — | — | planned | — | — | — |" ] && pass "add fills unset fields with —" || fail "add row: $(row c-three)"
snapshot
expect "add existing id fails" 1 L add a-one
unchanged "add existing id"

# delete
expect "delete" 0 L delete b-two
grep -qF "| b-two |" "$f" && fail "delete left the row" || pass "delete removes the row"

# failures
snapshot
expect "set unknown id fails" 1 L set nope stage=ci
grep -q "no row with id 'nope'" "$scratch/err" && pass "no-match message" || fail "no-match message: $(cat "$scratch/err")"
unchanged "set unknown id"
expect "delete unknown id fails" 1 L delete nope
expect "show unknown id fails" 1 L show nope
expect "set duplicate id fails" 1 L set dup stage=ci
grep -q "2 rows with id 'dup'" "$scratch/err" && pass "duplicate message" || fail "duplicate message: $(cat "$scratch/err")"
expect "delete duplicate id fails" 1 L delete dup
unchanged "duplicate id"
expect "id prefix doesn't match" 1 L set a stage=ci
expect "value with | is refused" 1 L set a-one next-action="a | b"
expect "value with newline is refused" 1 L set a-one next-action="$(printf 'a\nb')"
expect "add with | is refused" 1 L add d-four next-action="x|y"
expect "unknown field fails" 1 L set a-one colour=red
expect "set without fields fails" 1 L set a-one
expect "set id fails" 1 L set a-one id=z
expect "missing = fails" 1 L set a-one stage
unchanged "refused edits"
ls -A "$scratch" | grep -q '^\.ledger\..*\.tmp$' && fail "temp file left behind" || pass "no temp files left behind"

# malformed table
printf '| id | repo |\n|---|---|\n| a | b | c |\n' >"$f"; snapshot
expect "row with wrong cell count fails" 1 L set a repo=x
unchanged "malformed table"
printf '# no table\n' >"$f"
expect "missing table fails" 1 L set a repo=x

# parallel edits: the lock must keep every update
rm -f "$f"
for i in $(seq 1 12); do L add "p$i" stage=planned 2>/dev/null; done
pids=()
for i in $(seq 1 12); do L set "p$i" stage=ci commit="c$i" & pids+=($!); done
codes=0; for p in "${pids[@]}"; do wait "$p" || codes=$((codes + 1)); done
[ "$codes" -eq 0 ] && pass "parallel sets all exit 0" || fail "$codes parallel sets failed"
landed=0; for i in $(seq 1 12); do row "p$i" | grep -qF "| ci | c$i |" && landed=$((landed + 1)); done
[ "$landed" -eq 12 ] && pass "parallel sets all land" || fail "only $landed of 12 parallel sets landed"

# a held lock times out with a message
python3 -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT); fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close(); time.sleep(3)' "$scratch/.ledger.md.lock" "$scratch/held" &
holder=$!
for _ in $(seq 1 100); do [ -e "$scratch/held" ] && break; sleep 0.05; done
snapshot
expect "held lock times out" 1 python3 "$ledger" -f "$f" --lock-timeout 0.3 set p1 stage=x
grep -q "still locked after 0.3s" "$scratch/err" && pass "lock timeout message" || fail "lock timeout message: $(cat "$scratch/err")"
unchanged "lock timeout"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
expect "set works once the holder is gone" 0 L set p1 stage=ci

# symlinked ledger: edited at its target, the link stays
mv "$f" "$scratch/target.md"; ln -s "$scratch/target.md" "$f"
expect "set through a symlink" 0 L set p1 stage=merged
[ -L "$f" ] && grep -qF "| p1 | — | — | — | — | merged |" "$scratch/target.md" \
  && pass "symlink kept, target edited" || fail "symlink replaced or target unchanged"
rm -f "$f" "$scratch/target.md"

# missing parent dir: a message, not a traceback
expect "add in a missing dir fails" 1 python3 "$ledger" -f "$scratch/nope/ledger.md" add x
grep -q Traceback "$scratch/err" && fail "missing dir: traceback" || pass "missing dir: plain message"

# missing file
rm -f "$f"
expect "set on missing file fails" 1 L set a stage=ci
[ -e "$f" ] && fail "set created the file" || pass "set doesn't create the file"
expect "add creates the ledger" 0 L add first stage=planned
[ "$(sed -n 3p "$f")" = "| id | repo | branch | worktree | agent | stage | commit | CI | next action |" ] \
  && pass "new ledger has the standard columns" || fail "new header: $(sed -n 3p "$f")"
expect "delete last row" 0 L delete first
grep -q "no rows left" "$scratch/err" && pass "delete warns when the table is empty" || fail "empty warning"
expect "add to empty table" 0 L add again
row again >/dev/null && pass "row added to empty table" || fail "empty-table add"

# optional: round-trip a copy of a real ledger
if [ $# -ge 1 ]; then
  cp "$1" "$f"; snapshot
  id="$(awk -F'|' 'n == 2 { gsub(/^ +| +$/, "", $2); print $2; exit } /^\|/ { n++ }' "$f")"
  stage="$(L show "$id" | sed -n 's/^stage: //p')"
  expect "real ledger: re-set '$id' stage to its value" 0 L set "$id" stage="$stage"
  unchanged "real ledger round-trip"
  expect "real ledger: set a field" 0 L set "$id" commit=deadbeef
  row "$id" | grep -qF deadbeef && pass "real ledger: field set" || fail "real ledger: field not set"
fi

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures failed"; exit 1; fi
