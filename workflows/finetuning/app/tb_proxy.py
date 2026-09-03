#!/usr/bin/env python3
"""
Tiny reverse proxy that injects a <base> tag into TensorBoard's HTML responses.

The ACTIVATE platform proxy strips the session path before forwarding requests
to TensorBoard. Without a trailing slash in the browser URL, TensorBoard's
relative asset paths (index.js, etc.) resolve to the wrong parent directory.

This proxy sits in front of TensorBoard and injects:
  <base href="/me/session/{user}/{session}/">
into HTML responses, ensuring assets resolve correctly regardless of whether
the browser URL has a trailing slash.

Usage:
  SESSION_BASE_PATH=/me/session/user/session_name \
  TB_BACKEND_PORT=6007 \
  python3 tb_proxy.py [--port 6006]
"""

import http.server
import os
import sys
import urllib.request
import urllib.error


BACKEND = int(os.environ.get("TB_BACKEND_PORT", 6007))
BASE_PATH = os.environ.get("SESSION_BASE_PATH", "")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self._proxy()

    def do_POST(self):
        self._proxy()

    def _proxy(self):
        url = f"http://localhost:{BACKEND}{self.path}"
        body = None
        if self.command == "POST":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length > 0 else None

        req = urllib.request.Request(url, data=body, method=self.command)
        for key, val in self.headers.items():
            if key.lower() not in ("host", "connection"):
                req.add_header(key, val)

        try:
            resp = urllib.request.urlopen(req)
        except urllib.error.HTTPError as resp:
            pass  # Still send the error response through
        except Exception as e:
            self.send_error(502, str(e))
            return

        content = resp.read()
        ct = resp.headers.get("Content-Type", "")

        # Inject <base> into HTML so relative asset paths resolve correctly
        if "text/html" in ct and BASE_PATH:
            base_tag = f'<base href="{BASE_PATH}/">'.encode()
            content = content.replace(b"<head>", b"<head>" + base_tag, 1)

        self.send_response(resp.status)
        for key, val in resp.headers.items():
            if key.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(key, val)
        self.send_header("Content-Length", len(content))
        self.end_headers()
        self.wfile.write(content)

    def log_message(self, format, *args):
        pass


def main():
    port = 6006
    for i, arg in enumerate(sys.argv[1:], 1):
        if arg == "--port" and i < len(sys.argv) - 1:
            port = int(sys.argv[i + 1])

    print(f"TensorBoard proxy listening on port {port}, backend on {BACKEND}")
    print(f"Injecting <base href=\"{BASE_PATH}/\">")
    server = http.server.HTTPServer(("0.0.0.0", port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
