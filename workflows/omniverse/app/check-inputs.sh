# The form's values, checked once for both runtimes (sourced by their controllers)

f_fail() {
    echo "::error title=Error::$1"
    exit 1
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
    if [ "${service_engine}" = newton ]; then
        # Newton simulates joints only inside an articulation; the bonds between the chunks
        # of a fractured mesh are joints between free bodies, which it refuses
        if [ "${service_example}" = fracture ] || [ "${fracture_own_mesh}" = true ] || { [ "${service_example}" = physics ] && [ -z "${files_source}" ]; }; then
            f_fail "Newton cannot simulate a fractured mesh (its bonds are joints between free bodies, which Newton refuses): pick PhysX, or another example"
        fi
    fi
    if [ "${fracture_own_mesh}" = true ]; then
        if ! [[ "${fracture_cells}" =~ ^[0-9]+$ ]] || [ "${fracture_cells}" -lt 2 ]; then
            f_fail "Chunks must be a whole number of at least 2, got '${fracture_cells}'"
        fi
        if ! [[ "${fracture_seed}" =~ ^[0-9]+$ ]]; then
            f_fail "The seed must be a whole number, got '${fracture_seed}'"
        fi
        if ! [[ "${fracture_strength}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            f_fail "The bond strength must be a number of pascals, got '${fracture_strength}'"
        fi
        if [ -z "${files_source}" ]; then
            f_fail "Fracturing a mesh of yours needs it as the source: an OBJ file, or a directory holding one"
        fi
    fi
fi

if [ "${files_use_bucket}" = true ]; then
    # The paths are in the bucket: the full URIs replace them for the scripts that follow
    case "${files_bucket}" in
        pw://*|s3://*|gs://*) ;;
        *) f_fail "The files go through a bucket, and none was chosen (got '${files_bucket}')" ;;
    esac
    if [ -n "${files_source}" ]; then
        files_source="${files_bucket%/}/${files_source#/}"
    fi
    if [ -n "${files_destination}" ]; then
        files_destination="${files_bucket%/}/${files_destination#/}"
    fi
    {
        echo "export files_source=\"${files_source}\""
        echo "export files_destination=\"${files_destination}\""
    } >> inputs.sh
else
    if [ -n "${files_source}" ]; then
        case "${files_source}" in
            /*) ;;
            *) f_fail "The source must be an absolute path on the cluster (or turn on the bucket), got '${files_source}'" ;;
        esac
        if ! [ -r "${files_source}" ]; then
            f_fail "The source ${files_source} is not a readable file or directory on $(hostname)"
        fi
    fi
    if [ -n "${files_destination}" ]; then
        case "${files_destination}" in
            /*) ;;
            *) f_fail "The destination must be an absolute path on the cluster (or turn on the bucket), got '${files_destination}'" ;;
        esac
        if ! mkdir -p "${files_destination}" 2> /dev/null || ! [ -w "${files_destination}" ]; then
            f_fail "The destination ${files_destination} cannot be created or written by $(id -un) on $(hostname)"
        fi
    fi
fi
if [ "${service_example}" = scene ] && [ -z "${files_source}" ]; then
    f_fail "The 'scene' example renders a scene of yours: give its USD file, or the directory holding it, as the source"
fi

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
mkdir -p "${service_parent_install_dir}/omniverse/cache"
if ! [ -w "${service_parent_install_dir}/omniverse/cache" ]; then
    f_fail "${service_parent_install_dir}/omniverse is not writable by $(id -un)"
fi
