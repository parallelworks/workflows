#!/usr/bin/env bash
# check-exec.sh
#
# Executes the binaries that were just built, ON A COMPUTE NODE.
#
# This is the only check in the workflow that can distinguish a correct stack
# from one that cannot run. Everything else -- the build exiting 0, the endpoint
# answering HTTP -- passes identically either way. Run fair-mastodon proved it:
# it passed every recorded criterion while 45 specs in the environment, three
# GROMACS builds among them, carried skylake_avx512 (AVX-512) instructions that
# the zen2 worker cannot execute. `spack install` succeeded because compiling
# AVX-512 on an AVX-512 login node is perfectly legal; only running the result
# on the worker reveals it.
#
# It therefore has to be its own job. The build runs on the LOGIN node, where
# the wrong ISA executes fine -- so a check there proves nothing. This script is
# submitted to the scheduler so it lands on the same class of hardware the stack
# was built for.
#
# A binary built for the wrong microarchitecture dies on SIGILL (exit 132),
# which is called out by name because that exit status is the entire point of
# this check.

set -uo pipefail

EXEC_STATUS_FILE="${PWD}/EXEC_STATUS"
rm -f "$EXEC_STATUS_FILE"
trap 'rc=$?; printf "%s\n" "$rc" > "$EXEC_STATUS_FILE"; exit $rc' EXIT

# Written first so a cancel at any later point finds it (repo convention: the
# cancel script must exist before anything else can fail).
cat > cancel.sh <<'CANCEL'
#!/bin/bash
echo "[cancel] execution check stopped; nothing to clean up"
exit 0
CANCEL
chmod +x cancel.sh

log() { printf '[exec] %s\n' "$*"; }

printf '\n=== [exec] execution check on %s ===\n' "$(hostname)"
log "cores: $(nproc 2>/dev/null || echo '?')"

# A dry run installs nothing, so there is nothing to execute -- and failing here
# would fail every concretize_only run, which is the cheap validation path.
if [ "${service_concretize_only:-false}" = "true" ]; then
  printf '::notice::concretize_only run: nothing was installed, so there are no binaries to execute\n'
  exit 0
fi

spack_root="${service_install_prefix:-}"
if [ -z "$spack_root" ] || [ ! -f "${spack_root}/share/spack/setup-env.sh" ]; then
  printf '::error title=Error::no Spack at %s; cannot locate the built binaries\n' "${spack_root:-<unset>}" >&2
  exit 1
fi
# shellcheck disable=SC1091
. "${spack_root}/share/spack/setup-env.sh"

ENV_DIR="${env_dir:?env_dir not set by inputs.sh}"
[ -d "$ENV_DIR" ] || { printf '::error title=Error::no spack environment at %s\n' "$ENV_DIR" >&2; exit 1; }

log "spack target here: $(spack arch -t 2>/dev/null || echo '?')"
log "environment:       ${ENV_DIR}"

# Hash AND prefix: the hash is what addresses the spec for `spack load`, below.
specs="$(spack -e "$ENV_DIR" find --format '{hash} {prefix}' gromacs 2>/dev/null)"
if [ -z "$specs" ]; then
  printf '::error title=Error::no gromacs installs found in %s\n' "$ENV_DIR" >&2
  exit 1
fi

# NOT launched with srun, deliberately. This job is submitted to the compute
# partition, so the script is ALREADY executing on a worker -- srun would only
# add a launcher that cannot start half of these binaries. On this platform
# `srun --mpi=list` offers none, cray_shasta and pmi2, with no pmix plugin, and
# OpenMPI 5 dropped native PMI2 in favour of PMIx: `srun ./gmx_mpi` therefore
# cannot launch the two OpenMPI-linked GROMACS builds (the CUDA one among them),
# though they run perfectly standalone via singleton init. That SLURM has
# libpmi2.so but no slurm/pmi2.h or pmix.h is the same split the header probe
# reports -- the runtime is there, the headers to build against are not.
#
# So: run directly, and fall back to the binary's OWN launcher when its MPI
# cannot do singleton init (MPICH). No PMI negotiation is involved either way.

