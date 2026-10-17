#!/usr/bin/env bash
# ffnvcodec — NVIDIA Video Codec SDK headers in FFmpeg's form (nv-codec-headers):
# NVENC / NVDEC / CUVID / CUDA. Header-only: nothing is compiled or linked —
# FFmpeg loads the driver libraries at run time (nvcuda.dll, nvcuvid.dll,
# nvEncodeAPI64.dll on Windows; libcuda.so.1, libnvcuvid.so.1,
# libnvidia-encode.so.1 on Linux).
# Installs include/ffnvcodec/*.h and lib/pkgconfig/ffnvcodec.pc (Cflags only).
# Same for win64 and linux; macOS has no NVIDIA support (ffnvcodec_macos.sh).
set -euo pipefail
source "$(dirname "$0")/common.sh"

if already_built lib/pkgconfig/ffnvcodec.pc; then
    echo "=== ffnvcodec: already built, skipping ==="
    exit 0
fi

echo "=== ffnvcodec ==="
# The Makefile writes ffnvcodec.pc into its source dir: run it in the export
SRC_DIR=$(dep_src ffnvcodec)
# OS= : the Makefile runs cygpath on the prefix when OS=Windows_NT
make -C "$SRC_DIR" PREFIX="$DEPS_PREFIX" OS= install

[[ -f "$DEPS_PREFIX/include/ffnvcodec/nvEncodeAPI.h" ]] \
    || { echo "ERROR: ffnvcodec headers not installed" >&2; exit 1; }
# Header-only: the .pc must not add link flags (FFmpeg dlopen()s the driver)
if grep -q '^Libs' "$DEPS_PREFIX/lib/pkgconfig/ffnvcodec.pc"; then
    echo "ERROR: ffnvcodec.pc unexpectedly carries link flags" >&2
    exit 1
fi
echo "=== ffnvcodec: done ==="
