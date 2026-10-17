#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if already_built lib/pkgconfig/zlib.pc; then
    echo "=== zlib: already built, skipping ==="
    exit 0
fi

echo "=== zlib ==="
SRC_DIR=$(dep_src zlib)
dep_build_dir zlib

CMAKE_CROSS=""
CMAKE_AR_FLAGS=""
if [[ "$TARGET_OS" == "win64" ]]; then
    CMAKE_CROSS="-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64"
    CMAKE_AR_FLAGS="$CMAKE_LLVM_TOOLS"
fi

# Static only: a shared libz next to libz.a would win at link time
# shellcheck disable=SC2086
cmake "$SRC_DIR" \
    -GNinja \
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_C_FLAGS="${TARGET_CFLAGS} ${OPT_FLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DZLIB_BUILD_SHARED=OFF \
    -DZLIB_BUILD_STATIC=ON \
    -DZLIB_BUILD_TESTING=ON \
    ${CMAKE_CROSS} \
    ${CMAKE_AR_FLAGS}
# Library + its test programs only: "all" would also build infcover, which
# needs a coverage runtime (not available when cross-compiling for MSVC)
ninja -j"$JOBS" zlibstatic zlib_static_example static_minigzip
cmake --install .

# Tests: zlib's self-test program (writes into its working directory) and
# minigzip for a compress/decompress round trip (tests/deps/run_dep_tests.py)
tests_reset zlib
tests_add_program zlib test/zlib_static_example test/static_minigzip
tests_add zlib example zlib_static_example

# MSVC naming: FFmpeg probes zlib with -lz, which lld-link resolves only as z.lib
if [[ "$TARGET_OS" == "win64" ]]; then
    for lib in "$DEPS_PREFIX"/lib/zs.lib "$DEPS_PREFIX"/lib/libz.a "$DEPS_PREFIX"/lib/zlibstatic.lib; do
        [[ -f "$lib" ]] && mv -f "$lib" "$DEPS_PREFIX/lib/z.lib"
    done
    [[ -f "$DEPS_PREFIX/lib/z.lib" ]] || { echo "ERROR: zlib static library not found" >&2; exit 1; }
fi
echo "=== zlib: done ==="
