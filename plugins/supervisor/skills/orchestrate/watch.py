#!/usr/bin/env python3
"""Watches the supervisor's poller checks (~/code/.supervisor/watches.json).

Usage:
  watch.py [-f FILE] add <id> [--notify NAME] [--note TEXT] ci <owner/repo> <sha>
  watch.py [-f FILE] add <id> [--notify NAME] [--note TEXT] [--timeout-min N] cmd <shell command>
  watch.py [-f FILE] add <id> [--notify NAME] [--note TEXT] cron '<m h dom mon dow>'
  watch.py [-f FILE] add <id> [--notify NAME] [--note TEXT] at <YYYY-MM-DDTHH:MM>
  watch.py [-f FILE] list
  watch.py [-f FILE] show <id>
  watch.py [-f FILE] remove <id>
  watch.py [-f FILE] poll                    # one pass over every watch
  watch.py [-f FILE] wait [--interval 180]   # the poller's loop: poll until there are events
  watch.py [-f FILE] ack <event id> [...]    # the poller has delivered these events
  watch.py [-f FILE] await <id> [--interval 30]  # a worker waits for one watch (file only)

Kinds:
  ci    done when GitHub has at least one run for the commit and every one has completed;
        the result lists each run's conclusion and its failed jobs. gh errors are retried on
        the next pass (they're usually the secondary rate limit), and reported as `unknown`
        after 5 in a row.
  cmd   done when the command exits 0 (run with `sh -c`, 60 s limit per pass), or `timeout`
        after --timeout-min minutes.
  cron  recurring, local time, standard 5 fields (numbers, `*`, lists, ranges, `/` steps;
        day of week 0-7 with 0 and 7 Sunday). Fires once per matching minute, never more than
        once per pass; it never expires.
  at    one-shot at a local time.

Only the poller (the Haiku `poller` agent) runs `wait`, so only one process talks to GitHub.
It messages each event's `notify` target (default `main`, the supervisor) and acks it. Done
and one-shot watches stay, with their result, until `remove`, so `await` and `show` can read
them. `add` refuses an id that exists. Edits hold an exclusive lock on `.<name>.lock` next to
the file and replace it atomically, like ledger.py.

Exit codes: 0 ok; 1 usage or unknown id; for `await`, the watch's own outcome: 0 success,
3 failure, timeout or unknown.
"""

import argparse
import contextlib
import datetime as dt
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time

DEFAULT_FILE = os.path.expanduser("~/code/.supervisor/watches.json")
GH_ERRORS_BEFORE_UNKNOWN = 5


def die(msg):
    print(f"watch.py: {msg}", file=sys.stderr)
    sys.exit(1)


@contextlib.contextmanager
def locked(path):
    path = os.path.realpath(path)
    lock = os.path.join(os.path.dirname(path), "." + os.path.basename(path) + ".lock")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(lock, "a") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        state = {"watches": {}, "events": []}
        if os.path.exists(path) and os.path.getsize(path):
            with open(path) as f:
                state = json.load(f)
        before = json.dumps(state, sort_keys=True)
        yield state
        if json.dumps(state, sort_keys=True) != before:
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".watches.")
            with os.fdopen(fd, "w") as f:
                json.dump(state, f, indent=1, sort_keys=True)
                f.write("\n")
            os.replace(tmp, path)


def read(path):
    with locked(path) as state:
        return json.loads(json.dumps(state))


def now():
    # WATCH_NOW (YYYY-MM-DDTHH:MM) pins the clock, for test_watch.sh.
    if os.environ.get("WATCH_NOW"):
        return dt.datetime.fromisoformat(os.environ["WATCH_NOW"])
    return dt.datetime.now().replace(second=0, microsecond=0)


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M")


# --- cron -----------------------------------------------------------------------------------

FIELDS = [(0, 59), (0, 23), (1, 31), (1, 12), (0, 7)]


def parse_field(text, lo, hi):
    values = set()
    for part in text.split(","):
        step = 1
        if "/" in part:
            part, s = part.split("/", 1)
            step = int(s)
            if step < 1:
                raise ValueError(f"bad step in {text!r}")
        if part == "*":
            a, b = lo, hi
        elif "-" in part:
            a, b = (int(x) for x in part.split("-", 1))
        else:
            a = int(part)
            b = hi if step > 1 else a
        if not (lo <= a <= b <= hi):
            raise ValueError(f"{text!r} is outside {lo}-{hi}")
        values.update(range(a, b + 1, step))
    return values


