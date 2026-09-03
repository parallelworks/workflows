#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${ROOT_DIR}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to run tests" >&2
  exit 1
fi

if ! python3 -c "import pytest, yaml" >/dev/null 2>&1; then
  echo "Missing test dependencies. Install with:" >&2
  echo "  python3 -m pip install -r requirements-dev.txt" >&2
  exit 1
fi

python3 -m pytest -q tests
./scripts/test_local.sh yaml
