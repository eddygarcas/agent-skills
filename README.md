# agent-skills

Skills for coding agents (Claude Code, Codex, Cursor, and the other agents the
[skills CLI](https://github.com/vercel-labs/skills) supports).

| Skill | What it does |
|---|---|
| [`rails-spinel-native-binary`](skills/rails-spinel-native-binary/SKILL.md) | Compile a Rails app, especially a Rails API, into a single native binary with [roundhouse](https://github.com/rubys/roundhouse) (`--target spinel`) and the [Spinel](https://github.com/matz/spinel) AOT compiler: toolchain builds, transpiling, a re-runnable post-emit patch script, the `spin build` refusal and C-error loop, running the binary, and turning the bugs you hit into upstream issues and PRs. |

## Install

```sh
npx skills add eddygarcas/agent-skills --skill rails-spinel-native-binary
```

Add `-g` to install it for every project, and `-a claude-code` (or another agent) to pick the agent.

## Notes

roundhouse and Spinel are both under very active development; the skill describes a process and the failure
classes met on a real app, not a fixed recipe. The emitted binary serves SQLite, not Postgres.

MIT licensed.
