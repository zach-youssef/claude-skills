#!/usr/bin/env bash
# Tests for winpc against a stub host: WINPC_SSH points at a stub ssh that runs the PC side
# locally (both envs share this machine; cmd.exe's `type`, `echo` and nvidia-smi are emulated),
# with the PC's files in a scratch dir. Never contacts the real PC.
# Usage: test_winpc.sh
# shellcheck disable=SC2015 # `cond && pass || fail`: pass always succeeds
set -u

here="$(cd "$(dirname "$0")" && pwd)"
winpc="$here/winpc"
scratch="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

# expect <name> <exit code> <command...>: runs the command, checks its exit code; its output is
# left in $scratch/out and $scratch/err
expect() {
    local name="$1" want="$2"
    shift 2
    "$@" > "$scratch/out" 2> "$scratch/err"
    local got=$?
    if [ "$got" -eq "$want" ]; then pass "$name"; else fail "$name: exit $got, want $want ($(cat "$scratch/err"))"; fi
}
has() { if grep -qE -- "$2" "$scratch/$1"; then pass "$3"; else fail "$3: no /$2/ in $1: $(cat "$scratch/$1")"; fi; }
hasnt() { if grep -qE -- "$2" "$scratch/$1"; then fail "$3: /$2/ in $1: $(cat "$scratch/$1")"; else pass "$3"; fi; }

pc="$scratch/pc"
mkdir -p "$pc/native" "$pc/wsl" "$scratch/home" "$scratch/state"
export STUB_LOG="$scratch/ssh.log" STUB_HOME="$scratch/home"
export STUB_GPU="NVIDIA GeForce RTX 3080, 3 %, 1200 MiB, 10240 MiB" STUB_APPS=""
export XDG_STATE_HOME="$scratch/state" WINPC_CONF="$scratch/winpc.conf" WINPC_SSH="$scratch/stub-ssh"
: > "$STUB_LOG"

# The stub host: argv is <host> <command>, as ssh gets it. Files in $STUB_HOME steer it:
# unreachable (every connection fails), unreachable-push (receive-pack fails), corrupt (holds an
# op name: that op's hash lines are altered on the way back), bin/ (put first on the PC's PATH).
cat > "$scratch/stub-ssh" << 'EOF'
#!/bin/bash
host=$1 cmd=$2
echo "$host|$cmd" >> "$STUB_LOG"
if [ -e "$STUB_HOME/unreachable" ]; then echo "ssh: connect to host $host: timed out" >&2; exit 255; fi
export HOME="$STUB_HOME" PATH="$STUB_HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin"
case $cmd in
    'C:\msys64\usr\bin\bash.exe -s' | 'wsl.exe -d Ubuntu-24.04 -e bash -s')
        if [ -f "$STUB_HOME/corrupt" ]; then
            cat > "$STUB_HOME/stdin"
            if LC_ALL=C grep -qa "^$(cat "$STUB_HOME/corrupt") " "$STUB_HOME/stdin"; then
                bash -s < "$STUB_HOME/stdin" | LC_ALL=C sed 's/^[0-9a-f]\{8\}/00000000/'
                exit "${PIPESTATUS[0]}"
            fi
            exec bash -s < "$STUB_HOME/stdin"
        fi
        exec bash -s ;;
    'C:\msys64\usr\bin\git.exe receive-pack '* | 'wsl.exe -d Ubuntu-24.04 -e git receive-pack '*)
        if [ -e "$STUB_HOME/unreachable-push" ]; then echo "ssh: connection reset" >&2; exit 255; fi
        exec git receive-pack "${cmd##* }" ;;
esac
# cmd.exe: "a & b & c"
rest="$cmd"
while [ -n "$rest" ]; do
    one=${rest%% & *}
    if [ "$one" = "$rest" ]; then rest=; else rest=${rest#* & }; fi
    one=${one% 2>nul}
    case $one in
        'type "'*) f=${one#type \"}; f=${f%\"}; f=$(printf '%s' "$f" | tr '\\' /); cat "$f" 2> /dev/null ;;
        'echo '*) echo "${one#echo } " ;;
        'nvidia-smi --query-gpu='*) [ -n "$STUB_GPU" ] && printf '%s\r\n' "$STUB_GPU" ;;
        'nvidia-smi --query-compute-apps='*) [ -n "$STUB_APPS" ] && printf '%s\r\n' "$STUB_APPS" ;;
        *) echo "'$one' is not recognized as an internal or external command" >&2 ;;
    esac
