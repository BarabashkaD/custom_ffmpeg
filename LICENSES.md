# Licenses

## This repository

The build system (scripts, CMake modules, CI, tests) is MIT-licensed — see
[LICENSE](LICENSE). Patches in `patches/<project>/` modify third-party code and
are licensed under that project's license (table below).

## Third-party components

| Component | License | License files (in `sources/` or the tarball) | Used by profiles |
|---|---|---|---|
| FFmpeg | LGPL-2.1-or-later; GPL-2.0-or-later with `--enable-gpl` | `ffmpeg/LICENSE.md`, `COPYING.LGPLv2.1`, `COPYING.GPLv2` | all |
| x264 | GPL-2.0-or-later | `x264/COPYING` | full |
| x265 | GPL-2.0-or-later | `x265/COPYING` | full |
| libvpx | BSD-3-Clause + patent grant | `libvpx/LICENSE`, `libvpx/PATENTS` | full, lgpl |
| libwebp | BSD-3-Clause + patent grant | `libwebp/COPYING`, `libwebp/PATENTS` | full, lgpl |
| Opus | BSD-3-Clause | `opus/COPYING` | full, lgpl |
| libogg | BSD-3-Clause | `libogg/COPYING` | full, lgpl |
| libvorbis | BSD-3-Clause | `libvorbis/COPYING` | full, lgpl |
| LAME (mp3lame) | LGPL-2.0-or-later | `COPYING`, `LICENSE` in `lame-<version>.tar.gz` | full, lgpl |
| zlib | Zlib | `zlib/LICENSE` | full, lgpl |
| SVT-AV1 | BSD-3-Clause-Clear + AOMedia Patent License 1.0; bundled: fastfeat (BSD-3-Clause), safestringlib (MIT) | `svtav1/LICENSE.md`, `svtav1/PATENTS.md`, `svtav1/third_party/fastfeat/LICENSE`, `svtav1/third_party/safestringlib/LICENSE` | full, lgpl |
| dav1d | BSD-2-Clause | `dav1d/COPYING` | full, lgpl |
| nv-codec-headers (ffnvcodec) | MIT (headers only, nothing linked) | license header in each `ffnvcodec/include/ffnvcodec/*.h` | full, lgpl (Windows, Linux) |
| AMD AMF headers | MIT (headers only, nothing linked; header comments; AMD's notice: no license to codec patents/standards) | MIT text in every header of `AMF-headers-v<version>.tar.gz`; the AMF repository's `LICENSE.txt` | full, lgpl (Windows, Linux) |
| checkasm | BSD-2-Clause | `checkasm/LICENSE` | none — dav1d's test program only, not in any library |
| libvpl (Intel VPL dispatcher) | MIT | `libvpl/LICENSE`, `libvpl/third-party-programs.txt` | full, lgpl (Windows, Linux) |
| libva (VA-API, with libva-drm) | MIT | `libva/COPYING` | full, lgpl (Linux) |
| libdrm (core library only) | MIT | license header in each source file (`libdrm/xf86drm.c`, ...); `license : 'MIT'` in `libdrm/meson.build` | full, lgpl (Linux) |
| libva-utils | MIT; bundled googletest: BSD-3-Clause | `libva-utils/COPYING`, `libva-utils/test/gtest/LICENSE` | none — vainfo and the test_va_api test program only, not in any library |
| libaom (branch `av1-normative`, decoder only) | BSD-2-Clause + AOMedia Patent License 1.0 | `libaom/LICENSE`, `libaom/PATENTS` | none — reference decoder linked into SVT-AV1's `SvtAv1E2ETests` only, not installed, not in any library |

Patches: `patches/x264` and `patches/x265` are GPL-2.0-or-later,
`patches/libvpx` is BSD-3-Clause, `patches/libvpl` and `patches/libva` are MIT.

## License of the built libraries

The license of a build is fixed by its profile and checked during the build
(`FFMPEG_EXPECTED_LICENSE` in the profile against FFmpeg's configure result):

| Profile | Contents | License of the result |
|---|---|---|
| `minimal` | avutil + swscale | **LGPL-2.1-or-later** |
| `lgpl` | all FFmpeg libraries, VP8/VP9, AV1 (SVT-AV1 encoding, dav1d decoding), Opus, Vorbis, WebP, MP3, zlib, OS encoders/decoders, NVIDIA NVENC/NVDEC, AMD AMF, Intel QSV, VAAPI (Linux) | **LGPL-2.1-or-later** |
| `full` | `lgpl` + x264 + x265 | **GPL-2.0-or-later** |

What this means in practice (a summary, not legal advice):

- **LGPL builds** (`minimal`, `lgpl`) can be used by proprietary applications.
  The usual way is the **shared** build (DLL / `.so` / `.dylib`): users can
  replace the FFmpeg libraries. With the **static** build the application must
  additionally make relinking possible (e.g. provide its object files).
  Changes to FFmpeg or LAME themselves must be released under the LGPL.
- **GPL builds** (`full`) may only be used by GPL-compatible applications that
  are distributed with their source code — static or shared linking makes no
  difference for the GPL. Proprietary applications can use H.264/HEVC through
  the `lgpl` profile (FFmpeg's decoders; OS encoders: Media Foundation on
  Windows, VideoToolbox on macOS), by running an encoder as a separate
  process, or under a commercial x264/x265 license.
- **Distributing binaries** of any profile: ship the license texts of all
  included components and point to the corresponding source — the matching
  tag of this repository with its submodules and the LAME tarball
  (`versions.cmake`).
- **Patents** are separate from copyright: H.264/HEVC may require patent
  licenses depending on product and jurisdiction; libvpx and libwebp come with
  a royalty-free patent grant (their `PATENTS` files), SVT-AV1 with the
  royalty-free Alliance for Open Media Patent License 1.0 (`PATENTS.md`).
- LAME asks to be acknowledged in products that use it (its `LICENSE` file).
- **NVIDIA NVENC/NVDEC/CUDA** (Windows, Linux): only the MIT headers are
  compiled in; FFmpeg loads the proprietary driver libraries (`nvcuda.dll`,
  `nvEncodeAPI64.dll`, `libcuda.so.1`, ...) from the user's NVIDIA driver at
  run time — nothing of the driver is linked or shipped. The `nonfree` CUDA
  parts (`cuda-nvcc`, `libnpp`) are not enabled; the CUDA filters are compiled
  by clang (`cuda-llvm`).
- **Intel QSV** (Windows, Linux): only the libvpl dispatcher (MIT) is linked in;
  the runtime it loads (`libmfx64-gen.dll`, `libmfx-gen.so.1.2`) is part of the
  Intel GPU driver and is not distributed with the build.
- **VAAPI** (Linux): libva and libdrm (MIT) are linked in; the VA driver
  (`iHD_drv_video.so`, `radeonsi_drv_video.so`, ...) comes from the user's
  system and is loaded at run time — nothing of it is linked or shipped.
