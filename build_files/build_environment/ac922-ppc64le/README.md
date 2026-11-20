# Blender on ppc64le (POWER9 / RHEL8 family)

Build recipe for running Blender headless on **ppc64le**, verified 2026-11-19 on
AlmaLinux 8.10 + POWER9 (176 threads) against the **Blender 4.5.16 LTS** source tarball.

Target is the 4.5.16 LTS tarball, not this branch's `main`; this branch exists only to
hold the recipe, and the file paths quoted below are the 4.5.16 paths.

## No source patch was required

`git diff` against the 4.5.16 tarball is empty -- including the Cycles-CUDA work below.
ppc64le needs build-configuration work only; the CMake platform layer and
`BLI_build_config.h` already know the architecture
(`source/blender/blenlib/BLI_build_config.h:296-303` defines `ARCH_CPU_PPC64` for both
endiannesses). Everything below is dependency and flag work.

## Why build from source

* `linuxserver/blender` and every other container image publish `amd64`/`arm64` only.
* Blender 1.0 -> 5.3 never shipped a ppc64le package (checked release-by-release on two
  mirrors), and PyPI `bpy` ships `macosx_arm64` / `manylinux_x86_64` / `win_amd64` /
  `win_arm64` only.
* The dependency build system has no ppc64le library directory name, so
  `WITH_LIBS_PRECOMPILED=OFF` + a private prefix is the way in.

## The four blockers, in build order

| # | Blocker | Where it bites | Fix |
|---|---------|----------------|-----|
| 1 | `OpenImageIO` is `REQUIRED` with no opt-out | `build_files/cmake/platform/platform_unix.cmake:509` | build OIIO 3.0.19.1 |
| 1b | OIIO 3.0 itself hard-requires `OpenColorIO >= 2.0` -- even though Blender treats OCIO as optional (`set_and_warn_library_found`, `:513`) | `OpenImageIO/src/cmake/dependency_utils.cmake:157` "OpenColorIO is required, aborting" | build OCIO 2.4.1 with `-DOCIO_INSTALL_EXT_PACKAGES=MISSING` (pulls its own minizip-ng/yaml-cpp) |
| 2 | TBB must be >= 2021.13.0, and `WITH_TBB=OFF` silently kills Cycles | `platform_unix.cmake:565`, `CMakeLists.txt:1353` | build oneTBB 2021.13.0 (distro ships 2018) |
| 3 | FreeType must be compiled with brotli; the check is a `FATAL_ERROR` on *both* find paths | `platform_unix.cmake:178`, called from `:206` and `:681` | build FreeType 2.13.0 `-DFT_REQUIRE_BROTLI=ON`, **shared** |
| 4 | `blenlib/intern/fftw.cc:94` calls `fftwf_threads_set_callback()`, added in FFTW 3.3.9 | distro fftw 3.3.5 has no such symbol | build FFTW 3.3.10 twice (double, then `--enable-float`) |

Two further traps worth writing down:

* **Stale Find-module cache wins over `CMAKE_PREFIX_PATH`.** Once `FREETYPE_INCLUDE_DIR_*`
  or `FFTW3_LIBRARY_*` is cached from the distro copy, every later configure keeps using it
  and fails with "Freetype needs to be compiled with brotli support!". `configure_blender_ppc64le.sh`
  therefore passes `-U 'FREETYPE*' -U 'HAVE_BROTLI*' -U 'FFTW3*'` on every run.
* **Skip `patches/fftw3.diff`.** Its `config.h.in` hunk deletes `#undef HAVE_GETTIMEOFDAY`;
  with that line gone autoconf never writes the macro and `libbench2/timer.c` dies on
  `#error "timer not defined"`. The other hunk only mutes an assert message. FFTW 3.3.10 also
  does not support out-of-tree (VPATH) builds -- configure inside the source tree.
* FreeType has to be **shared**: `FindFreetype` does not add brotli to `FREETYPE_LIBRARIES`,
  so a static `libfreetype.a` reaches the final link with `brotliDecode` undefined.

## Feature matrix of this configuration

Off, because the dependency is absent or not worth a ppc64le port:
`USD` / `MATERIALX` / `HYDRA`, `OPENCOLLADA`, `ALEMBIC`, `OPENVDB` / `NANOVDB`,
`OPENSUBDIV`, `OPENIMAGEDENOISE`, `CYCLES_OSL`, `CYCLES_EMBREE`, `CYCLES_PATH_GUIDING`,
`LIBMV`, `FREESTYLE`, `CODEC_FFMPEG` / `CODEC_SNDFILE`, `MANIFOLD`, `QUADRIFLOW`,
`UV_SLIM`, `POTRACE`, `HARU`, `OPENAL`, `VULKAN_BACKEND`, `DRACO`, `MOD_FLUID`,
`MOD_OCEANSIM`, `INTERNATIONAL`, `MEM_JEMALLOC`, `PYTHON_INSTALL`, `HEADLESS=ON`.