done
exit 0
EOF
chmod +x "$scratch/stub-ssh"

cat > "$WINPC_CONF" << EOF
# test config
host        = winpc
native_root = $pc/native
wsl_root    = $pc/wsl
msys2       = C:\\msys64
wsl_distro  = Ubuntu-24.04
status_file = $pc/status.txt
lock_dir    = $pc/lock
logs_root   = $scratch/logs
EOF

# watcher <state> <age in s> [interval]: writes the watcher's status file (CRLF, as on Windows)
watcher() {
    printf 'state=%s\r\nreason=%s\r\nupdated=x\r\nepoch=%s\r\ninterval=%s\r\n' "$1" "test $1" \
        "$(($(date +%s) - $2))" "${3:-1}" > "$pc/status.txt"
}

# --- usage and config ---
expect "no arguments is a usage error" 64 "$winpc"
expect "--help" 0 "$winpc" --help
has out "^Usage:" "help prints the usage header"
has out "Exit codes" "help covers exit codes"
expect "unknown subcommand" 64 "$winpc" frobnicate
expect "bad env" 64 "$winpc" poll mac some-run
WINPC_CONF="$scratch/none.conf" expect "missing config" 78 "$winpc" status
grep -v '^lock_dir' "$WINPC_CONF" > "$scratch/partial.conf"
WINPC_CONF="$scratch/partial.conf" expect "config missing a key" 78 "$winpc" status
has err "missing lock_dir" "names the missing key"
sed 's/^host .*/host = win pc/' "$WINPC_CONF" > "$scratch/bad.conf"
WINPC_CONF="$scratch/bad.conf" expect "config with a bad host" 78 "$winpc" status
{ cat "$WINPC_CONF"; echo "colour = blue"; } > "$scratch/extra.conf"
WINPC_CONF="$scratch/extra.conf" expect "config with an unknown key" 78 "$winpc" status

# --- avail ---
expect "avail defaults to on" 0 "$winpc" avail
has out "^flag: on$" "flag on by default"
expect "avail off" 0 "$winpc" avail off
expect "avail shows off" 0 "$winpc" avail
has out "^flag: off$" "flag off after avail off"
expect "avail bogus" 64 "$winpc" avail maybe
"$winpc" avail on > /dev/null

# --- status ---
touch "$STUB_HOME/unreachable"
expect "status unreachable" 68 "$winpc" status
has out "verdict: unreachable" "unreachable verdict"
rm "$STUB_HOME/unreachable"
expect "status without a watcher file" 69 "$winpc" status
has out "^watcher: unknown" "missing file is unknown"
watcher idle 2
expect "status idle" 0 "$winpc" status
has out "^watcher: idle \(test idle, [0-9]+s ago\)$" "idle watcher line, CR stripped"
has out "^gpu: NVIDIA GeForce RTX 3080, 3 %, 1200 MiB, 10240 MiB$" "nvidia-smi line"
has out "^lock: free$" "lock free"
has out "^verdict: available$" "available verdict"
watcher busy 2
expect "status busy" 69 "$winpc" status
has out "^watcher: busy" "busy watcher"
watcher idle 600 15
expect "status stale" 69 "$winpc" status
has out "^watcher: stale" "old file is stale, not idle"
watcher idle -600
expect "status future-dated" 69 "$winpc" status
has out "^watcher: unknown \(status file is [0-9]+s in the future" "future file is unknown"
printf 'state=unknown\r\nreason=error: gpu: counters unavailable\r\nepoch=%s\r\ninterval=15\r\n' "$(date +%s)" > "$pc/status.txt"
expect "status when a watcher check failed" 69 "$winpc" status
has out "^watcher: unknown \(error: gpu: counters unavailable" "failed check named"
printf 'state=sleepy\r\nreason=x\r\nepoch=%s\r\ninterval=15\r\n' "$(date +%s)" > "$pc/status.txt"
expect "status with an unknown state" 69 "$winpc" status
has out "^watcher: unknown" "unknown state value isn't idle"
watcher idle 2
"$winpc" avail off > /dev/null
expect "status flag off" 69 "$winpc" status
has out "verdict: unavailable: avail flag off" "flag-off verdict"
"$winpc" avail on > /dev/null
mkdir -p "$pc/lock/held"
echo "run=other env=wsl pid=1 winpid=- epoch=1" > "$pc/lock/held/holder"
expect "status lock held" 75 "$winpc" status
has out "^lock: run=other" "shows the holder"
rm -rf "$pc/lock/held"

