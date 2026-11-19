#!/usr/bin/env bash
# Build the libraries Blender needs on ppc64le Linux (RHEL8/AlmaLinux 8/Rocky 8 family).
#
# Blender ships no precompiled libraries for ppc64le, and its CMake refuses the system
# copies of several of them, so build a private prefix from the versions pinned in
# build_files/build_environment/cmake/versions.cmake.
#
# Why each library is here (all four blockers were found the hard way):
#   OpenImageIO   REQUIRED unconditionally (platform_unix.cmake), and OIIO 3.0 itself
#                 hard-requires OpenColorIO >= 2.0 (dependency_utils.cmake "OpenColorIO is
#                 required, aborting") even though Blender treats OCIO as optional.
#   TBB >= 2021   CMake asks for exactly 2021.13.0; WITH_TBB=OFF silently disables Cycles
#                 (CMakeLists.txt "set_and_warn_dependency(WITH_TBB WITH_CYCLES OFF)").
#   FreeType      both FreeType code paths call check_freetype_for_brotli(), which is a
#                 FATAL_ERROR when the library lacks brotli (WOFF2). System FreeType does.
#                 Build it SHARED: FindFreetype does not add brotli to FREETYPE_LIBRARIES,
#                 so a static libfreetype.a leaves brotliDecode undefined at final link.
#   FFTW >= 3.3.9 blenlib/intern/fftw.cc calls fftwf_threads_set_callback(), added in FFTW
#                 3.3.9; the distro's 3.3.5 does not have it.
#
# Deliberately NOT applied: build_files/build_environment/patches/fftw3.diff.
#   Its config.h.in hunk deletes "#undef HAVE_GETTIMEOFDAY"; with that line gone autoconf
#   never writes the macro, so libbench2/timer.c dies on '#error "timer not defined"'.
#   The other hunk only silences an assert message. Skip the whole patch.
# Also note FFTW 3.3.10 does not support out-of-tree (VPATH) builds: configure inside the
#   source tree, once per precision variant.
set -uo pipefail

PREFIX=${PREFIX:-/opt/blender-deps-ppc64le}
SRC=${SRC:-$PREFIX/src}
LOGD=${LOGD:-$PREFIX/logs}
JOBS=${JOBS:-$(nproc)}
NUMA=()
if command -v numactl >/dev/null 2>&1 && [ -n "${NUMA_BIND:-}" ]; then
  NUMA=(numactl $NUMA_BIND)   # e.g. NUMA_BIND="--membind=0,8 --cpunodebind=8"
fi

mkdir -p "$PREFIX" "$SRC" "$LOGD"
if [ -e /opt/rh/gcc-toolset-12/enable ]; then
  # shellcheck disable=SC1091
  source /opt/rh/gcc-toolset-12/enable   # Blender needs GCC >= 11 (CMakeLists.txt)
elif [ "$(gcc -dumpversion | cut -d. -f1)" -lt 11 ]; then
  echo "need GCC >= 11: dnf install gcc-toolset-12-gcc gcc-toolset-12-gcc-c++" >&2
  exit 1
fi
export CC=gcc CXX=g++
export PKG_CONFIG_PATH="$PREFIX/lib64/pkgconfig:$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

log() { echo "[deps $(date -Is)] $*"; }
fetch() { # $1=url $2=dest
  [ -s "$2" ] && { log "cache hit $2"; return 0; }
  curl -fL --retry 5 --retry-delay 3 -sS -o "$2.part" "$1" || return 1
  mv -f "$2.part" "$2"
}
untar() { [ -d "$2" ] && return 0; mkdir -p "$2" && tar -xzf "$1" -C "$2" --strip-components=1; }
cmake_build() { # $1=name $2=srcdir $3=skip-if-exists-path $4..=cmake args
  local name=$1 srcdir=$2 sentinel=$3; shift 3
  if [ -n "$sentinel" ] && [ -e "$PREFIX/$sentinel" ]; then
    log "skip $name ($PREFIX/$sentinel present)"; return 0
  fi
  log "BEGIN $name"
  cmake -S "$srcdir" -B "$srcdir/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_RPATH="$PREFIX/lib;$PREFIX/lib64" \
    "$@" > "$LOGD/$name.cfg.log" 2>&1 || { log "CONFIGURE-FAIL $name (see $LOGD/$name.cfg.log)"; return 1; }
  "${NUMA[@]}" cmake --build "$srcdir/build" -j "$JOBS" > "$LOGD/$name.build.log" 2>&1 || \
    { log "BUILD-FAIL $name (see $LOGD/$name.build.log)"; return 1; }
  cmake --install "$srcdir/build" > "$LOGD/$name.inst.log" 2>&1 || { log "INSTALL-FAIL $name"; return 1; }
  log "DONE $name"
}

