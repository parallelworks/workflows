#!/usr/bin/env python3
"""Live Pareto front page for a Dakota study directory, as a pw endpoint.

    pareto-server.py --state-dir S --port P [--refresh 10] [--title TEXT]

Serves, from the standard library only, one page that plots every evaluated
design of the study under S (objective 1 against objective 2), highlights the
current non-dominated front, and shows the design variables and objectives of a
point on hover. The page polls /data.json every --refresh seconds while the
study is running and stops polling once S/status is final, so a page left open
over a long run costs one small request per refresh. Nothing is cached server
side: every request re-reads the files the optimizer step writes (atomically,
except evaluations.csv, which is appended — a torn last line is skipped), so the
page is only ever one refresh behind the optimizer.

Routes: /  the page; /data.json  the study as JSON; /evaluations.csv and
/pareto.csv  the raw files; /healthz  200 once the server is up.
"""

import argparse
import csv
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_DIR = ""
REFRESH_S = 10
TITLE = "Pareto front"


def read_json(name, default):
    try:
        with open(os.path.join(STATE_DIR, name)) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def read_text(name):
    try:
        with open(os.path.join(STATE_DIR, name)) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def read_csv(name):
    """Rows of a CSV as dicts; a torn trailing line (an append in progress) and
    anything unparseable is skipped rather than failing the whole page."""
    rows = []
    try:
        with open(os.path.join(STATE_DIR, name), newline="") as fh:
            reader = csv.reader(fh)
            header = next(reader, None)
            if not header:
                return []
            for row in reader:
                if len(row) == len(header):
                    rows.append(dict(zip(header, row)))
    except OSError:
        return []
    return rows


