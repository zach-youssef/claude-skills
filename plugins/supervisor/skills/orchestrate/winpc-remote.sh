# winpc-remote.sh: the PC side of winpc. Not run directly: winpc pipes it into `bash -s` in one
# environment (native = MSYS2 bash, wsl = WSL bash), after a header that sets WINPC_ENV, ROOT,
# LOCK_DIR and STATUS_FILE and before one `op_<name> <args...>` line. Whatever follows that line
# on stdin (put's tar stream) is left for the op: bash reads a script from a pipe one byte at a
# time.
#
# Layout under ROOT (the env's clone root): <repo>/ is the persistent clone, with each submodule
# an independent repository at its path; .winpc-runs/<run id>/ holds a run's meta, its marker
# file (logs newer than it are the run's), its claim (a directory: whoever makes it, the runner
# or a stop or start that gives up on it, decides whether the command runs), its pid files, its
# output (detached runs) and its result ("exit <n>", "stopped" or "preempted <reason>").
#
# The PC GPU lock is a directory, LOCK_DIR/held, made atomically with mkdir; held/holder says
# "run=<id> env=<env> pid=<pid> winpid=<pid> epoch=<s>". LOCK_DIR is a Windows path both
# environments reach, so native and WSL runs exclude each other. winpc breaks a holder whose
# process is gone (op_pid_alive, op_lock_break).
#
# While a command runs, a watchdog rereads the watcher's STATUS_FILE every interval and, when it
# says busy (a game started), kills the command's process tree and records "preempted".
#
# Written for bash 3.2 too, since winpc's tests run it on macOS against a stub host.
# shellcheck shell=bash

winpc_setup() {
    if [ "$WINPC_ENV" = native ]; then
        PATH="/usr/bin:$PATH"
        export PATH
    fi
    lockdir=$(to_posix "$LOCK_DIR")
    statusfile=$(to_posix "$STATUS_FILE")
    runs="$ROOT/.winpc-runs"
}

