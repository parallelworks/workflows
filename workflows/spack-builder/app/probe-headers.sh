#!/usr/bin/env bash
# probe-headers.sh OUTFILE LABEL
#
# Records which development headers exist on THIS node, as sourceable
# HDR_<NAME>="0|1" / HDR_<NAME>_PATH="..." lines, and prints a readable table.
#
# Why this exists at all: `spack external find` detects a package from its
# libraries, but Spack then COMPILES against it, which needs the -devel headers.
# An image that ships only the runtime package yields an external that looks
# usable and fails at configure time, hours in. prune-headerless-externals.py
# already removes such externals, but silently -- so when a build failed on a
# missing ucx or pmi2 header there was nothing in the log saying which headers
# the node actually had. This makes that state explicit, on every run, before
# the build starts.
#
# It also runs on BOTH nodes. The head node compiles and the worker executes,
# and on this platform they are not guaranteed to be the same image: a header
# present on the worker but absent on the head node cannot be linked against,
# which is a build failure waiting to happen rather than a property of the
# hardware. inspect-head-node.sh diffs the two files this writes.

# Deliberately not `set -e`: a missing header is the data we are collecting,
# not an error. Only a missing OUTFILE argument is fatal.
set -uo pipefail

OUT="${1:?usage: probe-headers.sh OUTFILE LABEL}"
LABEL="${2:-node}"

# Roots searched in order. /opt/amazon/efa is the AWS EFA libfabric, which
# carries its own headers outside the system include path; CUDA likewise.
SEARCH_ROOTS="/usr/include /usr/local/include /opt/amazon/efa/include"
[ -n "${CUDA_PREFIX:-}" ] && SEARCH_ROOTS="${SEARCH_ROOTS} ${CUDA_PREFIX}/include"
SEARCH_ROOTS="${SEARCH_ROOTS} /usr/local/cuda/include"

# NAME:sentinel header:what needs it. The sentinel is the header a dependent
# package actually includes, not merely any file the package ships.
PROBES="
UCX:ucp/api/ucp.h:openmpi fabrics=ucx, ucx as an external
LIBFABRIC:rdma/fabric.h:openmpi fabrics=ofi
VERBS:infiniband/verbs.h:ucx +verbs
RDMACM:rdma/rdma_cma.h:ucx +rdmacm
SLURM:slurm/slurm.h:mpich +slurm, openmpi schedulers=slurm
PMI2:slurm/pmi2.h:srun --mpi=pmi2 launch integration
PMIX:pmix.h:openmpi +pmix
CUDA:cuda.h:any +cuda build
GDRCOPY:gdrapi.h:ucx +gdrcopy
"

find_header() {
  local sentinel="$1" root
  for root in ${SEARCH_ROOTS}; do
    if [ -f "${root}/${sentinel}" ]; then
      printf '%s\n' "${root}/${sentinel}"
      return 0
    fi
  done
  return 1
}

: > "$OUT"
{
  printf 'HDR_LABEL="%s"\n' "$LABEL"
  printf 'HDR_HOST="%s"\n' "$(hostname)"
} >> "$OUT"

printf '\n=== [headers] %s node: %s ===\n' "$LABEL" "$(hostname)"

printf '%s\n' "$PROBES" | while IFS=: read -r name sentinel why; do
  [ -n "$name" ] || continue
  if path="$(find_header "$sentinel")"; then
    printf 'HDR_%s="1"\n'      "$name"        >> "$OUT"
    printf 'HDR_%s_PATH="%s"\n' "$name" "$path" >> "$OUT"
    printf '  present  %-10s %s\n' "$name" "$path"
  else
    printf 'HDR_%s="0"\n'       "$name" >> "$OUT"
    printf 'HDR_%s_PATH=""\n'   "$name" >> "$OUT"
    printf '  MISSING  %-10s (%s) -- needed by: %s\n' "$name" "$sentinel" "$why"
  fi
done

printf '=== [headers] wrote %s ===\n' "$OUT"
