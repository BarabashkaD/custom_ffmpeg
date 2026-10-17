#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if already_built lib/pkgconfig/x265.pc; then
    echo "=== x265: already built, skipping ==="
    exit 0
fi

echo "=== x265 (macOS/ARM64) ==="

LOCAL_SRC=$(x265_src)

dep_build_dir x265
BUILD_TMP="$PWD"

# ARM64 macOS: no x86 NASM assembly; ARM NEON/SVE is handled by the C compiler.
cmake "$LOCAL_SRC/source" \
    -GNinja \
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_C_FLAGS="${OPT_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${OPT_FLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
    ${CMAKE_SHARED} \
    ${X265_SHARED} \
    -DENABLE_CLI=ON \
    -DENABLE_TESTS=ON \
    -DENABLE_ASSEMBLY=OFF

ninja -j"$JOBS"
ninja install

# Tests: TestBench — x265's asm primitives against the C reference
tests_reset x265
tests_add_program x265 test/TestBench
tests_add x265 testbench TestBench

rm -rf "$LOCAL_SRC" "$BUILD_TMP"

echo "=== x265: done ==="
