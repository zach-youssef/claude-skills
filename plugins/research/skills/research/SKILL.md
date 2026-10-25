---
name: research
description: How the supervisor runs research work in ~/code/research - paper intake, reader tasks that write knowledge-base notes, note review, experiment proposals the user approves, experimenter runs, and recording results back into the knowledge base. Load together with orchestrate before reading papers, searching the knowledge base, or proposing or running an experiment.
---

# Research workflow

This skill adds research stages to the `orchestrate` lifecycle; it doesn't replace it. Load
`orchestrate` too: the ledger, task files, checkpoints, review loop, push, CI and merge work
exactly as there. What differs is the agents (`reader`, `experimenter`), the review checklists,
two user checkpoints, and budgets.

The knowledge base (KB) and experiments live in the research repo, `~/code/research`
(github.com/zach-youssef/research, private, default branch `main`). Its
`CLAUDE.md` and `docs/` are the authority on formats: `docs/knowledge-base.md` (notes, claim ids,
links, generated blocks, the `kb.py` CLI), `docs/intake.md` (fetching, PDF storage, reading big
PDFs) and `docs/experiments.md` (layout, `plan.md`, `results.json`, reproducibility). This skill
summarises them for routing; where they disagree, the repo's docs win, and the difference is a
bug to fix here.

Below, `kb.py` is the KB CLI at the repo root (`docs/knowledge-base.md`, "Tools"), run from
the repo or worktree root. Tools the repo's `CLAUDE.md` lists as not written yet are replaced
by following the formats by hand, as it says.

## 1. Stages and checkpoints

| Stage | Who | Branch | Ends with |
|---|---|---|---|
| 1. Intake | supervisor, user | — | the user picks the papers |
| 2. Read | `reader` | `paper-<id>` (`papers-<topic>` for several) | `## Report (reader, <sha>)`, ready-for-review |
| 3. Note review | `reviewer`, note checklist (§4) | same | clean, then push, CI, user's merge |
| 4. Propose | `experimenter`, propose mode | `exp-<slug>` | `## Report (experimenter, <sha>)`, `### Status: awaiting-approval` |
| 5. Approve | **user** | same | approval written to the task file |
| 6. Run and record | `experimenter`, run mode | same | `## Report (experimenter, <sha>)`, ready-for-review |
| 7a. Reproduce | `test-runner`, reproduction brief (§3) | same | `## Report (test-runner, repro <sha>)`: the rerun reproduces, as `docs/experiments.md` "Reproducing" defines it |
| 7b. Experiment review | `reviewer`, experiment checklist (§4), given the 7a report | same | clean, then push, CI, user's merge |
| 8. Absorb | supervisor | — | as orchestrate step 7, plus §7 |

Reviewers never run anything (their only write is the findings append): they judge
reproducibility from the test-runner's 7a report and the committed results and logs. What binds
results to code is `results.json`'s `inputs` fingerprint, not the commit sha
(`docs/experiments.md`, "Branch rewrites"), so a 7a report stays valid for any later head whose
`inputs` and `results.json` are unchanged. A new commit that changes either (compare with
`git rev-parse HEAD:experiments/<id>/<path>` against the ids the 7a report lists) means a new 7a
run before the re-review. Results with `exploratory: true` skip 7a: they can't be reproduced,
and `kb.py check` exempts them from the `inputs` comparison. That's safe because their verdicts
may only be `inconclusive` (`kb.py check` enforces it), so they can't make a note `verified`.

**The user decides:**
- which papers are read: they supply arXiv ids, URLs or local PDFs, or ask for a search
  (stage 1). Readers list "papers worth reading next" but never fetch them unasked;
- each experiment's `plan.md` before it runs (stage 5): show them the hypothesis, the claim ids
  under test, the success criteria, the reproduction tolerances, and the budget (`gpu`,
  `budget_wall_min`, `budget_downloads_mb`), verbatim from `plan.md`. The budget covers the run
  plus the 7a reproduction (§5), so say it's the doubled figure;
