# The form's values, checked once for both runtimes (sourced by their controllers)

if ! [[ "${service_frames}" =~ ^[0-9]+$ ]] || [ "${service_frames}" -lt 1 ]; then
    echo "::error title=Error::Frames must be a whole number of at least 1, got '${service_frames}'"
    exit 1
fi
if ! [[ "${service_resolution}" =~ ^[0-9]+x[0-9]+$ ]]; then
    echo "::error title=Error::Resolution must be WIDTHxHEIGHT, got '${service_resolution}'"
    exit 1
fi
case "${service_renderer}" in
    RayTracedLighting|RealTimePathTracing|PathTracing) ;;
    *)
        echo "::error title=Error::Unknown renderer '${service_renderer}': RayTracedLighting, RealTimePathTracing or PathTracing"
        exit 1
        ;;
esac
if [ -n "${service_scene}" ]; then
    case "${service_scene}" in
        /*) ;;
        *)
            echo "::error title=Error::The scene must be an absolute path on the cluster, got '${service_scene}'"
            exit 1
            ;;
    esac
    if ! [ -r "${service_scene}" ]; then
        echo "::error title=Error::The scene ${service_scene} is not a readable file on $(hostname)"
        exit 1
    fi
fi

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
mkdir -p "${service_parent_install_dir}/omniverse/cache"
if ! [ -w "${service_parent_install_dir}/omniverse/cache" ]; then
    echo "::error title=Error::${service_parent_install_dir}/omniverse is not writable by $(id -un)"
    exit 1
fi
