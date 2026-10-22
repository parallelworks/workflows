set -o pipefail

################################################################################
# Interactive Session Controller - Omniverse render
#
# Purpose: Check the form's values before the job is submitted, and with
#          Singularity pull the SIF (idempotent) into the install directory, which
#          the compute nodes share. The Docker image is pulled in start-template.sh
#          on the node where the job runs, because image caches are not shared.
# Runs on: Controller node
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_accept_eula: must be true; the container refuses to start otherwise
#   - service_frames, service_resolution, service_renderer: the render settings
#   - service_scene: optional; a USD file on the cluster's filesystem
#   - software_runtime: docker or singularity
#   - software_sif: optional; with singularity, a SIF you already have (empty pulls one)
#   - service_parent_install_dir: where omniverse/cache (Isaac Sim's home shared by
#     runs) and omniverse/containers (the SIF) go
################################################################################

if [ "${service_accept_eula}" != "true" ]; then
    echo "::error title=Error::Isaac Sim only starts once the NVIDIA Isaac Sim Additional Software and Materials License is accepted (the Accept the license checkbox): https://www.nvidia.com/en-us/agreements/enterprise-software/isaac-sim-additional-software-and-materials-license/"
    exit 1
fi

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
case "${software_runtime}" in
    docker)
        if [ -z "${software_image}" ]; then
            echo "::error title=Error::The container image is empty"
            exit 1
        fi
        ;;
    singularity) ;;
    *)
        echo "::error title=Error::Unknown container runtime '${software_runtime}': docker or singularity"
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

if [ "${software_runtime}" = singularity ]; then
    if [ -n "${software_sif}" ]; then
        if ! [ -r "${software_sif}" ]; then
            echo "::error title=Error::The Singularity image ${software_sif} is not a readable file on $(hostname)"
            exit 1
        fi
    else
        source tools/oras/libs.sh
        container_sif="${service_parent_install_dir}/omniverse/containers/isaac-sim-6.2.0.1.sif"
        mkdir -p "$(dirname "${container_sif}")"
        if ! [ -s "${container_sif}" ]; then
            echo "::group::Isaac Sim SIF Download"
            oras_pull_file ghcr.io/parallelworks/isaac-sim:6.2.0.1 isaac-sim-6.2.0.1.sif "${container_sif}"
            if ! [ -s "${container_sif}" ]; then
                echo "::error title=Error::Failed to download ${container_sif}"
                exit 1
            fi
            chmod a+r "${container_sif}"
            echo "::endgroup::"
        fi
    fi
fi

echo "::notice title=Info::Controller setup complete."