# If this landed on the same host that ran the build, nothing about the worker
# was exercised and the check must not imply otherwise. Happens when the cluster
# is configured scheduler=false, where there is no separate compute node at all.
HEAD_ENV="$(dirname "${env_dir}")/headers.head.env"
if [ -f "$HEAD_ENV" ]; then
  head_host="$( . "$HEAD_ENV" 2>/dev/null; printf '%s' "${HDR_HOST:-}" )"
  if [ -n "$head_host" ] && [ "$head_host" = "$(hostname)" ]; then
    printf '::warning title=Execution check ran on the build host::%s is the node that built the stack, so this check cannot detect a microarchitecture mismatch with the compute nodes. Submit with scheduler=true to exercise a worker.\n' \
      "$(hostname)"
  fi
fi

# Two distinct verdicts, because they mean different things:
#   isa_failures   -- SIGILL: the binary cannot execute on this CPU. This is the
#                     bug this job exists to catch, and it fails the run.
#   other_failures -- the binary started but its MPI could not initialise here
#                     (no OFI provider, no process manager, ...). Real, worth
#                     seeing, but a property of the launch environment rather
#                     than of what was compiled -- so it warns instead of
#                     failing, or every cluster without an EFA device would fail
#                     a run over intel-oneapi-mpi.
isa_failures=0
other_failures=0
checked=0

