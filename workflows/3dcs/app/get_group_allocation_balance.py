#!/usr/bin/env python3
"""Print the 3DCS allocation balance (total - used hours) of an organization group.

Exits 1 when the group is missing or its balance is zero or negative. Runs before any
compute job starts, on the PW_API_KEY the platform gives every step of the run.

Usage: get_group_allocation_balance.py <group-name> <organization-name>
"""
import os
import sys

import requests


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <group-name> <organization-name>")
    group_name, org_name = sys.argv[1], sys.argv[2]
    host = os.environ["PW_PLATFORM_HOST"]
    key = os.environ["PW_API_KEY"]
    response = requests.get(
        f"https://{host}/api/organizations/{org_name}/groups",
        # The run's key is a JWT: the API answers 401 to it under the Basic scheme
        headers={"Authorization": f"Bearer {key}"},
        timeout=60,
    )
    response.raise_for_status()
    for group in response.json():
        if group["name"] != group_name:
            continue
        allocations = group.get("allocations") or {}
        balance = float(allocations.get("total", 0)) - float(allocations.get("used", 0))
        print(f"{balance:.2f}")
        if balance <= 0:
            sys.exit(f"ERROR: the 3DCS allocation balance of group {group_name} is {balance:.2f} hours")
        return
    sys.exit(f"ERROR: group {group_name} not found in organization {org_name}")


if __name__ == "__main__":
    main()
