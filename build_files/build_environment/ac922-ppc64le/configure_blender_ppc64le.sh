#!/usr/bin/env bash
# Configure Blender (4.5 LTS) for ppc64le, headless, against a private dependency prefix.
# Verified against blender-4.5.16 on AlmaLinux 8.10 / POWER9, GCC 12 (gcc-toolset-12).
#
#   DEPS_PREFIX=/opt/blender-deps-ppc64le ./install_deps_ppc64le.sh
#   DEPS_PREFIX=/opt/blender-deps-ppc64le ./configure_blender_ppc64le.sh
#   cmake --build build -j"$(nproc)" && cmake --install build
#
# The three things that are easy to get wrong:
#   1. WITH_LIBS_PRECOMPILED=OFF is the whole trick. platform_unix.cmake only builds a
#      LIBDIR name from ${CMAKE_SYSTEM_PROCESSOR}, has no ppc64le prebuilt tree, and when
#      LIBDIR is missing it degrades to a STATUS message and sets WITH_LIBS_PRECOMPILED
#      back to OFF -- which also auto-disables WITH_CPU_CHECK. No source patch needed.
#   2. Re-run configure with -U for every package Find-module that can also be satisfied by
#      a distro package. FindFreetype/FindFFTW3 happily cache /usr/include, and a warm cache
#      then beats CMAKE_PREFIX_PATH forever: configure dies with "Freetype needs to be
#      compiled with brotli support!" while pointing at the wrong library.
#   3. Do not pass WITH_STRICT_BUILD_OPTIONS=ON; it turns the missing-LIBDIR notice into
#      a hard error.
set -euo pipefail

SRCD=${SRCD:-../blender-4.5.16}
BDIR=${BDIR:-build-ppc64le}
PREFIX=${DEPS_PREFIX:?set DEPS_PREFIX to the install_deps_ppc64le.sh prefix}
INST=${INST:-/opt/blender-ppc64le}

if [ -e /opt/rh/gcc-toolset-12/enable ]; then
  # shellcheck disable=SC1091
  source /opt/rh/gcc-toolset-12/enable
fi

exec cmake -S "$SRCD" -B "$BDIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INST" \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_INSTALL_RPATH="$PREFIX/lib;$PREFIX/lib64" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DPython_EXECUTABLE=/usr/bin/python3.11 \
  -DFFTW3_ROOT_DIR="$PREFIX" \
  -U 'FREETYPE*' -U 'HAVE_BROTLI*' -U 'FFTW3*' \
  -DWITH_LIBS_PRECOMPILED=OFF \
  -DWITH_INSTALL_PORTABLE=OFF \
  -DWITH_HEADLESS=ON \
  -DWITH_SYSTEM_FREETYPE=ON \
  -DWITH_PYTHON=ON -DWITH_PYTHON_INSTALL=OFF \
  -DWITH_BUILDINFO=OFF -DWITH_INTERNATIONAL=OFF -DWITH_MEM_JEMALLOC=OFF \
  -DWITH_OPENCOLORIO=ON -DWITH_IMAGE_OPENEXR=ON \
  -DWITH_CYCLES=ON \
  -DWITH_CYCLES_OSL=OFF -DWITH_CYCLES_EMBREE=OFF -DWITH_CYCLES_PATH_GUIDING=OFF \
  -DWITH_CYCLES_LOGGING=OFF -DWITH_OPENIMAGEDENOISE=OFF \
  -DWITH_USD=OFF -DWITH_MATERIALX=OFF -DWITH_HYDRA=OFF \
  -DWITH_OPENCOLLADA=OFF -DWITH_ALEMBIC=OFF -DWITH_OPENVDB=OFF -DWITH_NANOVDB=OFF \
  -DWITH_OPENSUBDIV=OFF -DWITH_LIBMV=OFF -DWITH_FREESTYLE=OFF \
  -DWITH_CODEC_FFMPEG=OFF -DWITH_CODEC_SNDFILE=OFF \
  -DWITH_MANIFOLD=OFF -DWITH_QUADRIFLOW=OFF -DWITH_UV_SLIM=OFF \
  -DWITH_POTRACE=OFF -DWITH_HARU=OFF -DWITH_OPENAL=OFF -DWITH_INPUT_NDOF=OFF \
  -DWITH_VULKAN_BACKEND=OFF -DWITH_DRACO=OFF \
  -DWITH_MOD_FLUID=OFF -DWITH_MOD_OCEANSIM=OFF \
  -DWITH_IMAGE_WEBP=OFF -DWITH_IMAGE_OPENJPEG=OFF
