"""app/start-template.sh, run against a fake pw CLI.

The start script is where the dashboard meets the platform: it chooses the
configuration, the credential the dashboard lives on after its run
completes, the stable address, and what to do about a dashboard already
serving there. Each of those went wrong in the standalone repository's
launcher before it was pinned by a test, so the same behaviours are pinned
here, by running the script rather than reading it.
"""

import stat
import subprocess
import textwrap
from pathlib import Path

import pytest

WORKFLOW = Path(__file__).resolve().parents[3]
TEMPLATE = WORKFLOW / "app" / "start-template.sh"
SERVE = WORKFLOW / "scripts" / "serve-endpoint.sh"
SLUG = "tidy-otter"

FAKE_PW = textwrap.dedent(
    r"""
    #!/bin/bash
    printf 'key=%s ctx=%s %s\n' "${PW_API_KEY-UNSET}" "${PW_CONTEXT-}" "$*" >> "${FAKE_PW_LOG}"
    authenticated() {
        if [ -n "${PW_API_KEY+x}" ]; then
            case " ${FAKE_PW_GOOD_KEYS} " in *" ${PW_API_KEY} "*) return 0 ;; esac
            return 1
        fi
        [ "${FAKE_PW_SAVED:-0}" = 1 ]
    }
    case "$1 $2" in
        "auth whoami")
            authenticated && echo tester && exit 0
            echo "Authentication has expired" >&2
            exit 1
            ;;
        "endpoints list")
            authenticated || exit 1
            cat "${FAKE_PW_ENDPOINTS}"
            ;;
        "endpoints delete")
            awk -F'\t' -v name="$3" '$1 != name' "${FAKE_PW_ENDPOINTS}" > "${FAKE_PW_ENDPOINTS}.new"
            mv "${FAKE_PW_ENDPOINTS}.new" "${FAKE_PW_ENDPOINTS}"
            ;;
        "endpoints run")
            case " $* " in
                *" --subdomain "*) [ "${FAKE_PW_REFUSE_SUBDOMAIN:-0}" = 1 ] && exit 1 ;;
            esac
            exit "${FAKE_PW_RUN_STATUS:-0}"
            ;;
    esac
    """
).lstrip()