# --- a repo with a submodule and a failing pre-push hook ---
G() { git -c user.name=t -c user.email=t@t -c protocol.file.allow=always "$@"; }
mkdir "$scratch/sub" "$scratch/repo"
G -C "$scratch/sub" init -q
echo sub > "$scratch/sub/file"
G -C "$scratch/sub" add file && G -C "$scratch/sub" commit -qm sub
G -C "$scratch/repo" init -q
mkdir -p "$scratch/repo/tools"
cat > "$scratch/repo/tools/gpu-lock.sh" << 'EOF'
#!/bin/bash
echo "gpu-lock: $*" > gpu-lock.used
exec "$@"
EOF
chmod +x "$scratch/repo/tools/gpu-lock.sh"
cat > "$scratch/repo/test.sh" << 'EOF'
#!/bin/bash
# prints noise and summary lines, writes a log and a failed screenshot, exits with $1
echo "compiling lots of things"
echo "PASS test-cpu (12 cases)"
echo "FAIL test-gpu (3 cases, exit 2)"
echo "  failed: Screenshot.Triangle"
echo "    some log tail"
echo "note: browser skipped"
echo "stderr noise" >&2
mkdir -p build/logs tests/gpu/approved/NVIDIA
echo "full log" > build/logs/test-gpu.log
echo png > tests/gpu/approved/NVIDIA/Screenshot.Triangle.received.png
pwd > ran-in
exit "$1"
EOF
chmod +x "$scratch/repo/test.sh"
G -C "$scratch/repo" add tools test.sh
G -C "$scratch/repo" submodule add -q "$scratch/sub" external/sub
G -C "$scratch/repo" commit -qm one
printf '#!/bin/sh\ntouch "%s/hook-ran"\nexit 1\n' "$scratch" > "$scratch/repo/.git/hooks/pre-push"
chmod +x "$scratch/repo/.git/hooks/pre-push"
sha=$(git -C "$scratch/repo" rev-parse HEAD)
subsha=$(git -C "$scratch/sub" rev-parse HEAD)
G -C "$scratch/repo" worktree add -q "$scratch/wt" "$sha" 2> /dev/null
G -C "$scratch/wt" submodule update -q --init 2> /dev/null

# the hook is live: a plain push fails
G init -q --bare "$scratch/bare.git"
if G -C "$scratch/repo" push -q "$scratch/bare.git" HEAD:refs/heads/x 2> /dev/null; then
    fail "the test hook should make a plain push fail"
else
    pass "the test hook blocks a plain push"
fi
rm -f "$scratch/hook-ran"

# --- sync ---
expect "sync native" 0 "$winpc" sync native "$scratch/repo" "$sha"
has out "synced repo $sha" "sync names the repo"
[ ! -e "$scratch/hook-ran" ] && pass "sync pushes with --no-verify" || fail "the pre-push hook ran"
[ "$(git -C "$pc/native/repo" rev-parse HEAD)" = "$sha" ] && pass "clone checked out at sha" || fail "clone HEAD"
[ "$(git -C "$pc/native/repo/external/sub" rev-parse HEAD)" = "$subsha" ] && pass "submodule checked out" \
    || fail "submodule HEAD"
[ "$(cat "$pc/native/repo/.git/winpc-synced")" = "$sha" ] && pass "sync marker" || fail "sync marker"
git -C "$pc/native/repo" symbolic-ref -q HEAD > /dev/null && fail "clone HEAD isn't detached" || pass "detached HEAD"
grep -q 'C:\\msys64\\usr\\bin\\git.exe receive-pack '"$pc/native/repo"'$' "$STUB_LOG" \
    && pass "push goes through the native receive-pack launcher" || fail "receive-pack launcher: $(tail -3 "$STUB_LOG")"
