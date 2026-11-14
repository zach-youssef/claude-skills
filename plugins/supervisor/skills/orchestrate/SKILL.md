---
name: orchestrate
description: How the supervisor (the main session, run from ~/code) decides whether to delegate, plans task graphs, briefs workers, runs the review/push/CI/merge loop, and absorbs workers' learnings. Load before spawning a worker or planning multi-step or multi-phase work.
---

# Orchestrate workers

You are the supervisor. You talk to the user, keep track of the work and own memory. Workers
(`planner`, `implementer`, `reviewer`, `test-runner`, `fixer`, `helper`) go deep on one task
each and are thrown away afterwards, along with their context.

## 1. Delegate or not

Do it **inline** when it's small (a few edits or commands), needs the conversation's context,
or is a question for the user.

**Delegate** when the task is:
- deep and self-contained (a feature, a port, a refactor): use `implementer`;
- noisy but simple (builds, test runs, CI logs): use `test-runner`, and `fixer` for mechanical fixes;
- independent of other tasks, so they can run in parallel;
- non-technical (prose, summaries, lists, lookups): use `helper`.

Research work (reading papers into the knowledge base, experiments in `~/code/research`): load
the `research` skill too, which adds the `reader` and `experimenter` agents and their stages.

A worker starts cold, so a brief that takes longer to write than the task takes to do means the
task stays inline.

## 2. Plan multi-phase work as a task graph

When a request has several distinct parts, or is a whole project, break it into a task graph
before starting. Do it yourself, or use `planner` when the work is complex or needs a lot of
code reading. A task graph lists:
- each task's goal, the repo and files it touches, its dependencies, the agent that runs it, and
  its definition of done;
- **parallel batches**: tasks with no dependency between them and no overlapping files run at
  the same time;
- the decisions the user must make, each with options and a recommendation, asked together up
  front.

