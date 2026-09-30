"""Starting up: claiming a port, and saying so when we cannot.

Running the dashboard on an ACTIVATE workspace failed with

    OSError: [Errno 98] Address already in use

four frames deep in socketserver, printed *after* a full fleet scrape and
two started worker threads — because port 8080 on those nodes belongs to
Grafana. These tests cover the two halves of that fix: bind before doing
any work, and explain the conflict in terms of what is actually holding
the port.
"""

import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from src.server.main import _create_server, _identify_listener


@pytest.fixture
def occupied_port():
    """A port held by an HTTP server that announces itself as Grafana."""

    class Handler(BaseHTTPRequestHandler):
        server_version = "nginx/1.2"

        def do_GET(self):
            body = b"<html><head><title>Grafana</title></head><body>hi</body></html>"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield httpd.server_address[1]
    finally:
        httpd.shutdown()
        httpd.server_close()


class TestIdentifyListener:
    def test_names_the_service_holding_the_port(self, occupied_port):
        """lsof and ss show nothing for another user's process; HTTP does."""
        assert "Grafana" in _identify_listener(occupied_port)

    def test_falls_back_to_the_server_header(self, occupied_port):
        """A page with no title still identifies itself in its headers."""
        description = _identify_listener(occupied_port)
        assert description.startswith("an HTTP server")

    def test_survives_a_port_that_does_not_speak_http(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        try:
            assert "not an HTTP server" in _identify_listener(listener.getsockname()[1])
        finally:
            listener.close()

    def test_survives_a_closed_port(self):
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        # No exception, no hang — just a vague answer.
        assert _identify_listener(port)


class TestCreateServer:
    def test_busy_port_exits_instead_of_raising_oserror(self, occupied_port, capsys):
        with pytest.raises(SystemExit) as exc:
            _create_server("127.0.0.1", occupied_port, None)
        assert exc.value.code == 1

        output = capsys.readouterr().out
        assert f"Port {occupied_port} is already in use" in output
        assert "Grafana" in output, "the message must say what is in the way"
        assert "pw endpoints run" in output, "and how to avoid choosing a port"

    def test_port_zero_gets_a_free_port(self):
        server = _create_server("127.0.0.1", 0, None)
        try:
            assert server.server_address[1] > 0
        finally:
            server.server_close()

    def test_unexpected_errors_still_raise(self):
        """Only address conflicts get the friendly treatment."""
        with pytest.raises(OSError):
            _create_server("203.0.113.1", 9, None)  # not a local address


class TestPortArgument:
    def test_zero_is_a_real_choice_not_an_absent_one(self):
        import sys

        import src.server.main as main_module

        argv = sys.argv
        try:
            sys.argv = ["prog", "--port", "0"]
            args = main_module.parse_args()
        finally:
            sys.argv = argv
        assert args.port == 0, "--port 0 must survive as 0, not read as unset"

    def test_no_port_flag_means_none(self):
        import sys

        import src.server.main as main_module

        argv = sys.argv
        try:
            sys.argv = ["prog"]
            args = main_module.parse_args()
        finally:
            sys.argv = argv
        assert args.port is None, "an absent --port must let the config file win"