Practical consequences: glTF/GLB and every mesh/data path, `bpy` scripting, procedural
geometry and Cycles CPU rendering are all intact. Video *encoding* is absent (render PNG
frames and encode out-of-process). Subsurf renders as base mesh until OpenSubdiv is
built. Headless also means no EEVEE and no OpenGL.

`WITH_HARFBUZZ` came back OFF on its own: the distro's harfbuzz 1.7.5 is not found by
`find_package(Harfbuzz)`. It only affects text shaping (Blender Text objects / UI fonts).

## Cycles-CUDA on V100 (sm_70)

GPU rendering works on ppc64le too: `nvcc` 12.4 builds and runs `sm_70` there (self-test
prints `gpu=Tesla V100-SXM2-16GB cc=70 err=no error`). Two things are worth knowing:

* **A non-empty device list proves nothing.** `WITH_CYCLES_DEVICE_CUDA` defaults ON and
  `WITH_CUDA_DYNLOAD` dlopens `libcuda`, so Cycles happily *lists* the card while
  `WITH_CYCLES_CUDA_BINARIES` -- default **OFF** (`CMakeLists.txt:673`) -- has compiled zero
  kernels. The failure then surfaces as a misleading `Out of memory`. Verify with
  `ls .../addons_core/cycles/lib/kernel_sm_70.cubin.zst`, not with the device list.
* **Pin the arch and the host compiler.** The default `CYCLES_CUDA_BINARIES_ARCH` list still
  carries targets CUDA 12 skips; ask for `sm_70` alone. `CUDA_HOST_COMPILER` must be the same
  GCC Blender itself uses (gcc-toolset-12 here). 4.5 folds all kernels into one `kernel.cu`
  TU, so the whole build is a single cubin: ~5 min on POWER9, 22,880,608 B, installed
  zstd-compressed beside the Cycles add-on. That precompilation is why GPU cold start costs
  only +0.2 s (compare ~100 s of first-use Metal kernel compilation on Apple silicon).

`CUDA_ON=1 ./configure_blender_ppc64le.sh` is the switch; `WITH_CYCLES_DEVICE_OPTIX` stays OFF
(no OptiX SDK on ppc64le).

Measured crossover, same scene and samples, warm wall time, 176 POWER9 threads vs one V100:

| frame | CUDA (sm_70) | CPU | winner |
|---|---|---|---|
| 256x192 / 16 spp | 0.3 s | **0.1 s** | CPU |
| 640x360 / 32 spp | 0.6 s | 0.7 s | tie -- crossover is ~0.23 MP |
| 960x540 / 64 spp | **0.9 s** | 2.6 s | GPU 2.9x |
| 1280x720 / 64 spp | **1.2 s** | 4.3 s | GPU 3.6x |

So: small previews on CPU, anything at or above ~0.5 MP on the GPU.

GPU and CPU agree numerically at 1280x720 / 64 spp -- image luma 90.67, std 75.11 and 65.9 %
non-black pixels identical, per-pixel `|delta luma|` mean 0.000, p99 0.000, max 2.2/255. That
is rounding-level agreement, **not** bit-identical output, so do not gate GPU/CPU equivalence
on a file hash (the same holds for the GLB table below). Memory returns to idle after exit;
no leak observed.

## Verification

`blender --version` -> `Blender 4.5.16 LTS`, no unresolved `ldd` entries.
The smoke script builds a subsurfed sphere+torus, exports GLB, renders with Cycles.

* GLB 240,276 bytes, glTF v2 header OK.
* Cycles CPU, 256x192 / 16 samples: **0.2 s cold, 0.0-0.1 s warm** -- faster on
  176 POWER9 threads than an Apple-silicon Metal GPU on the same script (0.9-2.4 s,
  plus ~100 s of one-time kernel compilation). Small preview frames belong on CPU here.
* Cycles CUDA (sm_70, `smoke.png` rendered on device 0 of the visible set): renders, matches
  the CPU image to within 2.2/255 per pixel, and releases all card memory on exit.

Cross-architecture byte comparison of the exported GLB (arm64 vs ppc64le, and three
repeat runs on the *same* machine) -- all three runs differ, so this is not an
architecture effect:

| bufferView | content | differs |
|---|---|---|
| positions, normals | float32 | **no, bit-identical** |
| `TEXCOORD_0` | float32 | 527/4512 elements, <= 1 ULP (~1e-7) |
| triangle indices | uint32 | every slot differs, but the **multiset is identical** |

Read that as: same topology, exact positions/normals, UV rounding noise, and a different
triangle *emission order* from threaded tessellation. Byte-stable GLB is not a property of
Blender on any platform; hash exported meshes on canonicalised content if you need caching.

## Not yet done

* OpenSubdiv (subsurf), harfbuzz (text shaping), ffmpeg (video encoding), and
  OpenImageDenoise (denoiser quality) would each be a follow-up dependency build.
* Only `sm_70` was built. Cards older than Volta need the arch list widened; Turing or newer
  additionally want OptiX, which has no ppc64le SDK.
* Multi-GPU was not exercised: nothing here tests two Cycles devices in one process, and a
  shared host wants `CUDA_VISIBLE_DEVICES` pinned to the cards you own.
