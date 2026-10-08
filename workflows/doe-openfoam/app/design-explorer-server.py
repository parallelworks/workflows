#!/usr/bin/env python3
"""Design Explorer over a design of experiments directory, as a pw endpoint.

    design-explorer-server.py --cases-dir CASES --design-explorer DIR --port P [--title TEXT]

Serves Design Explorer (https://tt-acm.github.io/DesignExplorer/, the files
install-design-explorer.sh downloads into DIR) and, next to it, the study as
the "server folder" Design Explorer loads: data/data.csv with the solved
cases (in: columns for the design variables, out: columns for the
coefficients, img: columns pointing at the images each case rendered) and
data/<case>/images/<name>.png. The page is opened with ?ID=<base64 of "data/">,
which is how Design Explorer is told where the folder is; a request for the
root without it is redirected there, so the endpoint URL alone opens the
study. Nothing is cached server side: data.csv is rebuilt from the case
directories on every request (study.py), so reloading the page shows the
cases that finished meanwhile.

Routes: /  Design Explorer (redirected to ?ID=...); /data/data.csv  the solved
cases; /data/<case>/images/<img>.png  the images; /results.csv  every case with
its status; /status.json  the counts; /healthz  200 once the server is up;
anything else is a file of the Design Explorer tree. Standard library only.
"""

import argparse
import base64
import io
import json
import mimetypes
import os
import struct
import sys
import time
import zlib
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import study  # noqa: E402

CASES_DIR = ""
DE_DIR = ""
TITLE = "Design of experiments"
STARTED = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
# the "folder" Design Explorer loads data.csv and the images from, relative to
# the page, so it needs no knowledge of the endpoint's host or path prefix
FOLDER_ID = base64.b64encode(b"data/").decode()


def placeholder_png():
    """A small light-gray PNG for a case without one of the images."""
    w, h = 160, 100
    row = b"\x00" + b"\xdd" * (w * 3)
    raw = row * h

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


PLACEHOLDER = placeholder_png()


def data_csv():
    rows = study.collect(CASES_DIR)
    header, table = study.design_explorer_rows(rows)
    out = io.StringIO()
    import csv
    writer = csv.writer(out)
    writer.writerow(header)
    writer.writerows(table)
    return out.getvalue()


def results_csv():
    rows = study.collect(CASES_DIR)
    tmp = os.path.join(CASES_DIR, ".results.csv.%d" % os.getpid())
    study.write_results_csv(rows, tmp)
    with open(tmp) as fh:
        text = fh.read()
    os.remove(tmp)
    return text


def settings_json():
    return json.dumps({"studyInfo": {"name": TITLE, "date": STARTED},
                       "dimScales": {}, "dimTicks": {}, "dimMark": {}})


def safe_join(root, rel):
    """root/rel, or None when rel escapes root."""
    path = os.path.normpath(os.path.join(root, rel.lstrip("/")))
    if path != root and not path.startswith(root + os.sep):
        return None
    return path


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype, cache=False):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "max-age=3600" if cache else "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def send_file(self, path, cache):
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError:
            self.send(404, "not found\n", "text/plain")
            return
        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype in ("application/javascript", "application/json"):
            ctype += "; charset=utf-8"
        self.send(200, data, ctype, cache)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        # a path-based endpoint (--no-subdomain) forwards the full
        # /me/session/<user>/<name>/ prefix, which pw endpoints run exports
        path, _, query = self.path.partition("?")
        prefix = os.environ.get("PW_ENDPOINT_PATH", "/").rstrip("/")
        if prefix and path.startswith(prefix):
            path = path[len(prefix):] or "/"
        try:
            if path in ("/", "/index.html"):
                if "ID=" not in query.upper():
                    self.send_response(302)
                    self.send_header("Location", "%s/?ID=%s" % (prefix, FOLDER_ID))
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if not os.path.isfile(os.path.join(DE_DIR, "index.html")):
                    self.send(500, "Design Explorer is not installed in %s\n" % DE_DIR, "text/plain")
                    return
                self.send_file(os.path.join(DE_DIR, "index.html"), cache=False)
            elif path == "/healthz":
                self.send(200, "ok\n", "text/plain")
            elif path == "/status.json":
                s = study.summary(study.collect(CASES_DIR))
                s.update({"title": TITLE, "started": STARTED,
                          "updated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
                self.send(200, json.dumps(s), "application/json")
            elif path == "/data/data.csv":
                self.send(200, data_csv(), "text/csv; charset=utf-8")
            elif path == "/results.csv":
                self.send(200, results_csv(), "text/csv; charset=utf-8")
            elif path in ("/data/no-image.png", "/data/settings.json", "/design_explorer_data/settings.json"):
                if path.endswith(".png"):
                    self.send(200, PLACEHOLDER, "image/png", cache=True)
                else:
                    self.send(200, settings_json(), "application/json")
            elif path.startswith("/data/"):
                target = safe_join(CASES_DIR, path[len("/data/"):])
                if target is None or not os.path.isfile(target) or not target.endswith(".png"):
                    self.send(404, "not found\n", "text/plain")
                else:
                    self.send_file(target, cache=True)
            else:
                target = safe_join(DE_DIR, path)
                if target is None or not os.path.isfile(target):
                    self.send(404, "not found\n", "text/plain")
                else:
                    self.send_file(target, cache=True)
        except Exception as exc:  # the page must outlive any odd state on disk
            self.send(500, "error: %s\n" % exc, "text/plain")


def main():
    global CASES_DIR, DE_DIR, TITLE
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases-dir", required=True)
    ap.add_argument("--design-explorer", required=True, help="directory holding Design Explorer's index.html")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--title", default=TITLE)
    args = ap.parse_args()
    CASES_DIR = os.path.abspath(args.cases_dir)
    DE_DIR = os.path.abspath(args.design_explorer)
    TITLE = args.title
    if not os.path.isfile(os.path.join(DE_DIR, "index.html")):
        sys.exit("design-explorer-server: no index.html in %s" % DE_DIR)

    # not http.server.ThreadingHTTPServer: that arrived in Python 3.7 and HSP
    # login nodes run 3.6
    class Server(ThreadingMixIn, HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    server = Server(("0.0.0.0", args.port), Handler)
    print("design-explorer-server: serving %s with Design Explorer from %s on port %d"
          % (CASES_DIR, DE_DIR, args.port), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
