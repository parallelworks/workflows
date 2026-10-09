#!/usr/bin/env bash
# resolve-profile.sh — decide whether to use explicit overrides or hardware detection.
#
# Policy (as required): overrides are all-or-nothing. TARGET, FABRIC, and CUDA_ARCH
# must be set TOGETHER or NONE of them. Mixing some overrides with some autodetection
# is rejected as too error-prone.
#
# Inputs (env vars, any of which may be empty):
#   OVERRIDE_TARGET      e.g. x86_64_v4  (spack microarch)
#   OVERRIDE_FABRIC      one of: aws|azure|gcp|oracle|generic
#   OVERRIDE_CUDA_ARCH   e.g. 90  (or the literal "none" to force a CPU-only build)
#   BUILD_GPU            0|1  (whether the GPU path is requested at all)
#
# Behavior:
#   - All three set   -> writes fabric.env directly from overrides; prints NEED_DETECT=0
#   - None set        -> prints NEED_DETECT=1 (caller must run detect-fabric.sh on a worker)
#   - Partial         -> exits non-zero with a clear message
#
# Output: writes $1 (default ./profile.decision), sourceable, containing NEED_DETECT
#         and, when overrides are complete, a ready-to-use fabric.env at $2
#         (default ./fabric.env).

set -euo pipefail
DECISION_OUT="${1:-./profile.decision}"
FABRIC_OUT="${2:-./fabric.env}"

log() { printf '[resolve] %s\n' "$*" >&2; }

t="${OVERRIDE_TARGET:-}"
f="${OVERRIDE_FABRIC:-}"
c="${OVERRIDE_CUDA_ARCH:-}"

# Count how many of the three are set.
set_count=0
[ -n "$t" ] && set_count=$((set_count+1))
[ -n "$f" ] && set_count=$((set_count+1))
[ -n "$c" ] && set_count=$((set_count+1))

if [ "$set_count" -eq 0 ]; then
  log "no overrides set -> hardware detection required on a worker node"
  echo "NEED_DETECT=1" > "$DECISION_OUT"
  exit 0
fi

if [ "$set_count" -ne 3 ]; then
  log "ERROR: partial overrides. You set $set_count of 3."
  log "  OVERRIDE_TARGET='$t' OVERRIDE_FABRIC='$f' OVERRIDE_CUDA_ARCH='$c'"
  log "  Set ALL THREE together (target, fabric, cuda-arch) or NONE. Mixing is not allowed."
  log "  For a CPU-only override, set OVERRIDE_CUDA_ARCH=none."
  exit 2
fi

# Validate the fabric value.
case "$f" in
  aws|azure|gcp|oracle|generic) : ;;
  *) log "ERROR: OVERRIDE_FABRIC='$f' invalid (expected aws|azure|gcp|oracle|generic)"; exit 2 ;;
esac

# All three set: synthesize fabric.env without any probing.
# CUDA_ARCH=none means "user explicitly wants CPU-only"; represent as no GPU.
HAS_GPU=0; GPU_ARCH=""
if [ "$c" != "none" ]; then
  HAS_GPU=1; GPU_ARCH="$c"
fi

# EFA prefix only meaningful for the aws profile; leave for build.sh to confirm.
EFA_PREFIX=""
[ "$f" = "aws" ] && EFA_PREFIX="/opt/amazon/efa"

# Quoted for the same reason detect-fabric.sh quotes: this file is sourced, and
# override_target is free text a user types. An unquoted value with a space in it
# runs the rest of the line as a command.
cat > "$FABRIC_OUT" <<EOF
CLOUD="override"
FABRIC_PROFILE="$f"
HAS_EFA="$( [ "$f" = "aws" ] && echo 1 || echo 0 )"
HAS_VERBS="$( { [ "$f" = "azure" ] || [ "$f" = "oracle" ]; } && echo 1 || echo 0 )"
EFA_PREFIX="$EFA_PREFIX"
HAS_GPU="$HAS_GPU"
GPU_ARCH="$GPU_ARCH"
CUDA_PREFIX=""
OVERRIDE_TARGET="$t"
EOF

log "complete overrides accepted: target=$t fabric=$f cuda_arch=$c"
echo "NEED_DETECT=0" > "$DECISION_OUT"
