#!/usr/bin/env python3
"""TensorBoard over a PhysicsNeMo run directory, fed from the run's console output.

The PhysicsNeMo examples log to the console (and to MLflow or W&B when enabled), not
to TensorBoard. This server follows the training log, writes every metric line
metrics.py recognises as a TensorBoard scalar and every PNG figure the run saves under
the log directory as a TensorBoard image, into <logdir>/tensorboard/<run name>, and
serves TensorBoard over <logdir>: event files a custom script writes itself anywhere
under it show up too. It starts before the training and keeps serving after it ends,
under `pw endpoints run`, which substitutes {port}.

Usage: tensorboard-server.py --logdir DIR --log FILE --done FILE --run-name NAME --port PORT
"""

import argparse
import os
import re
import shutil
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import metrics  # noqa: E402

POLL_S = 5
MAX_IMAGE_BYTES = 20 * 1024 * 1024
TRAILING_NUMBER = re.compile(r"^(.*?)[_-]?(\d+)$")


def png_header(data):
    """(width, height, colorspace) of a PNG, or None."""
    if len(data) < 26 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", data[16:24])
    colorspace = {0: 1, 2: 3, 3: 3, 4: 2, 6: 4}.get(data[25], 3)
    return width, height, colorspace


class Feeder(threading.Thread):
    def __init__(self, logdir, log, done, events_dir):
        super().__init__(daemon=True)
        from tensorboard.compat.proto import event_pb2, summary_pb2
        from tensorboard.summary.writer.event_file_writer import EventFileWriter

        self.event_pb2 = event_pb2
        self.summary_pb2 = summary_pb2
        self.logdir = os.path.realpath(logdir)
        self.log = log
        self.done = done
        self.events_dir = os.path.realpath(events_dir)
        self.writer = EventFileWriter(events_dir, flush_secs=POLL_S)
        self.parser = metrics.Parser()
        self.position = 0
        self.images = {}

    def add(self, tag, step, wall, **value):
        summary = self.summary_pb2.Summary(value=[self.summary_pb2.Summary.Value(tag=tag, **value)])
        self.writer.add_event(self.event_pb2.Event(wall_time=wall, step=step, summary=summary))

    def read_log(self):
        try:
            size = os.path.getsize(self.log)
        except OSError:
            return
        if size < self.position:
            self.position = 0
        with open(self.log, "rb") as f:
            f.seek(self.position)
            chunk = f.read()
        # only whole lines: the training may be in the middle of writing one
        end = chunk.rfind(b"\n") + 1
        self.position += end
        for line in chunk[:end].decode("utf-8", errors="replace").splitlines():
            record = self.parser.parse_line(line)
            if not record:
                continue
            namespace, step, values, wall = record
            for name, value in values.items():
                self.add("%s/%s" % (namespace, name), step, wall, simple_value=value)

    def scan_images(self, final=False):
        for root, dirs, files in os.walk(self.logdir):
            if os.path.realpath(root).startswith(self.events_dir):
                dirs[:] = []
                continue
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for name in files:
                if not name.lower().endswith(".png"):
                    continue
                path = os.path.join(root, name)
                try:
                    stat = os.stat(path)
                except OSError:
                    continue
                key = (stat.st_mtime, stat.st_size)
                if self.images.get(path) == key or stat.st_size > MAX_IMAGE_BYTES:
                    continue
                # a figure still being written is picked up on the next pass; after the
                # training there is no next pass, and nothing is being written any more
                if not final and time.time() - stat.st_mtime < POLL_S:
                    continue
                with open(path, "rb") as f:
                    data = f.read()
                header = png_header(data)
                if not header:
                    continue
                self.images[path] = key
                stem = os.path.splitext(name)[0]
                m = TRAILING_NUMBER.match(stem)
                tag, step = (m.group(1) or stem, int(m.group(2))) if m else (stem, 0)
                width, height, colorspace = header
                image = self.summary_pb2.Summary.Image(
                    height=height, width=width, colorspace=colorspace, encoded_image_string=data
                )
                self.add("figures/" + tag, step, stat.st_mtime, image=image)

    def run(self):
        while True:
            finished = os.path.exists(self.done)
            try:
                self.read_log()
                self.scan_images(final=finished)
                self.writer.flush()
            except Exception as e:  # keep serving what is there
                print("tensorboard-server: %s" % e, flush=True)
            if finished:
                print("tensorboard-server: the training ended; all of its metrics are loaded", flush=True)
                return
            time.sleep(POLL_S)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--logdir", required=True)
    p.add_argument("--log", required=True)
    p.add_argument("--done", required=True)
    p.add_argument("--run-name", default="training")
    p.add_argument("--port", type=int, required=True)
    args = p.parse_args()

    os.makedirs(args.logdir, exist_ok=True)
    # the scalars are rebuilt from the whole log, so a restarted server starts clean
    events_dir = os.path.join(args.logdir, "tensorboard", args.run_name)
    shutil.rmtree(events_dir, ignore_errors=True)
    os.makedirs(events_dir)
    Feeder(args.logdir, args.log, args.done, events_dir).start()

    from tensorboard import program

    tb = program.TensorBoard()
    tb.configure(
        argv=[
            None,
            "--logdir", args.logdir,
            "--host", "0.0.0.0",
            "--port", str(args.port),
            "--reload_interval", str(POLL_S),
            "--load_fast", "false",
        ]
    )
    print("tensorboard-server: serving %s on port %d" % (args.logdir, args.port), flush=True)
    sys.exit(tb.main())


if __name__ == "__main__":
    main()
