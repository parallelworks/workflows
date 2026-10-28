#!/bin/bash
# Starts MongoDB.
# Sourced by start-template.sh or restart-mongodb.sh.
# Can also be run directly: bash start-mongodb.sh  (auto-loads service.env)

_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f stop_existing > /dev/null 2>&1; then
  source "$_UTILS_DIR/utils.sh"
fi

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -e
  _svc_env="${SERVICE_ENV:-${HOME}/pw/LibreChat/singularity-data/service.env}"
  [ -f "$_svc_env" ] || { echo "ERROR: service.env not found at $_svc_env. Set SERVICE_ENV=/path/to/service.env" >&2; exit 1; }
  source "$_svc_env"
  if ! which singularity &>/dev/null; then
    module load apptainer 2>/dev/null || module load singularity 2>/dev/null || \
      { echo "ERROR: singularity/apptainer not found." >&2; exit 1; }
  fi
  unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT PYTHONSTARTUP LD_LIBRARY_PATH
fi

echo "::notice::Starting MongoDB..."
stop_existing mongodb
# The bind hides the kernel's FIPS flag from the container's OpenSSL; a kernel without
# the flag (a30gpuserver) has nothing to hide, and binding over a missing path fails
_nofips_bind=""
[ -e /proc/sys/crypto/fips_enabled ] && _nofips_bind="$DATA/nofips:/proc/sys/crypto/fips_enabled:ro"
run_bg mongodb \
  singularity exec \
    --writable-tmpfs \
    --bind "$MONGO_DATA_DIR:/data/db" \
    ${_nofips_bind:+--bind "$_nofips_bind"} \
    "$SIF/mongodb.sif" \
    mongod --noauth --dbpath /data/db --bind_ip_all --port "$MONGODB_PORT"

wait_for_port "$MONGODB_PORT" "MongoDB"
