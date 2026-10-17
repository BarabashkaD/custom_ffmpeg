#!/usr/bin/env bash
# libdrm — userspace interface to the kernel DRM (Direct Rendering Manager),
# meson. Linux only: libva's DRM backend (libva-drm) opens the GPU through it,
# and FFmpeg uses it for VAAPI device selection, DRM PRIME frame mapping
# (hwcontext_drm) and the kmsgrab input device.
# Only core libdrm is built: the vendor libraries (libdrm_intel, _amdgpu,
# _radeon, _nouveau, ...) are not used by libva or FFmpeg (libdrm_amdgpu would
# also compile in the install path of amdgpu.ids).
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [[ "$TARGET_OS" != "linux" ]]; then
    echo "=== libdrm: Linux only (VAAPI), skipping on ${TARGET_OS} ==="
    exit 0
fi

if already_built lib/pkgconfig/libdrm.pc; then
    echo "=== libdrm: already built, skipping ==="
    exit 0
fi

echo "=== libdrm ==="
LOCAL_SRC=$(dep_src libdrm)
dep_build_dir libdrm
BUILD_TMP="$PWD"

# Static + PIC core library. tests=true builds the test programs (tests/:
# hash, drmsl, drmdevice are upstream's meson tests; modetest & co. are KMS
# tools that need a display and are not installed). udev off (upstream
# default): device nodes are found through /sys and /dev directly.
env CC=clang "CFLAGS=${TARGET_CFLAGS} ${OPT_FLAGS}" "LDFLAGS=${LDFLAGS}" \
meson setup "$LOCAL_SRC" . \
    --prefix="$DEPS_PREFIX" \
    --libdir=lib \
    --buildtype=release \
    --default-library=static \
    -Db_staticpic=true \
    --wrap-mode=nodownload \
    -Dintel=disabled \
    -Dradeon=disabled \
    -Damdgpu=disabled \
    -Dnouveau=disabled \
    -Dvmwgfx=disabled \
    -Domap=disabled \
    -Dexynos=disabled \
    -Dfreedreno=disabled \
    -Dtegra=disabled \
    -Dvc4=disabled \
    -Detnaviv=disabled \
    -Dcairo-tests=disabled \
    -Dman-pages=disabled \
    -Dvalgrind=disabled \
    -Dudev=false \
    -Dtests=true \
    -Dinstall-test-programs=false

ninja -j"$JOBS"
meson install --no-rebuild

# Tests: upstream's meson tests (tests/meson.build) — hash table and skip list
# self-tests, and drmdevice, which lists the DRM devices through
# drmGetDevices2 and opens each node; without any DRM device it exits 77
# (the automake/meson "skipped" code, counted as SKIP by run_dep_tests.py).
# core-symbols-check (nm on a shared libdrm.so vs core-symbols.txt) checks the
# ABI of the shared library, which is not built here.
tests_reset libdrm
tests_add_program libdrm tests/hash tests/drmsl tests/drmdevice
tests_add libdrm hash hash
tests_add libdrm drmsl drmsl
tests_add libdrm drmdevice drmdevice

rm -rf "$LOCAL_SRC" "$BUILD_TMP"
echo "=== libdrm: done ==="