# --------------------------------------------------------------- system packages
# ninja-build lives in powertools/CRB on RHEL8; WITH_SYSTEM_FREETYPE still needs the
# headers only for the check, but we ship our own, so pull everything below anyway.
install_system_packages() {
  dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
  local pkgs="gcc-toolset-12-gcc gcc-toolset-12-gcc-c++ gcc-toolset-12-binutils
    gcc-toolset-12-libstdc++-devel ninja-build patch cmake git
    zlib-devel libzstd-devel libpng-devel libtiff-devel xz-devel lzo-devel
    pugixml-devel boost-devel gmp-devel python3.11-devel gettext-devel fftw-devel
    expat-devel yaml-cpp-devel libepoxy-devel sqlite-devel
    mesa-libGL-devel mesa-libEGL-devel libdrm-devel spirv-headers-devel
    libX11-devel libXcursor-devel libXi-devel libXxf86vm-devel libxkbcommon-devel
    shared-mime-info desktop-file-utils"
  local p miss=""
  for p in $pkgs; do
    dnf install -y --exclude='nvidia-driver*' "$p" >/dev/null 2>&1 || miss="$miss $p"
  done
  [ -n "$miss" ] && log "WARN not available (usually fine):$miss"
}
[ "${SKIP_DNF:-0}" = 1 ] || install_system_packages

# Let the loader find the prefix for helper tools that carry no rpath (oiiotool, occioctl).
if [ "$(id -u)" = 0 ]; then
  printf '%s\n%s\n' "$PREFIX/lib" "$PREFIX/lib64" > /etc/ld.so.conf.d/blender-deps-ppc64le.conf
  ldconfig 2>/dev/null || true
fi

# --------------------------------------------------------------------- libraries
# Versions below are Blender 4.5 LTS pins; keep them in sync with versions.cmake.
fetch https://github.com/fmtlib/fmt/archive/refs/tags/9.1.0.tar.gz "$SRC/fmt-9.1.0.tar.gz" \
  && untar "$SRC/fmt-9.1.0.tar.gz" "$SRC/fmt-9.1.0" \
  && cmake_build fmt "$SRC/fmt-9.1.0" include/fmt/core.h -DFMT_TEST=OFF -DFMT_DOC=OFF \
  || { log "ABORT fmt"; exit 1; }

fetch https://github.com/uxlfoundation/oneTBB/archive/refs/tags/v2021.13.0.tar.gz "$SRC/oneTBB-v2021.13.0.tar.gz" \
  && untar "$SRC/oneTBB-v2021.13.0.tar.gz" "$SRC/oneTBB-v2021.13.0" \
  && cmake_build tbb "$SRC/oneTBB-v2021.13.0" include/tbb/tbb.h \
       -DTBB_TEST=OFF -DTBB_BUILD_STATIC=OFF -DTBB_STRICT=OFF \
  || { log "ABORT tbb"; exit 1; }

fetch https://github.com/AcademySoftwareFoundation/Imath/archive/v3.1.7.tar.gz "$SRC/Imath-3.1.7.tar.gz" \
  && untar "$SRC/Imath-3.1.7.tar.gz" "$SRC/Imath-3.1.7" \
  && cmake_build imath "$SRC/Imath-3.1.7" include/Imath/ImathVec.h \
       -DBUILD_TESTING=OFF -DIMATH_BUILD_BENCH=OFF \
  || { log "ABORT imath"; exit 1; }

fetch https://github.com/AcademySoftwareFoundation/openexr/archive/v3.3.11.tar.gz "$SRC/openexr-3.3.11.tar.gz" \
  && untar "$SRC/openexr-3.3.11.tar.gz" "$SRC/openexr-3.3.11" \
  && cmake_build openexr "$SRC/openexr-3.3.11" include/OpenEXR/openexr.h \
       -DBUILD_TESTING=OFF -DOPENEXR_BUILD_EXAMPLES=OFF \
  || { log "ABORT openexr"; exit 1; }

fetch https://github.com/libjpeg-turbo/libjpeg-turbo/archive/2.1.3.tar.gz "$SRC/libjpeg-turbo-2.1.3.tar.gz" \
  && untar "$SRC/libjpeg-turbo-2.1.3.tar.gz" "$SRC/libjpeg-turbo-2.1.3" \
  && cmake_build jpeg "$SRC/libjpeg-turbo-2.1.3" include/turbojpeg.h \
       -DENABLE_TESTING=OFF -DWITH_JPEG8=ON -DENABLE_STATIC=ON \
  || { log "ABORT jpeg"; exit 1; }   # OIIO 3.0 looks for the `libjpeg-turbo` CMake package

fetch https://github.com/AcademySoftwareFoundation/OpenColorIO/archive/v2.4.1.tar.gz "$SRC/OpenColorIO-2.4.1.tar.gz" \
  && untar "$SRC/OpenColorIO-2.4.1.tar.gz" "$SRC/OpenColorIO-2.4.1" \
  && cmake_build ocio "$SRC/OpenColorIO-2.4.1" include/OpenColorIO/OpenColorIO.h \
       -DOCIO_INSTALL_EXT_PACKAGES=MISSING -DOCIO_BUILD_PYTHON=OFF -DOCIO_BUILD_APPS=OFF \
       -DOCIO_BUILD_DOCS=OFF -DOCIO_BUILD_TESTS=OFF -DOCIO_BUILD_GPU_TESTS=OFF \
       -DOCIO_WARNING_AS_ERROR=OFF \
  || { log "ABORT ocio"; exit 1; }   # MISSING lets OCIO fetch its own minizip-ng/yaml-cpp

