#!/bin/bash
# install-blast.sh <install directory>
# Builds, once, what fracturing a mesh of yours needs, under <install directory>/omniverse/blast:
# the NVIDIA Blast SDK's authoring libraries from the PhysX repository (BSD-3; its
# dependencies come through packman from NVIDIA's CDN, no account), the workflow's
# blast-fracture tool against them, and a Python venv with usd-core for make-scene.py.
# Runs on the login node (internet, compilers); idempotent: a finished install is kept.
set -eo pipefail
root="${1:?the install directory}/omniverse/blast"
app="$(cd "$(dirname "$0")" && pwd)"
if [ -x "${root}/blast-fracture" ] && [ -x "${root}/usd/bin/python" ]; then
    echo "::notice::The Blast SDK tools are in ${root}"
    exit 0
fi
for tool in git gcc g++ cmake make curl python3; do
    if ! command -v "${tool}" > /dev/null 2>&1; then
        echo "::error title=Error::Building the Blast SDK needs ${tool} on $(hostname)"
        exit 1
    fi
done
mkdir -p "${root}"
cd "${root}"
echo "::group::Blast SDK"
if ! [ -d PhysX/blast ]; then
    rm -rf PhysX
    git clone --depth 1 --filter=blob:none --sparse https://github.com/NVIDIA-Omniverse/PhysX.git
    (cd PhysX && git sparse-checkout set blast)
fi
cd PhysX/blast
# gcc 11 and later refuse three warnings the SDK's build turns into errors, and two
# sources miss an include each
sed -i 's/enablewarnings { "all", "vla" }/enablewarnings { "all" }/' premake5.lua
grep -q '"class-memaccess"' premake5.lua || sed -i 's/            "nonnull-compare"/            "nonnull-compare",\n            "class-memaccess",\n            "maybe-uninitialized"/' premake5.lua
f=source/sdk/extensions/authoring/NvBlastExtAuthoringPatternGeneratorImpl.cpp
grep -q '<cstdio>' "$f" || sed -i '0,/^#include/s//#include <cstdio>\n#include/' "$f"
f=source/sdk/extensions/stress/NvBlastExtStressSolver.cpp
grep -q '<limits>' "$f" || sed -i '0,/^#include/s//#include <limits>\n#include/' "$f"
sdk="${PWD}/_build/linux-x86_64/release/blast-sdk"
if ! [ -f "${sdk}/bin/libNvBlastExtAuthoring.so" ]; then
    ./setup.sh
    for target in NvBlastGlobals NvBlast NvBlastTk NvBlastExtShaders NvBlastExtAssetUtils NvBlastExtAuthoring; do
        ./build.sh --no-docker -r -t "${target}"
    done
fi
echo "::endgroup::"
echo "::group::blast-fracture"
cd "${root}"
cp "${app}/fracture/blast-fracture.cpp" "${app}/fracture/build.sh" .
bash ./build.sh "${sdk}"
echo "::endgroup::"
echo "::group::usd-core"
if ! [ -x "${root}/usd/bin/python" ]; then
    python3 -m venv "${root}/usd"
    "${root}/usd/bin/pip" -q install usd-core
fi
"${root}/usd/bin/python" -c "from pxr import Usd; print('usd-core', Usd.GetVersion())"
echo "::endgroup::"
echo "::notice::The Blast SDK tools are in ${root}"
