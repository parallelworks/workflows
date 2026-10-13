#!/usr/bin/env python3
"""Generate a 512x512 thumbnail for the Multi-Site Ray Cluster workflow.

Produces a network topology visualization showing two site clusters connected
to a central Ray hub, with task dots flowing between them. Uses pure-Python
PNG output (no Pillow required).
"""

import math
import random
import struct
import zlib
import os

WIDTH = HEIGHT = 512
BG = (10, 14, 23)         # #0a0e17
CYAN = (34, 211, 238)     # #22d3ee
BLUE = (59, 130, 246)     # #3b82f6  (site 1)
AMBER = (245, 158, 11)    # #f59e0b  (site 2)
GRID_COLOR = (30, 40, 60)
DIM = (107, 122, 144)


def lerp_color(c1, c2, t):
    return tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))


def blend(bg, fg, alpha):
    return tuple(int(bg[i] * (1 - alpha) + fg[i] * alpha) for i in range(3))


def write_png(pixels, width, height, filepath):
    def make_chunk(chunk_type, data):
        c = chunk_type + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    header = b"\x89PNG\r\n\x1a\n"
    ihdr = make_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))

    raw = b""
    for y in range(height):
        raw += b"\x00"
        for x in range(width):
            r, g, b, a = pixels[y * width + x]
            raw += struct.pack("BBBB", r, g, b, a)

    idat = make_chunk(b"IDAT", zlib.compress(raw, 9))
    iend = make_chunk(b"IEND", b"")

    with open(filepath, "wb") as f:
        f.write(header + ihdr + idat + iend)