- any budget change: more than 2× the wall clock, GPU use not in the plan, downloads past 1 GB
  in total that the approved plan doesn't cover (asked before the download starts);
- merges, as always.

Notes don't need the user's approval: the adversarial note review replaces it, and the user
sees the note at merge.

**Task ids** are `research-<branch>`, e.g. `research-paper-bridson2007poisson`. Worktrees are
`~/code/.supervisor/worktrees/research/<branch>`, as for any repo.

**Ledger stages:** the orchestrate stages, plus `awaiting-approval` (a `plan.md` waiting for the
user; next action "ask the user") and `reproducing` (the 7a test-runner is rerunning the
experiment). The propose, run and abandon modes of one experiment share a task id, branch and
task file; each is a fresh `experimenter` spawn. Transitions:
- spawning the propose run: `implementing` (agent `experimenter <id>`);
- its report with `### Status: awaiting-approval`: `awaiting-approval`, commit = its head sha,
  then ask the user;
- the user approves (as proposed or with changes): write `## User approval (<sha>)` and the run
  brief to the task file, then set `implementing` and spawn the run;
- the user rejects the plan: write `## Brief (abandon)` with the reason, set `implementing` and
  spawn the experimenter, which sets `status: abandoned`; the plan then goes through review and
  merge like any change, since abandoned plans stay in the repo. Dropping the branch instead is
  orchestrate's "abandoning a task", with the user's OK;
- the run's ready-for-review report: `reproducing`, commit = its head sha, and spawn the 7a
  test-runner (granting the GPU slot first with `gpu: yes`, released when its report lands);
  its report: `review N`, as orchestrate step 2 (exploratory results go straight to
  `review N`). A 7a report that stopped over budget (`### Result: fail`, reason over-budget) sets
  `blocked` and asks the user instead, since raising the reproduction's share is their call;
  it doesn't count as a repro report for the resume and reuse rules below;
- the abandon run's ready-for-review report: `review N`, with the abandon checklist (§4);
- `addressing N` on an experiment: once the experimenter's report for the new head is
  ready-for-review, go to `reproducing` if the head's `inputs` or `results.json` differ from the
  last 7a report's, then `review N+1`; otherwise straight to `review N+1`.

**Resuming** follows orchestrate 3b, with `reader` and `experimenter` in place of `implementer`
in the report greps (`## Report (reader|experimenter, <first 7 chars of HEAD>`). At
`awaiting-approval`, check the task file for the approval of the head commit
(`grep -n '^## User approval (<first 7 chars of HEAD>' <task file>`): if it's there, set
`implementing` and spawn the run; otherwise re-ask the user. At `reproducing`, the 7a run is
done when `grep -n '^## Report (test-runner, repro <first 7 chars of HEAD>' <task file>`
matches a report that finished (not one stopped over budget): go to `review N`; otherwise spawn
a fresh 7a test-runner. The `repro` in the heading keeps it from passing for a CI report at `ci`.
Wherever 3b would go to `review N` or `N+1` for a run-mode experiment whose results aren't
exploratory, go to `reproducing` instead unless a repro report's `inputs` and
`results.json` ids equal HEAD's.

## 2. Intake (stage 1)

- **User-supplied** arXiv id, URL or local PDF: the reader's brief names it, and the reader
  fetches it with the repo's intake tool (`docs/intake.md`).
- **Search on request:** run the intake tool's search mode yourself (it lists candidates and
  downloads nothing), show the user the list, and brief a reader with the ones they pick. Never
  fetch or read autonomously beyond what the user picked.
- **Check the KB first** (§6): a paper already in `kb/INDEX.md` gets a re-read only if the user
  asks, and then the brief says to keep the existing claim ids.
- **PDFs are never committed.** They live git-ignored in `<main>/papers/<id>/`, the main
  checkout's (`~/code/research`), even when working from a worktree; `docs/intake.md` "Storing
  PDFs" gives the layout and how tools resolve `<main>`. Writing there is safe: it's ignored, so
  it can't touch the user's tracked work.
- Licensing: notes paraphrase, with short quotes only where the wording matters; no figures
  copied from papers.

