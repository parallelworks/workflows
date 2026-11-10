#!/usr/bin/python3
"""Minimal client for the ACTIVATE API through the pw CLI.

The scripts under utils/ run in the user container, called by the scheduler on the
controller through the reverse ssh tunnel. They used to authenticate with the
PW_API_KEY environment variable, which the enrolled workspace no longer exports to
shell sessions, so the requests now go through `pw api`, which signs them with the
CLI's own credentials (the workspace's current context).
"""
import json
import shutil
import subprocess
import sys


def get(endpoint, params=None):
    """GET <endpoint> (relative to /api) and return the decoded JSON response."""
    # -X GET is required: with -f parameters alone pw api sends a POST
    command = [shutil.which('pw') or '/opt/pw/pw', 'api', '-X', 'GET', endpoint]
    for key, value in (params or {}).items():
        command += ['-f', f'{key}={value}']

    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        output = (result.stdout + result.stderr).strip()[:500]
        sys.exit(f"ERROR: {' '.join(command)} failed with code {result.returncode}: {output}")

    try:
        return json.loads(result.stdout)
    except ValueError:
        sys.exit(f"ERROR: {' '.join(command)} did not return valid JSON: {result.stdout[:500]}")