def study():
    problem = read_json("problem.json", {"variables": [], "objectives": []})
    variables = [v[0] for v in problem.get("variables", [])]
    objectives = problem.get("objectives", [])
    state = read_json("state.json", {})
    status = read_text("status") or "STARTING"
    evaluations = []
    for row in read_csv("evaluations.csv"):
        try:
            point = {
                "generation": int(row["generation"]),
                "case": row["case"],
                "status": row["status"],
                "x": {name: float(row[name]) for name in variables},
            }
            if row["status"] == "OK":
                point["f"] = {name: float(row[name]) for name in objectives}
            evaluations.append(point)
        except (KeyError, ValueError):
            continue
    front = []
    for row in read_csv("pareto.csv"):
        try:
            front.append({"f": {name: float(row[name]) for name in objectives},
                          "x": {name: float(row[name]) for name in variables}})
        except (KeyError, ValueError):
            continue
    return {
        "title": TITLE,
        "status": status,
        "final": status in ("CONVERGED", "FAILED"),
        "generation": state.get("gen", 0),
        "evaluations_total": state.get("evals", 0),
        "hv_history": state.get("hv_history", []),
        "variables": variables,
        "objectives": objectives,
        "evaluations": evaluations,
        "front": front,
        "refresh_s": REFRESH_S,
        "updated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
  :root {
    color-scheme: light;
    --surface: #fcfcfb; --page: #f9f9f7;
    --ink: #0b0b0b; --ink-2: #52514e; --muted: #898781;
    --grid: #e1e0d9; --axis: #c3c2b7; --border: rgba(11,11,11,0.10);
    --all: #2a78d6; --front: #eb6834; --fail: #898781;
    --good: #0ca30c; --critical: #d03b3b;
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      color-scheme: dark;
      --surface: #1a1a19; --page: #0d0d0d;
      --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781;
      --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10);
      --all: #3987e5; --front: #d95926; --fail: #898781;
    }
  }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 20px 16px 32px; background: var(--page); color: var(--ink);
         font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
  .wrap { max-width: 1040px; margin: 0 auto; }
  header { display: flex; flex-wrap: wrap; align-items: baseline; gap: 8px 20px; margin-bottom: 12px; }
  h1 { font-size: 18px; font-weight: 600; margin: 0; }
  .status { display: inline-flex; align-items: center; gap: 6px; color: var(--ink-2); }
  .status .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--all); }
  .status.final .dot { background: var(--good); }
  .status.failed .dot { background: var(--critical); }
  .meta { color: var(--muted); font-size: 12px; margin-left: auto; }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 12px; }
  .legend { display: flex; flex-wrap: wrap; gap: 6px 18px; margin: 0 0 6px 6px; color: var(--ink-2); font-size: 12px; }
  .legend span { display: inline-flex; align-items: center; gap: 6px; }
  .legend i { width: 10px; height: 10px; border-radius: 50%; display: inline-block; }
  .legend i.front { background: var(--front); }
  .legend i.all { background: var(--all); }
  .legend i.fail { background: none; border: 1.5px solid var(--fail); }
  svg { width: 100%; height: auto; display: block; }
  .grid line { stroke: var(--grid); }
  .axis line, .axis path { stroke: var(--axis); fill: none; }
  .tick text, .axis-label { fill: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
  .axis-label { fill: var(--ink-2); font-size: 12px; }
  .front-line { fill: none; stroke: var(--front); stroke-width: 2; }
  .pt { stroke: var(--surface); stroke-width: 2; }
  .pt.all { fill: var(--all); }
  .pt.front { fill: var(--front); }
  .pt.fail { fill: none; stroke: var(--fail); stroke-width: 1.5; }
  .hit { fill: transparent; cursor: pointer; }
  .hit:hover + .pt, .hit:focus + .pt { stroke: var(--ink); }
  .tip { position: fixed; pointer-events: none; display: none; background: var(--surface);
         color: var(--ink); border: 1px solid var(--border); border-radius: 6px; padding: 8px 10px;
         box-shadow: 0 4px 16px rgba(0,0,0,0.12); font-size: 12px; z-index: 10; min-width: 180px; }
  .tip b { font-size: 13px; }
  .tip table { border-collapse: collapse; margin-top: 4px; }
  .tip td { padding: 1px 0; }
  .tip td:first-child { color: var(--ink-2); padding-right: 12px; }
  .tip td:last-child { text-align: right; font-variant-numeric: tabular-nums; }
  .tip .obj td:last-child { font-weight: 600; }
  .empty { color: var(--muted); padding: 60px 0; text-align: center; }
  details { margin-top: 14px; color: var(--ink-2); }
  summary { cursor: pointer; }
  table.front { border-collapse: collapse; width: 100%; margin-top: 8px; font-size: 12px; }
  table.front th, table.front td { text-align: right; padding: 4px 8px; border-bottom: 1px solid var(--grid); font-variant-numeric: tabular-nums; }
  table.front th { color: var(--ink-2); font-weight: 500; }
  .wide { overflow-x: auto; }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1 id="title">__TITLE__</h1>
    <span class="status" id="status"><span class="dot"></span><span id="status-text">connecting</span></span>
    <span class="meta" id="meta"></span>
  </header>
  <div class="card">
    <div class="legend">
      <span><i class="front"></i>Pareto front <span id="n-front"></span></span>
      <span><i class="all"></i>all evaluations <span id="n-all"></span></span>
      <span id="legend-fail" hidden><i class="fail"></i>failed designs <span id="n-fail"></span></span>
    </div>
    <div id="chart"></div>
    <details>
      <summary>Front as a table</summary>
      <div class="wide"><table class="front" id="front-table"></table></div>
      <p>Raw data: <a href="evaluations.csv">evaluations.csv</a>, <a href="pareto.csv">pareto.csv</a>, <a href="data.json">data.json</a>.</p>
    </details>
  </div>
</div>
<div class="tip" id="tip"></div>
<script>
(function () {
  const W = 960, H = 520, M = {l: 68, r: 20, t: 16, b: 52};
  const chart = document.getElementById("chart");
  const tip = document.getElementById("tip");
  let timer = null, lastData = null;

  function fmt(v) {
    if (v === 0) return "0";
    const a = Math.abs(v);
    if (a >= 1000 || a < 0.001) return v.toExponential(3);
    return v.toPrecision(4);
  }
  function el(name, attrs, parent) {
    const e = document.createElementNS("http://www.w3.org/2000/svg", name);
    for (const k in attrs) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }
  function ticks(lo, hi, n) {
    const span = hi - lo, raw = span / n, p = Math.pow(10, Math.floor(Math.log10(raw)));
    const step = [1, 2, 5, 10].map(m => m * p).find(s => span / s <= n) || 10 * p;
    const out = [];
    for (let v = Math.ceil(lo / step) * step; v <= hi + 1e-12; v += step) out.push(v);
    return out;
  }
  function showTip(evt, point, objectives, variables, onFront) {
    tip.textContent = "";
    const head = document.createElement("b");
    head.textContent = (onFront ? "Pareto front · " : "") + "generation " + point.generation + ", " + point.case;
    tip.appendChild(head);
    const table = document.createElement("table");
    const rows = [];
    if (point.f) objectives.forEach(o => rows.push([o, fmt(point.f[o]), "obj"]));
    else rows.push(["result", point.status, "obj"]);
    variables.forEach(v => rows.push([v, fmt(point.x[v]), ""]));
    rows.forEach(([k, v, cls]) => {
      const tr = document.createElement("tr");
      if (cls) tr.className = cls;
      const a = document.createElement("td"), b = document.createElement("td");
      a.textContent = k; b.textContent = v;
      tr.appendChild(a); tr.appendChild(b); table.appendChild(tr);
    });
    tip.appendChild(table);
    tip.style.display = "block";
    moveTip(evt);
  }
  function moveTip(evt) {
    const x = evt.clientX + 14, y = evt.clientY + 14;
    const r = tip.getBoundingClientRect();
    tip.style.left = (x + r.width > window.innerWidth - 8 ? evt.clientX - r.width - 14 : x) + "px";
    tip.style.top = (y + r.height > window.innerHeight - 8 ? evt.clientY - r.height - 14 : y) + "px";
  }
  function hideTip() { tip.style.display = "none"; }

  function render(d) {
    const objectives = d.objectives, variables = d.variables;
    const ok = d.evaluations.filter(p => p.f), failed = d.evaluations.filter(p => !p.f);
    document.getElementById("n-front").textContent = "(" + d.front.length + ")";
    document.getElementById("n-all").textContent = "(" + ok.length + ")";
    document.getElementById("legend-fail").hidden = failed.length === 0;
    document.getElementById("n-fail").textContent = "(" + failed.length + ")";
    chart.textContent = "";
    if (objectives.length < 2 || ok.length === 0) {
      const p = document.createElement("div");
      p.className = "empty";
      p.textContent = d.generation === 0 ? "Waiting for the first generation to be proposed and evaluated…"
                                         : "Generation " + d.generation + " is being evaluated; no results yet.";
      chart.appendChild(p);
      renderTable(d);
      return;
    }
    const ox = objectives[0], oy = objectives[1];
    const xs = ok.map(p => p.f[ox]), ys = ok.map(p => p.f[oy]);
    let xlo = Math.min(...xs), xhi = Math.max(...xs), ylo = Math.min(...ys), yhi = Math.max(...ys);
    const px = (xhi - xlo) * 0.06 || Math.abs(xlo) * 0.1 || 0.5, py = (yhi - ylo) * 0.06 || Math.abs(ylo) * 0.1 || 0.5;
    xlo -= px; xhi += px; ylo -= py; yhi += py;
    const iw = W - M.l - M.r, ih = H - M.t - M.b;
    const sx = v => M.l + (v - xlo) / (xhi - xlo) * iw;
    const sy = v => M.t + ih - (v - ylo) / (yhi - ylo) * ih;
    const svg = el("svg", {viewBox: "0 0 " + W + " " + H, role: "img",
                           "aria-label": "Scatter plot of " + oy + " against " + ox + " with the Pareto front highlighted"}, chart);
    const grid = el("g", {class: "grid"}, svg), axis = el("g", {class: "axis"}, svg), tk = el("g", {class: "tick"}, svg);
    ticks(xlo, xhi, 7).forEach(v => {
      el("line", {x1: sx(v), x2: sx(v), y1: M.t, y2: M.t + ih}, grid);
      const t = el("text", {x: sx(v), y: M.t + ih + 16, "text-anchor": "middle"}, tk); t.textContent = fmt(v);
    });
    ticks(ylo, yhi, 6).forEach(v => {
      el("line", {x1: M.l, x2: M.l + iw, y1: sy(v), y2: sy(v)}, grid);
      const t = el("text", {x: M.l - 8, y: sy(v) + 4, "text-anchor": "end"}, tk); t.textContent = fmt(v);
    });
    el("path", {d: "M" + M.l + " " + M.t + "V" + (M.t + ih) + "H" + (M.l + iw)}, axis);
    const xl = el("text", {class: "axis-label", x: M.l + iw / 2, y: H - 10, "text-anchor": "middle"}, svg); xl.textContent = ox;
    const yl = el("text", {class: "axis-label", x: 16, y: M.t + ih / 2, "text-anchor": "middle",
                           transform: "rotate(-90 16 " + (M.t + ih / 2) + ")"}, svg); yl.textContent = oy;

    const frontKeys = new Set(d.front.map(p => objectives.map(o => p.f[o].toPrecision(9)).join("|")));
    const isFront = p => frontKeys.has(objectives.map(o => p.f[o].toPrecision(9)).join("|"));
    const sorted = d.front.slice().sort((a, b) => a.f[ox] - b.f[ox]);
    if (sorted.length > 1) {
      el("polyline", {class: "front-line", points: sorted.map(p => sx(p.f[ox]) + "," + sy(p.f[oy])).join(" ")}, svg);
    }
    // failed designs have no objectives: mark them along the bottom edge so the
    // tooltip can still show which design diverged
    failed.forEach(p => {
      const g = el("g", {}, svg);
      const cx = M.l + 10 + (parseInt(p.case.replace(/\D/g, ""), 10) || 1) * 14 + (p.generation - 1) * 2, cy = M.t + ih - 8;
      const hit = el("circle", {class: "hit", cx: cx, cy: cy, r: 12, tabindex: 0}, g);
      el("circle", {class: "pt fail", cx: cx, cy: cy, r: 4}, g);
      hit.addEventListener("pointerenter", e => showTip(e, p, objectives, variables, false));
      hit.addEventListener("pointermove", moveTip);
      hit.addEventListener("pointerleave", hideTip);
      hit.addEventListener("focus", e => showTip({clientX: cx, clientY: cy}, p, objectives, variables, false));
      hit.addEventListener("blur", hideTip);
    });
    const draw = (p, cls) => {
      const g = el("g", {}, svg), cx = sx(p.f[ox]), cy = sy(p.f[oy]);
      const hit = el("circle", {class: "hit", cx: cx, cy: cy, r: 12, tabindex: 0}, g);
      el("circle", {class: "pt " + cls, cx: cx, cy: cy, r: cls === "front" ? 5.5 : 4}, g);
      hit.addEventListener("pointerenter", e => showTip(e, p, objectives, variables, cls === "front"));
      hit.addEventListener("pointermove", moveTip);
      hit.addEventListener("pointerleave", hideTip);
      hit.addEventListener("focus", () => showTip({clientX: cx / W * chart.clientWidth, clientY: 200}, p, objectives, variables, cls === "front"));
      hit.addEventListener("blur", hideTip);
    };
    ok.filter(p => !isFront(p)).forEach(p => draw(p, "all"));
    ok.filter(isFront).forEach(p => draw(p, "front"));
    renderTable(d);
  }
  function renderTable(d) {
    const t = document.getElementById("front-table");
    t.textContent = "";
    const cols = d.objectives.concat(d.variables);
    const hr = document.createElement("tr");
    cols.forEach(c => { const th = document.createElement("th"); th.textContent = c; hr.appendChild(th); });
    t.appendChild(hr);
    d.front.slice().sort((a, b) => a.f[d.objectives[0]] - b.f[d.objectives[0]]).forEach(p => {
      const tr = document.createElement("tr");
      cols.forEach(c => { const td = document.createElement("td"); td.textContent = fmt(c in p.f ? p.f[c] : p.x[c]); tr.appendChild(td); });
      t.appendChild(tr);
    });
  }
  function setStatus(d) {
    const s = document.getElementById("status"), txt = document.getElementById("status-text");
    s.className = "status" + (d.status === "CONVERGED" ? " final" : d.status === "FAILED" ? " failed" : "");
    const ran = d.generation ? "generation " + d.generation + ", " + d.evaluations_total + " evaluations" : "starting";
    txt.textContent = (d.final ? d.status.toLowerCase() + " · " : "running · ") + ran;
    document.getElementById("meta").textContent = (d.final ? "final front" : "refreshes every " + d.refresh_s + " s") + " · updated " + d.updated;
    if (d.title) { document.title = d.title; document.getElementById("title").textContent = d.title; }
  }
  function poll() {
    fetch("data.json", {cache: "no-store"}).then(r => r.json()).then(d => {
      lastData = d; setStatus(d); render(d);
      if (d.final) { clearTimeout(timer); timer = null; }
      else timer = setTimeout(poll, d.refresh_s * 1000);
    }).catch(() => {
      document.getElementById("status-text").textContent = "no answer from the server; retrying";
      timer = setTimeout(poll, 15000);
    });
  }
  window.addEventListener("resize", () => { if (lastData) render(lastData); });
  poll();
})();
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split("?")[0]
        try:
            if path in ("/", "/index.html"):
                self.send(200, PAGE.replace("__TITLE__", TITLE.replace("<", "&lt;")),
                          "text/html; charset=utf-8")
            elif path == "/data.json":
                self.send(200, json.dumps(study()), "application/json")
            elif path == "/healthz":
                self.send(200, "ok\n", "text/plain")
            elif path in ("/evaluations.csv", "/pareto.csv"):
                try:
                    with open(os.path.join(STATE_DIR, path[1:]), "rb") as fh:
                        self.send(200, fh.read(), "text/csv")
                except OSError:
                    self.send(404, "not written yet\n", "text/plain")
            else:
                self.send(404, "not found\n", "text/plain")
        except Exception as exc:  # the page must outlive any odd state on disk
            self.send(500, "error: %s\n" % exc, "text/plain")


def main():
    global STATE_DIR, REFRESH_S, TITLE
    ap = argparse.ArgumentParser()
    ap.add_argument("--state-dir", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--refresh", type=int, default=10)
    ap.add_argument("--title", default="Pareto front")
    args = ap.parse_args()
    STATE_DIR = os.path.abspath(args.state_dir)
    REFRESH_S = max(2, args.refresh)
    TITLE = args.title
    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    server.daemon_threads = True
    print("pareto-server: serving %s on port %d (refresh %ds)" % (STATE_DIR, args.port, REFRESH_S),
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
