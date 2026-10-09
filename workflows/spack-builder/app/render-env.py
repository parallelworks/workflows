"""Render spack.yaml from the environment template plus a fabric fragment.

Run with Spack's own interpreter (`spack python render-env.py ...`) so PyYAML is
available without adding a dependency to the cluster image.

    spack python render-env.py FRAGMENT TEMPLATE OUT TARGET GPU_ACTIVE CUDA_ARCH MODULE_ROOT

It must be a real file: `spack python -` does not read a script from stdin the
way `python -` does -- it tries to open "-" as a filename.

The `packages:` section is merged STRUCTURALLY, not by text substitution. Both
sides legitimately configure the same package: the template pins MPI versions
globally, the fragment sets the fabric-specific variants. Splicing the fragment
in as text produced a YAML file with two `openmpi:` keys, which Spack rejects
outright ("found duplicate key"). Merging the parsed dicts -- and concatenating
`require` lists rather than letting one win -- is what lets both live together.
"""

import sys

import yaml

SPEC_PLACEHOLDERS = ("__MPI_SPECS__", "__CUDA_AWARE_MPI_SPECS__",
                     "__GROMACS_SPECS__", "__GROMACS_GPU_SPECS__")


def merge_packages(base, extra):
    """Deep-merge fragment package config into the template's.

    `require` lists are concatenated so a global version pin and a fabric
    variant requirement both apply; any other key the fragment sets wins.
    """
    for pkg, cfg in (extra or {}).items():
        if pkg not in base:
            base[pkg] = cfg
            continue
        merged = dict(base[pkg])
        for key, value in cfg.items():
            if key == "require":
                old = merged.get("require", [])
                old = [old] if isinstance(old, str) else list(old)
                new = [value] if isinstance(value, str) else list(value)
                merged["require"] = old + [v for v in new if v not in old]
            else:
                merged[key] = value
        base[pkg] = merged
    return base


