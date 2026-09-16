#!/usr/bin/env bash
# Builds the prebuilt conda environment that app/controller.sh unpacks when
# repo.anaconda.com is unreachable: the pinned Miniconda the controller installs,
# with base updated from app/<install_instructions>.yaml, packed with conda-pack.
# The result is pushed as ghcr.io/parallelworks/jupyterlab-conda:<install_instructions>
# containing one file, conda-env.tar.gz.
#
# Usage: ./build-conda-artifact.sh [<install_instructions>]   (default: jupyterlab4.1.5-python3.11.5)
#
# Runs on any x86_64 Linux host with internet access and apptainer/singularity (for the
# smoke test). The environment runs on glibc >= 2.28 regardless of the build host:
# conda packages are prebuilt, CONDA_OVERRIDE_GLIBC pins the solver's view and
# PIP_ONLY_BINARY keeps pip from compiling anything against the host's newer glibc.

set -euo pipefail
cd "$(dirname "$0")"

TAG=${1:-jupyterlab4.1.5-python3.11.5}
ENV_YAML=app/${TAG}.yaml
REGISTRY=ghcr.io/parallelworks/jupyterlab-conda
INSTALLER_URL=https://repo.anaconda.com/miniconda/Miniconda3-py312_24.9.2-0-Linux-x86_64.sh
WORK=${BUILD_DIR:-${HOME}/pw/build/jupyterlab-conda/${TAG}}
PREFIX=${WORK}/prefix
OUT=${WORK}/conda-env.tar.gz
# jupyterlab-slurm publishes no wheel; it is pure Python, so its sdist is safe to build
export CONDA_OVERRIDE_GLIBC=2.28 PIP_ONLY_BINARY=:all: PIP_NO_BINARY=jupyterlab-slurm

[ -f "${ENV_YAML}" ] || { echo "No environment definition ${ENV_YAML}"; exit 1; }
[ "$(uname -m)" == "x86_64" ] || { echo "The artifact is x86_64 only; this host is $(uname -m)"; exit 1; }
mkdir -p "${WORK}"

sed -e '/^name:/d' -e '/^prefix:/d' -e '/^$/d' "${ENV_YAML}" > "${WORK}/env.yaml"

echo "Installing Miniconda into ${PREFIX}"
[ -s "${WORK}/miniconda.sh" ] || wget -nv -O "${WORK}/miniconda.sh" "${INSTALLER_URL}"
rm -rf "${PREFIX}"
bash "${WORK}/miniconda.sh" -b -p "${PREFIX}"
source "${PREFIX}/etc/profile.d/conda.sh"
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>/dev/null || true
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r 2>/dev/null || true

echo "Updating base from ${ENV_YAML}"
conda env update -n base -f "${WORK}/env.yaml"

echo "Packing ${PREFIX}"
conda create -y -n packer -c conda-forge conda-pack
rm -f "${OUT}"
conda run -n packer conda-pack -p "${PREFIX}" -o "${OUT}" \
    --exclude 'pkgs/*' --exclude 'envs/*' --ignore-missing-files --n-threads -1

ls -lh "${OUT}"

runner=$(command -v apptainer || command -v singularity || true)
if [ -n "${runner}" ]; then
    echo "Smoke test in a glibc 2.28 container"
    rm -rf "${WORK}/smoke"; mkdir -p "${WORK}/smoke"
    "${runner}" exec --bind "${WORK}:/work" docker://rockylinux:8 bash -c '
        set -e
        ldd --version | head -1
        tar -xzf /work/conda-env.tar.gz -C /work/smoke
        /work/smoke/bin/python /work/smoke/bin/conda-unpack
        for f in /work/smoke/bin/*; do
            if [ -f "$f" ] && [ ! -L "$f" ] && [ "$(head -c 21 "$f")" == "#!/usr/bin/env python" ]; then
                sed -i "1s|^#!/usr/bin/env python|#!/work/smoke/bin/python|" "$f"
            fi
        done
        source /work/smoke/etc/profile.d/conda.sh
        conda activate base
        jupyter-lab --version
        jupyter kernelspec list
        jupyter-lab --no-browser --ip 127.0.0.1 --port 18888 --ServerApp.token="" --ServerApp.root_dir=/work/smoke > /work/smoke.log 2>&1 &
        for i in $(seq 1 30); do
            python -c "import urllib.request; urllib.request.urlopen(\"http://127.0.0.1:18888/lab\")" 2>/dev/null && break
            sleep 2
        done
        python -c "import urllib.request; print(\"HTTP\", urllib.request.urlopen(\"http://127.0.0.1:18888/lab\").status)"
        kill %1
    '
    rm -rf "${WORK}/smoke"
else
    echo "No apptainer/singularity: skipping the glibc 2.28 smoke test"
fi

echo ""
echo "Build complete: ${OUT}"
echo ""
echo "Push to GitHub Container Registry (from ${WORK}, so the file is stored as conda-env.tar.gz):"
echo "  cd ${WORK}"
echo "  printf '%s' \"\${GHCR_TOKEN}\" | oras login ghcr.io -u <github-user> --password-stdin"
echo "  oras push ${REGISTRY}:${TAG} conda-env.tar.gz"
echo "  oras logout ghcr.io"
echo "A new package is private by default: make it public in the GitHub package settings, then verify"
echo "  TOKEN=\$(curl -s 'https://ghcr.io/token?service=ghcr.io&scope=repository:parallelworks/jupyterlab-conda:pull' | jq -r .token)"
echo "  curl -s -o /dev/null -w '%{http_code}\\n' -H \"Authorization: Bearer \$TOKEN\" -H 'Accept: application/vnd.oci.image.manifest.v1+json' https://ghcr.io/v2/parallelworks/jupyterlab-conda/manifests/${TAG}   # 200 (404 without the Accept header)"
