#!/usr/bin/env python3
"""Serve the page over the outputs a run wrote.

    serve.py --port PORT --web DIR --render DIR

Static files (index.html, the stylesheet, the script, the theme and the fonts)
come from the web directory; render.json, the frames, the poses and the USD files
from the render directory. Standard library only, so the login node's own python3
(3.6 and up) serves it.
"""
import argparse
import os
from http.server import HTTPServer, SimpleHTTPRequestHandler
from socketserver import ThreadingMixIn


class Handler(SimpleHTTPRequestHandler):
    web_dir = "."
    render_dir = "."
    # Named here so every Python the login nodes run sends these types, whatever
    # its own mimetypes table says
    extensions_map = dict(SimpleHTTPRequestHandler.extensions_map,
                          **{".css": "text/css", ".js": "text/javascript", ".woff2": "font/woff2",
                             ".json": "application/json", ".png": "image/png", ".csv": "text/csv",
                             ".usda": "text/plain", ".usd": "application/octet-stream",
                             ".usdc": "application/octet-stream"})

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=self.web_dir, **kwargs)

    def translate_path(self, path):
        # A path-based endpoint forwards its prefix: the page's <base> keeps the
        # relative URLs right, and the server only looks at the tail
        path = path.split("?", 1)[0].split("#", 1)[0]
        if ".." in path.split("/"):
            return os.path.join(self.web_dir, "404")  # nothing above the served directories
        for tail in ("render.json", "frames/", "snapshots/", "poses.csv", "scene.usda"):
            at = path.find("/" + tail)
            if at >= 0:
                rest = os.path.normpath(path[at + 1:]).lstrip("/")
                return os.path.join(self.render_dir, rest)
        self.directory = self.web_dir
        at = max(path.rfind("/" + name) for name in
                 ("index.html", "styles.css", "app.js", "theme.css", "fonts.css",
                  "Geist-Variable.woff2", "GeistMono-Variable.woff2"))
        if at >= 0:
            return os.path.join(self.web_dir, path[at + 1:])
        if path.endswith("/"):
            return os.path.join(self.web_dir, "index.html")
        return os.path.join(self.web_dir, "404")  # nothing there: a 404

    def end_headers(self):
        if self.path.endswith((".json", ".html")) or self.path.endswith("/"):
            self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        pass


class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--web", required=True, help="directory of the page's files")
    parser.add_argument("--render", required=True, help="directory holding render.json and frames/")
    args = parser.parse_args()
    Handler.web_dir = os.path.abspath(args.web)
    Handler.render_dir = os.path.abspath(args.render)
    server = Server(("127.0.0.1", args.port), Handler)
    print(f"Serving {Handler.render_dir} on http://127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
