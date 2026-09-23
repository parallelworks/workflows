#!/usr/bin/env python3
"""Tee stdin -> stdout (with prefix) + batched POST to the dashboard.

The dispatcher pipes each remote worker's SSH output through this helper
so every line shows up in both the dispatcher log AND the live dashboard.

Usage:
    ssh ... 2>&1 | python3 stream_logs.py \
        --site-id site-2 --cluster-name hera \
        --dashboard http://localhost:8080 \
        --prefix "[hera] "

The dashboard endpoint is POST /api/worker/log with a body of:
    {"site_id": "...", "cluster_name": "...",
     "lines": [{"ts": 1700000000.0, "msg": "..."}, ...]}

Batched ~250ms so a noisy worker doesn't fire one request per line.
"""

import argparse
import json
import sys
import threading
import time
import urllib.error
import urllib.request


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--site-id", required=True)
    ap.add_argument("--cluster-name", default="")
    ap.add_argument("--dashboard", required=True)
    ap.add_argument("--prefix", default="")
    ap.add_argument("--flush-interval", type=float, default=0.25)
    ap.add_argument("--max-batch", type=int, default=50)
    args = ap.parse_args()

    url = args.dashboard.rstrip("/") + "/api/worker/log"

    pending = []
    lock = threading.Lock()
    stop = threading.Event()

    def post_batch(batch):
        if not batch:
            return
        try:
            body = json.dumps({
                "site_id": args.site_id,
                "cluster_name": args.cluster_name,
                "lines": batch,
            }).encode()
            req = urllib.request.Request(
                url,
                data=body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            urllib.request.urlopen(req, timeout=3).read()
        except (urllib.error.URLError, OSError, TimeoutError):
            # Dashboard down or slow — drop the batch; dispatch log still
            # has the same lines so we don't fail the worker over UI plumbing.
            pass

    def flusher():
        while not stop.is_set():
            stop.wait(args.flush_interval)
            with lock:
                if not pending:
                    continue
                batch = pending[: args.max_batch]
                del pending[: args.max_batch]
            post_batch(batch)
        # Final drain
        with lock:
            batch = pending[:]
            pending.clear()
        post_batch(batch)

    t = threading.Thread(target=flusher, daemon=True)
    t.start()

    try:
        for line in sys.stdin:
            sys.stdout.write(args.prefix + line)
            sys.stdout.flush()
            with lock:
                pending.append({"ts": time.time(), "msg": line.rstrip("\n")})
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        t.join(timeout=args.flush_interval + 1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
