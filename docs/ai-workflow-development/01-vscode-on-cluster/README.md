# Approach 01 — VS Code + Claude on a cloud cluster

Run Claude Code **inside a VS Code session on a cloud cluster** and let it build,
deploy, and debug Activate workflows that target *that same cluster*. Because the
agent's shell and the workflow's jobs share one node, debugging is fully local
(`ps -x`, `~/pw/jobs/…`).

## Setup

1. **Start VS Code on the cluster** — launch the **openvscode** session from the
   Activate UI, or `pw sessions create --type vscode <cluster> --open`. Open the
   integrated terminal (a shell on the cluster node).
2. **Authenticate `pw`** (cluster nodes are usually pre-authenticated; if not,
   `pw auth token` — see <https://parallelworks.com/docs/cli>). Check with
   `pw context list` and `pw cluster ls` (cluster should be `active`).
3. **Install the Claude Code VS Code extension**, sign in, and set permission mode to
   **bypass permissions** (the methodology runs many `pw`/`git`/shell commands).
4. **Install the skill** — from this directory:
   ```bash
   bash install.sh
   ```
   It copies the repo skill (`.claude/skills/activate-workflows/`) into
   `~/.claude/skills/activate-workflows/`. Keep this `workflows` repo on the
   node — the skill points at its real workflows (`workflows/`) and tutorials
   (`tutorials/`) for examples.
5. **Ask for a workflow**, e.g.:
   > *Using the activate-workflows skill, build a workflow that runs a simulation and
   > serves a live progress page as a session.*

The agent then follows `SKILL.md`: **develop on the target machine → wrap in YAML (the endpoint
pattern + `script_submitter`, matching the deployment variant) → deliver code via
`parallelworks/checkout` (push first) → run with `pw workflows run` → verify with
`pw endpoints list` → debug from `~/pw/jobs` + `ps -x` → iterate.**

## Notes

- **Give Claude write access** via a deploy key with write permission so it can push
  workflow code to a **development branch** (never straight to `canary` — it only
  accepts pull requests) and `parallelworks/checkout` it. Without write access, the
  agent stages files on the resource and uses a stand-in copy step beside a
  commented-out checkout for you to merge later (SKILL Step 2).
- Pick the resource whose login node **is** the VS Code node, run with
  `scheduler:false`, so `~/pw/jobs` and `ps -x` are local.
- `--dry-run` every YAML before a real run; when done, delete test endpoints
  (`pw endpoints delete <name>`) and cancel lingering runs
  (`pw workflows runs cancel <slug>`).
- The platform docs are the source of truth and may be newer than this skill:
  [workflows](https://parallelworks.com/docs/run/workflows/building-workflows)
  ([YAML fields](https://parallelworks.com/docs/run/workflows/building-workflows/yaml-fields) ·
  [inputs & expressions](https://parallelworks.com/docs/run/workflows/building-workflows/inputs-and-expressions) ·
  [actions](https://parallelworks.com/docs/run/workflows/building-workflows/actions)) ·
  [endpoint sessions](https://parallelworks.com/docs/run/sessions/endpoints) ·
  [`pw endpoints` CLI](https://parallelworks.com/docs/cli/pw/endpoints) ·
  [CLI](https://parallelworks.com/docs/cli).