def parse_cron(expr):
    parts = expr.split()
    if len(parts) != 5:
        raise ValueError("a cron expression has 5 fields")
    sets = [parse_field(p, lo, hi) for p, (lo, hi) in zip(parts, FIELDS)]
    if 7 in sets[4]:
        sets[4].add(0)
    # Like cron: with both day fields restricted, either may match.
    restricted = (parts[2] != "*", parts[4] != "*")
    return sets, restricted


def cron_matches(expr, t):
    (mins, hours, doms, mons, dows), (dom_r, dow_r) = parse_cron(expr)
    if t.minute not in mins or t.hour not in hours or t.month not in mons:
        return False
    dom_ok, dow_ok = t.day in doms, (t.isoweekday() % 7) in dows
    if dom_r and dow_r:
        return dom_ok or dow_ok
    return dom_ok and dow_ok


def last_cron_match(expr, after, upto):
    """The latest matching minute in (after, upto], or None. Scans at most 8 days back."""
    t = upto
    stop = max(after, upto - dt.timedelta(days=8))
    while t > stop:
        if cron_matches(expr, t):
            return t
        t -= dt.timedelta(minutes=1)
    return None


# --- checks ---------------------------------------------------------------------------------


def gh_json(args):
    out = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        lines = (out.stderr or out.stdout).strip().splitlines()
        raise RuntimeError(lines[-1] if lines else f"gh exited {out.returncode}")
    return json.loads(out.stdout or "null")


def check_ci(w):
    repo, sha = w["repo"], w["sha"]
    runs = gh_json(["run", "list", "-R", repo, "--commit", sha, "--json",
                    "databaseId,name,status,conclusion,url"])
    if not runs or any(r["status"] != "completed" for r in runs):
        return None
    lines, ok = [], True
    for r in runs:
        line = f"{r['name']} {r['databaseId']}: {r['conclusion']} {r['url']}"
        if r["conclusion"] not in ("success", "skipped", "neutral"):
            ok = False
            jobs = gh_json(["run", "view", str(r["databaseId"]), "-R", repo, "--json", "jobs"])
            failed = [j["name"] for j in (jobs or {}).get("jobs", [])
                      if j.get("conclusion") not in ("success", "skipped", "neutral", None)]
            if failed:
                line += "; jobs not green: " + ", ".join(failed)
        lines.append(line)
    return ("success" if ok else "failure"), "\n".join(lines)


def check_cmd(w, t):
    try:
        out = subprocess.run(["sh", "-c", w["cmd"]], capture_output=True, text=True, timeout=60)
        if out.returncode == 0:
            return "success", out.stdout.strip()[-2000:]
    except subprocess.TimeoutExpired:
        pass
    if w.get("timeout_min"):
        started = dt.datetime.fromisoformat(w["created"])
        if t >= started + dt.timedelta(minutes=w["timeout_min"]):
            return "timeout", f"not done after {w['timeout_min']} min"
    return None


def poll(state, t=None):
    """One pass. Appends events to state['events'] and returns the new ones."""
    t = t or now()
    new = []

    def event(wid, w, outcome, detail):
        e = {"id": f"{wid}@{iso(t)}", "watch": wid, "kind": w["kind"], "notify": w["notify"],
             "note": w.get("note", ""), "outcome": outcome, "detail": detail, "at": iso(t),
             "delivered": False}
        state["events"].append(e)
        new.append(e)

    for wid, w in sorted(state["watches"].items()):
        if w.get("status") == "done":
            continue
        kind = w["kind"]
        if kind == "cron":
            after = dt.datetime.fromisoformat(w.get("last_check") or w["created"])
            hit = last_cron_match(w["cron"], after, t)
            w["last_check"] = iso(max(after, t))  # a clock step back never refires a match
            if hit:
                w["last_fired"] = iso(hit)
                event(wid, w, "fired", f"scheduled {w['cron']}, matched {iso(hit)}")
            continue
        result = None
        if kind == "at":
            if t >= dt.datetime.fromisoformat(w["at"]):
                result = ("fired", f"due {w['at']}")
        elif kind == "cmd":
            result = check_cmd(w, t)
        elif kind == "ci":
            try:
                result = check_ci(w)
                w["errors"] = 0
            except (RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError) as err:
                w["errors"] = w.get("errors", 0) + 1
                w["last_error"] = str(err)
                if w["errors"] >= GH_ERRORS_BEFORE_UNKNOWN:
                    result = ("unknown", f"gh failed {w['errors']} times in a row: {err}")
        if result:
            w["status"], w["outcome"], w["result"], w["done_at"] = "done", result[0], result[1], iso(t)
            event(wid, w, *result)
    # Keep the log short: delivered events older than a week go.
    cutoff = iso(t - dt.timedelta(days=7))
    state["events"] = [e for e in state["events"] if not e["delivered"] or e["at"] >= cutoff]
    return new