# `gmx_mpi -version` calls MPI_Init. OpenMPI supports singleton init and runs
# standalone; MPICH built --with-pmi=pmi2 does not -- it tries to reach a process
# manager and dies with "write_line error; fd=-1 ... Bad file descriptor" (exit
# 139). That is a launch-environment failure, not a broken binary, and failing
# the run on it would block builds for the wrong reason. So a non-SIGILL failure
# is retried under the binary's OWN launcher, found from the MPI it actually
# links against rather than from whatever mpiexec happens to be on PATH.
launcher_for() {
  local bin="$1" lib prefix
  lib="$(ldd "$bin" 2>/dev/null | grep -oE '/[^ ]*/lib(mpi|mpich)[^ ]*\.so[^ ]*' | head -1)"
  [ -n "$lib" ] || return 1
  prefix="$(dirname "$(dirname "$lib")")"
  for cand in "${prefix}/bin/mpiexec" "${prefix}/bin/mpirun"; do
    [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

report_ok() {
  printf '%s\n' "$1" | grep -iE 'GROMACS version|SIMD instructions|GPU support|MPI library:' | sed 's/^/    /'
}

# Run a binary with the package's OWN run environment, as `spack load` or the
# module would give a user. Invoking the bare path is not representative and
# produces false failures: intel-oneapi-mpi needs FI_PROVIDER_PATH to find the
# libfabric providers it ships, and without it MPI_Init aborts with
# "OFI fi_getinfo() failed ... No data available" on a perfectly good binary.
# `spack load --sh` is used rather than `module load` deliberately -- it emits
# the same environment without touching the TCL module tree, whose name clashes
# in a GPU build would otherwise mask what this check is testing.
in_pkg_env() {
  local hash="$1" bin="$2" env_sh
  ( env_sh="$(spack -e "$ENV_DIR" load --sh "/$hash" 2>/dev/null || true)"
    [ -n "$env_sh" ] && eval "$env_sh"
    "$bin" -version 2>&1 )
}

# `<<<` not a pipe: a `while` in a pipeline runs in a subshell and the failure
# counters incremented inside it would be discarded at the end of the loop.
while read -r hash prefix; do
  [ -n "${prefix:-}" ] || continue
  bin=""
  for cand in "${prefix}/bin/gmx_mpi" "${prefix}/bin/gmx"; do
    [ -x "$cand" ] && { bin="$cand"; break; }
  done
  if [ -z "$bin" ]; then
    log "WARNING: no gmx/gmx_mpi binary under ${prefix}"
    continue
  fi

  checked=$((checked + 1))
  printf '\n--- %s\n' "$bin"

  # -version runs the binary and prints the SIMD level it was compiled for,
  # which is precisely the value that must match this node.
  out="$( in_pkg_env "$hash" "$bin" )"
  rc=$?

  # SIGILL is the whole point of this check and is never retried: the binary
  # carries instructions this CPU cannot execute, whatever the launcher.
  if [ $rc -eq 132 ]; then
    isa_failures=$((isa_failures + 1))
    printf '%s\n' "$out" | tail -10 | sed 's/^/    /'
    printf '::error title=Illegal instruction on the compute node::%s died with SIGILL (exit 132) on %s. It was compiled for a microarchitecture this node cannot execute -- the symptom of a stack built for the login node ISA. Check the target census of the environment.\n' \
      "$bin" "$(hostname)" >&2
    continue
  fi

  if [ $rc -eq 0 ]; then
    report_ok "$out"
    log "OK (exit 0)"
    continue
  fi

  if launcher="$(launcher_for "$bin")"; then
    log "exit ${rc} standalone; retrying under $(basename "$launcher") (MPI singleton init is not supported by every MPI)"
    out2="$( env_sh="$(spack -e "$ENV_DIR" load --sh "/$hash" 2>/dev/null || true)"
             [ -n "$env_sh" ] && eval "$env_sh"
             "$launcher" -n 1 "$bin" -version 2>&1 )"
    rc2=$?
    if [ $rc2 -eq 0 ]; then
      report_ok "$out2"
      log "OK under ${launcher} (exit 0)"
      continue
    fi
    if [ $rc2 -eq 132 ]; then
      isa_failures=$((isa_failures + 1))
      printf '%s\n' "$out2" | tail -10 | sed 's/^/    /'
      printf '::error title=Illegal instruction on the compute node::%s died with SIGILL (exit 132) under %s on %s.\n' \
        "$bin" "$launcher" "$(hostname)" >&2
      continue
    fi
    other_failures=$((other_failures + 1))
    printf '%s\n' "$out2" | tail -15 | sed 's/^/    /'
    printf '::warning title=Built binary did not run here::%s exited %s standalone and %s under %s on %s. Not an ISA fault (no SIGILL) -- most often an MPI that cannot initialise on this node, e.g. no OFI provider.\n' \
      "$bin" "$rc" "$rc2" "$launcher" "$(hostname)"
    continue
  fi

  other_failures=$((other_failures + 1))
  printf '%s\n' "$out" | tail -15 | sed 's/^/    /'
  printf '::warning title=Built binary did not run here::%s exited %s on %s and no MPI launcher was found for it\n' \
    "$bin" "$rc" "$(hostname)"
done <<< "$specs"

printf '\n=== [exec] checked %s binaries: %s ISA failures, %s environment failures ===\n' \
  "$checked" "$isa_failures" "$other_failures"

if [ "$checked" -eq 0 ]; then
  printf '::error title=Error::no runnable gromacs binary was found to check\n' >&2
  exit 1
fi

if [ "$isa_failures" -gt 0 ]; then
  printf '::error title=Error::%s binaries could not execute on %s (SIGILL)\n' "$isa_failures" "$(hostname)" >&2
  exit 1
fi

# Every binary failing is not an environment quirk any more -- nothing was
# actually proven to run, which is the same as having no check at all.
if [ "$other_failures" -ge "$checked" ]; then
  printf '::error title=Error::none of the %s binaries ran on %s; the check proved nothing\n' "$checked" "$(hostname)" >&2
  exit 1
fi

printf '::notice::%s of %s built binaries executed on %s with no illegal-instruction faults\n' \
  "$((checked - other_failures))" "$checked" "$(hostname)"