expect "sync wsl from a worktree" 0 "$winpc" sync wsl "$scratch/wt" "$sha"
[ "$(git -C "$pc/wsl/repo" rev-parse HEAD)" = "$sha" ] && pass "worktree syncs as the main repo's name" \
    || fail "wsl clone"
grep -q 'wsl.exe -d Ubuntu-24.04 -e bash -s' "$STUB_LOG" && pass "wsl launcher used" || fail "wsl launcher"
# a second commit, synced again: incremental, older run refs pruned
echo two > "$scratch/repo/two"
G -C "$scratch/repo" add two && G -C "$scratch/repo" commit -qm two
sha2=$(git -C "$scratch/repo" rev-parse HEAD)
expect "sync a newer commit" 0 "$winpc" sync native "$scratch/repo" "$sha2"
[ "$(git -C "$pc/native/repo" for-each-ref refs/remote-run/ | wc -l | tr -d ' ')" = 1 ] \
    && pass "old run refs pruned" || fail "run refs: $(git -C "$pc/native/repo" for-each-ref refs/remote-run/)"
# a push that loses the connection is 68, not 70
touch "$STUB_HOME/unreachable-push"
echo three > "$scratch/repo/three"
G -C "$scratch/repo" add three && G -C "$scratch/repo" commit -qm three
expect "sync with the connection lost mid-push" 68 "$winpc" sync native "$scratch/repo" "$(git -C "$scratch/repo" rev-parse HEAD)"
rm "$STUB_HOME/unreachable-push"
G -C "$scratch/repo" reset -q --hard "$sha2"
# nested submodules: top -> mid -> deep
for r in deep mid top; do G init -q "$scratch/$r"; echo "$r" > "$scratch/$r/file"; G -C "$scratch/$r" add file; done
G -C "$scratch/deep" commit -qm deep
G -C "$scratch/mid" submodule add -q "$scratch/deep" deep && G -C "$scratch/mid" commit -qm mid
G -C "$scratch/top" submodule add -q "$scratch/mid" lib/mid && G -C "$scratch/top" commit -qm top
G -C "$scratch/top" submodule update -q --init --recursive
expect "sync nested submodules" 0 "$winpc" sync native "$scratch/top" "$(git -C "$scratch/top" rev-parse HEAD)"
[ "$(git -C "$pc/native/top/lib/mid/deep" rev-parse HEAD)" = "$(git -C "$scratch/deep" rev-parse HEAD)" ] \
    && pass "nested submodule checked out" || fail "nested submodule HEAD"
expect "sync a missing commit" 65 "$winpc" sync native "$scratch/repo" deadbeef
expect "sync without a dir" 64 "$winpc" sync native repo "$sha"
expect "__git-ssh refuses other commands" 64 "$winpc" __git-ssh native winpc "git-upload-pack '/x'; rm -rf /"

# --- run ---
watcher idle 2
"$winpc" avail off > /dev/null
: > "$STUB_LOG"
expect "run refuses with the flag off" 69 "$winpc" run native "$scratch/repo" "$sha2" --task t1 -- ./test.sh 0
has err "avail flag is off" "says why"
[ -s "$STUB_LOG" ] && fail "contacted the PC with the flag off" || pass "flag off: PC not contacted"
"$winpc" avail on > /dev/null
watcher busy 2
expect "run refuses when the watcher says busy" 69 "$winpc" run native "$scratch/repo" "$sha2" --task t1 -- ./test.sh 0
has err "watcher busy" "busy reason"
watcher idle 600 15
expect "run refuses when the watcher is stale" 69 "$winpc" run native "$scratch/repo" "$sha2" --task t1 -- ./test.sh 0
has err "watcher stale" "stale reason"
rm "$pc/status.txt"
expect "run refuses without a watcher file" 69 "$winpc" run native "$scratch/repo" "$sha2" --task t1 -- ./test.sh 0
watcher idle 2
expect "run refuses an unsynced commit" 65 "$winpc" run native "$scratch/repo" "$sha" --task t1 -- ./test.sh 0
has err "not synced" "unsynced reason"
expect "run usage without --task" 64 "$winpc" run native "$scratch/repo" "$sha2" -- ./test.sh 0
expect "run with a name needs a full sha" 64 "$winpc" run native repo "${sha2:0:7}" --task t1 -- ./test.sh 0

