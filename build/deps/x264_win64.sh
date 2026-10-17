#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

# SHA-based cache check: skip if already built at the commit checked out in the
# submodule (not the gitlink in the superproject's HEAD, which lags behind an
# uncommitted submodule update). A single small read through the bind mount.
X264_SHA=$(git -C "$SRC/x264" rev-parse HEAD 2>/dev/null || echo "")
STORED_SHA=$(cat "$DEPS_PREFIX/.x264-sha" 2>/dev/null || echo "")

if already_built lib/x264.lib && [[ -n "$X264_SHA" ]] && [[ "$X264_SHA" == "$STORED_SHA" ]]; then
    echo "=== x264: already built at ${X264_SHA:0:8}, skipping ==="
    exit 0
fi

echo "=== x264 (windows/MSVC ABI) ==="

# Export x264 to the container's native FS (WORK_ROOT): building from the
# Windows bind mount is slow because every configure probe and compilation
# unit reads through it. Patches apply to the export, the submodule stays clean.
LOCAL_SRC=$(dep_src x264 --fresh)
apply_patches "$LOCAL_SRC" x264

# Build dir next to it, so .o/.a files are not written to the /artifacts mount
dep_build_dir x264
BUILD_TMP="$PWD"

CC="clang --target=x86_64-pc-windows-msvc -fuse-ld=lld" \
AR=llvm-ar \
RANLIB=llvm-ranlib \
AS=nasm \
bash "$LOCAL_SRC/configure" \
    --prefix="$DEPS_PREFIX" \
    --host=x86_64-w64-mingw32 \
    --cross-prefix= \
    ${LINK_FLAGS_X264} \
    --extra-cflags="${OPT_FLAGS} \
        -DHAVE_STRING_H \
        -isystem ${MSVC_INCLUDE} \
        -isystem ${WINSDK_INC_UCRT} \
        -isystem ${WINSDK_INC_SHARED} \
        -isystem ${WINSDK_INC_UM} \
        -isystem ${WINSDK_INC_WINRT} \
        -I\$(SRCPATH)/extras" \
    --extra-ldflags="-Wl,/base:0x140000000 \
        -Wl,/dynamicbase \
        -Wl,/nxcompat \
        -Wl,/tsaware \
        -L${MSVC_LIB} \
        -L${WINSDK_LIB_UCRT} \
        -L${WINSDK_LIB_UM}"

make -j"$JOBS" HAVE_GETOPT_LONG=0
make -j"$JOBS" checkasm HAVE_GETOPT_LONG=0
make install

# MSVC naming: clang/lld-link resolve -lx264 to x264.lib (lib*.a only in MinGW mode)
mv -f "$DEPS_PREFIX/lib/libx264.a" "$DEPS_PREFIX/lib/x264.lib"

# Tests: SIMD (checkasm, 8- and 10-bit) — run by tests/deps/run_dep_tests.py;
# the x264 CLI is installed into bin/ by make install
tests_reset x264
tests_add_program x264 checkasm8 checkasm10
tests_add x264 checkasm8 checkasm8
tests_add x264 checkasm10 checkasm10

# Persist the SHA so a subsequent docker run can skip the build entirely.
[[ -n "$X264_SHA" ]] && echo "$X264_SHA" > "$DEPS_PREFIX/.x264-sha"

# Remove the temporary source and build trees (output already in $DEPS_PREFIX).
rm -rf "$LOCAL_SRC" "$BUILD_TMP"

echo "=== x264: done ==="
