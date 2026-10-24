#!/usr/bin/env python3
"""Edit rows of the supervisor ledger (~/code/.supervisor/ledger.md) by task id.

Usage:
  ledger.py [-f FILE] show <id>
  ledger.py [-f FILE] set <id> <field>=<value> [<field>=<value> ...]
  ledger.py [-f FILE] add <id> [<field>=<value> ...]
  ledger.py [-f FILE] delete <id>

Fields are the table's column names, case-insensitive, with '-' or '_' for spaces
(e.g. stage, agent, commit, ci, next-action). An empty value is stored as '—'.

The ledger is the first markdown table whose first column is `id`. Only the
touched row changes; every other line is kept byte for byte. Each edit holds an
exclusive lock on a sidecar file (`.<ledger name>.lock`, next to the ledger), so
parallel calls don't lose each other's updates (failing after --lock-timeout
seconds, default 10, if the holder hangs), and writes a temp file next to
the ledger and renames it over the original, so a crash never leaves a
half-written ledger. A symlinked ledger is edited at its target.

Fails loudly (exit 1, message on stderr) when the id matches no row or more than
one, a field is unknown, a value contains '|' or a newline, or the table is
malformed. `add` creates the ledger, with the standard columns, if it doesn't
exist.
"""

import argparse
import contextlib
import fcntl
import os
import re
import sys
import tempfile
import time

DEFAULT_FILE = os.path.expanduser("~/code/.supervisor/ledger.md")
COLUMNS = ["id", "repo", "branch", "worktree", "agent", "stage", "commit", "CI", "next action"]
EMPTY = "—"
CELL_SPLIT = re.compile(r"(?<!\\)\|")


class LedgerError(Exception):
    pass


def cells(line):
    """Split a table row into stripped cells, or return None if it isn't a row."""
    s = line.strip()
    if not s.startswith("|") or not s.endswith("|") or len(s) < 2:
        return None
    return [c.strip() for c in CELL_SPLIT.split(s[1:-1])]


def format_row(values):
    return "| " + " | ".join(values) + " |\n"


def norm(name):
    return re.sub(r"[-_\s]+", " ", name.strip()).lower()


def find_table(lines):
    """Return (header, first_row_index, end_index) of the ledger table."""
    for i, line in enumerate(lines):
        header = cells(line)
        if header and norm(header[0]) == "id":
            sep = cells(lines[i + 1]) if i + 1 < len(lines) else None
            if not sep or not all(re.fullmatch(r":?-+:?", c) for c in sep):
                raise LedgerError(f"line {i + 2}: expected the table's separator row after the header")
            start = end = i + 2
            while end < len(lines) and cells(lines[end]) is not None:
                if len(cells(lines[end])) != len(header):
                    raise LedgerError(
                        f"line {end + 1}: {len(cells(lines[end]))} cells, header has {len(header)}")
                end += 1
            return header, start, end
    raise LedgerError("no table with an 'id' column found")


def matching_rows(lines, start, end, task_id):
    return [i for i in range(start, end) if cells(lines[i])[0] == task_id]


def the_row(lines, start, end, task_id):
    rows = matching_rows(lines, start, end, task_id)
    if not rows:
        raise LedgerError(f"no row with id '{task_id}'")
    if len(rows) > 1:
        lines_list = ", ".join(str(i + 1) for i in rows)
        raise LedgerError(f"{len(rows)} rows with id '{task_id}' (lines {lines_list}); fix the ledger by hand")
    return rows[0]


def check_value(value):
    if "|" in value or "\n" in value or "\r" in value:
        raise LedgerError(f"value {value!r} contains '|' or a newline, which would break the table")
    return value.strip() or EMPTY


def parse_assignments(header, assignments):
    index = {norm(h): i for i, h in enumerate(header)}
    updates = {}
    for a in assignments:
        if "=" not in a:
            raise LedgerError(f"expected <field>=<value>, got {a!r}")
        name, value = a.split("=", 1)
        if norm(name) not in index:
            raise LedgerError(f"unknown field {name!r}; fields: {', '.join(header)}")
        col = index[norm(name)]
        if col == 0:
            raise LedgerError("the id can't be changed with set; delete and add the row instead")
        updates[col] = check_value(value)
    return updates


