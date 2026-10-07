import base64, http.client, json, os, signal, socket, sys, time

host, port, name = sys.argv[1], int(sys.argv[2]), sys.argv[3]


def unregister(*_):
    # clean stop (plain pkill / SIGTERM): drop our registration so the
    # server forgets us immediately. SIGKILL restarts skip this and the
    # re-register overwrites the old entry instead.
    try:
        c = http.client.HTTPConnection(host, port, timeout=5)
        c.request("POST", "/unregister", json.dumps({"name": name}),
                  {"Content-Type": "application/json"})
        c.getresponse().read()
        print("worker %s unregistered" % name, flush=True)
    except OSError:
        pass
    sys.exit(0)


signal.signal(signal.SIGTERM, unregister)

conn = http.client.HTTPConnection(host, port, timeout=10)
conn.request("POST", "/register", json.dumps({"name": name}),
             {"Content-Type": "application/json"})
resp = conn.getresponse()
resp.read()
print("worker %s registered: HTTP %d" % (name, resp.status), flush=True)
if resp.status != 200:
    sys.exit(1)

sock = socket.create_connection((host, port), timeout=15)
key = base64.b64encode(os.urandom(16)).decode()
req = ("GET /ws HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
       "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
       "Sec-WebSocket-Version: 13\r\nX-Worker-Name: %s\r\n\r\n"
       % (host, port, key, name))
sock.sendall(req.encode())
status = sock.recv(1024).decode(errors="replace").split("\r\n")[0]
if " 101 " not in status + " ":
    print("worker %s WebSocket rejected: %s" % (name, status), flush=True)
    sys.exit(1)
print("worker %s WebSocket Connected" % name, flush=True)

sock.settimeout(None)
while True:
    time.sleep(30)
    # masked ping frame keeps the connection alive; a send failure
    # means the connection dropped, so exit and let the supervisor
    # restart the worker
    try:
        sock.sendall(b"\x89\x80" + os.urandom(4))
    except OSError:
        print("worker %s connection lost" % name, flush=True)
        sys.exit(1)
