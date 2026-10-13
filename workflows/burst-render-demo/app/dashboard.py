#!/usr/bin/env python3
"""Live dashboard server — receives tiles from workers and streams to browser."""

import asyncio
import base64
import json
import os
import time
from pathlib import Path

from fastapi import FastAPI, File, Form, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, HTMLResponse

app = FastAPI()

TEMPLATE_DIR = Path(__file__).parent / "templates"

# In-memory state
state = {
    "tiles": {},          # (x,y) -> {png_b64, metadata}
    "grid_size": 8,
    "image_size": 256,
    "start_time": None,
    "site_stats": {},     # site_id -> {count, total_render_ms, last_ts}
    "pending_sites": {},  # site_id -> {cluster_name, scheduler_type}
}
connected_ws = []  # list of WebSocket


@app.get("/", response_class=HTMLResponse)
async def index():
    return (TEMPLATE_DIR / "index.html").read_text()


def _compute_throughput_history():
    """Build per-second throughput buckets from tile arrival times."""
    if not state["tiles"] or not state["start_time"]:
        return []
    # Collect (relative_time, site_id) for each tile
    arrivals = []
    for tile_info in state["tiles"].values():
        t = tile_info.get("arrival_time")
        if t is None:
            continue
        arrivals.append((t - state["start_time"], tile_info["metadata"].get("site_id", "unknown")))
    if not arrivals:
        return []
    arrivals.sort()
    # Bucket into 1-second windows
    max_t = arrivals[-1][0]
    buckets = []
    bucket_start = 0
    while bucket_start <= max_t:
        bucket_end = bucket_start + 1.0
        per_site = {}
        total = 0
        for rel_t, sid in arrivals:
            if bucket_start <= rel_t < bucket_end:
                per_site[sid] = per_site.get(sid, 0) + 1
                total += 1
        buckets.append({"ts_offset": round(bucket_start, 1), "total": total, "perSite": per_site})
        bucket_start += 1.0
    return buckets


@app.get("/api/state")
async def get_state():
    """Return current state for late-joining browsers."""
    return {
        "grid_size": state["grid_size"],
        "image_size": state["image_size"],
        "tiles": {
            f"{k[0]},{k[1]}": v for k, v in state["tiles"].items()
        },
        "site_stats": state["site_stats"],
        "elapsed_s": round(time.time() - state["start_time"], 1) if state["start_time"] else 0,
        "total_tiles": state["grid_size"] ** 2,
        "completed_tiles": len(state["tiles"]),
        "throughput_history": _compute_throughput_history(),
        "pending_sites": state["pending_sites"],
    }


@app.post("/api/worker/pending")
async def worker_pending(data: dict):
    """Mark a site as pending (dispatched but not yet connected)."""
    site_id = data["site_id"]
    state["pending_sites"][site_id] = {
        "cluster_name": data.get("cluster_name", ""),
        "scheduler_type": data.get("scheduler_type", ""),
    }
    msg = json.dumps({
        "type": "pending_site",
        "site_id": site_id,
        "cluster_name": data.get("cluster_name", ""),
        "scheduler_type": data.get("scheduler_type", ""),
    })
    stale = []
    for ws in connected_ws:
        try:
            await ws.send_text(msg)
        except Exception:
            stale.append(ws)
    for ws in stale:
        connected_ws.remove(ws)
    return {"status": "ok"}


@app.post("/api/tile")
async def receive_tile(
    tile: UploadFile = File(...),
    metadata: str = Form(...),
):
    """Receive a rendered tile from a worker."""
    meta = json.loads(metadata)
    png_bytes = await tile.read()
    png_b64 = base64.b64encode(png_bytes).decode()

    tx, ty = meta["tile_x"], meta["tile_y"]
    site_id = meta.get("site_id", "unknown")

    if state["start_time"] is None:
        state["start_time"] = time.time()

    state["grid_size"] = meta.get("grid_size", state["grid_size"])
    state["image_size"] = meta.get("width", state["image_size"])

    now = time.time()
    state["tiles"][(tx, ty)] = {"png_b64": png_b64, "metadata": meta, "arrival_time": now}

    # Remove from pending once connected
    state["pending_sites"].pop(site_id, None)

    # Update site stats
    if site_id not in state["site_stats"]:
        state["site_stats"][site_id] = {
            "count": 0, "total_render_ms": 0, "first_ts": now,
            "cluster_name": meta.get("cluster_name", ""),
            "scheduler_type": meta.get("scheduler_type", ""),
            "num_workers": meta.get("num_workers", 1),
            "nodes": {},
        }
    stats = state["site_stats"][site_id]
    stats["count"] += 1
    stats["total_render_ms"] += meta.get("render_time_ms", 0)
    stats["last_ts"] = now

    # Track per-node stats within each site
    node_hostname = meta.get("node_hostname", "")
    if node_hostname:
        if node_hostname not in stats["nodes"]:
            stats["nodes"][node_hostname] = {"count": 0, "total_render_ms": 0}
        stats["nodes"][node_hostname]["count"] += 1
        stats["nodes"][node_hostname]["total_render_ms"] += meta.get("render_time_ms", 0)

    # Broadcast to all WebSocket clients
    msg = json.dumps({
        "type": "tile",
        "tile_x": tx,
        "tile_y": ty,
        "site_id": site_id,
        "render_time_ms": meta.get("render_time_ms", 0),
        "png_b64": png_b64,
        "completed": len(state["tiles"]),
        "total": state["grid_size"] ** 2,
        "site_stats": state["site_stats"],
        "elapsed_s": round(time.time() - state["start_time"], 1) if state["start_time"] else 0,
        "pending_sites": state["pending_sites"],
    })
    stale = []
    for ws in connected_ws:
        try:
            await ws.send_text(msg)
        except Exception:
            stale.append(ws)
    for ws in stale:
        connected_ws.remove(ws)

    return {"status": "ok", "completed": len(state["tiles"])}


@app.post("/api/config")
async def set_config(grid_size: int = Form(8), image_size: int = Form(256)):
    """Set grid configuration (called before rendering starts)."""
    state["grid_size"] = grid_size
    state["image_size"] = image_size
    state["tiles"] = {}
    state["start_time"] = None
    state["site_stats"] = {}
    state["pending_sites"] = {}
    return {"status": "ok", "grid_size": grid_size, "image_size": image_size}


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    connected_ws.append(ws)
    try:
        # Send current state on connect
        await ws.send_text(json.dumps({
            "type": "init",
            "grid_size": state["grid_size"],
            "image_size": state["image_size"],
            "completed": len(state["tiles"]),
            "total": state["grid_size"] ** 2,
            "site_stats": state["site_stats"],
            "pending_sites": state["pending_sites"],
        }))
        while True:
            await ws.receive_text()  # keep alive
    except WebSocketDisconnect:
        if ws in connected_ws:
            connected_ws.remove(ws)


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("DASHBOARD_PORT", 8080))
    uvicorn.run(app, host="0.0.0.0", port=port)
