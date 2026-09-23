#!/usr/bin/env python3
"""POST a rendered tile to the dashboard — pure stdlib, no curl needed."""

import json
import os
import sys
import uuid
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError


def multipart_encode(fields, files):
    """Build a multipart/form-data body from fields and files (stdlib only)."""
    boundary = uuid.uuid4().hex
    parts = []

    for name, value in fields.items():
        parts.append(
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
            f"{value}\r\n"
        )

    for name, (filename, data, content_type) in files.items():
        parts.append(
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
            f"Content-Type: {content_type}\r\n\r\n"
        )
        # Binary part — handled separately
        parts.append(None)  # placeholder for binary data
        parts.append("\r\n")

    parts.append(f"--{boundary}--\r\n")

    # Assemble body
    body = b""
    file_idx = 0
    file_items = list(files.values())
    for part in parts:
        if part is None:
            body += file_items[file_idx][1]
            file_idx += 1
        else:
            body += part.encode()

    content_type = f"multipart/form-data; boundary={boundary}"
    return body, content_type


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <dashboard_url> <tile_file> <metadata_json>", file=sys.stderr)
        sys.exit(2)

    dashboard_url = sys.argv[1]
    tile_file = sys.argv[2]
    metadata_json = sys.argv[3]

    url = f"{dashboard_url}/api/tile"

    with open(tile_file, "rb") as f:
        tile_data = f.read()

    body, content_type = multipart_encode(
        fields={"metadata": metadata_json},
        files={"tile": (os.path.basename(tile_file), tile_data, "image/png")},
    )

    req = Request(url, data=body, method="POST")
    req.add_header("Content-Type", content_type)

    try:
        resp = urlopen(req, timeout=30)
        print(resp.getcode())
    except HTTPError as e:
        print(e.code)
    except (URLError, OSError):
        print("000")


if __name__ == "__main__":
    main()
