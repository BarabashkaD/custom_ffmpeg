#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if already_built lib/pkgconfig/libwebp.pc; then
    echo "=== libwebp: already built, skipping ==="
    exit 0
fi

echo "=== libwebp ==="
SRC_DIR=$(dep_src libwebp)
dep_build_dir webp

CMAKE_CROSS=""
CMAKE_AR_FLAGS=""
if [[ "$TARGET_OS" == "win64" ]]; then
    CMAKE_CROSS="-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64"
    CMAKE_AR_FLAGS="$CMAKE_LLVM_TOOLS"
fi

# shellcheck disable=SC2086
cmake "$SRC_DIR" \
    -GNinja \
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_C_FLAGS="${TARGET_CFLAGS} ${OPT_FLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
    ${CMAKE_SHARED} \
    -DWEBP_BUILD_ANIM_UTILS=OFF \
    -DWEBP_BUILD_CWEBP=ON \
    -DWEBP_BUILD_DWEBP=ON \
    -DWEBP_BUILD_WEBPINFO=ON \
    -DWEBP_BUILD_WEBPMUX=ON \
    -DWEBP_BUILD_GIF2WEBP=OFF \
    -DWEBP_BUILD_IMG2WEBP=ON \
    -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_EXTRAS=OFF \
    -DWEBP_BUILD_FUZZTEST=OFF \
    ${CMAKE_CROSS} \
    ${CMAKE_AR_FLAGS}
ninja -j"$JOBS"
ninja install
echo "=== libwebp: done ==="