# Windows paths (C:\...) to this environment's form; anything else unchanged
to_posix() {
    case $1 in
        [A-Za-z]:\\* | [A-Za-z]:/*)
            if command -v cygpath > /dev/null 2>&1; then cygpath -u "$1"; return; fi
            if command -v wslpath > /dev/null 2>&1; then wslpath -u "$1"; return; fi
            ;;
    esac
    printf '%s\n' "$1"
}

msg() { printf 'winpc (%s): %s\n' "$WINPC_ENV" "$*" >&2; }

winpid_of() {
    if [ -r "/proc/$1/winpid" ]; then cat "/proc/$1/winpid"; else echo -; fi
}

# pid_alive <pid> <winpid or ->: Windows pids for native processes (an MSYS2 pid may not be
# visible across Windows sessions), POSIX pids otherwise
pid_alive() {
    if [ "$WINPC_ENV" = native ] && [ "$2" != - ] && command -v tasklist > /dev/null 2>&1; then
        MSYS2_ARG_CONV_EXCL='*' tasklist /FI "PID eq $2" /NH 2> /dev/null | grep -q " $2 "
        return
    fi
    kill -0 "$1" 2> /dev/null
}

# kill_tree <pid> [<winpid>]: the process group <pid> leads (commands run under set -m), and on
# native its Windows process tree, which MSYS2 signals don't reach for native children. The
# recorded winpid covers an MSYS2 pid this session can't see (another Windows session).
kill_tree() {
    local pid=$1 winpid=${2:--} i=0
    [ "$winpid" = - ] && winpid=$(winpid_of "$pid")
    if [ "$WINPC_ENV" = native ] && [ "$winpid" != - ] && command -v taskkill > /dev/null 2>&1; then
        MSYS2_ARG_CONV_EXCL='*' taskkill /F /T /PID "$winpid" > /dev/null 2>&1
    fi
    kill -TERM -- "-$pid" 2> /dev/null || kill -TERM "$pid" 2> /dev/null
    while kill -0 "$pid" 2> /dev/null && [ $i -lt 10 ]; do
        sleep 1
        i=$((i + 1))
    done
    kill -KILL -- "-$pid" 2> /dev/null
    return 0
}

# Sets st_state (idle, busy or unknown), st_reason and st_interval from the watcher's file
read_status() {
    local k v
    st_state=unknown st_reason='' st_interval=15
    [ -r "$statusfile" ] || return 1
    while IFS='=' read -r k v || [ -n "$k" ]; do
        v=${v%$'\r'}
        case $k in
            state) st_state=$v ;;
            reason) st_reason=$v ;;
            interval) case $v in '' | *[!0-9]*) ;; *) [ "$v" -ge 1 ] && st_interval=$v ;; esac ;;
        esac
    done < "$statusfile"
}

watchdog() {
    local pid=$1 rundir=$2
    while kill -0 "$pid" 2> /dev/null; do
        if read_status && [ "$st_state" = busy ]; then
            printf '%s\n' "${st_reason:-busy}" > "$rundir/preempted"
            kill_tree "$pid"
            return 0
        fi
        sleep "$st_interval"
    done
}

lock_acquire() { # <run id> <pid or pending>
    local winpid=-
    [ "$2" != pending ] && winpid=$(winpid_of "$2")
    mkdir -p "$lockdir" || return 70
    if mkdir "$lockdir/held" 2> /dev/null; then
        printf 'run=%s env=%s pid=%s winpid=%s epoch=%s\n' "$1" "$WINPC_ENV" "$2" "$winpid" \
            "$(date +%s)" > "$lockdir/held/holder"
        return 0
    fi
    msg "the PC GPU lock is held: $(cat "$lockdir/held/holder" 2> /dev/null || echo '(holder not written yet)')"
    return 75
}

lock_held_by() { case $(cat "$lockdir/held/holder" 2> /dev/null) in "run=$1 "*) return 0 ;; esac; return 1; }

lock_set_pid() { # <run id> <pid>: a detached runner takes over its lock from op_start
    lock_held_by "$1" || return 0
    printf 'run=%s env=%s pid=%s winpid=%s epoch=%s\n' "$1" "$WINPC_ENV" "$2" "$(winpid_of "$2")" \
        "$(date +%s)" > "$lockdir/held/holder.tmp" && mv -f "$lockdir/held/holder.tmp" "$lockdir/held/holder"
}

lock_release() { lock_held_by "$1" && rm -rf "$lockdir/held"; return 0; }

check_synced() { # <clone> <sha>
    local synced head
    synced=$(cat "$1/.git/winpc-synced" 2> /dev/null)
    head=$(git -C "$1" rev-parse HEAD 2> /dev/null)
    if [ "$synced" != "$2" ] || [ "$head" != "$2" ]; then
        msg "$1 is not synced to $2 (synced: ${synced:-none}, HEAD: ${head:-none}); run winpc sync first"
        return 65
    fi
}

new_run() { # <run id> <repo> <sha> <task>: sets rundir; a run id is never reused
    rundir="$runs/$1"
    mkdir -p "$runs" || return 70
    mkdir "$rundir" || { msg "run $1 already exists"; return 70; }
    printf 'repo=%s\nsha=%s\ntask=%s\n' "$2" "$3" "$4" > "$rundir/meta"
    touch "$rundir/started"
}

# run_command <clone> <rundir> <command...>: runs the command in its own process group under a
# login shell (the env's toolchain setup), through the repo's tools/gpu-lock.sh when it has one,
# with the watchdog beside it. Output goes to stdout; returns the command's status.
run_command() {
    local clone=$1 rundir=$2 job wd st
    shift 2
    cd "$clone" || return 70
    if [ -x tools/gpu-lock.sh ]; then set -- tools/gpu-lock.sh "$@"; fi
    set -m
    if [ "$WINPC_ENV" = native ]; then
        MSYSTEM=CLANG64 CHERE_INVOKING=1 bash -lc '"$@"' winpc "$@" < /dev/null 2>&1 &
    else
        bash -lc '"$@"' winpc "$@" < /dev/null 2>&1 &
    fi
    job=$!
    set +m
    echo "$job" > "$rundir/jobpid"
    winpid_of "$job" > "$rundir/jobwinpid"
    # a stop that came before jobpid existed couldn't kill the job: do it now
    [ -f "$rundir/stopped" ] && kill_tree "$job"
    watchdog "$job" "$rundir" < /dev/null > /dev/null 2>&1 &
    wd=$!
    wait "$job"
    st=$?
    kill "$wd" 2> /dev/null
    wait "$wd" 2> /dev/null
    return "$st"
}

result_of() { # <rundir> <status>
    if [ -f "$1/stopped" ]; then
        echo stopped
    elif [ -f "$1/preempted" ]; then
        echo "preempted $(cat "$1/preempted")"
    else
        echo "exit $2"
    fi
}

write_result() { printf '%s\n' "$2" > "$1/result.tmp" && mv -f "$1/result.tmp" "$1/result"; }

# --- ops (one per invocation) ---

op_prepare() { # <repo> [<submodule path>...]: makes the clone and each submodule's repository
    local clone="$ROOT/$1" p d
    shift
    for p in "" "$@"; do
        d="$clone${p:+/$p}"
        mkdir -p "$d" || return 70
        if [ ! -e "$d/.git" ]; then git -C "$d" init -q || return 70; fi
        git -C "$d" config core.autocrlf false || return 70
    done
}

prune_refs() { # <repo dir> <sha to keep>
    git -C "$1" for-each-ref --format='%(refname)' refs/remote-run/ | while read -r ref; do
        [ "$ref" = "refs/remote-run/$2" ] || git -C "$1" update-ref -d "$ref"
    done
}

op_checkout() { # <repo> <sha> [<submodule path> <sha>]...: detached, forced, parents first
    local clone="$ROOT/$1" sha=$2
    shift 2
    rm -f "$clone/.git/winpc-synced"
    git -C "$clone" checkout -q -f --detach "$sha" || return 70
    prune_refs "$clone" "$sha"
    while [ $# -ge 2 ]; do
        git -C "$clone/$1" checkout -q -f --detach "$2" || return 70
        prune_refs "$clone/$1" "$2"
        shift 2
    done
    echo "$sha" > "$clone/.git/winpc-synced"
}

op_run() { # <repo> <sha> <task> <run id> <command...>: in the foreground, output to stdout
    local repo=$1 sha=$2 task=$3 id=$4 clone="$ROOT/$1" st result
    shift 4
    check_synced "$clone" "$sha" || return
    lock_acquire "$id" "$$" || return # first: a 75 leaves nothing behind, so winpc can retry
    if ! new_run "$id" "$repo" "$sha" "$task" || ! mkdir "$rundir/claimed"; then
        lock_release "$id"
        return 70
    fi
    run_command "$clone" "$rundir" "$@"
    st=$?
    lock_release "$id"
    result=$(result_of "$rundir" "$st")
    write_result "$rundir" "$result"
    # On a line of its own even when the output didn't end with a newline. It carries the
    # result, so the op itself succeeds (a command exiting 255 mustn't look like ssh failing).
    printf '\n@@winpc-%s %s\n' "$id" "$result"
}

# detach_windows <command line>: starts it with Win32_Process.Create, outside the SSH session's
# job object, so it outlives the session (and, for wsl.exe, keeps the distro running)
detach_windows() {
    local cl ps enc
    cl=$(printf '%s' "$1" | sed "s/'/''/g")
    ps="\$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine='$cl'}; exit \$r.ReturnValue"
    enc=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
    MSYS2_ARG_CONV_EXCL='*' powershell.exe -NoProfile -NonInteractive -EncodedCommand "$enc" < /dev/null > /dev/null
}

op_start() { # <repo> <sha> <task> <run id> <command...>: detached, outliving the SSH session
    local repo=$1 sha=$2 task=$3 id=$4 clone="$ROOT/$1" runner ps enc i=0
    shift 4
    check_synced "$clone" "$sha" || return
    lock_acquire "$id" pending || return
    new_run "$id" "$repo" "$sha" "$task" || { lock_release "$id"; return 70; }
    runner="$rundir/runner.sh"
    {
        printf 'WINPC_ENV=%q ROOT=%q LOCK_DIR=%q STATUS_FILE=%q\n' "$WINPC_ENV" "$ROOT" "$LOCK_DIR" "$STATUS_FILE"
        declare -f
        echo winpc_setup
        printf 'runner_main %q %q %q' "$clone" "$rundir" "$id"
        printf ' %q' "$@"
        echo
    } > "$runner"
    if [ "$WINPC_ENV" = native ] && command -v powershell.exe > /dev/null 2>&1; then
        detach_windows "$(cygpath -w /usr/bin/bash.exe) $(cygpath -m "$runner")"
    elif [ "$WINPC_ENV" = wsl ] && [ -n "${WSL_DISTRO_NAME:-}" ] && command -v powershell.exe > /dev/null 2>&1; then
        # through Windows interop: tmux or nohup runs die when the distro idles out
        detach_windows "wsl.exe -d $WSL_DISTRO_NAME -e bash $runner"
    elif command -v tmux > /dev/null 2>&1; then
        tmux new-session -d -s "winpc-$id" "bash $(printf %q "$runner")"
    else
        msg "no tmux: starting with nohup, which may not outlive the session"
        nohup bash "$runner" < /dev/null > /dev/null 2>&1 &
    fi
    while [ ! -d "$rundir/claimed" ] && [ $i -lt 30 ]; do
        sleep 0.5
        i=$((i + 1))
    done
    if mkdir "$rundir/claimed" 2> /dev/null; then # the runner can no longer run the command
        msg "the runner for $id didn't start"
        write_result "$rundir" "exit 70"
        lock_release "$id"
        return 70
    fi
    if [ -f "$rundir/result" ]; then # stopped before its runner started
        msg "$id ended before it started: $(cat "$rundir/result")"
        return 69
    fi
    echo "started $id"
}

runner_main() { # <clone> <rundir> <run id> <command...>
    local clone=$1 rundir=$2 id=$3 st
    shift 3
    # too late (op_start gave up) or stopped before it started: the claim is taken, don't run
    mkdir "$rundir/claimed" 2> /dev/null || return 0
    echo $$ > "$rundir/pid.tmp" && mv -f "$rundir/pid.tmp" "$rundir/pid"
    winpid_of $$ > "$rundir/winpid"
    lock_set_pid "$id" $$
    if ! lock_held_by "$id"; then
        msg "$id lost the PC GPU lock before it started"
        write_result "$rundir" "exit 70"
        return 0
    fi
    if [ -f "$rundir/stopped" ]; then
        write_result "$rundir" stopped
        lock_release "$id"
        return 0
    fi
    run_command "$clone" "$rundir" "$@" > "$rundir/out.log" 2>&1
    st=$?
    write_result "$rundir" "$(result_of "$rundir" "$st")"
    lock_release "$id"
}

# keep in sync with summary_re in winpc
summary() { grep -E '^(PASS|FAIL|note: |  failed: |  note: )' "$@" 2> /dev/null; return 0; }

op_poll() { # <run id>: "state: <result | running | starting | lost>", then the summary so far
    local rundir="$runs/$1" pid
    [ -f "$rundir/meta" ] || { msg "no run $1"; return 65; }
    if [ -f "$rundir/result" ]; then
        echo "state: $(cat "$rundir/result")"
    elif [ ! -f "$rundir/pid" ]; then
        echo "state: starting"
    else
        pid=$(cat "$rundir/pid")
        if pid_alive "$pid" "$(cat "$rundir/winpid" 2> /dev/null || echo -)"; then
            echo "state: running"
        else
            echo "state: lost"
        fi
    fi
    [ -f "$rundir/out.log" ] && summary "$rundir/out.log"
    return 0
}

op_stop() { # <run id>: exits 75 ("state: stopping") if the run's processes outlive the stop
    local rundir="$runs/$1" job pid i=0
    [ -f "$rundir/meta" ] || { msg "no run $1"; return 65; }
    # a foreground run (no runner.sh) has no runner to hand the lock back; stop would free it early
    if [ ! -f "$rundir/result" ] && [ ! -f "$rundir/runner.sh" ]; then
        msg "$1 is a foreground run; stop is for detached runs (interrupt the run instead)"
        return 64
    fi
    if [ ! -f "$rundir/result" ]; then
        touch "$rundir/stopped"
        if mkdir "$rundir/claimed" 2> /dev/null; then # its runner hasn't started and now won't
            write_result "$rundir" stopped
            lock_release "$1"
        else
            job=$(cat "$rundir/jobpid" 2> /dev/null)
            [ -n "$job" ] && kill_tree "$job" "$(cat "$rundir/jobwinpid" 2> /dev/null || echo -)"
            while [ ! -f "$rundir/result" ] && [ $i -lt 30 ]; do
                sleep 0.5
                i=$((i + 1))
            done
        fi
        if [ ! -f "$rundir/result" ]; then
            pid=$(cat "$rundir/pid" 2> /dev/null)
            if [ -n "$pid" ] && pid_alive "$pid" "$(cat "$rundir/winpid" 2> /dev/null || echo -)"; then
                msg "$1's runner is still alive; the lock stays held (stop again, or check the PC)"
                echo "state: stopping"
                return 75
            fi
            write_result "$rundir" stopped # the runner is gone without a result
            lock_release "$1"
        fi
    fi
    echo "state: $(cat "$rundir/result")"
}

op_meta() { cat "$runs/$1/meta" 2> /dev/null || { msg "no run $1"; return 65; }; }

op_output() { cat "$runs/$1/out.log" 2> /dev/null; return 0; }

# op_logs_tar <run id>: a tar on stdout (nothing if empty) of the clone's build/logs files and
# failed screenshots (*.received.png, *.flip.png) newer than the run's marker
op_logs_tar() {
    local rundir="$runs/$1" repo list
    repo=$(sed -n 's/^repo=//p' "$rundir/meta" 2> /dev/null)
    [ -n "$repo" ] || { msg "no run $1"; return 65; }
    cd "$ROOT/$repo" || return 70
    list="$rundir/logs.list"
    {
        [ -d build/logs ] && find build/logs -type f -newer "$rundir/started"
        find . -path ./.git -prune -o -type f \( -name '*.received.png' -o -name '*.flip.png' \) \
            -newer "$rundir/started" -print | sed 's|^\./||'
    } > "$list"
    if [ -s "$list" ]; then tar -cf - -T "$list"; fi
}

op_lock_holder() { cat "$lockdir/held/holder" 2> /dev/null; }

op_lock_break() { # <holder line>: removes the lock only if that holder still has it
    [ "$(cat "$lockdir/held/holder" 2> /dev/null)" = "$1" ] || return 1
    rm -rf "$lockdir/held"
}

op_pid_alive() { pid_alive "$1" "$2"; }

abs_path() { case $1 in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$ROOT/$1" ;; esac; }

sha256_list() { # sorted "hash  path" lines for the files under <name>, run in its parent
    if command -v sha256sum > /dev/null 2>&1; then
        find "$1" -type f -exec sha256sum {} + | LC_ALL=C sort
    else
        find "$1" -type f -exec shasum -a 256 {} + | LC_ALL=C sort
    fi
}

op_put() { # <dir> <name>: extracts the tar that follows on stdin into <dir>, prints its hashes
    local dir
    dir=$(abs_path "$1")
    mkdir -p "$dir" || return 70
    tar -xf - -C "$dir" || return 70
    cd "$dir" && sha256_list "$2"
}

op_get() { # <path>: a tar of it on stdout
    local p
    p=$(abs_path "$1")
    [ -e "$p" ] || { msg "no $p"; return 65; }
    tar -cf - -C "$(dirname "$p")" "$(basename "$p")"
}

op_hashes() { # <path>
    local p
    p=$(abs_path "$1")
    cd "$(dirname "$p")" && sha256_list "$(basename "$p")"
}

winpc_setup