def write_atomically(path, lines):
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=".ledger.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.writelines(lines)
            f.flush()
            os.fsync(f.fileno())
        if os.path.exists(path):
            os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        else:
            umask = os.umask(0)
            os.umask(umask)
            os.chmod(tmp, 0o666 & ~umask)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def read_lines(path):
    with open(path, encoding="utf-8", newline="") as f:
        lines = f.readlines()
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    return lines


@contextlib.contextmanager
def locked(path, timeout):
    """Hold an exclusive lock for a read-modify-write of the ledger at path.

    The lock is on a sidecar file, not the ledger, since os.replace swaps the
    ledger's inode and a lock on the old one would no longer exclude anyone.
    The kernel drops it when the holder exits, so a crash leaves no stale lock;
    a hung holder makes this fail after `timeout` seconds instead of blocking.
    """
    directory, name = os.path.split(path)
    lock_path = os.path.join(directory, f".{name}.lock")
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise LedgerError(
                        f"{lock_path} still locked after {timeout:g}s; another ledger.py is running "
                        "or hung (find it with: lsof " + lock_path + ")")
                time.sleep(0.05)
        yield
    finally:
        os.close(fd)


def run(args):
    args.file = os.path.realpath(args.file)
    if args.command == "show":
        edit(args)
    else:
        with locked(args.file, args.lock_timeout):
            edit(args)


def edit(args):
    task_id = check_value(args.id)
    if task_id == EMPTY:
        raise LedgerError("empty id")

    if args.command == "add" and not os.path.exists(args.file):
        lines = ["# Supervisor ledger\n", "\n", format_row(COLUMNS), format_row(["---"] * len(COLUMNS))]
    else:
        try:
            lines = read_lines(args.file)
        except FileNotFoundError:
            raise LedgerError(f"{args.file} doesn't exist")
    header, start, end = find_table(lines)

    if args.command == "show":
        row = cells(lines[the_row(lines, start, end, task_id)])
        for name, value in zip(header, row):
            print(f"{name}: {value}")
        return

    if args.command == "set":
        if not args.fields:
            raise LedgerError("set needs at least one <field>=<value>")
        i = the_row(lines, start, end, task_id)
        row = cells(lines[i])
        for col, value in parse_assignments(header, args.fields).items():
            row[col] = value
        lines[i] = format_row(row)
    elif args.command == "add":
        if matching_rows(lines, start, end, task_id):
            raise LedgerError(f"a row with id '{task_id}' already exists")
        row = [task_id] + [EMPTY] * (len(header) - 1)
        for col, value in parse_assignments(header, args.fields).items():
            row[col] = value
        lines.insert(end, format_row(row))
    elif args.command == "delete":
        del lines[the_row(lines, start, end, task_id)]
        if end - start == 1:
            print(f"{args.file}: no rows left", file=sys.stderr)

    write_atomically(args.file, lines)


def main():
    parser = argparse.ArgumentParser(description="Edit supervisor ledger rows by id.")
    parser.add_argument("-f", "--file", default=DEFAULT_FILE, help=f"ledger path (default {DEFAULT_FILE})")
    parser.add_argument("--lock-timeout", type=float, default=10, metavar="SECONDS",
                        help="give up when another edit holds the lock this long (default 10)")
    sub = parser.add_subparsers(dest="command", required=True)
    for name, takes_fields in (("show", False), ("set", True), ("add", True), ("delete", False)):
        p = sub.add_parser(name)
        p.add_argument("id")
        if takes_fields:
            p.add_argument("fields", nargs="*", metavar="field=value")
    args = parser.parse_args()
    try:
        run(args)
    except (LedgerError, OSError) as e:
        print(f"ledger.py: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
