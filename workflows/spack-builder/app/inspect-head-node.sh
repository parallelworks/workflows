#!/usr/bin/env bash
# inspect-head-node.sh RUNDIR APP_DIR
#
# Runs on the LOGIN (head) node, as a second step of the detect job, and does
# two things the compute-node probe cannot:
#
#   1. Records the head node's own parameters. A login-node build happens here,
#      so its microarchitecture, OS image and toolchain decide what gets
#      compiled -- yet until now only the worker's parameters were ever written
#      down. When a stack misbehaves on the worker, the first question is how
#      the two nodes differ, and that was unanswerable after the fact.
#
#   2. Diffs its headers against the worker's. For a login-node build, a header
#      present on the worker but missing HERE cannot be linked against, even
#      though the hardware supports the feature -- the classic split-image
#      failure, and one that otherwise surfaces as a configure error hours into
#      a compile. That case fails the run immediately and loudly. For a worker
#      build (service_build_on=compute) the head does not compile, so the same
#      finding is only reported.
#
#   3. Diffs the site externals discovered on each node. The build uses the
#      worker's either way; the diff is logged so a split image is visible.
#
# The reverse case -- present here, missing on the worker -- is reported as a
# warning rather than an error: it builds fine and may still run, because the
# runtime library can be present while only the -devel headers are absent. It
# is logged because it is the shape of a genuine runtime failure and is worth
# seeing before someone spends a day on it.

set -uo pipefail

RUNDIR="${1:?usage: inspect-head-node.sh RUNDIR APP_DIR}"
APP_DIR="${2:?usage: inspect-head-node.sh RUNDIR APP_DIR}"

HEAD_ENV="${RUNDIR}/headers.head.env"
COMPUTE_ENV="${RUNDIR}/headers.compute.env"

log() { printf '[head] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Head node parameters.
# ---------------------------------------------------------------------------
printf '\n=== [head] login node parameters ===\n'
log "host:      $(hostname)"
eval "$(bash "${APP_DIR}/cpu-counts.sh")"
log "cpus:      ${CPUS_PHYSICAL} physical cores, ${CPUS_LOGICAL} logical"
log "memory:    $(awk '/MemTotal/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo 2>/dev/null || echo '?')"
log "kernel:    $(uname -r)"
log "os:        $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || echo unknown)"
log "glibc:     $(getconf GNU_LIBC_VERSION 2>/dev/null || echo '?')"
log "gcc:       $(gcc -dumpfullversion 2>/dev/null || gcc -dumpversion 2>/dev/null || echo '<none>')"

HEAD_TARGET=""; HEAD_ARCH=""
spack_root="${service_install_prefix:-}"
if [ -n "$spack_root" ] && [ -f "${spack_root}/share/spack/setup-env.sh" ]; then
  # shellcheck disable=SC1091
  . "${spack_root}/share/spack/setup-env.sh"
  HEAD_TARGET="$(spack arch -t 2>/dev/null || echo '')"
  HEAD_ARCH="$(spack arch 2>/dev/null || echo '')"
fi
log "spack target: ${HEAD_TARGET:-<unknown>} (arch=${HEAD_ARCH:-<unknown>})"

# The CUDA toolkit used for linking lives here, not on the worker.
if command -v nvcc >/dev/null 2>&1; then
  log "nvcc:      $(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9.]*\).*/\1/p')"
else
  log "nvcc:      <none on head node>"
fi

# The head/worker target split is exactly what resolve-target.py exists to
# reconcile, so print both side by side while the numbers are in hand.
if [ -f "${RUNDIR}/fabric.env" ]; then
  # shellcheck disable=SC1091
  ( . "${RUNDIR}/fabric.env" 2>/dev/null
    printf '[head] compute target: %s (arch=%s) on %s\n' \
      "${BUILD_TARGET:-<unknown>}" "${BUILD_ARCH:-<unknown>}" "${DETECT_HOST:-<unknown>}"
    if [ -n "${BUILD_TARGET:-}" ] && [ -n "${HEAD_TARGET}" ] && [ "${BUILD_TARGET}" != "${HEAD_TARGET}" ]; then
      printf '::notice::head node (%s) and compute node (%s) differ in microarchitecture; resolve-target.py decides what is built\n' \
        "${HEAD_TARGET}" "${BUILD_TARGET}"
    fi
  )
fi

# ---------------------------------------------------------------------------
# 2. Headers on this node.
# ---------------------------------------------------------------------------
bash "${APP_DIR}/probe-headers.sh" "${HEAD_ENV}" head

# ---------------------------------------------------------------------------
# 3. Diff against the worker.
# ---------------------------------------------------------------------------
if [ ! -f "${COMPUTE_ENV}" ]; then
  # Not an error: with full overrides the detect job is skipped and no worker is
  # ever allocated, so there is nothing to compare against.
  printf '\n::notice::no compute-node header probe at %s; skipping head/compute header comparison\n' "${COMPUTE_ENV}"
  exit 0
fi

printf '\n=== [head] header comparison: compute vs head ===\n'

missing_on_head=""
missing_on_compute=""

# Subshells so neither file's variables leak into the other's namespace.
names="$(grep -oE '^HDR_[A-Z0-9_]+="' "${COMPUTE_ENV}" | sed -e 's/^HDR_//' -e 's/="$//' \
         | grep -vE '^(LABEL|HOST)$' | grep -v '_PATH$')"

