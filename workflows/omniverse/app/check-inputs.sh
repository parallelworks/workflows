# The form's values, checked once for both runtimes (sourced by their controllers)

f_fail() {
    echo "::error title=Error::$1"
    exit 1
}
f_bucket_uri() {
    case "$1" in
        pw://*|s3://*|gs://*|https://*) return 0 ;;
    esac
    return 1
}

# The render form; the builder has none of these
if [ -n "${service_example}" ]; then
    case "${service_example}" in
        pyramid|fracture|scene|physics) ;;
        *) f_fail "Unknown example '${service_example}': pyramid, fracture, scene or physics" ;;
    esac
    case "${service_engine}" in
        physx|newton) ;;
        *) f_fail "Unknown physics engine '${service_engine}': physx or newton" ;;
    esac
    if ! [[ "${service_frames}" =~ ^[0-9]+$ ]] || [ "${service_frames}" -lt 1 ]; then
        f_fail "Frames must be a whole number of at least 1, got '${service_frames}'"
    fi
    # A physics-only run hides the render fields, which then arrive empty
    if [ "${service_example}" != physics ]; then
        if ! [[ "${service_resolution}" =~ ^[0-9]+x[0-9]+$ ]]; then
            f_fail "Resolution must be WIDTHxHEIGHT, got '${service_resolution}'"
        fi
        case "${service_renderer}" in
            RayTracedLighting|RealTimePathTracing|PathTracing) ;;
            *) f_fail "Unknown renderer '${service_renderer}': RayTracedLighting, RealTimePathTracing or PathTracing" ;;
        esac
    fi
    if [ -n "${service_snapshots}" ] && ! [[ "${service_snapshots}" =~ ^[0-9]+$ ]]; then
        f_fail "Snapshot interval must be a whole number of frames (0 for the last frame only), got '${service_snapshots}'"
    fi
fi

if [ -n "${files_source}" ] && ! f_bucket_uri "${files_source}"; then
    case "${files_source}" in
        /*) ;;
        *) f_fail "The source must be a bucket URI (pw://, s3://, gs://) or an absolute path on the cluster, got '${files_source}'" ;;
    esac
    if ! [ -r "${files_source}" ]; then
        f_fail "The source ${files_source} is not a readable file or directory on $(hostname)"
    fi
fi
if [ "${service_example}" = scene ] && [ -z "${files_source}" ]; then
    f_fail "The 'scene' example renders a scene of yours: give its USD file, or the directory holding it, as the source"
fi
if [ -n "${files_destination}" ] && ! f_bucket_uri "${files_destination}"; then
    case "${files_destination}" in
        /*) ;;
        *) f_fail "The destination must be a bucket URI (pw://, s3://, gs://) or an absolute path on the cluster, got '${files_destination}'" ;;
    esac
    if ! mkdir -p "${files_destination}" 2> /dev/null || ! [ -w "${files_destination}" ]; then
        f_fail "The destination ${files_destination} cannot be created or written by $(id -un) on $(hostname)"
    fi
fi

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
mkdir -p "${service_parent_install_dir}/omniverse/cache"
if ! [ -w "${service_parent_install_dir}/omniverse/cache" ]; then
    f_fail "${service_parent_install_dir}/omniverse is not writable by $(id -un)"
fi
