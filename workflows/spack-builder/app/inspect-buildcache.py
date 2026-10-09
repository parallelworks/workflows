#!/usr/bin/env python3
"""Report what is in a Spack binary build cache, and whether it is intact.

Exists so a build cache can be diagnosed from the workflow logs alone. A cache
that was copied to a new cluster is the interesting case: `spack install` reports
"Building" instead of "Extracting" for a dozen different reasons, and without
this report the log cannot tell a *corrupt* cache (truncated blobs from an
interrupted copy) from a *complete but irrelevant* one (every hash differs
because this image resolved different externals). The first needs a re-copy, the
second is working as designed, and they look identical from the outside.

Plain python3 with no Spack import on purpose: the report must also be printable
before Spack is usable, and on a node where it is not installed at all.

  inspect-buildcache.py <cache>                inventory + integrity
  inspect-buildcache.py <cache> --lock <lock>  the above plus a hit/miss forecast
                                               for a concretized spack.lock

Exit status is 0 unless the cache is structurally broken (missing or truncated
blobs), which is a fact the caller may want to act on rather than just print.
"""

import json
import os
import sys

MAX_LISTED = 10


def log(msg=""):
    print(msg, flush=True)


def blob_path(cache, checksum):
    return os.path.join(cache, "blobs", "sha256", checksum[:2], checksum)


def manifests(cache):
    """Yield (package name, manifest path). The name comes from the directory,
    not from the filename: a version containing a dash (ca-certificates-mozilla,
    libedit-3.1) makes the filename ambiguous to split."""
    root = os.path.join(cache, "v3", "manifests", "spec")
    for dirpath, _, names in os.walk(root):
        for name in sorted(names):
            if name.endswith(".spec.manifest.json"):
                yield os.path.basename(dirpath), os.path.join(dirpath, name)


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return f"{n:.1f}{unit}" if unit != "B" else f"{n}B"
        n /= 1024


def spec_name(path):
    return os.path.basename(path)[: -len(".spec.manifest.json")]


def inventory(cache, verbose=True):
    """Inventory + integrity. Returns (specs_by_hash, broken)."""
    log(f"--- build cache: {cache}")
    if not os.path.isdir(cache):
        log("::error title=Error::build cache path does not exist")
        return {}, ["<missing cache>"]

    layout = os.path.join(cache, "v3", "layout.json")
    index = os.path.join(cache, "v3", "manifests", "index", "index.manifest.json")
    log(f"layout.json: {'present' if os.path.exists(layout) else 'MISSING'}"
        f"   index: {'present' if os.path.exists(index) else 'MISSING (cold cache, or never pushed)'}")

    specs, broken, cached_bytes = {}, [], 0
    for pkg, path in manifests(cache):
        # <name>-<version>-<dag hash>.spec.manifest.json, and the dag hash is
        # exactly the key spack.lock uses, which is what makes the forecast below
        # a file-existence test rather than a Spack query.
        stem = spec_name(path)
        dag_hash = stem.rsplit("-", 1)[-1]
        specs[dag_hash] = (pkg, stem)
        try:
            with open(path) as f:
                data = json.load(f)["data"]
        except (OSError, ValueError, KeyError) as e:
            broken.append(f"{stem}: unreadable manifest ({e})")
            continue
        for blob in data:
            want = blob.get("contentLength")
            bp = blob_path(cache, blob["checksum"])
            try:
                have = os.path.getsize(bp)
            except OSError:
                broken.append(f"{stem}: missing blob {blob['checksum'][:12]}")
                continue
            cached_bytes += have
            # Size, not checksum: hashing 1.4 GiB on every run costs minutes and
            # the failure this guards against is a truncated file from an
            # interrupted copy or a full disk, which a size check catches exactly.
            if want is not None and have != want:
                broken.append(f"{stem}: blob {blob['checksum'][:12]} is {have}B, manifest says {want}B")

    log(f"cached specs: {len(specs)}   blob bytes referenced: {human(cached_bytes)}")
    if verbose:
        by_name = {}
        for pkg, _ in specs.values():
            by_name[pkg] = by_name.get(pkg, 0) + 1
        log("packages: " + ", ".join(f"{n}({c})" if c > 1 else n for n, c in sorted(by_name.items())))

    if broken:
        # A warning, not an error: Spack falls back to compiling whatever it
        # cannot extract, so the run still produces a correct stack. What the
        # reader needs is the reason it suddenly takes two hours.
        log(f"::warning::build cache is damaged: {len(broken)} problem(s); it is incomplete "
            "or was copied while being written. Those specs will be compiled from source.")
        for item in broken[:MAX_LISTED]:
            log(f"  BROKEN {item}")
        if len(broken) > MAX_LISTED:
            log(f"  ... and {len(broken) - MAX_LISTED} more")
    else:
        log("integrity: every manifest's blobs are present and the expected size")
    return specs, broken


def forecast(cache, lock_path, specs):
    """Say, per package, whether the install will come from the cache or compile."""
    log()
    log(f"--- cache hit forecast for {lock_path}")
    try:
        with open(lock_path) as f:
            lock = json.load(f)
    except (OSError, ValueError) as e:
        log(f"::warning::cannot read {lock_path}: {e}")
        return
    concrete = lock.get("concrete_specs", {})
    hits, misses, external = [], [], []
    for dag_hash, node in concrete.items():
        label = f"{node.get('name','?')}@{node.get('version','?')}"
        if node.get("external_path") or node.get("external"):
            external.append(label)
        elif dag_hash in specs:
            hits.append(label)
        else:
            misses.append((label, dag_hash))
    log(f"{len(hits)} of {len(hits) + len(misses)} buildable specs are in the cache "
        f"({len(external)} external, never cached)")
    if misses:
        log(f"will be COMPILED ({len(misses)}):")
        for label, dag_hash in sorted(misses)[:MAX_LISTED]:
            # A same-name/different-hash entry is the signal that the cache is
            # complete but was built against a different image or fabric profile:
            # nothing is wrong with it, it simply does not apply here.
            same = sorted(stem for pkg, stem in specs.values() if pkg == label.split("@")[0])
            note = f"   (cache has {', '.join(same)} — different hash)" if same else ""
            log(f"  {label} {dag_hash[:12]}{note}")
        if len(misses) > MAX_LISTED:
            log(f"  ... and {len(misses) - MAX_LISTED} more")
    if hits and not misses:
        log("every buildable spec is cached: this run should install from binaries only")


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cache = argv[1]
    lock = argv[argv.index("--lock") + 1] if "--lock" in argv else None
    specs, broken = inventory(cache, verbose=not lock)
    if lock:
        forecast(cache, lock, specs)
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
