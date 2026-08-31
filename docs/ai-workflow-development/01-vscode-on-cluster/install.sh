#!/usr/bin/env bash
# Install the `activate-workflows` Claude Code skill for this approach.
#
#   bash install.sh
#
# Copies the repo skill (.claude/skills/activate-workflows/) into
# ~/.claude/skills/activate-workflows/ where Claude Code (CLI and the VS Code
# extension — both read ~/.claude) auto-discovers it. Re-run any time to update.
set -euo pipefail

# Resolve paths relative to this script, so it works from any cwd.
APPROACH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SKILL="$(cd "${APPROACH_DIR}/../../.." && pwd)/.claude/skills/activate-workflows"
DST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/activate-workflows"

if [[ ! -f "${REPO_SKILL}/SKILL.md" ]]; then
  echo "ERROR: repo skill not found at ${REPO_SKILL}" >&2
  exit 1
fi

mkdir -p "${DST}"
cp -r "${REPO_SKILL}/." "${DST}/"

echo "Installed activate-workflows skill to: ${DST}"
echo "  - SKILL.md"
echo "  - references/"
echo
echo "The skill points at this repo's own workflows (workflows/) for working examples —"
echo "keep this repo available on the node."
echo
echo 'In Claude Code: "Using the activate-workflows skill, build a workflow that ..."'