expect "run passes the command's exit code" 3 "$winpc" run native "$scratch/repo" "$sha2" --task t1 -- ./test.sh 3
cp "$scratch/out" "$scratch/run.out"
has run.out "^PASS test-cpu \(12 cases\)$" "PASS line shown"
has run.out "^FAIL test-gpu" "FAIL line shown"
has run.out "^  failed: Screenshot.Triangle$" "failed case shown"
has run.out "^note: browser skipped$" "note shown"
has run.out "^winpc: command exited 3$" "exit line"
hasnt run.out "compiling|some log tail|stderr noise|@@winpc" "noise filtered out"
dest="$scratch/logs/t1/$sha2"
has run.out "^winpc: logs in $dest$" "says where the logs are"
[ -f "$dest/build/logs/test-gpu.log" ] && pass "build/logs copied back" || fail "no build/logs in $dest"
[ -f "$dest/tests/gpu/approved/NVIDIA/Screenshot.Triangle.received.png" ] && pass "failed screenshot copied back" \
    || fail "no screenshot in $dest"
log=$(find "$dest" -name "winpc-t1-*.log" | head -n 1)
[ -n "$log" ] && grep -q "compiling lots of things" "$log" && grep -q "stderr noise" "$log" \
    && pass "full output kept locally" || fail "full log: $log"
[ "$(cat "$pc/native/repo/ran-in")" = "$pc/native/repo" ] && pass "runs in the clone" || fail "ran in $(cat "$pc/native/repo/ran-in")"
grep -q "gpu-lock: ./test.sh 3" "$pc/native/repo/gpu-lock.used" && pass "runs through tools/gpu-lock.sh" \
    || fail "gpu-lock.sh not used"
[ ! -e "$pc/lock/held" ] && pass "lock released after run" || fail "lock left held"
expect "run success" 0 "$winpc" run native "$scratch/repo" "$sha2" --task t1 -- ./test.sh 0
has out "^winpc: command exited 0$" "exit 0 line"
# shellcheck disable=SC2016 # $1 is for the remote bash
expect "run with an argument needing quotes" 0 "$winpc" run native "$scratch/repo" "$sha2" --task t1 -- \
    bash -c 'echo "PASS quoted $1"' x "a 'b' \$c"
has out "^PASS quoted a 'b' \\\$c$" "arguments arrive intact"
expect "a command exiting 69 is told apart" 69 "$winpc" run native "$scratch/repo" "$sha2" --task t1 -- bash -c 'exit 69'
has out "^winpc: command exited 69$" "exit line for 69"

expect "output without a final newline" 3 "$winpc" run native "$scratch/repo" "$sha2" --task t1 -- \
    bash -c 'printf "PASS x"; exit 3'
has out "^PASS x$" "unterminated summary line shown"
has out "^winpc: command exited 3$" "result found after an unterminated line"
expect "a command exiting 255 isn't a lost connection" 255 "$winpc" run native "$scratch/repo" "$sha2" --task t1 -- \
    bash -c 'exit 255'
hasnt err "unreachable" "no spurious unreachable"

# lock held by a live process: refuses; by a dead one: broken and run
sleep 300 &
live=$!
mkdir -p "$pc/lock/held"
echo "run=other env=wsl pid=$live winpid=- epoch=1" > "$pc/lock/held/holder"
expect "run refuses while a live holder has the lock" 75 "$winpc" run native "$scratch/repo" "$sha2" --task t1 -- ./test.sh 0
has err "lock is held" "lock reason"
kill "$live"
wait "$live" 2> /dev/null
expect "run breaks a dead holder's lock" 0 "$winpc" run native "$scratch/repo" "$sha2" --task t1 -- ./test.sh 0
has err "broke a stale PC GPU lock" "says it broke it"

# preemption: the watcher turns busy mid-run
watcher idle 0 1
(sleep 2 && watcher busy 0 1) &
expect "run is preempted when a game starts" 69 "$winpc" run native "$scratch/repo" "$sha2" --task t1 -- \
    bash -c 'echo "PASS before"; sleep 30; echo "PASS after"'
