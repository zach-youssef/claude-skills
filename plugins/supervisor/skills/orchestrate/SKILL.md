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

Some things limit parallelism on this machine:
- GPU tests share the device, so run them one at a time per machine;
- memory-heavy builds (personal-site's Gradle and e2e) need care;
- tasks editing the same files go in sequence.

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
- **Constraints:** scope, and anything the user ruled out.
- **The report format** in the agent's definition. It's already there; just don't override it.
- **The task file** `~/code/.supervisor/tasks/<id>.md`. Write the brief there first, then pass
  its path. The worker appends checkpoints to it, which is what lets work resume.

**Reports go to the task file, not your context.** Every worker appends its full report to the
**end** of the task file under its own heading, `## Report (<agent>, <sha or date>)` (reviewers
`## Review N (<sha>)`), with the report's sections at `###`. It hands back at most about 10
lines: the status, the commit sha, the verdict or counts, and that heading as the pointer. When
a heading repeats (a rerun), the last one counts. Read the full report only when the handback
isn't enough to decide the next step. Reviewers and test-runners have no Write or Edit tools, so
they append with one quoted heredoc (`cat >> <task file>`), limited to that file. Planners are
read-only, so they return the full report and you write it into the task file. Helpers return
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
    `merging` | `merged` (absorb pending) | `blocked` | `abandoned`, plus `awaiting-approval`
    (a plan waiting for the user) and `reproducing` (a rerun before review) for research
    experiments, as the `research` skill describes;
  - commit: the exact sha under review or CI, which is what may be merged (this is orchestration
    state, not memory, so a hash is fine here);
  - CI run ids;
  - next action.

  Below the table: the task graph's batches, the user's pending decisions, and the decisions
  already made this project. **Update it at every transition, before acting on it:** spawning,
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
  ```
  Fields are the column names, case-insensitive, with `-` for spaces (`ci`, `next-action`); an
  empty value stores `—`. `add` creates the ledger if it's missing. Edit the notes below the
  table as before. Tests: `test_ledger.sh [<copy of a ledger>]`, never on the real file.
- **`tasks/<id>.md`:** the brief, the worker's `## Checkpoints`, every `## Report (…)`
  (status, decisions, learnings), review findings (`## Review N (…)`) and CI or test failure
  reports. Workers append their own checkpoints, reports and findings; you write planner
  reports and the user's decisions there **before** acting on them or spawning the next worker.
  Nothing a later step needs may live only in your context.
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
   skills and agents) that the supervisor makes on the user's explicit instructions skip review:
   commit on a working branch, push, then ask to merge as usual.

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
   A `test-runner` watches CI for that exact commit: it polls `gh run list --commit <sha>` until
   the runs appear, then `gh run watch <id> --exit-status` for **every** run on that commit.
   It also runs whatever needs real hardware (MoltenVK GPU tests) locally. Until a repo has CI,
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
   merge **on the remote**, never by checking out the user's checkout:
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
       in a follow-up branch;
     - preferences and decisions go in that repo's memory dir (see the `projects` memory).
       Those dirs load only in sessions started inside the repo, so read them yourself when
       planning work there and copy what matters into briefs;
     - cross-project items go in the supervisor's memory.
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
- Your own context is the only one that lasts. At a phase boundary (memory and docs current,
  work merged), suggest the user run `/compact`.
- When a command keeps prompting for permission (in your session or workers'), tell the user the
  exact rule to add to the allowlist.
