# claude-skills

Skills for [Claude Code](https://claude.com/claude-code), packaged as a plugin marketplace.

## Install

```
/plugin marketplace add zach-youssef/claude-skills
/plugin install wrap-up@claude-skills
/plugin install supervisor@claude-skills
/plugin install research@claude-skills
```

Run `/plugin marketplace update claude-skills` to pick up changes.

## Plugins

### wrap-up

End-of-session memory update. Run `/wrap-up` at the end of a session and Claude reviews the
conversation, then:

- writes what a future session would need (corrections, decisions, project state, gotchas,
  references) to the project's auto-memory directly, fixing or deleting stale memories;
- proposes changes to your global `~/.claude/CLAUDE.md` as exact lines and applies only the
  ones you approve;
- reports what it created, updated, deleted and deliberately left out.

It only runs when you invoke it, never on its own.

### supervisor

A supervisor/worker workflow. The main session (run from `~/code`, across all repos) plans,
delegates and owns memory; workers go deep on one task each and are discarded afterwards.

- `orchestrate` skill: when to delegate, task graphs for parallel work, worker briefs, and the
  change lifecycle (implement on a working branch, adversarial review loop, push, green CI, ask
  to merge, absorb learnings, clean up).
- Agents: `planner`, `implementer` and `reviewer` (Opus), `test-runner` and `fixer` (Sonnet),
  `helper` (Haiku, non-technical tasks). Implementers work in their own worktrees under
  `~/code/.supervisor/worktrees/<repo>/<branch>`.
- Resumable: orchestration state (`ledger.md`, per-task files with checkpoints and reports,
  worktrees) lives in `~/code/.supervisor/`, so a restarted supervisor reconciles it with git and
  CI and re-spawns workers from their checkpoints. `orchestrate/ledger.py` edits ledger rows by
  id and fails loudly when the id matches no row or several (tests: `test_ledger.sh`).
- Lean supervisor context: workers append their full reports (reviewers their findings) to the
  task file and hand back about 10 lines; findings reach the implementer by pointer, and small
  fix-only re-reviews resume the previous reviewer.

To have a new `~/code` session print the ledger, add this SessionStart hook to
`~/.claude/settings.json` (it isn't in a plugin `hooks.json`, since the plugin is symlinked rather
than installed). It matches the cwd exactly, so sessions in subdirectories stay quiet:

```json
"hooks": {
  "SessionStart": [{ "hooks": [{ "type": "command", "timeout": 10, "command":
    "f=\"$HOME/code/.supervisor/ledger.md\"; [ \"$(jq -r .cwd)\" = \"$HOME/code\" ] && [ -f \"$f\" ] && { echo \"Supervisor ledger ($f). Load the orchestrate skill, reconcile each row with git/gh, then resume:\"; cat \"$f\"; }; exit 0"
  }] }]
}
```

For local development, symlink instead of installing, so edits apply immediately:
`~/.claude/agents/<name>.md` → `plugins/*/agents/<name>.md` and
`~/.claude/skills/<name>` → `plugins/*/skills/<name>`. The links are per file, so a new agent or
skill needs its own link.

### research

Research workflow on top of `supervisor` (install both): agents read papers into a knowledge
base, then design and run experiments that test the papers' claims and record the results back
into it. The knowledge base and experiments live in a separate repo (`~/code/research`), whose
docs define the formats.

- `research` skill: the stages (intake, read, note review, propose, the user's approval, run,
  reproduction by a test-runner, experiment review, absorb) on the `orchestrate` lifecycle,
  brief templates, reviewer checklists for notes (every claim checked against its cited page)
  and experiments (criterion fixed in advance, reproducible, numbers match the logs), budgets
  (stop at 2×, ask before downloads past 1 GB), the GPU slot, and searching the knowledge base
  without loading it whole.
- Agents (Opus): `reader` writes one note per paper with every claim referenced, and lists
  papers worth reading next without fetching them; `experimenter` proposes a `plan.md` and stops
  for approval, then runs it within the budget and writes `results.json` and `results.md`.
- The user approves which papers are read, each experiment plan, any budget change, and merges.

## Adding a skill

1. Create `plugins/<name>/.claude-plugin/plugin.json` and `plugins/<name>/skills/<name>/SKILL.md`.
2. Add an entry for it to `plugins` in `.claude-plugin/marketplace.json`.
3. Check it with `claude plugin validate .`

## License

[MIT](LICENSE)
