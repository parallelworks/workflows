#!/usr/bin/env bash
# Builds blast-fracture against a Blast SDK built from the NVIDIA PhysX repository
# (BSD-3): github.com/NVIDIA-Omniverse/PhysX, directory blast/.
#
#   git clone --depth 1 --filter=blob:none --sparse https://github.com/NVIDIA-Omniverse/PhysX.git
#   (cd PhysX && git sparse-checkout set blast && cd blast && ./setup.sh &&
#       for t in NvBlastGlobals NvBlast NvBlastTk NvBlastExtAuthoring; do ./build.sh --no-docker -r -t $t; done)
#   ./build.sh PhysX/blast/_build/linux-x86_64/release/blast-sdk
#
# The SDK's own build on Rocky 9 with gcc 11 needed, in blast/premake5.lua, the vla
# warning dropped from enablewarnings and class-memaccess and maybe-uninitialized added
# to disablewarnings, plus #include <cstdio> in
# source/sdk/extensions/authoring/NvBlastExtAuthoringPatternGeneratorImpl.cpp and
# #include <limits> in source/sdk/extensions/stress/NvBlastExtStressSolver.cpp (its
# test programs do not build there; the libraries above do). The SDK is built with
# the pre-C++11 ABI, so this tool is too.
set -euo pipefail
sdk="${1:?the blast-sdk directory (<blast>/_build/linux-x86_64/release/blast-sdk)}"
cd "$(dirname "$0")"
includes=()
while IFS= read -r dir; do includes+=(-I "${dir}"); done < <(find "${sdk}/include" -type d)
g++ -std=c++17 -O2 -D_GLIBCXX_USE_CXX11_ABI=0 "${includes[@]}" blast-fracture.cpp \
    -L"${sdk}/bin" -lNvBlastExtAuthoring -lNvBlast -lNvBlastGlobals -Wl,-rpath,"${sdk}/bin" -o blast-fracture
echo "built ./blast-fracture"
