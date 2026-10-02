"""The three variant YAMLs, read rather than run.

They differ only in their platform defaults. The endpoint once picked up the
run slug in the move to this repository, and users who knew the dashboard as
hpc-status found it renamed every run; general and noaa also kept pointing at
a branch that was deleted when the move merged.
"""

import re
from pathlib import Path

import pytest
import yaml

YAMLS = Path(__file__).resolve().parents[3] / "yamls"
VARIANTS = {"general": "hpc-status", "hsp": "hpc-status", "noaa": "rdhpcs-status"}


def load(variant):
    return yaml.safe_load((YAMLS / f"{variant}.yaml").read_text())


def form(variant):
    return load(variant)["on"]["execute"]["inputs"]


@pytest.mark.parametrize("variant,name", VARIANTS.items())
def test_the_endpoint_is_named_without_the_run_slug(variant, name):
    text = (YAMLS / f"{variant}.yaml").read_text()
    (args,) = re.findall(r'pw_endpoints_args="([^"]*)"', text)
    assert "RUN_SLUG" not in args
    assert args == f"--name ${{service_endpoint_name:-{name}}}"
    assert form(variant)["service"]["items"]["name"]["default"] == name


@pytest.mark.parametrize("variant", VARIANTS)
def test_everything_fetched_from_github_comes_from_canary(variant):
    text = (YAMLS / f"{variant}.yaml").read_text()
    assert re.findall(r"^\s+branch:\s*(\S+)", text, re.M) == ["canary"]
    refs = re.findall(r"uses:\s*github/parallelworks/workflows@(\S+)", text)
    assert refs and set(refs) == {"canary"}


def test_the_variants_ask_the_same_questions():
    def fields(variant):
        inputs = form(variant)
        groups = {key: list(value.get("items", {})) for key, value in inputs.items()}
        groups["service"] = [f for f in groups["service"] if f != "pw_context"]
        return list(inputs), groups

    reference = fields("general")
    for variant in ("hsp", "noaa"):
        assert fields(variant) == reference, variant


def test_keep_serving_decides_whether_the_run_lets_go():
    jobs = load("general")["jobs"]
    (cancel,) = [s for s in jobs["wait_for_endpoint"]["steps"] if s["name"] == "Cancel Script Submitter"]
    assert cancel["if"] == "${{ inputs.service.detach != false }}"
    (wait,) = [s for s in jobs["wait_for_endpoint"]["steps"] if s["name"] == "Wait for endpoint"]
    assert wait["with"]["skip_cleanups_file"] == "${{ needs.preprocessing.outputs.HEALTHY_MARKER_PATH }}"