fetch https://github.com/google/brotli/archive/refs/tags/v1.0.9.tar.gz "$SRC/brotli-1.0.9.tar.gz" \
  && untar "$SRC/brotli-1.0.9.tar.gz" "$SRC/brotli-1.0.9" \
  && cmake_build brotli "$SRC/brotli-1.0.9" include/brotli/decode.h -DBROTLI_DISABLE_TESTS=ON \
  || { log "ABORT brotli"; exit 1; }

fetch https://github.com/freetype/freetype/archive/VER-2-13-0.tar.gz "$SRC/freetype-2.13.0.tar.gz" \
  && untar "$SRC/freetype-2.13.0.tar.gz" "$SRC/freetype-2.13.0" \
  && cmake_build freetype "$SRC/freetype-2.13.0" lib64/libfreetype.so \
       -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=ON \
       -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_PNG=ON \
       -DFT_REQUIRE_BROTLI=ON -DFT_REQUIRE_ZLIB=ON \
       -DPC_BROTLIDEC_INCLUDEDIR="$PREFIX/include" -DPC_BROTLIDEC_LIBDIR="$PREFIX/lib64" \
  || { log "ABORT freetype"; exit 1; }

# --------------------------------------------------------------- FFTW 3.3.10 x2
# In-tree builds only, double first then float (same header serves both families; the
# threads callback lives in libfftw3{,f}_threads.a, which FindFftw3.cmake looks up).
FFTW_MD5=8ccbf6a5ea78a16dbc3e1306e234cc5c
if [ ! -e "$PREFIX/lib/libfftw3f_threads.a" ]; then
  fetch http://www.fftw.org/fftw-3.3.10.tar.gz "$SRC/fftw-3.3.10.tar.gz" || { log "ABORT fftw fetch"; exit 1; }
  echo "$FFTW_MD5  $SRC/fftw-3.3.10.tar.gz" | md5sum -c - || { log "ABORT fftw md5"; exit 1; }
  for variant in double float; do
    T=$SRC/fftw-$variant
    if [ ! -d "$T" ]; then mkdir -p "$T"; tar -xzf "$SRC/fftw-3.3.10.tar.gz" -C "$T" --strip-components=1; fi
    args=(--enable-static --enable-threads --with-pic --without-omp "--prefix=$PREFIX")
    [ "$variant" = float ] && args+=(--enable-float)
    log "BEGIN fftw-$variant"
    ( cd "$T" && ./configure "${args[@]}" > "$LOGD/fftw-$variant.cfg.log" 2>&1 ) || { log "CONFIGURE-FAIL fftw-$variant"; exit 1; }
    grep -q '^#define HAVE_GETTIMEOFDAY 1' "$T/config.h" || { log "CONFIG-H-SUSPECT fftw-$variant"; exit 1; }
    "${NUMA[@]}" make -C "$T" -j "$JOBS" > "$LOGD/fftw-$variant.build.log" 2>&1 || { log "BUILD-FAIL fftw-$variant"; exit 1; }
    make -C "$T" install > "$LOGD/fftw-$variant.inst.log" 2>&1 || { log "INSTALL-FAIL fftw-$variant"; exit 1; }
    log "DONE fftw-$variant"
  done
fi

# ------------------------------------------------------------ OpenImageIO 3.0.19.1
fetch https://github.com/AcademySoftwareFoundation/OpenImageIO/archive/refs/tags/v3.0.19.1.tar.gz "$SRC/OpenImageIO-v3.0.19.1.tar.gz" \
  && untar "$SRC/OpenImageIO-v3.0.19.1.tar.gz" "$SRC/OpenImageIO-v3.0.19.1" \
  && cmake_build openimageio "$SRC/OpenImageIO-v3.0.19.1" include/OpenImageIO/imageio.h \
       -DUSE_PYTHON=OFF -DBUILD_TESTING=OFF -DOIIO_BUILD_TESTS=OFF -DBUILD_DOCS=OFF \
       -DUSE_QT=OFF -DUSE_FFMPEG=OFF -DUSE_OPENVDB=OFF -DUSE_PTEX=OFF -DUSE_HDF5=OFF \
       -DUSE_AVIF=OFF -DUSE_WEBP=OFF -DUSE_OPENJPEG=OFF -DUSE_GIF=OFF -DUSE_FREEIMAGE=OFF \
       -DUSE_FREETYPE=OFF -DUSE_OPENCV=OFF -DUSE_OPENSSL=OFF -DUSE_NAS=OFF -DUSE_DCACHE=OFF \
       -DUSE_libuhdr=OFF -DUSE_JXL=OFF -DUSE_OCIO=ON -DLINKSTATIC=OFF -DSTOP_ON_WARNING=OFF \
  || { log "ABORT openimageio"; exit 1; }

log "ALL-DEPS-DONE prefix=$PREFIX"
