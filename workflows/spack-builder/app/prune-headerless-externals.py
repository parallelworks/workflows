"""Drop externals that provide libraries but no development headers.

    spack python prune-headerless-externals.py SITE_PACKAGES_YAML

`spack external find` detects a package from its libraries or binaries, but Spack
then wants to COMPILE against it, which needs headers. Images that ship only the
runtime package and not its `-devel` counterpart therefore produce an external
that looks fine and fails at configure time. This has now bitten three times:

    slurm      runtime, no headers -> mpich +slurm:
               "configure: error: --with-slurm is given but not found"
    rdma-core  runtime, no headers -> ucx +verbs:
               "RDMACM requested but required file (rdma/rdma_cma.h) not found"
    libfabric  runtime, no headers -> openmpi fabrics=ofi:
               "checking for ofi header at /usr/include... not found"

The same cluster can go either way: an AWS image carries the EFA libfabric under
/opt/amazon/efa WITH headers, while a GCE image has /usr/lib64/libfabric.so.1 and
no /usr/include/rdma/fabric.h. So this cannot be decided statically in the
fragment -- it has to be probed per image.

Removing the entry lets Spack build its own copy, which is the right outcome: a
headerless system library is useless as a build dependency. If a package's
externals are all pruned, its `buildable: false` pin is dropped too, otherwise
nothing could satisfy it and concretization would fail outright.
"""

import os
import sys

import yaml

# A header that must exist under <prefix>/include for the external to be usable
# as something other packages compile against.
SENTINEL_HEADERS = {
    "libfabric": "rdma/fabric.h",
    "ucx": "ucp/api/ucp.h",
}


def main(argv):
    path = argv[1]
    if not os.path.exists(path):
        return

    with open(path) as f:
        data = yaml.safe_load(f) or {}
    packages = data.get("packages") or {}

    changed = False
    for name, sentinel in SENTINEL_HEADERS.items():
        cfg = packages.get(name)
        if not isinstance(cfg, dict):
            continue
        externals = cfg.get("externals") or []
        keep = []
        for ext in externals:
            prefix = ext.get("prefix", "")
            header = os.path.join(prefix, "include", sentinel)
            if os.path.exists(header):
                keep.append(ext)
            else:
                changed = True
                print("  pruning %s external at %s (no %s)" % (name, prefix, sentinel))

        if len(keep) == len(externals):
            continue
        if keep:
            cfg["externals"] = keep
        else:
            cfg.pop("externals", None)
            # Without any external left, a not-buildable pin makes the package
            # unsatisfiable rather than merely unavailable.
            if cfg.pop("buildable", None) is False:
                print("  %s: dropped buildable:false so Spack can build its own" % name)
            if not cfg:
                packages.pop(name)
            print("  %s will be built from source" % name)

    if not changed:
        print("  no headerless externals found")
        return

    data["packages"] = packages
    with open(path, "w") as f:
        yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
    print("  updated %s" % path)


if __name__ == "__main__":
    main(sys.argv)
