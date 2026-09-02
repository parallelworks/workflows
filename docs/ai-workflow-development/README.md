# Building Activate workflows with AI agents

Approaches for using an AI coding agent (Claude Code) to design, build, test, and
debug [Activate](https://parallelworks.com) workflows. Each approach is a different way
to *host and drive the agent*; they share the same platform reference and point the
agent at the repo's own workflows and tutorials.

**Official docs (authoritative — newer than this skill when they conflict):**
[building workflows](https://parallelworks.com/docs/run/workflows/building-workflows)
([YAML fields](https://parallelworks.com/docs/run/workflows/building-workflows/yaml-fields) ·
[inputs & expressions](https://parallelworks.com/docs/run/workflows/building-workflows/inputs-and-expressions) ·
[actions](https://parallelworks.com/docs/run/workflows/building-workflows/actions)) ·
[endpoint sessions](https://parallelworks.com/docs/run/sessions/endpoints) ·
[`pw endpoints` CLI](https://parallelworks.com/docs/cli/pw/endpoints) ·
[`pw` CLI](https://parallelworks.com/docs/cli)

## The model

| Piece | Where | Shared? |
|-------|-------|---------|
| **Reference** — platform facts (YAML schema, the endpoint pattern, `script_submitter`, `pw` CLI, job-dir layout, deployment variants, code delivery) | [`/.claude/skills/activate-workflows/references/`](../../.claude/skills/activate-workflows/references/) | shared by every approach |
| **Examples to learn from** — the real workflows (`workflows/`) and tutorials (`tutorials/`) in this repo | this repo | shared |
| **Methodology** — the step-by-step process the agent follows | [`/.claude/skills/activate-workflows/SKILL.md`](../../.claude/skills/activate-workflows/SKILL.md) | shared (approaches may fork it) |
| **Setup guide + installer** — how to host/drive the agent | `<approach>/README.md` + `<approach>/install.sh` | per approach |

The canonical skill lives **in this repo** at `.claude/skills/activate-workflows/`, so
Claude Code auto-discovers it whenever it works inside this repo. To use it from
anywhere else (e.g. on a cluster), `install.sh` copies it to
`~/.claude/skills/activate-workflows/` (CLI *and* VS Code extension both read `~/.claude`).

## Approaches

| # | Approach | Where the agent runs | Workflow target | Guide |
|---|----------|----------------------|-----------------|-------|
| 01 | VS Code + Claude on a cloud cluster | The cluster's VS Code session (login node) | That same cluster | [`01-vscode-on-cluster/`](01-vscode-on-cluster/) |

_Future approaches get a new numbered directory that **reuses the shared
`references/`** and ships its own `SKILL.md`, `README.md`, and `install.sh`._

## Installing the skill

Each approach ships a `bash install.sh`. For approach 01:

```bash
cd 01-vscode-on-cluster
bash install.sh
```

It copies the repo skill (`.claude/skills/activate-workflows/`) into
`~/.claude/skills/activate-workflows/`. Then, in Claude Code:

> *Using the activate-workflows skill, build a workflow that …*

The skill points at this repo's real workflows (`workflows/`) and tutorials
(`tutorials/`) for worked patterns, so keep this repo available on the node.

## Adding a new approach

1. `cp -r 01-vscode-on-cluster NN-your-approach`.
2. Reuse the shared skill unless the *process* genuinely differs (the core methodology
   is portable). `install.sh` already resolves the repo skill relative to itself.
3. Rewrite `README.md`: prerequisites, how to host/drive the agent, how it targets
   resources, and `bash install.sh`.
4. Add a row to the **Approaches** table above.

> The skill teaches from the repo's own `workflows/` and `tutorials/` —
> point new material there. New tutorials require maintainer approval.
