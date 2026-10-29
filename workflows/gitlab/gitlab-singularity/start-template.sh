################################################################################
# Interactive Session Service Starter - GitLab (Singularity)
#
# Purpose: Run the GitLab Linux package image as the workflow user, no root
#          and no Docker daemon: an Apptainer/Singularity instance started
#          with --fakeroot, whose user namespace maps the image's service
#          accounts (git, gitlab-psql, ...) onto the user's subuid range, so
#          the package's own init (runit) runs unchanged. The image runs from
#          a writable sandbox directory, extracted once from the SIF into the
#          run directory: a plain directory needs neither a FUSE mount of the
#          SIF nor an overlay for what the package writes outside its volumes,
#          which a hardened login node may allow to no user namespace. Behind
#          a pw endpoint on a pinned subdomain, with ACTIVATE as an OpenID
#          Connect provider when the form carries an OIDC client, a license,
#          the CI runners (shell on this host, SLURM through Jacamar CI) and
#          the demo project. What does not depend on the runtime is in
#          lib/start.sh (this script) and lib/launcher.sh (the launcher).
# Runs on: Controller node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - service_parent_install_dir: where containers/gitlab.sif lives
#   - the variables lib/start.sh and lib/launcher.sh list
################################################################################

set -x
set -o pipefail

source "${PW_PARENT_JOB_DIR}/workflows/gitlab/lib/start.sh"

container_sif="${service_parent_install_dir}/containers/gitlab.sif"
image_dir="${service_rundir}/image"
work_dir="${service_rundir}/work"
# work/ holds the container's /tmp and /var/tmp (--workdir), a real temporary
# directory (world-writable and sticky: Ruby's Dir.tmpdir, used by the Rails
# processes running as the image's accounts, accepts nothing less), and the
# temporary files of singularity itself, which the host's /tmp may refuse
# (noexec); the config/activate mount point must exist before the config
# volume is bound over it
mkdir -p "${work_dir}/tmp" "${service_rundir}/config/activate"
chmod 1777 "${work_dir}/tmp"
export APPTAINER_TMPDIR="${work_dir}/tmp" SINGULARITY_TMPDIR="${work_dir}/tmp"

# Load singularity/apptainer if not already in PATH
if ! which singularity &> /dev/null; then
    if module load apptainer 2>/dev/null; then
        echo "::notice::Loaded apptainer module"
    elif module load singularity 2>/dev/null; then
        echo "::notice::Loaded singularity module"
    else
        echo "::error title=Error::singularity/apptainer not found in PATH and could not be loaded via module"
        exit 1
    fi
fi
if ! [ -f "${container_sif}" ]; then
    echo "::error title=Error::Missing container image ${container_sif}"
    exit 1
fi

# Host environments (module paths, LD_LIBRARY_PATH on HPC) must not leak into
# the container; the image's own environment is all it needs
unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT PYTHONSTARTUP LD_LIBRARY_PATH

# The package chowns its data to the image's accounts, which the user
# namespace maps onto the user's subuid range; an NFS server sees the user's
# own id in that request and refuses it, so the run directory must be on a
# filesystem local to this node (the login node's home on the cloud clusters)
case "$(stat -f -c %T "${service_rundir}" 2>/dev/null)" in
    nfs|nfs4)
        echo "::error title=Error::${service_rundir} is on NFS on $(hostname): the GitLab image's user namespace cannot change file ownership there. Use a run directory on a filesystem local to this node, or the Docker runtime"
        exit 1
        ;;
esac
# The image runs from a sandbox directory extracted from the SIF the
# controller pulled, with --writable: a directory needs no FUSE mount and no
# overlay, which a hardened node may allow to no user namespace (fusermount
# without user_allow_other, a mount binary the namespace cannot execute),
# and what the package writes outside its volumes (runit's supervise
# directories, the configuration run's node files) persists like an installed
# package's. The extraction runs with --fakeroot too, so the image's ownership
# survives (mapped onto the subuid range). The marker names the SIF the
# sandbox came from: a new image replaces the sandbox, and GitLab migrates
# the data on the next start (one minor version at a time)
sif_id="$(basename "$(readlink -f "${container_sif}")") $(stat -L -c %s "${container_sif}")"
image_marker="${service_rundir}/.image-source"
if [ -d "${image_dir}" ] && [ "$(cat "${image_marker}" 2>/dev/null)" != "${sif_id}" ]; then
    echo "::notice::Removing ${image_dir}, extracted from $(cat "${image_marker}" 2>/dev/null || echo 'an unknown or interrupted image'); ${sif_id%% *} replaces it"
    rm -f "${image_marker}"
    # Its files belong to the mapped ids, so the user namespace removes them
    if ! singularity exec --fakeroot --bind "${service_rundir}" "${container_sif}" rm -rf "${image_dir}"; then
        echo "::error title=Error::Could not remove ${image_dir} (above)"
        exit 1
    fi
