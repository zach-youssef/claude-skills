# claude-skills

Skills for [Claude Code](https://claude.com/claude-code), packaged as a plugin marketplace.

## Install

```
/plugin marketplace add zach-youssef/claude-skills
/plugin install wrap-up@claude-skills
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

## Adding a skill

1. Create `plugins/<name>/.claude-plugin/plugin.json` and `plugins/<name>/skills/<name>/SKILL.md`.
2. Add an entry for it to `plugins` in `.claude-plugin/marketplace.json`.
3. Check it with `claude plugin validate .`

## License

[MIT](LICENSE)
