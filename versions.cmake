# Central version registry for custom_ffmpeg.
#
# Submodules (sources/) are pinned to release tags — the commit is recorded in
# the superproject; this list documents which tag each one is:
#   ffmpeg     n8.1.3
#   x264       stable branch (x264 has no release tags)
#   x265       4.2
#   libvpx     v1.17.0
#   opus       v1.6.1
#   libogg     v1.3.6
#   libvorbis  v1.3.7
#   libwebp    v1.6.0
#   zlib       v1.3.2
#   svtav1     v4.2.0
#   dav1d      1.5.4
#   checkasm   v1.2.0  (dav1d's test framework; must match dav1d's
#                       subprojects/checkasm.wrap — build/deps/dav1d.sh checks)
#   ffnvcodec  n12.1.14.0  (nv-codec-headers, NVENC/NVDEC API 12.1)
#              FFmpeg 8.1 configure accepts >= 12.1.14.0 (main line) or the
#              legacy 12.0/11.x/8.1 lines; 12.x is the first API with AV1
#              (av1_nvenc / AV1 NVDEC). The header API version is the minimum
#              NVIDIA driver at run time: 12.1 -> Windows 531.61, Linux
#              530.41.03 (spring 2023). Newer lines raise it (12.2: 551.76 /
#              550.54.14, 13.0: 570, 13.1: 610) for features FFmpeg merely
#              gates with #ifdef (temporal filter, UHQ tuning, 10-bit H.264,
#              4:2:2) — broad driver support wins.
#   libvpl     v2.17.0
#   libdrm     libdrm-2.4.134  (Linux only; core library for libva-drm/FFmpeg)
#   libva      2.24.1  (Linux only; VA-API 1.24, July 2026. FFmpeg 8.1
#                       configure accepts libva >= 0.35 but enables parts by
#                       header: AV1 encoding needs 2.14, VVC decoding 2.22)
#   libva-utils 2.24.0 (vainfo + test_va_api for libva's own tests; the
#                       release matching libva 2.24)
#   libaom     av1-normative @ 3fc443c9b (v1.0.0-errata1-37) — test-only: the
#              reference decoder of SvtAv1E2ETests. The branch SVT-AV1 v4.2.0's
#              test/e2e_test/libaom_dependency.cmake fetches (no tag on it);
#              release tags do not fit SVT-AV1's copy of aom/inspection.h.
# To move a pin: check out the new tag in the submodule, commit the gitlink,
# update this list (and X265_VERSION below when x265 changes).

# Minimum target systems (README "Minimum supported"). macOS: Apple silicon
# only — 27 is the first release without Intel support; every library is built
# for it (MACOSX_DEPLOYMENT_TARGET, the target triple) and checked (LC_BUILD_VERSION).
# Linux: builds run on Ubuntu 24.04 (glibc 2.39); the programs and shared
# libraries must not need a newer glibc (checked after the build).
set(MACOS_MIN_VERSION "27.0")
set(GLIBC_MAX_VERSION "2.39")

# x265 reads its version from git tags, which a shallow submodule checkout
# (CI) does not have; x265Version.txt is written from this value instead
set(X265_VERSION     "4.2")

# mp3lame — official SourceForge archive (CVS-based project, no git)
set(LAME_VERSION     "3.100")
set(LAME_URL         "https://sourceforge.net/projects/lame/files/lame/3.100/lame-3.100.tar.gz/download")
set(LAME_TARBALL     "lame-3.100.tar.gz")
set(LAME_SHA256      "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e")

# AMD AMF — public headers only (FFmpeg loads the AMF runtime from the driver).
# Official release asset = amf/public/include of the tag (~80 KB; the AMF
# repository is >1 GB of binaries/samples). 1.5.0 is the oldest release FFmpeg
# n8.1.3 compiles with: configure accepts 1.4.36, but 1.4.36's
# components/DisplayCapture.h has an unguarded extern "C" and breaks the C
# build of the amf_capture source. FFmpeg passes the header version to the
# driver's AMFInit, so the oldest working headers ask the least of AMD drivers.
set(AMF_HEADERS_VERSION "1.5.0")
set(AMF_HEADERS_URL     "https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v1.5.0/AMF-headers-v1.5.0.tar.gz")
set(AMF_HEADERS_TARBALL "AMF-headers-v1.5.0.tar.gz")
set(AMF_HEADERS_SHA256  "d569647fa26f289affe81a206259fa92f819d06db1e80cc334559953e82a3f01")