fi
if ! [ -d "${image_dir}" ]; then
    echo "::notice::Extracting ${container_sif} into ${image_dir} (about a minute, once per run directory)"
    if ! singularity build --fakeroot --sandbox "${image_dir}" "${container_sif}"; then
        echo "::error title=Error::Could not extract ${container_sif} with --fakeroot on $(hostname): the GitLab image needs user namespaces and a subuid/subgid range for $(id -un) (an administrator adds one with 'apptainer config fakeroot --add $(id -un)')"
        exit 1
    fi
    echo "${sif_id}" > "${image_marker}"
fi
# The user namespace must map the image's accounts: a --fakeroot that falls
# back to a single mapped id (no subuid range for the user) cannot run it
uid_range=$(singularity exec --fakeroot "${image_dir}" awk 'NR > 1 { print $3 }' /proc/self/uid_map 2>/dev/null | sort -n | tail -n 1)
if [ -z "${uid_range}" ]; then
    echo "::error title=Error::Could not run ${image_dir} with --fakeroot on $(hostname): the GitLab image needs user namespaces and fakeroot. Try the Docker runtime there"
    exit 1
fi
if [ "${uid_range}" -lt 65536 ]; then
    echo "::error title=Error::fakeroot on $(hostname) maps ${uid_range} user ids for $(id -un), and the GitLab image's service accounts need 65536: an administrator adds a subuid/subgid range with 'apptainer config fakeroot --add $(id -un)'"
    exit 1
fi
echo "::notice::fakeroot maps ${uid_range} user ids on $(hostname)"

export image_dir work_dir
export instance_name="gitlab_${PW_RUN_SLUG}"

# The instance outlives the endpoint's process tree: cancel.sh stops the
# package's services (a TERM to the entrypoint's host-side process does not
# reach the script inside), then the instance, whose PID namespace takes the
# rest with it. The submitter runs it over ssh, in a shell that has not loaded
# the module this script may have
cat >> cancel.sh <<CANCELEOF
if ! command -v singularity >/dev/null 2>&1; then
    module load apptainer 2>/dev/null || module load singularity 2>/dev/null
fi
if singularity instance list 2>/dev/null | awk '{ print \$1 }' | grep -qxF "${instance_name}"; then
    timeout 30 singularity exec --cleanenv --pwd / instance://${instance_name} gitlab-ctl stop 2>/dev/null
    singularity instance stop -F ${instance_name} 2>/dev/null || true
fi
CANCELEOF

echo "::group::Starting GitLab"

# pw endpoints run exports PORT, PW_ENDPOINT_HOST, PW_ENDPOINT_PATH and
# PW_ENDPOINT_URL to the wrapped command; the launcher writes the container's
# configuration at runtime because GitLab must know its public host name
# (external_url: absolute URLs, clone URLs, the OIDC redirect URI) before it
# starts. The image's entrypoint, run in the instance's foreground, keeps the
# endpoint alive for the life of the container.
cat > launch-gitlab-${PW_JOB_ID}.sh <<'LAUNCHEOF'
#!/bin/bash
set -x
set -o pipefail

source "${gitlab_lib}/launcher.sh"
gitlab_launcher_init
gitlab_write_nginx_snippet
# The container shares the host's network, so the bundled nginx listens on the
# endpoint's own port and GitLab's sshd on the form's, and every other TCP
# listener of the package (fixed loopback ports in the image, which Docker
# isolates per container) is moved to a free port or turned off, so that two
# GitLabs on one host do not collide: puma's port (workhorse reaches it over
# its unix socket), the metrics of workhorse and gitaly, sidekiq's metrics and
# health checks, nginx's status page (on every interface) and the Kubernetes
# agent server
free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}
gitlab_write_omnibus_config "${PORT}" \
    "nginx['listen_addresses'] = ['127.0.0.1']" \
    "nginx['status']['enable'] = false" \
    "puma['port'] = $(free_port)" \
    "gitlab_workhorse['prometheus_listen_addr'] = '127.0.0.1:$(free_port)'" \
    "gitaly['configuration'] = { prometheus_listen_addr: '127.0.0.1:$(free_port)' }" \
    "sidekiq['metrics_enabled'] = false" \
    "sidekiq['health_checks_enabled'] = false" \
    "gitlab_kas['enable'] = false"
