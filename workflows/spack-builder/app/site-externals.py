"""Move the managed site externals between the site scope and a per-node file.

    spack python site-externals.py clear   SITE_PACKAGES_YAML PKG...
    spack python site-externals.py extract SITE_PACKAGES_YAML OUT_YAML PKG...
    spack python site-externals.py apply   SITE_PACKAGES_YAML IN_YAML PKG...

Driven by find-externals.sh, which owns the PKG list. Only the named packages
are touched: the same site packages.yaml also carries the registered compilers
(the system gcc and the built stack gcc), and those must survive every call.

`clear` exists because `spack external find` skips any spec that is already
configured in ANY scope (spack.detection.update_configuration). Without it, the
second node to run discovery would add nothing and its file would silently be a
copy of the first node's.
"""

import os
import sys

import yaml


def load(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        return yaml.safe_load(f) or {}


def save(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    action, site = argv[1], argv[2]

    data = load(site)
    packages = data.get("packages") or {}

    if action == "clear":
        names = argv[3:]
        for name in names:
            packages.pop(name, None)
        data["packages"] = packages
        save(site, data)
        return 0

    if action == "extract":
        out, names = argv[3], argv[4:]
        picked = {n: packages[n] for n in names if n in packages}
        save(out, {"packages": picked})
        return 0

    if action == "apply":
        src, names = argv[3], argv[4:]
        incoming = (load(src).get("packages") or {})
        for name in names:
            packages.pop(name, None)
        for name in names:
            if name in incoming:
                packages[name] = incoming[name]
        data["packages"] = packages
        save(site, data)
        return 0

    print("unknown action %r" % action, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv) or 0)