# --- commands -------------------------------------------------------------------------------


def cmd_add(args):
    w = {"kind": args.kind, "notify": args.notify, "note": args.note or "", "status": "active",
         "created": iso(now())}
    rest = args.spec
    if args.kind == "ci":
        if len(rest) != 2 or "/" not in rest[0] or len(rest[1]) < 7:
            die("ci takes <owner/repo> <sha>")
        w["repo"], w["sha"] = rest
    elif args.kind == "cmd":
        if not rest:
            die("cmd takes a shell command")
        w["cmd"] = " ".join(rest)
        if args.timeout_min:
            w["timeout_min"] = args.timeout_min
    elif args.kind == "cron":
        w["cron"] = " ".join(rest)
        try:
            parse_cron(w["cron"])
        except ValueError as err:
            die(f"cron: {err}")
    elif args.kind == "at":
        try:
            w["at"] = iso(dt.datetime.fromisoformat(" ".join(rest)))
        except ValueError:
            die("at takes YYYY-MM-DDTHH:MM (local time)")
    with locked(args.file) as state:
        if args.id in state["watches"]:
            die(f"watch {args.id!r} exists (remove it first)")
        state["watches"][args.id] = w
    print(f"added {args.id}")


def fmt(wid, w):
    spec = {"ci": lambda: f"{w.get('repo')} {w.get('sha', '')[:12]}", "cmd": lambda: w.get("cmd"),
            "cron": lambda: w.get("cron"), "at": lambda: w.get("at")}[w["kind"]]()
    tail = f" -> {w['outcome']} at {w['done_at']}" if w.get("status") == "done" else ""
    return f"{wid}\t{w['kind']}\t{w['status']}{tail}\tnotify={w['notify']}\t{spec}\t{w.get('note', '')}"


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-f", "--file", default=DEFAULT_FILE)
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("id")
    a.add_argument("--notify", default="main")
    a.add_argument("--note")
    a.add_argument("--timeout-min", type=int)
    a.add_argument("kind", choices=["ci", "cmd", "cron", "at"])
    a.add_argument("spec", nargs=argparse.REMAINDER)
    sub.add_parser("list")
    for name in ("show", "remove"):
        sub.add_parser(name).add_argument("id")
    sub.add_parser("poll")
    w = sub.add_parser("wait")
    w.add_argument("--interval", type=int, default=180)
    k = sub.add_parser("ack")
    k.add_argument("events", nargs="+")
    aw = sub.add_parser("await")
    aw.add_argument("id")
    aw.add_argument("--interval", type=int, default=30)
    args = p.parse_args()

    if args.cmd == "add":
        cmd_add(args)
    elif args.cmd == "list":
        st = read(args.file)
        for wid, wt in sorted(st["watches"].items()):
            print(fmt(wid, wt))
        pending = [e["id"] for e in st["events"] if not e["delivered"]]
        if pending:
            print("undelivered events: " + " ".join(pending))
    elif args.cmd == "show":
        st = read(args.file)
        if args.id not in st["watches"]:
            die(f"no watch {args.id!r}")
        print(json.dumps(st["watches"][args.id], indent=1, sort_keys=True))
    elif args.cmd == "remove":
        with locked(args.file) as st:
            if st["watches"].pop(args.id, None) is None:
                die(f"no watch {args.id!r}")
        print(f"removed {args.id}")
    elif args.cmd == "poll":
        with locked(args.file) as st:
            new = poll(st)
        for e in new:
            print(json.dumps(e, sort_keys=True))
    elif args.cmd == "wait":
        while True:
            with locked(args.file) as st:
                poll(st)
                pending = [e for e in st["events"] if not e["delivered"]]
            if pending:
                for e in pending:
                    print(json.dumps(e, sort_keys=True))
                return
            time.sleep(args.interval)
    elif args.cmd == "ack":
        with locked(args.file) as st:
            ids = set(args.events)
            known = {e["id"] for e in st["events"]}
            missing = ids - known
            if missing:
                die("no event " + ", ".join(sorted(missing)))
            for e in st["events"]:
                if e["id"] in ids:
                    e["delivered"] = True
    elif args.cmd == "await":
        while True:
            wt = read(args.file)["watches"].get(args.id)
            if wt is None:
                die(f"no watch {args.id!r}")
            if wt.get("status") == "done":
                print(f"{args.id}: {wt['outcome']}\n{wt['result']}")
                sys.exit(0 if wt["outcome"] in ("success", "fired") else 3)
            time.sleep(args.interval)


if __name__ == "__main__":
    main()