sed "s/^Port 22$/Port ${service_ssh_port}\nListenAddress 127.0.0.1/" "${image_dir}/assets/sshd_config" > "${run_dir}/sshd_config"

# The configuration goes in as a host variable with the APPTAINERENV_ /
# SINGULARITYENV_ prefix: it reaches the container with --cleanenv and stays
# out of the process list. Apptainer expands $, backticks and backslashes in
# such values, so they are escaped and arrive verbatim. The package's logs
# stay in logs/ instead of being tailed into this job's output forever
set +x
config=$(sed 's/^GITLAB_OMNIBUS_CONFIG=//' "${run_dir}/gitlab.env" | sed 's/[\\$`]/\\&/g')
export APPTAINERENV_GITLAB_OMNIBUS_CONFIG="${config}" SINGULARITYENV_GITLAB_OMNIBUS_CONFIG="${config}"
unset config
set -x
export APPTAINERENV_GITLAB_SKIP_TAIL_LOGS=true SINGULARITYENV_GITLAB_SKIP_TAIL_LOGS=true

gitlab_exec() {
    singularity exec --cleanenv --pwd / instance://"${instance_name}" "$@"
}
gitlab_alive() {
    kill -0 "$(cat "${run_dir}/wrapper.pid")" 2>/dev/null
}
gitlab_logs() {
    tail -n 80 "${run_dir}/gitlab.log"
}

# A host in FIPS mode (fips=1 on its kernel command line: STIG images) shows
# /proc/sys/crypto/fips_enabled = 1 to the container, whose OpenSSH then
# wants a FIPS provider the image does not have and dies while the entrypoint
# creates the SSH host keys ("PRNG is not seeded"). The image is not a FIPS
# build (GitLab ships those separately), so it is given a 0 to read
fips_bind=""
if [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = "1" ]; then
    echo 0 > "${run_dir}/fips_enabled"
    fips_bind="--bind ${run_dir}/fips_enabled:/proc/sys/crypto/fips_enabled"
    echo "::notice::$(hostname) runs in FIPS mode; the container reads fips_enabled=0 (the GitLab image is not a FIPS build)"
fi

# The image's volumes are bound from the run directory (every mount point
# exists in the image: --writable creates none), the snippet directory and
# the sshd configuration (whose port is fixed in the image) from this job
singularity instance stop -F "${instance_name}" 2>/dev/null || true
if ! singularity instance start --fakeroot --writable --contain --cleanenv \
        --uts --hostname "${host}" \
        --workdir "${work_dir}" ${fips_bind} \
        --bind "${service_rundir}/config:/etc/gitlab" \
        --bind "${service_rundir}/logs:/var/log/gitlab" \
        --bind "${service_rundir}/data:/var/opt/gitlab" \
        --bind "${run_dir}/activate:/etc/gitlab/activate:ro" \
        --bind "${run_dir}/sshd_config:/assets/sshd_config:ro" \
        "${image_dir}" "${instance_name}"; then
    fail "Could not start the GitLab instance ${instance_name} (above)"
fi
singularity exec --cleanenv --pwd / instance://"${instance_name}" /assets/init-container > "${run_dir}/gitlab.log" 2>&1 &
echo $! > "${run_dir}/wrapper.pid"

gitlab_wait_ready
gitlab_setup

wait "$(cat "${run_dir}/wrapper.pid")"
gitlab_logs
fail "The GitLab container stopped (its log is above; the package's logs are in ${service_rundir}/logs)"
LAUNCHEOF
chmod +x launch-gitlab-${PW_JOB_ID}.sh

pw endpoints run ${pw_endpoints_args} -- ./launch-gitlab-${PW_JOB_ID}.sh
finish_endpoint_run $?