**Reviewing a plan:** a plan past about 10 tasks gets one review round on its risky core (the
interfaces between tasks, the order, the shared files and the user's decisions), not on each
task's wording. Per-task details get caught in that task's implementation review.

The plan goes in `~/code/.supervisor/plans/` (section 3b), split by task once it's long.

Some things limit parallelism on this machine:
- GPU tests share the device, so run them one at a time per machine; the Windows PC (NVIDIA) is a
  second machine, used only through `~/.claude/skills/orchestrate/winpc` (usage: `winpc --help`),
  which grants runs only while the user isn't gaming and has its own GPU lock;
- memory-heavy builds (personal-site's Gradle and e2e) need care;
- tasks editing the same files go in sequence;
- the agent cap (the ledger's `## Agent cap`) counts implementers, planners and fixers. A
  reviewer or test-runner runs on top of it, one at a time, so a finished implementation never
  waits for a slot;
- the usage limit: start the second Opus worker of a batch only after the first one has written
  its first checkpoint, so one limit hit doesn't kill both during setup.

## 3. Brief a worker

Spawn workers in the background with `run_in_background`. Each brief contains:
- **Repo and branch:** the absolute repo path and a descriptive working-branch name, e.g.
  `zgal-growable-arrays`. Implementers make their own worktree at
  `~/code/.supervisor/worktrees/<repo>/<branch>` (the supervisor runs from `~/code`, which isn't a git
  repo, so the built-in worktree isolation doesn't apply).
- **Goal and definition of done:** which tests must pass, and which docs to update.
- **Context pointers, not dumps:**
  - the repo's `CLAUDE.md` and the focused docs it links to;
  - the memories that matter, copied or summarised, since workers don't load memory;
  - the decisions the user already made.
- **Constraints:** scope, and anything the user ruled out. Rules every worker already has in
  its definition (no `git stash`, the GPU slot claim, the gitlink check, commit attribution from
  its own system reminder) aren't repeated; a brief adds only task-specific rules.
- **The report format** in the agent's definition. It's already there; just don't override it.
- **The task file** `~/code/.supervisor/tasks/<id>.md`. Write the brief there first, then pass
  its path. The worker appends checkpoints to it, which is what lets work resume.

**Reports go to the task file, not your context.** Every worker appends its full report to the
**end** of the task file under its own heading, `## Report (<agent>, <sha or date>)` (reviewers
`## Review N (<sha>)`), with the report's sections at `###`. It hands back at most about 10
lines: the status, the commit sha, the verdict or counts, and that heading as the pointer. When
a heading repeats (a rerun), the last one counts. Read the full report only when the handback
isn't enough to decide the next step. Reviewers and test-runners have no Write or Edit tools, so
they append with one quoted heredoc (`cat >> <task file>`), limited to that file. Planners write
only under `~/code/.supervisor/plans/` and to their task file: they write the plan there and
hand back the pointer. Helpers return
their result inline by default, since it's usually text you need right away; ask for the task
file in the brief when it's long.

## 3b. Keep state durable so everything can resume

A session can be interrupted at any moment, and worker contexts and agent ids don't survive it.
So all orchestration state lives on disk, in `~/code/.supervisor/` (not memory, not a repo):

- **`ledger.md`:** one row per active task:
  - id (`<repo>-<branch>`, unique across repos), repo, branch, worktree;
  - agent: the type, plus its id *for this session only* (ids don't survive a restart);
  - stage: `planned` | `implementing` | `review N` (reviewer running) | `addressing N`
    (implementer on findings) | `fixing` | `pushed` | `ci` | `awaiting-merge` | `approved` |
    `merging` | `merged` (absorb pending) | `blocked` | `stalled (rate limit, resets HH:MM)` |
    `abandoned`, plus `awaiting-approval`
    (a plan waiting for the user) and `reproducing` (a rerun before review) for research
    experiments, as the `research` skill describes;
  - commit: the exact sha under review or CI, which is what may be merged (this is orchestration
    state, not memory, so a hash is fine here);
  - CI run ids;
  - next action.

  Below the table: the GPU slot, the task graph's batches, the user's pending decisions, and
  open follow-ups. The SessionStart hook loads the whole ledger every session, so it holds only
  live state. Decisions go in `decisions/<project>.md`, one line each, with the date, and the
  ledger keeps a one-line pointer per project. When a section below the table passes about 30
  lines, move what's settled into that project's file. Drop a follow-up once it's queued as a
  task or done. **Update it at every transition, before acting on it:** spawning,
  each report, each review round, a push, CI starting or finishing, asking the user, their
  answer. So a stage means "intended, maybe not finished", and every step must be safe to repeat.

  **Edit rows with `ledger.py`**, not sed or Edit. It sits next to this file; call it by its full
  path, `~/.claude/skills/orchestrate/ledger.py`. It needs no Read first, exits non-zero with a
  message when the id matches no row or several, refuses `|` and newlines in values, locks
  (`.ledger.md.lock`, failing after 10 s if the holder hangs) so parallel calls don't lose
  updates, and replaces the file atomically:
  ```
  ledger.py add <id> repo=<repo> branch=<branch> worktree=<path> agent=implementer stage=implementing next-action="…"
  ledger.py set <id> stage="review 1" commit=<sha> next-action="…"
  ledger.py show <id>
  ledger.py delete <id>
  ledger.py gpu show                 # prints the holder, or none
  ledger.py gpu claim <holder>       # exit 2 if someone else holds it
  ledger.py gpu release <holder>     # exit 2 if someone else holds it
  ```
  Fields are the column names, case-insensitive, with `-` for spaces (`ci`, `next-action`); an
  empty value stores `—`. `add` creates the ledger if it's missing. The `gpu` commands edit
  the `- Holder: <name>.` line under `## GPU slot`. Briefs tell workers to claim the slot with
  their task id before a GPU run or a push through a GPU pre-push hook, release it afterwards, and
  wait and retry (don't take it) on exit 2. Edit the notes below the
  table as before. Tests: `test_ledger.sh [<copy of a ledger>]`, never on the real file.
- **`tasks/<id>.md`:** the brief, the worker's `## Checkpoints`, every `## Report (…)`
  (status, decisions, learnings), review findings (`## Review N (…)`) and CI or test failure
  reports. Workers append their own checkpoints, reports and findings; you write the user's
  decisions there **before** acting on them or spawning the next worker.
  Nothing a later step needs may live only in your context.
- **`plans/<project>/`:** a task graph past about 200 lines is split into `overview.md`
  (goal, findings, architecture, batches, decisions, risks: what every task shares) and one
  `<task id>.md` per task or milestone. A brief points at the overview plus its own task's
  file, never "read the whole plan". Smaller plans stay one file, `plans/<project>.md`. Keep
  to two levels: each level is a lookup that relies on a one-line description.
- **`decisions/<project>.md`:** the user's decisions and supervisor calls, settled, newest
  first. Read the project's file when planning or briefing there.
- **Worktrees** (`worktrees/<repo>/<branch>`) keep the code, committed or not.

**Resuming** (a SessionStart hook prints the ledger in `~/code`; otherwise read it first):
1. Reconcile each row with reality in **both directions**, after `git -C <repo> fetch`:
   - at `merging` or later, the merged check below comes first; once it passes, a missing
     branch and worktree are expected;
   - `git -C <worktree> status` (including a rebase in progress) and `git log`;
   - whether the local branch, `origin/<branch>` and the ledger's commit are the same sha. If
     the branch moved after review or CI (`pushed`, `ci`, `awaiting-merge` or later), the stage
     goes back to `review N+1`, for the new commit. At `addressing N` or `fixing` a moving
     branch is expected: go to `review N+1` only if the worktree is clean and the task file has
     `## Report (implementer|fixer, <first 7 chars of HEAD>` with status ready-for-review or
     fixed (not blocked or escalated), unless it's a fixer report marked `wording-only`, which
     skips the review (step 3 of the lifecycle); otherwise resume that worker (step 2);
   - CI for that exact commit (`gh run list --commit <sha>`);
   - at `review N`: whether the task file already has the review of the ledger's commit
     (`grep -n '^## Review N (<first 7 chars of the sha>' <task file>`). If it does, the
     reviewer finished: move to `addressing N` (or on, if it said clean) instead of reviewing
     again. Likewise `## Report (test-runner, <sha>)` for the ledger's commit at `ci`;
   - only at `merging` or later: whether it's merged
     (`git -C <repo> merge-base --is-ancestor <commit> origin/<default>`). Before that stage the
     check means nothing, since a branch with no commits yet is trivially an ancestor.

   Where reality is ahead, move the row forward. Where it's behind (e.g. `pushed` but the branch
   isn't on the remote), move it back and redo that step.
2. Agent ids from before the restart are gone, so everything is re-spawned fresh:
   - implementers and fixers get their task file, the worktree and "resume from your
     checkpoints", plus whatever their stage calls for: "address review N findings in <task
     file>" for `addressing N`, the test-runner report pointer for `fixing`, the push
     instruction for an approved review;
   - reviewers and test-runners lost their context, so run fresh ones, unless their section is
     already in the task file (step 1).
3. Re-ask the user any pending decision. Briefly tell them what was resumed.

## 4. Lifecycle of a change

1. The `implementer` commits on its working branch, runs the targeted local checks, and reports
   **ready for review**. It doesn't push.
2. Spawn a `reviewer` on the branch's diff (`git -C <worktree> diff origin/<default>...HEAD`),
   with the brief's goal, the task file and the round number N. Set the stage first
   (`ledger.py set <id> stage="review N" commit=<sha>`), and the agent once it exists
   (`agent="reviewer <agent-id>"`). It writes its findings to the task file under
   `## Review N (<sha>)` itself.
3. Relay the findings **by pointer**: tell the implementer "address review N findings in <task
   file>" (SendMessage to the same agent, so it keeps its context), without pasting them. It
   fixes each finding or rebuts it with reasons. Then review again, for **at most two rounds**
   per change. After round 2, the implementer (or a fixer, for nits) addresses the remaining
   findings without a third review; list every finding it rebuts or leaves open, with both
   sides' reasons, in the merge ask, so the user decides.

   **Supervisor orchestration changes** (the ledger, task files, memory, and this plugin's
   skills and agents) that the supervisor makes on the user's explicit instructions skip review
   and the working branch: commit them directly to `main` and push (the user's standing
   permission, 2026-10-31). This doesn't cover other repos, or changes nobody asked for.

   **Nit-only rounds:** when every open finding is low or nit and mechanical (wording,
   headings, obvious small code fixes), spawn a fresh `fixer` (Sonnet) with the task file and
   the review pointer instead of messaging the implementer, whose long context is expensive.
   High or medium findings, or anything needing a design call, stay with the implementer. After
   such a round (stage `fixing`), skip the re-review if the fix is wording or docs only: every
   file in `git -C <worktree> diff --stat <old-sha> HEAD` is prose and the fixer's report says
   `wording-only`. Then set the ledger's commit to the new HEAD and continue at step 4. If a fix
   touched code, or rules that change workflow behaviour, re-review with a fresh reviewer, as
   below.

   **Re-reviews:** every round gets a fresh reviewer, so each context is discarded after one
   round and no verdict anchors on that reviewer's earlier findings. It gets what round 1 got
   in step 2 (the brief's goal and the full diff, for context) plus the previous review
   (`## Review N (<old sha>)` in the task file; after a restart that heading is where the old
   sha is) and the change since then, `git -C <worktree> range-diff origin/<default> <old-sha>
   HEAD`, with findings under `## Review N+1 (<new sha>)`. It checks that each earlier finding
   is fixed or soundly rebutted, and reviews the change itself, including its effect on code
   outside the changed hunks. When the range-diff is mostly new work rather than fixes, it
   reviews the full diff as in round 1, still checking the previous review's findings.
4. Once the review is clean, tell the implementer to push the working branch.

   In steps 3–6, if the implementer isn't alive in this session (a restart, or it was stopped),
   spawn a fresh one with the task file and "resume", plus the review pointer or the push
   instruction.
5. Record the pushed commit (`git -C <worktree> rev-parse HEAD`, which must equal
   `origin/<branch>`) in the ledger (`ledger.py set <id> stage=ci commit=<sha>`, then
   `ci=<run ids>` once the runs exist).
   Watch CI yourself with one background shell loop (`run_in_background`): poll
   `gh run list --commit <sha>` until the runs appear, then `gh run watch <id> --exit-status` on
   **every** run on that commit, one watch at a time (several at once trip GitHub's secondary
   rate limit, and a watch that exits 1 with no run output means "unknown", not red: check
   `gh run view` before calling it a failure). The loop costs no tokens until it exits. Spawn a
   `test-runner` instead (Haiku when it's CI only) when the commit also needs local hardware
   checks (MoltenVK GPU tests), so one worker runs both and reports once. Until a repo has CI,
   its local stack verification is the check.

   On failure, the test-runner's report is in the task file: point a `fixer` at it for
   mechanical fixes, or the implementer for design problems (`fixing`). Fixes are squashed into
   the commits they belong to, so the re-review (`review N`, a fresh reviewer as in step 3)
   gets only the change since the ledger's commit:
   `git -C <worktree> range-diff origin/<default> <old-sha> HEAD`. Once that's clean, push with
   `--force-with-lease` (tell the fixer or implementer to, or do it yourself) and run CI again.
   Any change to the branch means a new commit in the ledger and a new CI run.
6. When CI is green and the task file's reports have repo-doc learnings not yet in their "Docs
   updated" items, tell the implementer to commit them on the branch (it knows the docs; you
   don't read them), and send that through review and CI too. Then **ask the user for
   permission to merge** (`awaiting-merge`): give a short summary and the potentially
   controversial decisions from the reports. Once they agree (`approved`, then `merging`),
   merge **on the remote**, never by checking out the user's checkout.

   **Batch pre-approval:** when a batch starts, ask the user once whether its tasks may merge as
   soon as review is clean and CI is green. Record a yes under the ledger's `## Pending user
   decisions` as `merge pre-approved: <ids> (user, <date>)`; it covers those ids only and is
   deleted with the batch. A pre-approved task goes from `ci` green straight to `merging`, and
   the merge summary (what changed, the controversial decisions) goes to the user as a status
   message when it merges. A finding rebutted or left open after round 2 still asks: the user
   decides those.

   The merge itself:
   - `git -C <repo> fetch`. If the default branch moved, `git -C <worktree> rebase
     origin/<default>` (a conflict goes to the implementer, at `addressing N`). Then back to
     `review N` with the same range-diff, `git push --force-with-lease` the working branch, and
     CI on the new commit, before asking again;
   - check `git -C <worktree> rev-parse HEAD` equals the ledger's CI-green commit, then
     `git -C <worktree> push origin <branch>:<default>` (the remote refuses anything that isn't
     a fast-forward);
   - `git -C <repo> fetch` again, and fast-forward the local default branch only if that
     checkout is clean and on it;
   - remove the worktree (`git -C <repo> worktree remove <path>`; git won't delete a branch
     that's checked out in one), then delete the working branch locally and on the remote;
   - set the stage to `merged`.

   The user's checkouts may hold their own work (e.g. untracked files in ppu), and
   `~/code/claude-skills`'s checkout is live: `~/.claude/agents` and skills symlink into it.
7. **Absorb and clean up:**
   - Go through the reports in the task file (not just your context, which may be from after a
     restart) and record what a future session needs, following
     `~/.claude/skills/wrap-up/SKILL.md` (it can't be invoked by the model, so read it):
     - repo knowledge already went into the repo's docs in step 6. Prefer that: docs reach every
       worker, while memory reaches them only through your briefs. Trust the reports' "Docs
       updated" items rather than reading docs or diffs to check. Anything learned later goes
       to `decisions/<project>.md` tagged `repo docs`, and from there into a **docs sweep**:
       once a project holds five or more such lines, queue a docs-only task on that repo
       (branch `docs-sweep-<YYYY-MM-DD>`) for a Sonnet `fixer`, with the lines in its brief.
       It writes them into the repo's docs, and the sweep gets one review round from a
       reviewer run on Sonnet (`model: "sonnet"`; it checks each line landed where the docs'
       structure puts it and matches the code), then CI and the merge ask; delete the lines
       once it merges;
     - preferences and decisions go in that repo's memory dir (see the `projects` memory).
       Those dirs load only in sessions started inside the repo, so read them yourself when
       planning work there and copy what matters into briefs;
     - cross-project items go in the supervisor's memory;
     - the reports' `Plan deltas` (where the code differs from `plans/<project>/`) go into
       the plan, so later briefs start from what was built.
   - Stop the worker if it's still running. Only now, with the row at `merged` and the learnings
     absorbed, delete its ledger row (`ledger.py delete <id>`) and task file, and the ledger
     itself and its `.ledger.md.lock` once it's empty (the script says when no rows are left).

**Abandoning a task** (the user cancels it, or drops a `blocked` one): set it to `abandoned`,
absorb its learnings, and with the user's OK remove the worktree and delete the branch locally
and on the remote. Then delete its row and task file.

## 5. Stay lean

- Take workers' handbacks, not their logs; the full reports wait in the task file. When you
  need more detail, ask the worker a question rather than reading everything yourself.
- Don't read raw diffs or docs for review or absorb: reviewers read the diff, and reports say
  what changed and which docs were updated. Pass findings and failures to the next worker by
  pointer to the task file, not by pasting them.
- Memory's `MEMORY.md` index loads every session. Past about 40 lines, group it into topic
  sub-indexes (`<topic>/MEMORY.md`, one line each in the top index), at most two levels deep.
- Your own context is the only one that lasts. At a phase boundary (memory and docs current,
  work merged), suggest the user run `/compact`.
- When a command keeps prompting for permission (in your session or workers'), tell the user the
  exact rule to add to the allowlist.
- Status messages to the user are one or two lines per event (a report, a review verdict, CI).
  Fuller summaries are kept for merge asks and phase ends.
- **Usage limit:** when workers die on a usage limit (HTTP 429), set each row to
  `stalled (rate limit, resets HH:MM)`, keeping its worktree, and schedule a wakeup for the reset
  time. Then resume them from their checkpoints, staggered as in section 2.
