"""Print the packages that must be excluded from the generated module tree.

    spack python external-modules.py ENV/spack.lock

External packages get no modulefile, but `autoload: direct` still lists them as
requirements of the modules that depend on them -- and environment-modules treats
a missing requirement as a hard error that aborts the WHOLE load. The symptom is
nasty because it is silent in the wrong direction:

    $ module load openmpi/5.0.10-gcc-14.2.0
    ERROR: Unable to locate a modulefile for 'glibc/2.34-none-none'
    $ which mpirun
    /opt/amazon/openmpi/bin/mpirun      # <- the SYSTEM MPI, not the one built

Nothing loads, the shell keeps the system MPI, and a user can easily benchmark
the wrong stack without noticing.

The set of externals is site-specific -- it is whatever `spack external find`
turned up on that image, plus glibc -- so it cannot be hardcoded in the template.
Deriving it from the concretized lockfile keeps the exclusion correct on any
cluster.
"""

import json
import sys

# Not external, but an internal shim that should never appear as a module.
ALWAYS_EXCLUDE = ["compiler-wrapper"]


def main(argv):
    with open(argv[1]) as f:
        lock = json.load(f)
    names = {s["name"] for s in lock["concrete_specs"].values() if s.get("external")}
    names.update(ALWAYS_EXCLUDE)
    print(",".join(sorted(names)))


if __name__ == "__main__":
    main(sys.argv)