class Harness:
    def __init__(self, root: Path):
        self.root = root
        self.bin = root / "bin"
        self.work = root / "work"
        self.log = root / "pw.log"
        self.endpoints = root / "endpoints.tsv"
        self.env_file = root / "parallelworks-env.sh"
        for directory in (self.bin, self.work):
            directory.mkdir()
        pw = self.bin / "pw"
        pw.write_text(FAKE_PW)
        pw.chmod(pw.stat().st_mode | stat.S_IXUSR)
        python = root / "software" / "hpc_status" / "venv" / "bin" / "python"
        python.parent.mkdir(parents=True)
        python.write_text("#!/bin/sh\n")
        python.chmod(0o755)
        app = root / "job" / "workflows" / "hpc_status" / "app"
        app.parent.mkdir(parents=True)
        app.symlink_to(WORKFLOW / "app")
        self.endpoints.write_text("")
        self.log.write_text("")

    def listed(self, *rows):
        self.endpoints.write_text("".join("\t".join(row) + "\n" for row in rows))

    def run(self, script=TEMPLATE, **overrides):
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.root),
            "FAKE_PW_LOG": str(self.log),
            "FAKE_PW_ENDPOINTS": str(self.endpoints),
            "FAKE_PW_GOOD_KEYS": "run-key",
            "PW_API_KEY": "run-key",
            "PW_ENV_FILE": str(self.env_file),
            "PW_PARENT_JOB_DIR": str(self.root / "job"),
            "PW_RUN_SLUG": SLUG,
            "PW_USER": "alvaro",
            "PW_PLATFORM_HOST": "activate.parallel.works",
            "pw_endpoints_args": "--name hpc-status",
            "service_parent_install_dir": str(self.root / "software"),
        }
        env.update({k: v for k, v in overrides.items() if v is not None})
        for key in [k for k, v in overrides.items() if v is None]:
            env.pop(key, None)
        return subprocess.run(
            ["bash", str(script)],
            cwd=self.work,
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def calls(self, *prefix):
        wanted = " ".join(prefix)
        return [
            line for line in self.log.read_text().splitlines()
            if line.split(" ", 2)[2].startswith(wanted)
        ]

    def launcher(self):
        return (self.work / "launch-dashboard.sh").read_text()


@pytest.fixture
def harness(tmp_path):
    return Harness(tmp_path)


class TestConfiguration:
    @pytest.mark.parametrize(
        "host,config",
        [
            ("activate.hpc.mil", "configs/config.hpcmp.yaml"),
            ("hpcmp.parallel.works", "configs/config.hpcmp.yaml"),
            ("noaa.parallel.works", "configs/config.noaa.yaml"),
            ("activate.parallel.works", "configs/config.yaml"),
            ("", "configs/config.yaml"),
        ],
    )
    def test_auto_resolves_the_config_from_the_platform(self, harness, host, config):
        """A ${{ }} expression cannot see the host; the script can."""
        result = harness.run(PW_PLATFORM_HOST=host, service_platform="auto")
        assert result.returncode == 0, result.stdout + result.stderr
        assert f"--config {config}" in harness.launcher()

    def test_an_explicit_platform_wins_over_the_host(self, harness):
        result = harness.run(PW_PLATFORM_HOST="noaa.parallel.works", service_platform="hpcmp")
        assert result.returncode == 0, result.stdout + result.stderr
        assert "--config configs/config.hpcmp.yaml" in harness.launcher()

    def test_the_form_reaches_the_server(self, harness):
        result = harness.run(
            service_theme="dark",
            service_enable_cluster_pages="false",
            service_enable_cluster_monitor="false",
            service_cluster_monitor_interval="300",
            service_sweep_concurrency="4",
        )
        assert result.returncode == 0, result.stdout + result.stderr
        launcher = harness.launcher()
        for flag in (
            "--default-theme dark",
            "--disable-cluster-pages",
            "--disable-cluster-monitor",
            "--cluster-monitor-interval 300",
            "--max-concurrent-ssh 4",
        ):
            assert flag in launcher

    def test_it_serves_the_port_and_path_the_endpoint_assigns(self, harness):
        """PORT and PW_ENDPOINT_PATH are only known inside pw endpoints run."""
        assert harness.run().returncode == 0
        launcher = harness.launcher()
        assert '--port "${PORT}"' in launcher
        assert '--url-prefix "${PW_ENDPOINT_PATH:-/}"' in launcher
        assert "--host 127.0.0.1" in launcher, "the tunnel dials loopback; nothing else should"


class TestAddress:
    @pytest.mark.parametrize(
        "user,expected",
        [
            ("Matthew.Shaxted", "status-matthew-shaxted"),
            ("mshaxted", "status-mshaxted"),
            ("Foo_Bar.99", "status-foo-bar-99"),
            ("-leading-and-trailing-", "status-leading-and-trailing"),
        ],
    )
    def test_derives_a_valid_hostname_label_from_the_user(self, harness, user, expected):
        assert harness.run(PW_USER=user).returncode == 0
        (run,) = harness.calls("endpoints", "run")
        assert f"--subdomain {expected} " in run

    def test_a_chosen_subdomain_is_folded_too(self, harness):
        assert harness.run(service_subdomain="My_Fleet.Status").returncode == 0
        (run,) = harness.calls("endpoints", "run")
        assert "--subdomain my-fleet-status " in run

    def test_falls_back_when_the_subdomain_is_refused(self, harness):
        """A platform with no sessions domain must still serve the dashboard."""
        result = harness.run(FAKE_PW_REFUSE_SUBDOMAIN="1")
        assert result.returncode == 0, result.stdout + result.stderr
        first, second = harness.calls("endpoints", "run")
        assert "--subdomain" in first and "--subdomain" not in second
        assert "pw subdomains reserve status-alvaro" in result.stdout

    def test_the_endpoint_keeps_the_name_it_is_given(self, harness):
        """Users know the dashboard as hpc-status; the run slug is not part of it."""
        assert harness.run().returncode == 0
        (run,) = harness.calls("endpoints", "run")
        assert " --name hpc-status " in run
        assert SLUG not in run

    def test_a_local_port_is_pinned_only_when_asked(self, harness):
        assert harness.run(service_local_port="9123").returncode == 0
        assert harness.run(service_local_port="0").returncode == 0
        pinned, chosen = harness.calls("endpoints", "run")
        assert " --port 9123 " in pinned
        assert "--port" not in chosen, "0 lets the CLI pick a free port"

    def test_an_endpoint_that_never_registers_fails_the_job(self, harness):
        result = harness.run(FAKE_PW_RUN_STATUS="1")
        assert result.returncode == 1
        assert "pw endpoints command failed" in result.stdout


class TestStartingAgainRestarts:
    def test_the_previous_dashboard_at_the_address_is_replaced(self, harness):
        """Its run completed long ago, and so did the old workflow's."""
        harness.listed(
            ("hpc-status-lucky-moth", "running", "https://status-alvaro.activate.pw/"),
            ("hpc-status", "running", "https://status-alvaro.activate.pw/"),
            ("jupyterlab-quiet-owl", "running", "https://quiet-owl.activate.pw/lab"),
        )
        result = harness.run()
        assert result.returncode == 0, result.stdout + result.stderr
        deleted = [line.rsplit(" ", 1)[1] for line in harness.calls("endpoints", "delete")]
        assert deleted == ["hpc-status-lucky-moth", "hpc-status"]
        assert "jupyterlab-quiet-owl" in harness.endpoints.read_text()
        assert len(harness.calls("endpoints", "run")) == 1

    def test_someone_elses_endpoint_at_the_address_is_left_alone(self, harness):
        """The address is taken, so the dashboard serves at an assigned one instead."""
        harness.listed(("grafana-x", "running", "https://status-alvaro.activate.pw/"))
        result = harness.run(FAKE_PW_REFUSE_SUBDOMAIN="1")
        assert result.returncode == 0, result.stdout + result.stderr
        assert "is served by endpoint grafana-x" in result.stdout
        assert not harness.calls("endpoints", "delete")
        first, second = harness.calls("endpoints", "run")
        assert "--subdomain" in first and "--subdomain" not in second

    def test_another_dashboard_at_another_address_is_left_alone(self, harness):
        """A second dashboard has its own name and subdomain, as it always had."""
        harness.listed(("hpc-status-noaa", "running", "https://status-alvaro-noaa.activate.pw/"))
        result = harness.run()
        assert result.returncode == 0, result.stdout + result.stderr
        assert not harness.calls("endpoints", "delete")


class TestDurableCredentials:
    """The run's key is revoked when the run completes; the dashboard is not."""

    def test_it_adopts_the_workspace_key(self, harness):
        harness.env_file.write_text("export PW_API_KEY=workspace-key\n")
        result = harness.run(FAKE_PW_GOOD_KEYS="run-key workspace-key")
        assert result.returncode == 0, result.stdout + result.stderr
        (run,) = harness.calls("endpoints", "run")
        assert run.startswith("key=workspace-key ")

    def test_it_only_adopts_a_key_that_works(self, harness):
        harness.env_file.write_text("export PW_API_KEY=dead-key\n")
        result = harness.run()
        assert result.returncode == 0, result.stdout + result.stderr
        (run,) = harness.calls("endpoints", "run")
        assert run.startswith("key=run-key ")
        assert "stop collecting" in result.stdout, "say so when nothing outlives the run"

    def test_no_warning_when_the_dashboard_stops_with_its_run(self, harness):
        """With Keep Serving off the run's key lasts exactly as long as the dashboard."""
        result = harness.run(service_detach="false")
        assert result.returncode == 0, result.stdout + result.stderr
        assert "stop collecting" not in result.stdout

    def test_saved_credentials_win_when_they_authenticate(self, harness):
        harness.env_file.write_text("export PW_API_KEY=workspace-key\n")
        result = harness.run(FAKE_PW_GOOD_KEYS="run-key workspace-key", FAKE_PW_SAVED="1")
        assert result.returncode == 0, result.stdout + result.stderr
        (run,) = harness.calls("endpoints", "run")
        assert run.startswith("key=UNSET ")

    def test_saved_credentials_alone_are_durable(self, harness):
        """By hand there is no key in the environment, only pw auth."""
        result = harness.run(PW_API_KEY=None, FAKE_PW_SAVED="1")
        assert result.returncode == 0, result.stdout + result.stderr
        assert "the saved pw credentials" in result.stdout
        assert "stop collecting" not in result.stdout

    def test_an_unauthenticated_host_fails_before_publishing(self, harness):
        result = harness.run(FAKE_PW_GOOD_KEYS="other-key")
        assert result.returncode == 1
        assert "is not authenticated" in result.stdout
        assert not harness.calls("endpoints", "run")

    def test_the_noaa_identity_is_pinned(self, harness):
        """Saved credentials must answer as the NOAA identity, not the current one."""
        result = harness.run(service_pw_context="noaa")
        assert result.returncode == 0, result.stdout + result.stderr
        (run,) = harness.calls("endpoints", "run")
        assert " ctx=noaa " in run

    def test_no_key_reaches_the_launcher(self, harness):
        harness.env_file.write_text("export PW_API_KEY=workspace-key\n")
        assert harness.run(FAKE_PW_GOOD_KEYS="run-key workspace-key").returncode == 0
        launcher = harness.launcher()
        assert "workspace-key" not in launcher and "run-key" not in launcher


def test_the_template_is_not_traced():
    """set -x would print the keys the credential block handles."""
    source = TEMPLATE.read_text()
    assert "set -x" not in source.replace("No set -x in this block", "")


class TestServeEndpointByHand:
    """scripts/serve-endpoint.sh publishes from a clone with the workflow's own scripts."""

    def test_it_publishes_under_the_name_and_address_users_know(self, harness):
        result = harness.run(SERVE)
        assert result.returncode == 0, result.stdout + result.stderr
        (run,) = harness.calls("endpoints", "run")
        assert " --name hpc-status --subdomain status-alvaro -- ./launch-dashboard.sh" in run
        launcher = (harness.root / ".hpc_status" / "endpoint" / "launch-dashboard.sh").read_text()
        assert f'cd "{WORKFLOW / "app"}"' in launcher

    def test_it_replaces_the_previous_dashboard_first(self, harness):
        harness.listed(("hpc-status", "running", "https://status-alvaro.activate.pw/"))
        result = harness.run(SERVE)
        assert result.returncode == 0, result.stdout + result.stderr
        assert [line.rsplit(" ", 1)[1] for line in harness.calls("endpoints", "delete")] == ["hpc-status"]

    def test_its_environment_reaches_the_launch(self, harness):
        result = harness.run(SERVE, ENDPOINT_NAME="fleet", ENDPOINT_SUBDOMAIN="my-fleet",
                             PINNED_PORT="9123", PLATFORM="hpcmp")
        assert result.returncode == 0, result.stdout + result.stderr
        (run,) = harness.calls("endpoints", "run")
        assert " --name fleet --port 9123 --subdomain my-fleet " in run
        launcher = (harness.root / ".hpc_status" / "endpoint" / "launch-dashboard.sh").read_text()
        assert "--config configs/config.hpcmp.yaml" in launcher