## 3. Brief templates

Write the brief to the task file (orchestrate §3), then spawn with its path.

**Reader:**
```
# research-paper-<id>
## Brief
- Task: read <paper: arXiv id | URL | ~/code/research/papers/<id>/paper.pdf> into kb/papers/<id>.md, status `read` (or `verified`, on a re-read where docs/knowledge-base.md "Statuses" says so).
- Repo: /Users/zyoussef/code/research, branch paper-<id> off origin/main, worktree ~/code/.supervisor/worktrees/research/paper-<id>.
- Focus: <what the user cares about, e.g. "the claims an O(N) NumPy implementation can test">; or "general".
- Related notes already in the KB: <ids from §6, or none>.
- Existing note: <none | re-read: keep claim ids, add new ones after the last>.
- Done when: kb.py check and kb.py index --check exit 0, every claim has a page or section reference, committed, report in this file.
## Rules
- PDFs stay in ~/code/research/papers/<id>/, never committed. Don't fetch papers beyond the ones above; list them under "Papers worth reading next".
- Commit on the working branch only; don't push until the supervisor says the review is clean.
- Commit attribution: <line from the system reminder>.
## Checkpoints
```

**Experimenter, propose mode:**
```
# research-exp-<slug>
## Brief
- Mode: propose.
- Task: propose an experiment testing <claim ids, e.g. bridson2007poisson#C1, #C3; none withdrawn>.
- Repo: /Users/zyoussef/code/research, branch exp-<slug> off origin/main, worktree ~/code/.supervisor/worktrees/research/exp-<slug>.
- Constraints: <CPU only | GPU allowed (needs the slot at run time)>, budget ceiling <budget_wall_min, budget_downloads_mb>, ci_smoke <true | false>, domain repo <none | repo + what it must provide>.
- Done when: experiments/<YYYY-MM-DD>-<slug>/plan.md is complete per docs/experiments.md (status: proposed, approved: empty), with a budget covering the run plus the supervisor's reproduction run, kb.py check and kb.py index --check exit 0, committed, report with Status: awaiting-approval.
## Rules
- Write plan.md, plus the INDEX.md and Experiments blocks kb.py index regenerates from it: no code, no runs, no downloads.
- Commit on the working branch only; don't push.
- Commit attribution: <line>.
## Checkpoints
```

**Experimenter, run mode** (same task file; add below the propose report):
```
## User approval (<sha of the approved plan.md commit>)
- Approved by the user on <date>: <verbatim, or "as proposed">. Changes requested: <none | …>.

## Brief (run)
- Mode: run. Resume the worktree from the checkpoints above.
- First commit: fill `approved: <user> <YYYY-MM-DD>` and set `status: approved` in plan.md, plus only the changes the User approval section requests and what kb.py index regenerates.
- GPU: <not allowed | allowed only after the supervisor grants the slot; ask (SendMessage to "main") first and say when done>.
- Done when: results.json passes kb.py check (including its `inputs` against HEAD), results.md matches it (`## Reproduce` restating plan.md's tolerances), plan.md has `status: done`, the tested notes' statuses follow the `verified` rule in docs/knowledge-base.md "Statuses", kb.py index has regenerated the backlinks, the smoke mode runs in under a minute, committed, report with Status: ready-for-review.
```

**Experimenter, abandon mode** (same task file, when the user rejects the plan):
```
## Brief (abandon)
- Mode: abandon. Resume the worktree from the checkpoints above.
- Reason: <the user's words>.
- Done when: plan.md has `status: abandoned` and the reason under `## Method`, kb.py index has regenerated INDEX.md and the Experiments blocks, kb.py check and kb.py index --check exit 0, committed, report with Status: ready-for-review.
```

The task file's last `## Brief…` heading is the current one, so an experimenter told only
"resume" picks the run mode.