wait
has out "^winpc: preempted: watcher busy \(test busy\)" "preempted line"
has out "^PASS before$" "output before preemption"
hasnt out "PASS after" "command killed"
[ ! -e "$pc/lock/held" ] && pass "lock released after preemption" || fail "lock held after preemption"

# connection lost
watcher idle 2
touch "$STUB_HOME/unreachable"
expect "run unreachable" 68 "$winpc" run native "$scratch/repo" "$sha2" --task t1 -- ./test.sh 0
rm "$STUB_HOME/unreachable"

# --- start / poll / fetch / stop ---
expect "start" 0 "$winpc" start wsl "$scratch/repo" "$sha" --task t2 -- \
    bash -c 'sleep 2; echo "PASS detached"; echo noise; ./test.sh 0 > /dev/null'
id=$(sed -n 's/^winpc: started \([^ ]*\) .*/\1/p' "$scratch/out")
[ -n "$id" ] && pass "start prints the run id ($id)" || fail "no run id: $(cat "$scratch/out")"
[ -d "$pc/lock/held" ] && pass "detached run holds the lock" || fail "detached run without lock"
grep -q "run=$id .*pid=[0-9]" "$pc/lock/held/holder" && pass "runner took over the lock" || fail "holder: $(cat "$pc/lock/held/holder")"
expect "poll while running" 75 "$winpc" poll wsl "$id"
has out "^state: (running|starting)$" "running state"
expect "start refuses while the lock is held" 75 "$winpc" start native "$scratch/repo" "$sha2" --task t3 -- true
i=0
until "$winpc" poll wsl "$id" > "$scratch/out" 2>&1 || [ $i -ge 30 ]; do sleep 1; i=$((i + 1)); done
has out "^state: exit 0$" "poll reports the finished run"
has out "^PASS detached$" "poll shows the summary"
expect "fetch" 0 "$winpc" fetch wsl "$id"
has out "^PASS detached$" "fetch prints the summary"
hasnt out "noise" "fetch filters"
[ -f "$scratch/logs/t2/$sha/winpc-$id.log" ] && pass "fetch copies the output" || fail "no output copy"
[ -f "$scratch/logs/t2/$sha/build/logs/test-gpu.log" ] && pass "fetch copies build/logs" || fail "fetch logs"
[ ! -e "$pc/lock/held" ] && pass "finished detached run released the lock" || fail "lock held after detached run"

expect "start a long run" 0 "$winpc" start native "$scratch/repo" "$sha2" --task t3 -- bash -c 'echo "PASS early"; sleep 60'
id2=$(sed -n 's/^winpc: started \([^ ]*\) .*/\1/p' "$scratch/out")
sleep 1
expect "stop" 0 "$winpc" stop native "$id2"
has out "^state: stopped$" "stop result"
expect "poll a stopped run" 0 "$winpc" poll native "$id2"
expect "fetch a stopped run" 69 "$winpc" fetch native "$id2"
has out "^PASS early$" "stopped run's summary"
[ ! -e "$pc/lock/held" ] && pass "stop released the lock" || fail "lock held after stop"
# stopped before its runner starts (a slow runner, via a slow nohup on the wsl env's PATH; native
# puts MSYS2's /usr/bin first): the command never runs
mkdir -p "$STUB_HOME/bin"
printf '#!/bin/bash\nsleep 4\nexec /usr/bin/nohup "$@"\n' > "$STUB_HOME/bin/nohup"
chmod +x "$STUB_HOME/bin/nohup"
"$winpc" start wsl "$scratch/repo" "$sha" --task t4 -- touch "$scratch/t4-ran" > "$scratch/start4.out" 2>&1 &
start4=$!
i=0
until [ -n "$(find "$pc/wsl/.winpc-runs" -maxdepth 1 -name 't4-*' 2> /dev/null)" ] || [ $i -ge 50 ]; do sleep 0.1; i=$((i + 1)); done
id4=$(basename "$(find "$pc/wsl/.winpc-runs" -maxdepth 1 -name 't4-*' | head -n 1)")
expect "stop a run that hasn't started" 0 "$winpc" stop wsl "$id4"
has out "^state: stopped$" "cancelled before it started"
wait "$start4"
[ $? -eq 69 ] && pass "start reports the run ended before it started" || fail "start: $(cat "$scratch/start4.out")"
sleep 5
[ ! -e "$scratch/t4-ran" ] && pass "a late runner doesn't run a stopped command" || fail "the stopped command ran"
[ ! -e "$pc/lock/held" ] && pass "cancelled start released the lock" || fail "lock held after cancelled start"
rm -rf "${STUB_HOME:?}/bin"

