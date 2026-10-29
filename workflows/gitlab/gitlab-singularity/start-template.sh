################################################################################
# Interactive Session Service Starter - GitLab (Singularity)
#
# Purpose: Run the GitLab Linux package image as the workflow user, no root
#          and no Docker daemon: an Apptainer/Singularity instance started
#          with --fakeroot, whose user namespace maps the image's service
#          accounts (git, gitlab-psql, ...) onto the user's subuid range, so
#          the package's own init (runit) runs unchanged. The SIF runs as is
#          where the node mounts it with a writable layer; a node that cannot
#          (no FUSE mount or rootless overlay for a user namespace: hardened
#          login nodes) gets the image extracted once into the run directory
#          and run from that directory; a run directory on a network
#          filesystem, which refuses the container's ownership changes, keeps
#          GitLab's state in ext3 images instead. Behind a pw endpoint on a pinned
#          subdomain, with ACTIVATE as an OpenID Connect provider when the form
#          carries an OIDC client, a license, the CI runners (shell on this
#          host, SLURM through Jacamar CI) and the demo project. What does not
#          depend on the runtime is in lib/start.sh (this script) and
#          lib/launcher.sh (the launcher).
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
mkdir -p "${work_dir}/tmp" "${service_rundir}/config/activate" "${HOME}/.singularity_cache"
chmod 1777 "${work_dir}/tmp"
export APPTAINER_TMPDIR="${work_dir}/tmp" SINGULARITY_TMPDIR="${work_dir}/tmp"
export APPTAINER_CACHEDIR="${HOME}/.singularity_cache" SINGULARITY_CACHEDIR="${HOME}/.singularity_cache"

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

# The SIF runs as is where this node mounts it under --fakeroot with a
# writable layer (--writable-tmpfs: the package writes outside its volumes,
# runit's supervise directories and the configuration run's node files).
# A hardened node allows a user namespace neither the FUSE mount (fusermount
# without user_allow_other) nor a rootless overlay, so there the SIF is
# extracted once into the run directory, with --fakeroot so the image's
# ownership survives (mapped onto the subuid range), and that directory runs
# with --writable: the writes then persist in it like an installed package's.
# The probe runs here, on the node that runs the service; the directory, once
# there, decides for the run directory, and a marker names the SIF it came
# from so a new image replaces it (GitLab migrates the data on the next start,
# one minor version at a time)
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
uid_range=""
if [ -d "${image_dir}" ]; then
    image_ref="${image_dir}"
    image_flag="--writable"
    echo "::notice::Running the image extracted into ${image_dir} (this node could not mount the SIF when it was extracted)"
else
    probe=$(singularity exec --fakeroot --writable-tmpfs "${container_sif}" \
        sh -c 'touch /opt/.activate-probe 2>/dev/null && echo writable; awk "NR > 1 { print \$3 }" /proc/self/uid_map' 2>/dev/null)
    uid_range=$(printf '%s\n' "${probe}" | grep -E '^[0-9]+$' | sort -n | tail -n 1)
    if printf '%s\n' "${probe}" | grep -qx writable; then
        image_ref="${container_sif}"
        image_flag="--writable-tmpfs"
        echo "::notice::Running ${container_sif} as is (this node mounts it with a writable layer)"
    else
        echo "::notice::$(hostname) cannot mount ${container_sif} with a writable layer under fakeroot (no FUSE mount or rootless overlay for a user namespace); extracting it into ${image_dir} (about a minute, once per run directory)"
        if ! singularity build --fakeroot --sandbox "${image_dir}" "${container_sif}"; then
            echo "::error title=Error::Could not extract ${container_sif} with --fakeroot on $(hostname): the GitLab image needs user namespaces and a subuid/subgid range for $(id -un) (an administrator adds one with 'apptainer config fakeroot --add $(id -un)')"
            exit 1
        fi
        echo "${sif_id}" > "${image_marker}"
        image_ref="${image_dir}"
        image_flag="--writable"
    fi
fi
# The user namespace must map the image's accounts: a --fakeroot that falls
# back to a single mapped id (no subuid range for the user) cannot run it
if [ -z "${uid_range}" ]; then
    uid_range=$(singularity exec --fakeroot "${image_ref}" awk 'NR > 1 { print $3 }' /proc/self/uid_map 2>/dev/null | sort -n | tail -n 1)
fi
if [ -z "${uid_range}" ]; then
    echo "::error title=Error::Could not run ${image_ref} with --fakeroot on $(hostname): the GitLab image needs user namespaces and fakeroot. Try the Docker runtime there"
    exit 1
fi
if [ "${uid_range}" -lt 65536 ]; then
    echo "::error title=Error::fakeroot on $(hostname) maps ${uid_range} user ids for $(id -un), and the GitLab image's service accounts need 65536: an administrator adds a subuid/subgid range with 'apptainer config fakeroot --add $(id -un)'"
    exit 1
fi
echo "::notice::fakeroot maps ${uid_range} user ids on $(hostname)"

