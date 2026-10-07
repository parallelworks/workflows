import base64, hashlib, http.server, json, socketserver, sys, time

PORT = int(sys.argv[1])
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
workers = {}

# self-contained live topology page: polls /workers and redraws an
# SVG hub-and-spoke; no external assets so it renders on closed
# networks. Kept free of "${" sequences (platform templating).
PAGE = ("""<!doctype html><html><head><meta charset="utf-8">
<title>app-testbed</title>
<style>
 body{font-family:system-ui,sans-serif;margin:0;background:#10141a;color:#dbe4ee}
 header{padding:14px 22px;border-bottom:1px solid #2a3442;display:flex;gap:18px;align-items:baseline;flex-wrap:wrap}
 h1{font-size:18px;margin:0}
 .muted{color:#8299b5;font-size:13px}
 a{color:#7db3e8}
 svg{display:block;margin:0 auto;max-width:960px;width:100%}
 .hub{fill:#2c5f9e;stroke:#96c3f0;stroke-width:2}
 text{fill:#dbe4ee;font-size:13px;text-anchor:middle}
 .small{fill:#8299b5;font-size:11px}
</style></head><body>
<header><h1>app-testbed</h1><div id="stats" class="muted">loading&#8230;</div>
<div class="muted"><a href="/workers">/workers</a> &#183; <a href="/health">/health</a></div></header>
<svg id="topo" viewBox="0 0 960 440"></svg>
<script>
function esc(s){return String(s).replace(/[&<>"]/g,function(c){return "&#"+c.charCodeAt(0)+";"})}
function ago(t){var s=Math.max(0,Date.now()/1000-t);
  return s<90?Math.round(s)+"s":s<5400?Math.round(s/60)+"m":(s/3600).toFixed(1)+"h"}
function draw(w){
  var names=Object.keys(w).sort(),n=names.length,cx=480,cy=110,p=[];
  p.push('<circle class="hub" cx="'+cx+'" cy="'+cy+'" r="34"/>');
  p.push('<text x="'+cx+'" y="'+(cy+4)+'">server</text>');
  p.push('<text class="small" x="'+cx+'" y="'+(cy-44)+'">:__PORT__</text>');
  for(var i=0;i<n;i++){
    var wk=w[names[i]],on=wk.connected,col=on?"#38b26f":"#5a6b80";
    var x=n>1?120+720*i/(n-1):cx,y=330;
    var label=names[i].length>26?names[i].slice(0,24)+"&#8230;":esc(names[i]);
    p.push('<line x1="'+cx+'" y1="'+(cy+34)+'" x2="'+x+'" y2="'+(y-26)+
      '" stroke="'+col+'" stroke-width="2"'+(on?"":' stroke-dasharray="6 5"')+'/>');
    p.push('<circle cx="'+x+'" cy="'+y+'" r="26" fill="#1d2938" stroke="'+col+'" stroke-width="2"/>');
    p.push('<circle cx="'+x+'" cy="'+y+'" r="7" fill="'+col+'"/>');
    p.push('<text x="'+x+'" y="'+(y+48)+'">'+label+'</text>');
    p.push('<text class="small" x="'+x+'" y="'+(y+64)+'">'+
      (on?"connected "+ago(wk.ws_since):"registered "+ago(wk.registered)+", offline")+'</text>');
  }
  if(!n){p.push('<text class="small" x="'+cx+'" y="330">no workers registered yet</text>')}
  document.getElementById("topo").innerHTML=p.join("");
  var live=names.filter(function(k){return w[k].connected}).length;
  document.getElementById("stats").textContent=n+" worker(s) registered, "+live+" connected";
}
function tick(){fetch("/workers").then(function(r){return r.json()}).then(draw).catch(function(){})}
tick();setInterval(tick,3000);
</script></body></html>""").replace("__PORT__", str(PORT)).encode()

STALE_S = 3600


def prune():
    # forget workers that have been offline for over an hour; connected
    # ones and fresh disconnects stay visible (grey) on the topology page
    now = time.time()
    for n in [n for n, w in workers.items()
              if not w.get("connected")
              and now - w.get("last_seen", w.get("registered", now)) > STALE_S]:
        workers.pop(n, None)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(PAGE)))
            self.end_headers()
            self.wfile.write(PAGE)
        elif self.path == "/health":
            self._json(200, {"ok": True, "workers": len(workers)})
        elif self.path == "/workers":
            prune()
            self._json(200, workers)
        elif self.path == "/ws":
            self._websocket()
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/register":
            n = int(self.headers.get("Content-Length", 0))
            d = json.loads(self.rfile.read(n) or b"{}")
            name = d.get("name", "unknown")
            workers[name] = {"registered": time.time(), "connected": False,
                             "last_seen": time.time()}
            self._json(200, {"ok": True, "name": name})
        elif self.path == "/unregister":
            n = int(self.headers.get("Content-Length", 0))
            d = json.loads(self.rfile.read(n) or b"{}")
            gone = workers.pop(d.get("name", ""), None)
            self._json(200, {"ok": gone is not None})
        else:
            self._json(404, {"error": "not found"})

    def _websocket(self):
        key = self.headers.get("Sec-WebSocket-Key")
        if not key:
            self._json(400, {"error": "not a websocket request"})
            return
        accept = base64.b64encode(
            hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        name = self.headers.get("X-Worker-Name", "unknown")
        if name in workers:
            workers[name]["connected"] = True
            workers[name]["ws_since"] = time.time()
            workers[name]["last_seen"] = time.time()
        self.connection.settimeout(300)
        try:
            while True:
                if not self.connection.recv(4096):
                    break
        except OSError:
            pass
        finally:
            if name in workers:
                workers[name]["connected"] = False
                workers[name]["last_seen"] = time.time()
        self.close_connection = True

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

Server(("127.0.0.1", PORT), Handler).serve_forever()
