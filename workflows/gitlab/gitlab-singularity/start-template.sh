################################################################################
# Interactive Session Service Starter - GitLab (Singularity)
#
# Purpose: Run the GitLab Linux package image from one SIF as the workflow
#          user, no root and no Docker daemon: an Apptainer instance started
#          with --fakeroot, whose user namespace maps the image's service
#          accounts (git, gitlab-psql, ...) onto the user's subuid range, so
#          the package's own init (runit) runs unchanged. Behind a pw endpoint
#          on a pinned subdomain, with ACTIVATE as an OpenID Connect provider
#          when the form carries an OIDC client, a license, the CI runners
#          (shell on this host, SLURM through Jacamar CI) and the demo project.
#          What does not depend on the runtime is in lib/start.sh (this script)
#          and lib/launcher.sh (the launcher).
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - service_parent_install_dir: where containers/gitlab.sif lives
#   - the variables lib/start.sh and lib/launcher.sh list
################################################################################

set -x

source "${PW_PARENT_JOB_DIR}/workflows/gitlab/lib/start.sh"

container_sif="${service_parent_install_dir}/containers/gitlab.sif"
# tmp/ is the container's /tmp, a real temporary directory (world-writable
# and sticky: Ruby's Dir.tmpdir, used by the Rails processes running as the
# image's accounts, accepts nothing less); the config/activate mount point
# must exist before the config volume is bound over it
mkdir -p "${service_rundir}/tmp" "${service_rundir}/config/activate"
chmod 1777 "${service_rundir}/tmp"

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
# filesystem local to this node (the login node's home on the cloud clusters;
# a compute node's is NFS). Both are checked on the node that runs the service
case "$(stat -f -c %T "${service_rundir}" 2>/dev/null)" in
    nfs|nfs4)
        echo "::error title=Error::${service_rundir} is on NFS on $(hostname): the GitLab image's user namespace cannot change file ownership there. Use a run directory on a local filesystem, run on the login node, or use the Docker runtime"
        exit 1
        ;;
esac
# The user namespace must map the image's accounts: a --fakeroot that falls
# back to a single mapped id (no subuid range for the user) cannot run it
uid_range=$(singularity exec --fakeroot --writable-tmpfs "${container_sif}" \
    awk 'NR > 1 { print $3 }' /proc/self/uid_map 2>/dev/null | sort -n | tail -n 1)
if [ -z "${uid_range}" ]; then
    echo "::error title=Error::Apptainer could not run ${container_sif} with --fakeroot on $(hostname): the GitLab image needs user namespaces, a mountable SIF (squashfs or FUSE) and fakeroot. Try the Docker runtime there"
    exit 1
fi
if [ "${uid_range}" -lt 65536 ]; then
    echo "::error title=Error::fakeroot on $(hostname) maps ${uid_range} user ids for $(id -un), and the GitLab image's service accounts need 65536: an administrator adds a subuid/subgid range with 'apptainer config fakeroot --add $(id -un)'"
    exit 1
fi
echo "::notice::fakeroot maps ${uid_range} user ids on $(hostname)"

export container_sif
export instance_name="gitlab_${PW_RUN_SLUG}"

# The instance outlives the endpoint's process tree: cancel.sh stops the
# package's services (a TERM to the entrypoint's host-side process does not
# reach the script inside), then the instance, whose PID namespace takes the
# rest with it
cat >> cancel.sh <<CANCELEOF
if singularity instance list 2>/dev/null | awk '{ print \$1 }' | grep -qxF "${instance_name}"; then
    timeout 90 singularity exec --cleanenv --pwd / instance://${instance_name} gitlab-ctl stop 2>/dev/null
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

source "${gitlab_lib}/launcher.sh"
gitlab_launcher_init
gitlab_write_nginx_snippet
# The container shares the host's network, so the bundled nginx listens on the
# endpoint's own port and GitLab's sshd on the form's
gitlab_write_omnibus_config "${PORT}" "nginx['listen_addresses'] = ['127.0.0.1']"
singularity exec "${container_sif}" cat /assets/sshd_config \
    | sed "s/^Port 22$/Port ${service_ssh_port}\nListenAddress 127.0.0.1/" > "${run_dir}/sshd_config"

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

# The image's volumes are bound from the run directory; the snippet directory
# and the sshd configuration (whose port is fixed in the image) from this job
singularity instance stop -F "${instance_name}" 2>/dev/null || true
if ! singularity instance start --fakeroot --writable-tmpfs --contain --cleanenv \
        --uts --hostname "${host}" \
        --bind "${service_rundir}/config:/etc/gitlab" \
        --bind "${service_rundir}/logs:/var/log/gitlab" \
        --bind "${service_rundir}/data:/var/opt/gitlab" \
        --bind "${service_rundir}/tmp:/tmp" \
        --bind "${run_dir}/activate:/etc/gitlab/activate:ro" \
        --bind "${run_dir}/sshd_config:/assets/sshd_config:ro" \
        "${container_sif}" "${instance_name}"; then
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