for name in ${names}; do
  c="$( . "${COMPUTE_ENV}"; eval "printf '%s' \"\${HDR_${name}:-0}\"" )"
  h="$( . "${HEAD_ENV}";    eval "printf '%s' \"\${HDR_${name}:-0}\"" )"
  if [ "$c" = "1" ] && [ "$h" = "1" ]; then
    printf '  both     %s\n' "$name"
  elif [ "$c" = "1" ] && [ "$h" = "0" ]; then
    printf '  HEAD-ONLY-MISSING  %s -- on compute, NOT on head\n' "$name"
    missing_on_head="${missing_on_head} ${name}"
  elif [ "$c" = "0" ] && [ "$h" = "1" ]; then
    printf '  head only          %s -- on head, NOT on compute\n' "$name"
    missing_on_compute="${missing_on_compute} ${name}"
  else
    printf '  neither  %s\n' "$name"
  fi
done

if [ -n "${missing_on_compute# }" ]; then
  printf '::warning title=Header present on head but not compute::%s -- a login-node build links here and may fail to resolve at runtime on the worker\n' \
    "${missing_on_compute# }"
fi

if [ -n "${missing_on_head# }" ]; then
  if [ "${service_build_on:-login}" = "compute" ]; then
    printf '::notice title=Headers missing on the head node::%s present on the compute node but absent on the head node. Not a problem for this run: the build runs on a worker.\n' \
      "${missing_on_head# }"
  else
    printf '::error title=Headers missing on the build host::%s present on the compute node but absent on the head node. The build links HERE, so these cannot be used no matter what the worker supports -- the images differ. Install the matching -devel packages on the head node, run the build on a worker instead, or expect the corresponding externals to be pruned and rebuilt from source.\n' \
      "${missing_on_head# }" >&2
    exit 1
  fi
else
  printf '\n=== [head] header sets are compatible ===\n'
fi

# ---------------------------------------------------------------------------
# 4. Site externals: head vs compute. Informational -- the build applies the
#    compute file wherever it runs (find-externals.sh).
# ---------------------------------------------------------------------------
HEAD_EXT="${externals_head:-${RUNDIR}/externals.head.yaml}"
COMPUTE_EXT="${externals_compute:-${RUNDIR}/externals.compute.yaml}"
printf '\n=== [head] site externals: head vs compute ===\n'
if [ -f "${HEAD_EXT}" ] && [ -f "${COMPUTE_EXT}" ]; then
  if diff -u --label "head ($(hostname))" --label "compute ($(sed -n 's/^DETECT_HOST="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${RUNDIR}/fabric.env" 2>/dev/null))" \
       "${HEAD_EXT}" "${COMPUTE_EXT}"; then
    printf '[head] identical: both nodes discovered the same externals\n'
  else
    printf '::notice::the head and compute nodes discovered different site externals (diff above); the build uses the compute node'"'"'s\n'
  fi
else
  printf '[head] skipped: head=%s compute=%s\n' \
    "$([ -f "${HEAD_EXT}" ] && echo present || echo missing)" \
    "$([ -f "${COMPUTE_EXT}" ] && echo present || echo missing)"
fi
