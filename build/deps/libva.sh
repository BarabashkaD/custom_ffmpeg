#!/usr/bin/env bash
# libva — VA-API (Video Acceleration API), meson. Linux only: FFmpeg's VAAPI
# decoders/encoders/filters (Intel, AMD, Mesa drivers) and, on Linux, the
# device under Intel QSV (libvpl). Built: libva + libva-drm (the DRM display
# backend FFmpeg uses); X11/GLX/Wayland backends off.
# The VA driver (iHD_drv_video.so, radeonsi_drv_video.so, ...) comes with the
# system's GPU driver packages and is dlopen()ed from the driver search path
# compiled in below (LIBVA_DRIVERS_PATH / LIBVA_DRIVER_NAME override it at run
# time, as with the distro libva).
# Also built from libva-utils (same project, MIT): vainfo (bin/) and the VA-API
# conformance tests test_va_api (tests/libva/) — both need a VA driver and a
# GPU, run_dep_tests.py skips them without one.
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [[ "$TARGET_OS" != "linux" ]]; then
    echo "=== libva: Linux only (VAAPI), skipping on ${TARGET_OS} ==="
    exit 0
fi

if already_built lib/pkgconfig/libva.pc; then
    echo "=== libva: already built, skipping ==="
    exit 0
fi

echo "=== libva ==="

# Driver search path compiled into libva (colon-separated, like
# LIBVA_DRIVERS_PATH). Upstream defaults to <prefix>/lib/dri — a build-machine
# path. The distro locations instead: Debian/Ubuntu multiarch, Fedora/openSUSE
# lib64, Arch lib.
DRIVERS_PATH="${LIBVA_DRIVERS_DIR:-/usr/lib/${TARGET_TRIPLE:-x86_64-linux-gnu}/dri:/usr/lib64/dri:/usr/lib/dri}"

LOCAL_SRC=$(dep_src libva --fresh)
apply_patches "$LOCAL_SRC" libva
dep_build_dir libva
BUILD_TMP="$PWD"

MESON_ENV=(CC=clang CXX=clang++ "CFLAGS=${TARGET_CFLAGS} ${OPT_FLAGS}"
           "CXXFLAGS=${TARGET_CFLAGS} ${OPT_FLAGS}" "LDFLAGS=${LDFLAGS}")

# Static + PIC (patches/libva: upstream hard-codes shared_library()).
# sysconfdir=/etc: libva reads <sysconfdir>/libva.conf at run time — the
# prefix-relative default would compile in the install path.
env "${MESON_ENV[@]}" meson setup "$LOCAL_SRC" . \
    --prefix="$DEPS_PREFIX" \
    --libdir=lib \
    --sysconfdir=/etc \
    --buildtype=release \
    --default-library=static \
    -Db_staticpic=true \
    --wrap-mode=nodownload \
    -Ddriverdir="$DRIVERS_PATH" \
    -Ddisable_drm=false \
    -Dwith_x11=no \
    -Dwith_glx=no \
    -Dwith_wayland=no \
    -Dwith_win32=no \
    -Denable_docs=false
ninja -j"$JOBS"
meson install --no-rebuild

for pc in libva libva-drm; do
    [[ -f "$DEPS_PREFIX/lib/pkgconfig/$pc.pc" ]] \
        || { echo "ERROR: $pc.pc not installed" >&2; exit 1; }
done
[[ -f "$DEPS_PREFIX/lib/libva.a" && -f "$DEPS_PREFIX/lib/libva-drm.a" ]] \
    || { echo "ERROR: static libva / libva-drm not installed" >&2; exit 1; }
# A shared libva next to the .a would win at link time (FFmpeg would then
# need libva.so.2 at run time)
if compgen -G "$DEPS_PREFIX/lib/libva*.so*" > /dev/null; then
    echo "ERROR: shared libva libraries installed" >&2
    exit 1
fi

rm -rf "$LOCAL_SRC" "$BUILD_TMP"

# ── libva-utils: vainfo + test_va_api ────────────────────────────────────────
# Linked statically against the libraries above (prefer_static: pkg-config
# --static, so libva-drm's Requires.private libdrm and libva's -ldl come along).
echo "=== libva-utils ==="
UTILS_SRC=$(dep_src libva-utils)
dep_build_dir libva-utils
BUILD_TMP="$PWD"
env "${MESON_ENV[@]}" meson setup "$UTILS_SRC" . \
    --prefix="$DEPS_PREFIX" \
    --buildtype=release \
    --prefer-static \
    --wrap-mode=nodownload \
    -Ddrm=true \
    -Dx11=false \
    -Dwayland=false \
    -Dwin32=false \
    -Dtests=true
ninja -j"$JOBS" vainfo/vainfo test/test_va_api

install -d "$DEPS_PREFIX/bin"
install -m 755 vainfo/vainfo "$DEPS_PREFIX/bin/"

# test_va_api needs a VA driver + device: run_dep_tests.py runs it after a
# vainfo probe (no manifest row — without a GPU it would only fail)
tests_reset libva
tests_add_program libva test/test_va_api

rm -rf "$UTILS_SRC" "$BUILD_TMP"
echo "=== libva: done ==="
