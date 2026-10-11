#!/usr/bin/env python3
"""Design Explorer over a study of case directories, as a pw endpoint.

    design-explorer-server.py --cases-dir CASES --design-explorer DIR --port P
                              [--title TEXT] [--link LABEL=URL ...]

CASES holds one directory per evaluation (params.in, results.out, images/*):
case_<j>/ as workflows/doe writes them, or iter_<N>/case_<j>/ as a Dakota study
proposes them; study.py reads either. doe-openfoam's cases/ and dakota-openfoam's
state/ are examples; for a Dakota state directory status.json also carries the
optimizer's objectives, bounds and hypervolume (the page's Pareto view).
--link adds a button to the page's header.

Serves the page design-explorer.html next to this script, a self-contained
take on Design Explorer (https://tt-acm.github.io/DesignExplorer/) styled for
the ACTIVATE platform (the hpc_status tokens): parallel coordinates drawn on a
canvas, sliders that pick a case or filter the brushed ones, the designs below
as a gallery, a table or a sensitivity grid, and a panel for the selected case
with its images and animations. It needs nothing from the Design Explorer
tree: --design-explorer is optional and only serves that tree's files, for a
page that still loads them.
The study is served under data/: data.csv with the solved cases (in: columns
for the design variables, out: columns for the outputs, img: columns
pointing at the images each case rendered, the format Design Explorer itself
reads) and data/<case>/images/<file> (study.MEDIA). Nothing is cached server side:
data.csv is rebuilt from the case directories on every request (study.py),
and the page polls status.json and reloads the cases when their count
changes, until every case has finished.

Routes: /  the page; /data/data.csv  the solved cases; /data/<case>/images/<file>
the images and animations; /results.csv  every case with its status; /status.json  the counts
and the title; /healthz  200 once the server is up; anything else is a file of
the Design Explorer tree (its libraries). Standard library only.
"""

import argparse
import io
import json
import mimetypes
import os
import re
import struct
import sys
import tempfile
import time
import zlib
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import study  # noqa: E402

CASES_DIR = ""
DE_DIR = ""
TITLE = "Design of experiments"
LINKS = []
STARTED = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "design-explorer.html")
# older Pythons (3.6 on HSP login nodes) and bare /etc/mime.types miss some
for _ext, _type in ((".webp", "image/webp"), (".svg", "image/svg+xml"), (".mp4", "video/mp4"),
                    (".webm", "video/webm")):
    mimetypes.add_type(_type, _ext)


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
    fd, tmp = tempfile.mkstemp(suffix=".csv")
    os.close(fd)
    try:
        study.write_results_csv(rows, tmp)
        with open(tmp) as fh:
            return fh.read()
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def safe_join(root, rel):
    """root/rel, or None when rel escapes root."""
    path = os.path.normpath(os.path.join(root, rel.lstrip("/")))
    if path != root and not path.startswith(root + os.sep):
        return None
    return path


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype, cache=False, headers=()):
        """cache: True (an hour), "revalidate" (kept, but asked about each
        time: a case's images can be rendered again) or False."""
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache" if cache == "revalidate" else "max-age=3600" if cache else "no-store")
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass  # a video the browser stopped reading after its first bytes

    def send_file(self, path, cache):
        try:
            with open(path, "rb") as fh:
                st = os.fstat(fh.fileno())
                tag = '"%x-%x"' % (st.st_mtime_ns, st.st_size)
                if cache == "revalidate" and self.headers.get("If-None-Match") == tag:
                    self.send(304, b"", "application/octet-stream", cache, [("ETag", tag)])
                    return
                data = fh.read()
        except OSError:
            self.send(404, "not found\n", "text/plain")
            return
        validators = [("ETag", tag)] if cache == "revalidate" else []
        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype in ("application/javascript", "application/json"):
            ctype += "; charset=utf-8"
        # byte ranges: Safari only plays a video served with them, and seeking
        # in one needs them everywhere
        m = re.match(r"bytes=(\d*)-(\d*)$", self.headers.get("Range", "").strip())
        if m and (m.group(1) or m.group(2)) and data:
            size = len(data)
            if m.group(1):
                start, end = int(m.group(1)), int(m.group(2)) if m.group(2) else size - 1
            else:
                start, end = max(0, size - int(m.group(2))), size - 1
            if start >= size or start > end:
                self.send(416, b"", ctype, cache, [("Content-Range", "bytes */%d" % size)])
                return
            end = min(end, size - 1)
            self.send(206, data[start:end + 1], ctype, cache,
                      [("Content-Range", "bytes %d-%d/%d" % (start, end, size)), ("Accept-Ranges", "bytes")] + validators)
            return
        self.send(200, data, ctype, cache, [("Accept-Ranges", "bytes")] + validators)

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
                self.send_file(PAGE, cache=False)
            elif path == "/healthz":
                self.send(200, "ok\n", "text/plain")
            elif path == "/status.json":
                s = study.summary(study.collect(CASES_DIR), CASES_DIR)
                s.update({"title": TITLE, "started": STARTED, "links": LINKS,
                          "updated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
                self.send(200, json.dumps(s), "application/json")
            elif path == "/data/data.csv":
                self.send(200, data_csv(), "text/csv; charset=utf-8")
            elif path == "/results.csv":
                self.send(200, results_csv(), "text/csv; charset=utf-8")
            elif path == "/data/no-image.png":
                self.send(200, PLACEHOLDER, "image/png", cache=True)
            elif path.startswith("/data/"):
                target = safe_join(CASES_DIR, path[len("/data/"):])
                if (target is None or not os.path.isfile(target)
                        or os.path.splitext(target)[1].lower() not in study.MEDIA):
                    self.send(404, "not found\n", "text/plain")
                else:
                    # a case's images: not listed until written, and
                    # revalidated, so no browser keeps an old render
                    self.send_file(target, cache="revalidate")
            elif DE_DIR:
                target = safe_join(DE_DIR, path)
                if target is None or not os.path.isfile(target):
                    self.send(404, "not found\n", "text/plain")
                else:
                    self.send_file(target, cache=True)
            else:
                self.send(404, "not found\n", "text/plain")
        except Exception as exc:  # the page must outlive any odd state on disk
            self.send(500, "error: %s\n" % exc, "text/plain")


def main():
    global CASES_DIR, DE_DIR, TITLE, LINKS
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases-dir", required=True)
    ap.add_argument("--design-explorer", default="", help="a Design Explorer tree to serve files from (optional)")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--title", default=TITLE)
    ap.add_argument("--link", action="append", default=[], metavar="LABEL=URL",
                    help="a button in the page header; repeatable")
    args = ap.parse_args()
    for link in args.link:
        label, sep, url = link.partition("=")
        if sep and label.strip() and url.strip().startswith(("https://", "http://", "/")):
            LINKS.append({"label": label.strip(), "url": url.strip()})
        else:
            print("design-explorer-server: ignoring --link %r (expected LABEL=URL)" % link, flush=True)
    CASES_DIR = os.path.abspath(args.cases_dir)
    DE_DIR = os.path.abspath(args.design_explorer) if args.design_explorer else ""
    TITLE = args.title
    if not os.path.isfile(PAGE):
        sys.exit("design-explorer-server: missing %s" % PAGE)

    # not http.server.ThreadingHTTPServer: that arrived in Python 3.7 and HSP
    # login nodes run 3.6
    class Server(ThreadingMixIn, HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    server = Server(("0.0.0.0", args.port), Handler)
    print("design-explorer-server: serving %s on port %d" % (CASES_DIR, args.port), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
