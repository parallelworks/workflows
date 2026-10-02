"""app/controller.sh's restart, run against a fake pw CLI.

The endpoint keeps one name across launches, and the run waits for it by that
name: the previous dashboard has to be gone before the controller returns, or
the wait would find it answering and release the run on the old dashboard.
"""

import stat
import subprocess
import textwrap
from pathlib import Path

import pytest

WORKFLOW = Path(__file__).resolve().parents[3]
CONTROLLER = WORKFLOW / "app" / "controller.sh"

FAKE_PW = textwrap.dedent(
    r"""
    #!/bin/bash
    printf '%s\n' "$*" >> "${FAKE_PW_LOG}"
    case "$1 $2" in
        "endpoints list") cat "${FAKE_PW_ENDPOINTS}" ;;
        "endpoints delete")
            awk -F'\t' -v name="$3" '$1 != name' "${FAKE_PW_ENDPOINTS}" > "${FAKE_PW_ENDPOINTS}.new"
            mv "${FAKE_PW_ENDPOINTS}.new" "${FAKE_PW_ENDPOINTS}"
            ;;
    esac
    """
).lstrip()


def executable(path: Path, body: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class Harness:
    def __init__(self, root: Path):
        self.root = root
        self.bin = root / "bin"
        self.log = root / "pw.log"
        self.endpoints = root / "endpoints.tsv"
        self.software = root / "software"
        executable(self.bin / "pw", FAKE_PW)
        # A venv that imports: the controller reuses it and goes straight to the restart
        executable(self.software / "hpc_status" / "venv" / "bin" / "python", "#!/bin/sh\nexit 0\n")
        app = root / "job" / "workflows" / "hpc_status" / "app"
        app.parent.mkdir(parents=True)
        app.symlink_to(WORKFLOW / "app")
        self.endpoints.write_text("")
        self.log.write_text("")

    def listed(self, *rows):
        self.endpoints.write_text("".join("\t".join(row) + "\n" for row in rows))

    def run(self, **overrides):
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.root),
            "FAKE_PW_LOG": str(self.log),
            "FAKE_PW_ENDPOINTS": str(self.endpoints),
            "PW_PARENT_JOB_DIR": str(self.root / "job"),
            "pw_endpoints_args": "--name hpc-status",
            "service_parent_install_dir": str(self.software),
        }
        env.update(overrides)
        return subprocess.run(
            ["bash", str(CONTROLLER)], cwd=self.root, env=env,
            capture_output=True, text=True, timeout=60,
        )

    def deleted(self):
        return [line.split()[2] for line in self.log.read_text().splitlines()
                if line.startswith("endpoints delete ")]


@pytest.fixture
def harness(tmp_path):
    return Harness(tmp_path)


def test_the_previous_dashboard_with_this_name_is_deleted_wherever_it_runs(harness):
    harness.listed(
        ("hpc-status", "running", "https://status-alvaro-old.activate.pw/"),
        ("hpc-status-lucky-moth", "running", "https://status-alvaro.activate.pw/"),
        ("jupyterlab-quiet-owl", "running", "https://quiet-owl.activate.pw/lab"),
    )
    result = harness.run()
    assert result.returncode == 0, result.stdout + result.stderr
    assert harness.deleted() == ["hpc-status"]
    remaining = harness.endpoints.read_text()
    assert "hpc-status-lucky-moth" in remaining, "the start script owns the address"
    assert "jupyterlab-quiet-owl" in remaining


def test_nothing_is_deleted_without_a_dashboard_of_this_name(harness):
    harness.listed(("hpc-status-noaa", "running", "https://status-alvaro-noaa.activate.pw/"))
    result = harness.run()
    assert result.returncode == 0, result.stdout + result.stderr
    assert harness.deleted() == []


def test_a_failed_install_leaves_the_previous_dashboard_serving(harness):
    harness.listed(("hpc-status", "running", "https://status-alvaro.activate.pw/"))
    executable(harness.software / "hpc_status" / "venv" / "bin" / "python", "#!/bin/sh\nexit 1\n")
    executable(harness.bin / "python3", "#!/bin/sh\nexit 1\n")
    executable(harness.software / ".uv" / "uv", "#!/bin/sh\nexit 1\n")
    result = harness.run()
    assert result.returncode != 0
    assert harness.deleted() == []
