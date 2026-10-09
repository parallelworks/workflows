"""Download, up front, the source of every spec this install will compile.

    spack -e ENV_DIR python prefetch-sources.py

`spack install` fetches each package's source just before building it, so a
build that fails part way has only downloaded what came before the failure;
dependents of the failed package are never attempted. Fetching everything right
after concretization puts every archive into the source cache
($SPACK_ROOT/var/spack/cache, on the shared filesystem) first. A login-node
build that then fails -- typically a header the login image lacks -- can be
re-run with the build on a worker, which unpacks from that cache and downloads
nothing, so the worker needs no internet. It also turns "this source cannot be
downloaded" into an error minutes into the run rather than hours.

Only what will actually be COMPILED is fetched: externals have no source,
installed specs need nothing, and a spec the binary cache can supply would
download sources that are never used -- on a warm redeploy that is gigabytes
(CUDA, Intel MPI) for a run that compiles nothing. The binary-cache test is
Spack's own (`get_mirrors_for_spec(index_only=True)`), the same index the
installer consults, so it never disagrees with what install then does.

Two details make that true, and both were learned the hard way (gce run
in-oarfish reported "0 from the binary cache" and downloaded 59 archives for an
install that then compiled nothing):

  * The index has to be loaded first. `index_only=True` only reads the
    in-memory index, which a fresh `spack python` process has not populated;
    the installer calls BINARY_INDEX.update() before it looks, and so must this.
  * A spec installed from the binary cache never needs its BUILD-only
    dependencies (cmake, autotools, ...), so the walk does not descend into
    them -- only into link/run dependencies, which must be present at run time.

Prints one line per spec saying whether its source was already cached or had to
be downloaded, then a summary. Exits non-zero if any fetch failed.
"""

import os
import sys

import spack.binary_distribution as bindist
import spack.caches
import spack.deptypes as dt
import spack.environment as ev


def stage_paths(pkg):
    """Source-cache paths of every archive this package's stage will fetch
    (the main source plus any resources)."""
    root = spack.caches.FETCH_CACHE.root
    for st in pkg.stage:
        layout = getattr(st, "mirror_layout", None)
        if layout is not None:
            yield os.path.join(root, layout.path)


def main():
    env = ev.active_environment()
    if env is None:
        print("::error title=Error::prefetch-sources.py needs an active environment (spack -e)",
              file=sys.stderr)
        return 2

    bindist.BINARY_INDEX.update()

    external = installed = binary = 0
    cached, downloaded, failed, uncacheable = [], [], [], []
    seen = set()
    stack = list(env.concrete_roots())

    while stack:
        spec = stack.pop()
        if spec.dag_hash() in seen:
            continue
        seen.add(spec.dag_hash())
        label = spec.cformat("{name}{@version} {/hash:7}")
        if spec.external:
            external += 1
            continue
        if spec.installed:
            # Its whole link/run closure is installed too.
            installed += 1
            continue
        if bindist.get_mirrors_for_spec(spec, index_only=True):
            binary += 1
            stack.extend(spec.dependencies(deptype=dt.LINK | dt.RUN))
            continue
        stack.extend(spec.dependencies())
        pkg = spec.package
        if not pkg.has_code:
            continue

        # A fetcher Spack will not cache (a git branch, say) is downloaded again
        # by every build, so a worker re-run would still need the internet.
        if any(not st.default_fetcher.cachable for st in pkg.stage):
            uncacheable.append(label)
        paths = list(stage_paths(pkg))
        was_cached = bool(paths) and all(os.path.exists(p) for p in paths)
        try:
            with pkg.stage:
                pkg.do_fetch()
        except Exception as e:  # report every failure, not just the first
            failed.append(label)
            print("  FAILED      %s: %s" % (label, e), flush=True)
            continue
        if was_cached:
            cached.append(label)
            print("  cached      %s" % label, flush=True)
        else:
            downloaded.append(label)
            print("  downloaded  %s" % label, flush=True)

    print("prefetch: %d to compile -- %d already in the source cache, %d downloaded, %d failed "
          "(skipped: %d external, %d installed, %d from the binary cache)"
          % (len(cached) + len(downloaded) + len(failed), len(cached), len(downloaded),
             len(failed), external, installed, binary))
    print("source cache: %s" % spack.caches.FETCH_CACHE.root)
    if uncacheable:
        print("::warning::not cacheable, so a re-run on a worker downloads these again: %s"
              % ", ".join(uncacheable))
    if failed:
        print("::error title=Error::could not fetch the source of %s" % ", ".join(failed),
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