# Where GitLab's state (config/, data/, logs/) lives. The package chowns its
# files to the image's accounts, which the user namespace maps onto the
# subuid range; a network filesystem (NFS, Lustre, GPFS: the home of an HPC
# system) gets that request as the user's own id and refuses it, while a
# local disk takes it. Probed with a chown in the run directory: where it
# works the three directories are bound as volumes; where it does not, each
# of the three becomes an ext3 image under state/, mounted by fuse2fs inside
# the instance (an image bind), so ownership lives inside the images and the
# network filesystem only sees three files of the user's. The root filesystem
# keeps its tmpfs overlay either way: runit's service directory must report
# changes at once, which it does not through a FUSE-mounted overlay image
state_layout="${service_state_layout:-auto}"
state_dir="${service_rundir}/state"
if [ "${state_layout}" = "auto" ]; then
    if [ -s "${state_dir}/data.img" ]; then
        state_layout=image
    elif singularity exec --fakeroot --bind "${service_rundir}/data:/mnt" "${image_ref}" \
            sh -c 'touch /mnt/.chown-probe && chown 998:998 /mnt/.chown-probe; s=$?; rm -f /mnt/.chown-probe; exit $s' >/dev/null 2>&1; then
        state_layout=directories
    else
        state_layout=image
        echo "::notice::The filesystem of ${service_rundir} does not let the container change file ownership (a network filesystem): GitLab's state goes into ext3 images under ${state_dir} instead of config/, data/ and logs/"
    fi
fi
state_binds=""
case "${state_layout}" in
    image)
        if [ "${image_flag}" = "--writable" ]; then
            echo "::error title=Error::$(hostname) can neither mount ${container_sif} nor change file ownership in ${service_rundir}: an extracted image needs a run directory on a local filesystem. Choose one there"
            exit 1
        fi
        if ! command -v fuse2fs >/dev/null 2>&1; then
            echo "::error title=Error::Keeping GitLab's state in ext3 images needs fuse2fs (e2fsprogs) on $(hostname); install it, or use a run directory on a local filesystem"
            exit 1
        fi
        # data.img takes the form's size (repositories, database, uploads);
        # the sparse files only hold what is written. The directory bound
        # from each image is made by the namespace's root, so it belongs to
        # an id the namespace maps: the image's own upper/ belongs to the
        # user, whose id may lie beyond the mapped range (65536 ids on some
        # HPC systems), and root in the namespace cannot write there
        mkdir -p "${state_dir}"
        state_image_size="${service_state_image_size:-20}"
        for spec in "config 256" "logs 4096" "data $(( state_image_size * 1024 ))"; do
            set -- ${spec}
            if ! [ -s "${state_dir}/$1.img" ]; then
                if ! singularity overlay create --sparse --size "$2" "${state_dir}/$1.img"; then
                    echo "::error title=Error::Could not create ${state_dir}/$1.img (above; it needs mkfs.ext3 of e2fsprogs on $(hostname))"
                    exit 1
                fi
                if ! singularity exec --fakeroot --bind "${state_dir}/$1.img:/mnt:image-src=/" "${image_ref}" mkdir -p /mnt/gitlab; then
                    echo "::error title=Error::Could not mount ${state_dir}/$1.img inside the container (above; fuse2fs on $(hostname))"
                    rm -f "${state_dir}/$1.img"
                    exit 1
                fi
                echo "::notice::Created ${state_dir}/$1.img ($2 MiB, sparse; grow it with resize2fs while GitLab is stopped)"
            fi
        done
        state_binds="--bind ${state_dir}/config.img:/etc/gitlab:image-src=/gitlab --bind ${state_dir}/logs.img:/var/log/gitlab:image-src=/gitlab --bind ${state_dir}/data.img:/var/opt/gitlab:image-src=/gitlab"
        ;;
    directories)
        state_binds="--bind ${service_rundir}/config:/etc/gitlab --bind ${service_rundir}/logs:/var/log/gitlab --bind ${service_rundir}/data:/var/opt/gitlab"
        ;;
    *)
        echo "::error title=Error::Unknown state layout '${state_layout}' (auto, directories or image)"
        exit 1
        ;;
esac
echo "::notice::GitLab's state layout: ${state_layout}"

export image_ref image_flag work_dir state_layout state_binds
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
singularity exec "${image_ref}" cat /assets/sshd_config \
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

# The 0 a FIPS-mode host hands the container (lib/start.sh); binds over proc
# files are allowed
fips_bind=""
if [ -n "${fips_enabled_file}" ]; then
    fips_bind="--bind ${fips_enabled_file}:/proc/sys/crypto/fips_enabled"
fi

# The image's volumes are bound from the run directory's directories or ext3
# images (every mount point exists in the image: --writable creates none);
# the snippet directory and the sshd configuration (whose port is fixed in
# the image) come from this job
singularity instance stop -F "${instance_name}" 2>/dev/null || true
if ! singularity instance start --fakeroot ${image_flag} --contain --cleanenv \
        --uts --hostname "${host}" \
        --workdir "${work_dir}" ${fips_bind} ${state_binds} \
        --bind "${run_dir}/activate:/etc/gitlab/activate:ro" \
        --bind "${run_dir}/sshd_config:/assets/sshd_config:ro" \
        "${image_ref}" "${instance_name}"; then
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