def draw_circle_mask(cx, cy, r, x, y):
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def generate():
    random.seed(42)
    cx, cy, radius = WIDTH // 2, HEIGHT // 2, WIDTH // 2 - 1

    pixels = [BG + (255,)] * (WIDTH * HEIGHT)

    def set_pixel(x, y, color, alpha=1.0):
        if 0 <= x < WIDTH and 0 <= y < HEIGHT:
            if not draw_circle_mask(cx, cy, radius, x, y):
                return
            if alpha < 1.0:
                bg_c = pixels[y * WIDTH + x][:3]
                color = blend(bg_c, color, alpha)
            pixels[y * WIDTH + x] = color + (255,)

    def draw_filled_circle(center_x, center_y, r, color, alpha=1.0):
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                if dx * dx + dy * dy <= r * r:
                    set_pixel(center_x + dx, center_y + dy, color, alpha)

    def draw_ring(center_x, center_y, r, color, thickness=2, alpha=1.0):
        for dy in range(-r - thickness, r + thickness + 1):
            for dx in range(-r - thickness, r + thickness + 1):
                d2 = dx * dx + dy * dy
                if (r - thickness) ** 2 <= d2 <= (r + thickness) ** 2:
                    set_pixel(center_x + dx, center_y + dy, color, alpha)

    def draw_line(x0, y0, x1, y1, color, alpha=1.0, thick=1, dashed=False):
        steps = max(abs(x1 - x0), abs(y1 - y0), 1)
        for s in range(steps + 1):
            if dashed and (s // 8) % 2 == 1:
                continue
            t = s / steps
            lx = int(x0 + (x1 - x0) * t)
            ly = int(y0 + (y1 - y0) * t)
            for d in range(-thick // 2, thick // 2 + 1):
                set_pixel(lx, ly + d, color, alpha)
                set_pixel(lx + d, ly, color, alpha)

    # --- Central Ray hub ---
    hub_x, hub_y = cx, cy - 40
    hub_r = 45

    # Hub glow
    for dy in range(-hub_r - 20, hub_r + 21):
        for dx in range(-hub_r - 20, hub_r + 21):
            d = math.sqrt(dx * dx + dy * dy)
            if d < hub_r + 20:
                glow_alpha = max(0, 0.15 * (1 - d / (hub_r + 20)))
                set_pixel(hub_x + dx, hub_y + dy, CYAN, glow_alpha)

    draw_ring(hub_x, hub_y, hub_r, CYAN, thickness=3)
    draw_filled_circle(hub_x, hub_y, hub_r - 4, (20, 30, 50), 0.9)

    # "RAY" text (simple pixel font)
    # R
    for dy in range(-12, 13):
        set_pixel(hub_x - 18, hub_y + dy, CYAN)
    for dx in range(-18, -8):
        set_pixel(dx + hub_x, hub_y - 12, CYAN)
        set_pixel(dx + hub_x, hub_y, CYAN)
    for dy in range(-12, 1):
        set_pixel(hub_x - 8, hub_y + dy, CYAN)
    draw_line(hub_x - 16, hub_y + 1, hub_x - 8, hub_y + 12, CYAN)

    # A
    draw_line(hub_x - 4, hub_y + 12, hub_x + 2, hub_y - 12, CYAN)
    draw_line(hub_x + 2, hub_y - 12, hub_x + 8, hub_y + 12, CYAN)
    for dx in range(-2, 6):
        set_pixel(hub_x + dx, hub_y + 2, CYAN)

    # Y
    draw_line(hub_x + 12, hub_y - 12, hub_x + 17, hub_y, CYAN)
    draw_line(hub_x + 22, hub_y - 12, hub_x + 17, hub_y, CYAN)
    for dy in range(0, 13):
        set_pixel(hub_x + 17, hub_y + dy, CYAN)

    # --- Site 1 (On-Prem / Blue) — left side ---
    site1_x, site1_y = cx - 130, cy + 110
    site1_nodes = [(site1_x - 40, site1_y), (site1_x, site1_y + 35), (site1_x + 40, site1_y)]

    # Connection lines from site 1 to hub
    for nx, ny in site1_nodes:
        draw_line(nx, ny - 18, hub_x, hub_y + hub_r, BLUE, 0.3, thick=1, dashed=True)

    # Site 1 label area
    draw_filled_circle(site1_x, site1_y - 45, 8, BLUE, 0.3)
    for dx in range(-50, 51):
        set_pixel(site1_x + dx, site1_y - 55, BLUE, 0.2)

    # Site 1 nodes
    for nx, ny in site1_nodes:
        draw_ring(nx, ny, 18, BLUE, thickness=2, alpha=0.8)
        draw_filled_circle(nx, ny, 15, (20, 30, 60), 0.8)
        # CPU dots inside
        for i in range(4):
            angle = i * math.pi / 2 + math.pi / 4
            dx = int(7 * math.cos(angle))
            dy = int(7 * math.sin(angle))
            draw_filled_circle(nx + dx, ny + dy, 2, BLUE, 0.9)

    # --- Site 2 (Cloud / Amber) — right side ---
    site2_x, site2_y = cx + 130, cy + 110
    site2_nodes = [(site2_x - 40, site2_y), (site2_x, site2_y + 35),
                   (site2_x + 40, site2_y), (site2_x, site2_y - 20)]

    # Connection lines from site 2 to hub
    for nx, ny in site2_nodes:
        draw_line(nx, ny - 18, hub_x, hub_y + hub_r, AMBER, 0.3, thick=1, dashed=True)

    # Site 2 label area
    draw_filled_circle(site2_x, site2_y - 55, 8, AMBER, 0.3)
    for dx in range(-50, 51):
        set_pixel(site2_x + dx, site2_y - 65, AMBER, 0.2)

    # Site 2 nodes
    for nx, ny in site2_nodes:
        draw_ring(nx, ny, 18, AMBER, thickness=2, alpha=0.8)
        draw_filled_circle(nx, ny, 15, (40, 30, 20), 0.8)
        for i in range(4):
            angle = i * math.pi / 2 + math.pi / 4
            dx = int(7 * math.cos(angle))
            dy = int(7 * math.sin(angle))
            draw_filled_circle(nx + dx, ny + dy, 2, AMBER, 0.9)

    # --- Task flow dots ---
    random.seed(123)
    for _ in range(30):
        # Dot flowing from site 1 to hub
        t = random.random()
        src = random.choice(site1_nodes)
        fx = int(src[0] + (hub_x - src[0]) * t)
        fy = int(src[1] - 18 + (hub_y + hub_r - src[1] + 18) * t)
        dot_alpha = 0.3 + 0.5 * (1 - abs(t - 0.5) * 2)
        draw_filled_circle(fx, fy, 3, BLUE, dot_alpha)

    for _ in range(30):
        # Dot flowing from site 2 to hub
        t = random.random()
        src = random.choice(site2_nodes)
        fx = int(src[0] + (hub_x - src[0]) * t)
        fy = int(src[1] - 18 + (hub_y + hub_r - src[1] + 18) * t)
        dot_alpha = 0.3 + 0.5 * (1 - abs(t - 0.5) * 2)
        draw_filled_circle(fx, fy, 3, AMBER, dot_alpha)

    # --- Bottom bar chart (mini throughput) ---
    bar_y = HEIGHT - 60
    bar_h_max = 35
    n_bars = 30
    bar_w = 10
    bar_gap = 3
    bar_start_x = cx - (n_bars * (bar_w + bar_gap)) // 2

    for i in range(n_bars):
        # Simulate throughput ramp-up
        t = i / n_bars
        h1 = int(bar_h_max * (0.3 + 0.7 * min(t * 2, 1)) * (0.7 + 0.3 * random.random()))
        h2 = int(bar_h_max * (0.2 + 0.6 * min(t * 2, 1)) * (0.6 + 0.4 * random.random()))
        bx = bar_start_x + i * (bar_w + bar_gap)

        # Site 1 (bottom)
        for dy in range(h1):
            for dx in range(bar_w):
                set_pixel(bx + dx, bar_y - dy, BLUE, 0.6)

        # Site 2 (stacked on top)
        for dy in range(h2):
            for dx in range(bar_w):
                set_pixel(bx + dx, bar_y - h1 - dy, AMBER, 0.6)

    # --- Circle border ---
    for angle_step in range(int(2 * math.pi * radius * 2)):
        a = angle_step / (radius * 2)
        for dr in range(-1, 2):
            bx = int(cx + (radius + dr) * math.cos(a))
            by = int(cy + (radius + dr) * math.sin(a))
            if 0 <= bx < WIDTH and 0 <= by < HEIGHT:
                pixels[by * WIDTH + bx] = CYAN + (200,)

    # --- Circular crop ---
    for y in range(HEIGHT):
        for x in range(WIDTH):
            if not draw_circle_mask(cx, cy, radius, x, y):
                pixels[y * WIDTH + x] = (0, 0, 0, 0)

    # --- Write PNG ---
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "thumbnails")
    out_path = os.path.join(out_dir, "ray-cluster.png")
    write_png(pixels, WIDTH, HEIGHT, out_path)
    print(f"Wrote {out_path} ({WIDTH}x{HEIGHT})")


if __name__ == "__main__":
    generate()