**Test-runner, reproduction (stage 7a):** "Clone the research repo into
`$TMPDIR/research-repro-<slug>-<sha7>`, removing that directory first if it exists
(`git clone --branch exp-<slug> ~/code/research <dir>`, then `git -C <dir> checkout <sha>`; the
branch needn't be pushed, since worktree branches live in the main repo's refs). Check that the
committed `results.json` `inputs` equal `git rev-parse HEAD:experiments/<id>/<path>` for `src`,
`run.sh` and `requirements.txt` (for a missing or empty `src/`, git's empty-tree id
`4b825dc642cb6eb9a060e54bf8d69288fbee4904`, as `docs/experiments.md` says). Run
`experiments/<id>/run.sh --smoke`, then reproduce in place in the clone as
`docs/experiments.md` "Reproducing" says (the full `experiments/<id>/run.sh`, compared with
`git show HEAD:experiments/<id>/results.json` using `plan.md`'s tolerance lines, then
`git restore` and `git clean` the outputs). Budget: the reproduction's share of the plan's
budget (`plan.md` `## Budget`), with the stops in the skill's §5: report `### Result: fail` with
the reason over-budget instead of going on. <With gpu: yes: You hold the GPU slot, granted for
this run; don't ask for it.>
Report under `## Report (test-runner, repro <sha>)`: the `inputs` ids and the `results.json`
blob id (`git rev-parse HEAD:experiments/<id>/results.json`), each criterion's recorded and
rerun verdict, each toleranced metric's recorded and rerun value against its tolerance, the
other metrics as informational, wall clock and downloads spent, and reproduces yes or no. Then
remove the clone." With `gpu: yes`, set the slot's `Holder:` to the task id before spawning,
and release it when the repro report lands.

**Reviewer:** the orchestrate brief, plus "apply the <note | abandoned plan | experiment>
checklist in `~/.claude/skills/research/SKILL.md` §4". For a note, give the PDF path and the
page renders the reader left in `<main>/papers/<id>/pages/`. For an experiment, give the 7a
report's heading.

## 4. Review checklists

**Note** (stage 3). The reviewer reads the PDF itself (Read with `pages`, at most 20 per call),
or for big PDFs the page text and PNGs the reader left in `<main>/papers/<id>/pages/`. It
doesn't generate renders itself: if they're missing, that's a finding. It checks:
- every claim against its cited page, section, table or equation: the paper says it, with the
  stated numbers, conditions and caveats. A claim the paper doesn't make, or makes more weakly,
  is a high finding;
- every claim line follows the grammar in `docs/knowledge-base.md` "Claims" (its reference
  holds at least a page or a section, withdrawn claims are marked as it says), and no reference
  points to a page that doesn't hold the claim. Pages are PDF pages counted from 1, not printed
  page numbers;
- the important claims are there (the abstract's and the conclusion's at least), each with an
  id; existing claim ids aren't renumbered or reused;
- `Implementation notes` give a source for every value the paper doesn't state (another paper,
  the authors' code, a guess marked as one);
- frontmatter (title, authors, year, venue, ids, `pdf_sha256`) matches the paper; the TL;DR
  keeps to the format in `docs/knowledge-base.md` "Note format" and matches the claims;
- `Related` links resolve and their relations (`extends`, `uses`, `contradicts`, `related`) are
  right;
