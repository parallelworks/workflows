#!/usr/bin/python3
"""Print "<status> <user@address>" for the cluster with the given id.

Reads the output of `pw cluster ls -o json` on stdin and prints nothing when the
cluster is not in it, so the caller can tell a cluster that is listed but stopped
from a listing it could not get.
"""
import json
import sys

text = sys.stdin.read()
start = next((i for i, c in enumerate(text) if c == '[' and (i == 0 or text[i - 1] == '\n')), -1)
try:
    clusters = json.loads(text[start:text.rindex(']') + 1]) if start >= 0 else []
except ValueError:
    clusters = []

for cluster in clusters:
    if str(cluster.get('id')) == sys.argv[1]:
        address = cluster.get('connectionString') or ''
        if not address and cluster.get('ipAddress'):
            address = '{}@{}'.format(cluster.get('user') or '', cluster['ipAddress'])
        print(cluster.get('status') or 'unknown', address)
        break
