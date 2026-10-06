"""Reconcile the target detected on a compute node with what this build host can emit.

    spack python resolve-target.py [WANTED_TARGET]

Prints shell-sourceable KEY=VALUE lines:

    TARGET          the microarchitecture to build for
    TARGET_STATUS   exact | fallback | common | host
    TARGET_NOTE     human-readable explanation

Exits non-zero when the two targets are not in the same CPU family, because no
target can satisfy both and building anyway produces binaries that cannot run.

Why this exists
---------------
The build runs on the login node while the stack is meant for the compute nodes,
and the two are routinely different instance types. Spack will only emit code the
BUILD HOST can run, and `packages: all: target: [...]` is a *preference*, so a
target the host cannot support is silently dropped instead of failing. On the
cluster this was written for, the login node is skylake_avx512 and the workers are
cascadelake: asking for cascadelake quietly produced skylake_avx512 binaries.

Two directions, two very different consequences:

  * worker target is OLDER than the host (e.g. host cascadelake, worker skylake):
    the host can emit it, so build exactly for the worker. Correct and optimal.

  * worker target is NEWER than the host on the SAME lineage (e.g. host
    skylake_avx512, worker cascadelake): the host cannot emit it at all. Fall back
    to the host's own target. Those binaries still RUN on the worker -- a newer
    microarchitecture on the same lineage is a superset -- they just leave the
    newer instructions unused. That is a performance trade, not a correctness bug,
    but it must be said out loud rather than discovered in a benchmark. Build on a
    worker node instead if the last few percent matter.

  * the two are INCOMPARABLE -- neither is an ancestor of the other, which is what
    different vendors means: an Intel login node and AMD compute nodes, or the
    reverse. Falling back to the host's target here is WRONG, and silently so.
    aws `c5n.9xlarge` login nodes report skylake_avx512 while the `g6`/`g5` GPU
    partitions are AMD EPYC (zen3): AVX-512 is not a subset of zen3, it is absent
    from it, so those binaries SIGILL on the worker. Verified with archspec on the
    aws login node -- `zen3 <= skylake_avx512` and `skylake_avx512 <= zen3` are
    both False. Build for the best COMMON ancestor instead (x86_64_v3 for that
    pair): the most capable target both machines actually implement.

The dangerous case this prevents is the reverse of what people expect: building
for a target the compute node does NOT implement yields SIGILL at run time, which
is why the wanted target is never trusted blindly.
"""

import shlex
import sys

from spack.vendor.archspec import cpu


def main(argv):  # noqa: C901
    wanted = (argv[1] if len(argv) > 1 else "").strip()
    host = cpu.host()

    def emit(target, status, note):
        # Shell-quoted: the note contains spaces and parentheses, and the caller
        # consumes this with `eval`.
        print("TARGET=%s" % shlex.quote(target))
        print("TARGET_STATUS=%s" % shlex.quote(status))
        print("TARGET_NOTE=%s" % shlex.quote(note))

    if not wanted:
        emit(host.name, "host",
             "no target from detection; using this build host's own target")
        return

    if wanted not in cpu.TARGETS:
        emit(host.name, "host",
             "unknown target %r; using this build host's own target" % wanted)
        return

    target = cpu.TARGETS[wanted]
    if target <= host:
        emit(wanted, "exact",
             "build host (%s) can emit the compute-node target" % host.name)
        return

    if host <= target:
        emit(host.name, "fallback",
             "build host (%s) cannot emit %s; building for %s instead, which RUNS on "
             "%s but does not use its newer instructions. Set 'Run the build on' to a "
             "worker node to target it exactly." % (host.name, wanted, host.name, wanted))
        return

    # Incomparable. Nothing the host emits natively is guaranteed to run on the
    # worker, so neither target is an answer.
    if target.family != host.family:
        print("::error title=Error::compute node is %s (%s) and the build host is %s "
              "(%s): no target can serve both. Set 'Run the build on' to a worker node."
              % (wanted, target.family, host.name, host.family), file=sys.stderr)
        return 1

    # `ancestors` is ordered most-specific first, so the first one the host can
    # also emit is the most capable target BOTH machines implement.
    common = next((a.name for a in target.ancestors if a <= host), None)
    if common is None:
        emit(host.family.name, "common",
             "no common ancestor of %s and %s beyond the bare %s family"
             % (wanted, host.name, host.family))
        return

    emit(common, "common",
         "compute node (%s) and build host (%s) are different lineages, so neither "
         "can run the other's code; building for %s, the most capable target both "
         "implement. Set 'Run the build on' to a worker node to target %s exactly."
         % (wanted, host.name, common, wanted))


if __name__ == "__main__":
    sys.exit(main(sys.argv) or 0)
