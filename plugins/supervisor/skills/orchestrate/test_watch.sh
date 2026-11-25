#!/usr/bin/env bash
# Tests for watch.py. Uses a scratch state file, a pinned clock (WATCH_NOW) and a fake gh.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
f="$scratch/watches.json"
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }
W() { python3 "$here/watch.py" -f "$f" "$@"; }
expect() {
  local name="$1" want="$2"; shift 2
  "$@" >"$scratch/out" 2>"$scratch/err"
  local got=$?
  if [ "$got" -eq "$want" ]; then pass "$name"; else fail "$name: exit $got, want $want ($(cat "$scratch/err"))"; fi
}
has() { if grep -q -- "$2" "$scratch/out"; then pass "$1"; else fail "$1: no '$2' in: $(cat "$scratch/out")"; fi; }
hasnt() { if grep -q -- "$2" "$scratch/out"; then fail "$1: unexpected '$2' in: $(cat "$scratch/out")"; else pass "$1"; fi; }

# Fake gh: runs.json is what `gh run list` returns; gh_fail makes every call fail.
mkdir "$scratch/bin"
cat >"$scratch/bin/gh" <<GH
#!/usr/bin/env bash
[ -e "$scratch/gh_fail" ] && { echo "HTTP 403: API rate limit exceeded" >&2; exit 1; }
case "\$2" in
  list) cat "$scratch/runs.json" ;;
  view) echo '{"jobs":[{"name":"Test abc","conclusion":"failure"},{"name":"Post statuses","conclusion":"success"}]}' ;;
esac
GH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH"

export WATCH_NOW=2026-11-25T14:00   # a Wednesday
expect "add ci" 0 W add ci1 --note "site batch" ci o/r 0123456789abcdef
expect "duplicate id refused" 1 W add ci1 ci o/r 0123456789abcdef
expect "bad ci spec refused" 1 W add bad ci norepo 123
expect "bad cron refused" 1 W add bad cron '61 * * * *'
expect "add cron Mon+Thu 14:23" 0 W add dependabot --note check cron '23 14 * * 1,4'
expect "add at" 0 W add remind at 2026-11-25T15:00
expect "add cmd" 0 W add build --timeout-min 10 cmd test -e "$scratch/built"

echo '[]' >"$scratch/runs.json"
expect "poll with nothing done" 0 W poll
if [ -s "$scratch/out" ]; then fail "no events expected: $(cat "$scratch/out")"; else pass "no events while runs are missing"; fi

echo '[{"databaseId":1,"name":"CI","status":"in_progress","conclusion":"","url":"u"}]' >"$scratch/runs.json"
expect "poll with a running run" 0 W poll
hasnt "running CI isn't done" '"watch": "ci1"'

echo '[{"databaseId":1,"name":"CI","status":"completed","conclusion":"failure","url":"u"}]' >"$scratch/runs.json"
WATCH_NOW=2026-11-25T14:03 expect "poll after CI failed" 0 W poll
has "ci failure event" '"outcome": "failure"'
has "failed job named" 'jobs not green: Test abc'
hasnt "green job not listed" 'Post statuses'
WATCH_NOW=2026-11-25T14:06 expect "done watch doesn't fire again" 0 W poll
hasnt "no second ci event" '"watch": "ci1"'

touch "$scratch/built"
WATCH_NOW=2026-11-25T14:06 expect "cmd success" 0 W poll
has "cmd event" '"watch": "build"'
expect "await a done cmd watch" 0 W await build
has "await prints outcome" 'build: success'
expect "await a failed ci watch exits 3" 3 W await ci1

W add slow --timeout-min 5 cmd false >/dev/null
WATCH_NOW=2026-11-25T14:20 expect "cmd timeout" 0 W poll
has "timeout outcome" '"outcome": "timeout"'

WATCH_NOW=2026-11-25T15:01 expect "at fires once due" 0 W poll
has "at fired" '"watch": "remind"'
hasnt "cron not due on Wednesday" '"watch": "dependabot"'

WATCH_NOW=2026-11-26T14:20 expect "Thursday before 14:23" 0 W poll
hasnt "cron not early" '"watch": "dependabot"'
WATCH_NOW=2026-11-26T14:25 expect "Thursday after 14:23" 0 W poll
has "cron fires on a pass after the minute" '"watch": "dependabot"'
WATCH_NOW=2026-11-26T14:28 expect "next pass" 0 W poll
hasnt "cron fires once per match" '"watch": "dependabot"'
WATCH_NOW=2026-12-03T14:40 expect "a week later" 0 W poll
has "cron keeps firing past 7 days" '"watch": "dependabot"'
expect "list" 0 W list
has "cron still active" 'dependabot	cron	active'

W add flaky ci o/r fedcba9876543210 >/dev/null
touch "$scratch/gh_fail"
for i in 1 2 3; do WATCH_NOW=2026-12-03T15:0$i W poll >/dev/null; done
WATCH_NOW=2026-12-03T15:04 expect "four gh errors" 0 W poll
hasnt "gh errors retried" '"watch": "flaky"'
WATCH_NOW=2026-12-03T15:05 expect "fifth gh error" 0 W poll
has "unknown after 5" '"outcome": "unknown"'
rm "$scratch/gh_fail"
WATCH_NOW=2026-12-03T14:00 W poll >"$scratch/out"
hasnt "a clock step back doesn't refire cron" '"watch": "dependabot"'

# wait returns the undelivered events at once; ack clears them; then wait polls (interval 1).
WATCH_NOW=2026-12-03T15:06 expect "wait returns pending events" 0 W wait --interval 1
ids=$(python3 -c 'import json,sys; print(" ".join(json.loads(l)["id"] for l in open(sys.argv[1])))' "$scratch/out")
expect "ack all" 0 W ack $ids
expect "ack unknown refused" 1 W ack nope@x
W add soon cmd test -e "$scratch/later" >/dev/null
( sleep 2; touch "$scratch/later" ) &
( sleep 20; pkill -f "watch.py -f $f wait" ) 2>/dev/null & watchdog=$!
WATCH_NOW=2026-12-03T15:10 expect "wait blocks until an event" 0 W wait --interval 1
kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
has "wait woke on the new event" '"watch": "soon"'
expect "remove" 0 W remove soon
expect "remove unknown" 1 W remove soon
expect "await unknown" 1 W await soon

[ "$failures" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$failures failed"; exit 1; }
