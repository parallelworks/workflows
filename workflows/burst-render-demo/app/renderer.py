#!/usr/bin/env python3
"""Mandelbrot tile renderer — pure Python + Pillow."""

import argparse
import json
import struct
import time
import zlib
from math import log2

# Mandelbrot region: centered on a visually interesting area
REGION = (-2.5, -1.25, 1.0, 1.25)  # xmin, ymin, xmax, ymax
MAX_ITER = 256

# Color palettes: each is a list of (r, g, b) anchor points for interpolation
PALETTES = {
    "electric": [
        (0, 0, 0), (0, 7, 100), (32, 107, 203),
        (237, 255, 255), (255, 170, 0), (0, 2, 0),
    ],
    "fire": [
        (0, 0, 0), (25, 7, 26), (109, 1, 31),
        (189, 21, 2), (238, 113, 0), (255, 255, 0),
    ],
    "ocean": [
        (0, 0, 0), (0, 20, 50), (0, 72, 120),
        (0, 150, 180), (72, 210, 210), (200, 255, 255),
    ],
    "cosmic": [
        (0, 0, 0), (20, 0, 40), (80, 0, 120),
        (160, 30, 200), (220, 100, 255), (255, 220, 255),
    ],
}


def lerp_color(palette, t):
    """Interpolate through a palette given t in [0, 1]."""
    n = len(palette) - 1
    idx = t * n
    i = int(idx)
    if i >= n:
        return palette[-1]
    f = idx - i
    c0, c1 = palette[i], palette[i + 1]
    return tuple(int(c0[j] + (c1[j] - c0[j]) * f) for j in range(3))


def render_tile(tile_x, tile_y, grid_size, img_w, img_h, palette_name="electric"):
    """Render a single Mandelbrot tile. Returns list of (r,g,b) pixel tuples."""
    palette = PALETTES.get(palette_name, PALETTES["electric"])

    xmin, ymin, xmax, ymax = REGION
    tile_w = (xmax - xmin) / grid_size
    tile_h = (ymax - ymin) / grid_size

    x0 = xmin + tile_x * tile_w
    y0 = ymin + tile_y * tile_h

    pixels = []
    for py in range(img_h):
        for px in range(img_w):
            # Map pixel to complex plane
            cx = x0 + (px / img_w) * tile_w
            cy = y0 + (py / img_h) * tile_h

            zx, zy = 0.0, 0.0
            iteration = 0
            while zx * zx + zy * zy <= 4.0 and iteration < MAX_ITER:
                zx, zy = zx * zx - zy * zy + cx, 2.0 * zx * zy + cy
                iteration += 1

            if iteration == MAX_ITER:
                pixels.append((0, 0, 0))
            else:
                # Smooth coloring
                smooth = iteration + 1 - log2(log2(max(zx * zx + zy * zy, 1.001)))
                t = (smooth / MAX_ITER) % 1.0
                pixels.append(lerp_color(palette, t))

    return pixels


def write_png(pixels, width, height, filepath):
    """Write pixels as a PNG file without Pillow (pure Python)."""
    def make_chunk(chunk_type, data):
        c = chunk_type + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    header = b"\x89PNG\r\n\x1a\n"
    ihdr = make_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))

    raw = b""
    for y in range(height):
        raw += b"\x00"  # filter: none
        for x in range(width):
            r, g, b = pixels[y * width + x]
            raw += struct.pack("BBB", r, g, b)

    idat = make_chunk(b"IDAT", zlib.compress(raw, 9))
    iend = make_chunk(b"IEND", b"")

    with open(filepath, "wb") as f:
        f.write(header + ihdr + idat + iend)


def write_png_pillow(pixels, width, height, filepath):
    """Write pixels as PNG using Pillow if available."""
    from PIL import Image
    img = Image.new("RGB", (width, height))
    img.putdata(pixels)
    img.save(filepath, "PNG")


def main():
    parser = argparse.ArgumentParser(description="Render a Mandelbrot tile")
    parser.add_argument("--tile-x", type=int, required=True)
    parser.add_argument("--tile-y", type=int, required=True)
    parser.add_argument("--grid-size", type=int, required=True)
    parser.add_argument("--width", type=int, default=256)
    parser.add_argument("--height", type=int, default=256)
    parser.add_argument("--palette", default="electric", choices=list(PALETTES.keys()))
    parser.add_argument("--output", default="tile.png")
    parser.add_argument("--site-id", default="unknown")
    parser.add_argument("--cluster-name", default="")
    parser.add_argument("--scheduler-type", default="")
    parser.add_argument("--num-workers", type=int, default=1)
    parser.add_argument("--node-hostname", default="")
    args = parser.parse_args()

    t0 = time.time()
    pixels = render_tile(
        args.tile_x, args.tile_y, args.grid_size,
        args.width, args.height, args.palette,
    )
    elapsed_ms = (time.time() - t0) * 1000

    # Try Pillow first, fall back to pure Python PNG
    try:
        write_png_pillow(pixels, args.width, args.height, args.output)
    except ImportError:
        write_png(pixels, args.width, args.height, args.output)

    # Output metadata as JSON to stdout
    meta = {
        "tile_x": args.tile_x,
        "tile_y": args.tile_y,
        "grid_size": args.grid_size,
        "width": args.width,
        "height": args.height,
        "render_time_ms": round(elapsed_ms, 1),
        "site_id": args.site_id,
        "cluster_name": args.cluster_name,
        "scheduler_type": args.scheduler_type,
        "num_workers": args.num_workers,
        "node_hostname": args.node_hostname,
        "palette": args.palette,
    }
    print(json.dumps(meta))


if __name__ == "__main__":
    main()
