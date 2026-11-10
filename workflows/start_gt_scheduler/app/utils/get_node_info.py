#!/usr/bin/python3
import argparse
import json

import pw_api

# This script runs in the user container, called by the scheduler on the controller
# through the reverse ssh tunnel. It authenticates through the pw CLI (see pw_api.py)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Process resource_name, resource_namespace and org_name')
    parser.add_argument('--resource_name', type=str, help='Name of the resource')
    parser.add_argument('--resource_namespace', type=str, help='Namespace (owner user) of the resource')
    parser.add_argument('--org_name', type=str, required=True, help='Name of the organization of the resource owner')
    args = parser.parse_args()

    # includeFailed is required because the API omits failed nodes by default and
    # the scheduler uses this output precisely to detect failed nodes
    nodes = pw_api.get(
        f'organizations/{args.org_name}/users/{args.resource_namespace}/clusters/{args.resource_name}/nodes',
        {'includeFailed': 'true'}
    )

    if nodes is None:
        nodes = []

    # The API exposes the node hostname under "name" but consumers of this output
    # (jq in scheduler-libs.sh) select nodes by the "hostname" key
    for node in nodes:
        node['hostname'] = node.get('name')

    print(json.dumps(nodes, indent=4))