- `status` is `read`, or `verified` where the rule in `docs/knowledge-base.md` "Statuses"
  says so (a re-read); every section filled in (`- none` where there's nothing to say);
- `kb.py check` and `kb.py index --check` exit 0; the note is under the length the docs give.

**Abandoned plan** (after an abandon run): plan.md has `status: abandoned`; the user's reason
is under `## Method`; nothing else changed besides what `kb.py index` regenerates
(`kb.py index --check` exits 0).

**Experiment** (stage 7b):
- the measurement tests the claim: the metric, inputs and conditions match what the claim
  says, not an easier neighbour of it;
- the criterion applied is the one fixed in the approved `plan.md` (diff `plan.md` against the
  approved commit in the task file's `## User approval (<sha>)`, before any rebase makes that
  sha unreachable; afterwards plan.md's `approved:` is the lasting record): no hypothesis,
  claim, criterion, metric, threshold or tolerance changed after approval, and `approved:`
  matches that section;
- each claim under test has a verdict (`supports | contradicts | inconclusive`) that follows
  from the criterion and the numbers; a near miss is `inconclusive` or `contradicts`, not
  `supports`. With `exploratory: true`, every verdict is `inconclusive`;
- reproducibility (`docs/experiments.md` "Reproducibility"): dependencies pinned with `==`,
  seeds fixed and recorded, the environment recorded, results from a clean tree (or marked
  exploratory), and everything that affects the results inside `src/`, `run.sh` and
  `requirements.txt`. Unless exploratory, a 7a report whose `inputs` and `results.json` ids
  equal HEAD's says the rerun reproduces, against the tolerances in the approved `plan.md`
  (restated, unchanged, in `results.md` `## Reproduce`);
- the numbers in `results.md` match `results.json`, and both match the run logs; figures come
  from the recorded run;
- the budget was kept (wall clock, downloads, GPU only under a grant, no download past 1 GB
  without the user's OK);
- domain-repo code is pinned by a merged commit sha in `results.json`;
- statuses: plan.md `status: done` (the approval commit set `approved`), and the tested notes'
  statuses follow the `verified` rule in `docs/knowledge-base.md` "Statuses", including notes
  that lose `verified` to this run's verdict;
- the paper notes' generated `Experiments` blocks are current (`kb.py index --check`).

## 5. Budgets and the GPU slot

- `plan.md`'s budget is three frontmatter keys: `gpu` (`yes|no`), `budget_wall_min` and
  `budget_downloads_mb` (`docs/experiments.md`). It covers the experimenter's run plus the 7a
  reproduction (wall clock, downloads, GPU), with `## Budget` giving each one's share. The
  clone's `runs/` starts empty, so count the reproduction's downloads again unless a cache
  outside the checkout (pip's) serves them. The experimenter and the 7a test-runner each
  **stop at 2× their share** and report `blocked` (reason over-budget, with what was spent and
  what's left to do). Raising the budget is the user's call.
- **Downloads past 1 GB** in total (the run's and the reproduction's together) need the user's
  OK before they start, whatever the 2× rule allows: unless the approved plan's budget already
  covers them, the experimenter stops before that download and reports `blocked` (reason
  downloads). A plan that budgets more than 1 GB says so in its report, so the user sees it at
  approval.
- GPU work follows the ledger's `## GPU slot` (one Mac GPU workload at a time). The experimenter
  asks the supervisor (SendMessage to "main") before any GPU step, waits for the grant (the
  supervisor's reply; the slot's `Holder:` records it, naming the task by its ledger id or its
  plan code, e.g. X3), and says when it's done. With `gpu: no` in the plan, or no
  grant, it stops and reports `blocked` instead of running.
- Experiments that need domain code (ZGAL in vulkan_test, vulkan_splatting) build it as a
  separate `implementer` task on a working branch in that repo, through the normal lifecycle.
  The experiment runs against the merged commit and records its sha.

## 6. Searching the KB

Don't load notes whole. In order, stopping when you have enough:
1. Read `~/code/research/kb/INDEX.md`: one line per paper (id, year, title, tags, status,
   TL;DR) and the experiments table.
2. `kb.py search <query> [--tag t] [--status s] [--limit n]`: prints `id §section L<line>:
   snippet`.
3. `kb.py show <id>`: frontmatter, the heading outline with line numbers, the claims and the
   backlinks, without the body.
4. Read only the line ranges you need from the note (`offset`/`limit`).

Run them in the main checkout for merged knowledge, or in a worktree for a branch's. Put the ids
and line ranges in briefs, not the text.

## 7. Absorbing research work

On top of orchestrate step 7:
- the knowledge itself is in the KB, committed and reviewed; don't copy it into memory;
- the reader's "papers worth reading next" go to the user as a choice (stage 1), not into a
  queue of reads;
- friction with the workflow (unclear docs, a tool that fell short, a checklist item that missed
  something) goes into the research repo's docs, or this plugin, on a follow-up branch; bump the
  plugin's patch version for changes here.