def main(argv):
    frag_path, tmpl_path, out_path, target, gpu_active, cuda_arch, module_root = argv[1:8]
    gpu_active = gpu_active == "1"

    with open(frag_path) as f:
        frag = yaml.safe_load(f)["fabric"]

    def specs_block(key, only_if=True):
        if not only_if:
            return ""
        items = [s.replace("__CUDA_ARCH__", cuda_arch) for s in frag.get(key, [])]
        return "\n".join('    - "%s"' % s for s in items)

    with open(tmpl_path) as f:
        tmpl = f.read()

    # The fragment's packages are merged after parsing, so drop the placeholder line.
    tmpl = "\n".join(l for l in tmpl.split("\n") if l.strip() != "__FABRIC_PACKAGES__")

    for placeholder, value in [
        ("__TARGET__", target),
        ("__MODULE_ROOT__", module_root),
        ("__MPI_SPECS__", specs_block("mpi_specs")),
        ("__CUDA_AWARE_MPI_SPECS__", specs_block("cuda_aware_mpi_specs", gpu_active)),
        ("__GROMACS_SPECS__", specs_block("gromacs_specs")),
        ("__GROMACS_GPU_SPECS__", specs_block("gromacs_gpu_specs", gpu_active)),
    ]:
        tmpl = tmpl.replace(placeholder, value)

    leftover = [p for p in SPEC_PLACEHOLDERS + ("__TARGET__", "__MODULE_ROOT__",
                                                "__FABRIC_PACKAGES__", "__CUDA_ARCH__")
                if p in tmpl]
    if leftover:
        sys.exit("render-env: unsubstituted placeholders remain: %s" % ", ".join(leftover))

    env = yaml.safe_load(tmpl)
    env["spack"]["packages"] = merge_packages(env["spack"].get("packages", {}),
                                              frag.get("packages", {}))

    # cuda_arch has to reach EVERY package that consumes CUDA, not only the ones
    # a spec string names. Setting it per-spec covered gromacs and missed the
    # transitive ones: on gce2 run funky-pigeon, ucx and gdrcopy concretized with
    # `cuda_arch:=none` because nothing named them, and gdrcopy's build then ran
    #   nvcc --generate-code arch=compute_none,code=sm_none
    #   nvcc fatal : Unsupported gpu architecture 'compute_none'
    # after 1h28m of compiling. A preference under `packages: all:` applies to
    # any package that HAS the variant and leaves the rest untouched, which is
    # the only place that reaches a dependency no spec mentions.
    # Reuse must be constrained to the chosen target, or it silently defeats it.
    # `packages: all: target:` is a PREFERENCE, and `reuse: true` outranks a
    # preference: an installed spec for a different microarchitecture satisfies
    # the request, so Spack takes it. On aws run fair-mastodon the target
    # resolved correctly to x86_64_v3 for a zen2 worker, and the environment
    # still came out with 45 skylake_avx512 specs -- fftw, gcc-runtime, curl and
    # the three CPU gromacs builds -- reused wholesale from the Intel login
    # node's earlier CPU stack. Those carry AVX-512 and cannot execute on zen2,
    # so the run "passed" with a stack that would SIGILL on the nodes it was
    # built for. Nothing in the pass criteria can see that.
    #
    # `include` keeps reuse working for everything already at the right target
    # (which is the normal redeploy case, where it is the whole point) and
    # forbids it for everything else, from the local install tree and the build
    # cache alike.
    env["spack"].setdefault("concretizer", {})["reuse"] = {
        "include": ["target=%s" % target]
    }

    # A GPU environment contains a ~cuda and a +cuda build of the same
    # name/version/compiler for openmpi, gromacs, fftw, hwloc and more, and the
    # CPU projections name both identically -- so `module tcl refresh` aborts
    # with "Name clashes detected in module files" AFTER a completely successful
    # install (gce2 run caring-warthog: the whole GPU stack built and pushed,
    # then the run failed on naming). Two changes, GPU builds only:
    #   * a -cuda suffix, so a user can SEE which module is the CUDA build. It
    #     marks exactly one thing: THIS package is CUDA-enabled. The constraint
    #     is `+cuda` on the package itself -- NOT `^mpi+cuda`, which was the
    #     first attempt and silently mislabelled three builds in four. A variant
    #     constraint on a VIRTUAL is dropped, so `^mpi+cuda` degenerates to
    #     `^mpi` and matched every MPI build: run moral-silkworm named its
    #     mpich~cuda and intel-oneapi-mpi GROMACS "-cuda" although neither they
    #     nor their MPI had CUDA at all. Constrain the concrete provider, or the
    #     package, and matching behaves.
    #     `+cuda ^mpi` (package is CUDA-enabled AND links an MPI) comes first so
    #     such a package keeps the MPI in its name; `+cuda` alone then catches
    #     the CUDA-aware MPIs themselves, which PROVIDE mpi rather than depend
    #     on it and so never match the first rule.
    #   * a hash suffix, because a suffix alone is not sufficient: pmix and prrte
    #     appear twice with IDENTICAL variants, differing only in which hwloc
    #     they were built against, and no projection can express that.
    if gpu_active:
        tcl = env["spack"]["modules"]["default"]["tcl"]
        tcl["projections"] = {
            "+cuda ^mpi": "{name}/{version}-{^mpi.name}-{^mpi.version}-cuda",
            "+cuda": "{name}/{version}-{compiler.name}-{compiler.version}-cuda",
            **tcl.get("projections", {}),
        }
        tcl["hash_length"] = 7

    if gpu_active and cuda_arch:
        all_cfg = env["spack"]["packages"].setdefault("all", {})
        existing = all_cfg.get("variants", "")
        if isinstance(existing, list):
            all_cfg["variants"] = existing + ["cuda_arch=%s" % cuda_arch]
        else:
            all_cfg["variants"] = (existing + " " if existing else "") + \
                                  "cuda_arch=%s" % cuda_arch

    # The stack compiler is written down only in the template. Report it so the
    # caller can install and register it before concretizing -- `spack python -c`
    # takes a single statement, so a multi-line inline reader is not an option.
    req = env["spack"]["packages"]["c"]["require"]
    gcc_spec = req[0] if isinstance(req, list) else req

    with open(out_path, "w") as f:
        yaml.safe_dump(env, f, default_flow_style=False, sort_keys=False, width=100)

    print("rendered %s: target=%s gpu=%s cuda_arch=%s specs=%d"
          % (out_path, target, gpu_active, cuda_arch if gpu_active else "n/a",
             len(env["spack"]["specs"])))
    print("GCC_SPEC=%s" % gcc_spec)


if __name__ == "__main__":
    main(sys.argv)