# stop refuses a foreground run (it would free the lock while the command still runs)
watcher idle 0 1
"$winpc" run native "$scratch/repo" "$sha2" --task t6 -- bash -c 'sleep 4' > "$scratch/run6.out" 2>&1 &
run6=$!
i=0
until [ -n "$(find "$pc/native/.winpc-runs" -maxdepth 1 -name 't6-*' 2> /dev/null)" ] || [ $i -ge 50 ]; do sleep 0.1; i=$((i + 1)); done
id6=$(basename "$(find "$pc/native/.winpc-runs" -maxdepth 1 -name 't6-*' | head -n 1)")
expect "stop refuses a foreground run" 64 "$winpc" stop native "$id6"
[ -d "$pc/lock/held" ] && pass "refused stop kept the lock" || fail "lock freed by stop of a foreground run"
wait "$run6"

# a detached run is preempted too
watcher idle 0 1
expect "start a run to preempt" 0 "$winpc" start wsl "$scratch/repo" "$sha" --task t5 -- bash -c 'echo "PASS d"; sleep 30'
id5=$(sed -n 's/^winpc: started \([^ ]*\) .*/\1/p' "$scratch/out")
watcher busy 0 1
i=0
until "$winpc" poll wsl "$id5" > "$scratch/out" 2>&1 || [ $i -ge 30 ]; do sleep 1; i=$((i + 1)); done
has out "^state: preempted test busy$" "poll shows the preemption"
expect "fetch a preempted run" 69 "$winpc" fetch wsl "$id5"
has out "^winpc: preempted" "fetch reports the preemption"
[ ! -e "$pc/lock/held" ] && pass "preempted detached run released the lock" || fail "lock held after detached preemption"
watcher idle 2

expect "poll an unknown run" 65 "$winpc" poll native nope
expect "poll a bad run id" 64 "$winpc" poll native '../x'

# --- put / get ---
mkdir -p "$scratch/data/scene/sub"
head -c 4096 /dev/urandom > "$scratch/data/scene/sub/blob.bin"
printf 'a\r\nb\n' > "$scratch/data/scene/crlf.txt"
expect "put a directory" 0 "$winpc" put wsl "$scratch/data/scene" datasets
has out "2 files, SHA-256 checked" "put checks hashes"
cmp -s "$scratch/data/scene/sub/blob.bin" "$pc/wsl/datasets/scene/sub/blob.bin" && pass "put copies bytes" || fail "put bytes"
expect "get it back" 0 "$winpc" get wsl datasets/scene "$scratch/back"
cmp -s "$scratch/data/scene/crlf.txt" "$scratch/back/scene/crlf.txt" && pass "get keeps CRLF bytes" || fail "get bytes"
expect "get a missing path" 70 "$winpc" get wsl datasets/none "$scratch/back"
echo op_put > "$STUB_HOME/corrupt"
expect "put notices a hash mismatch" 70 "$winpc" put wsl "$scratch/data/scene" datasets
has err "SHA-256 mismatch" "put mismatch reason"
echo op_hashes > "$STUB_HOME/corrupt"
expect "get notices a hash mismatch" 70 "$winpc" get wsl datasets/scene "$scratch/back2"
has err "SHA-256 mismatch" "get mismatch reason"
rm "$STUB_HOME/corrupt"
touch "$STUB_HOME/unreachable"
expect "get unreachable" 68 "$winpc" get wsl datasets/scene "$scratch/back3"
expect "put unreachable" 68 "$winpc" put wsl "$scratch/data/scene" datasets
rm "$STUB_HOME/unreachable"

echo
if [ "$failures" -eq 0 ]; then echo "all passed"; else echo "$failures failed"; fi
[ "$failures" -eq 0 ]
