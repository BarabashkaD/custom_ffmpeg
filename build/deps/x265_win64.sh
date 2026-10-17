#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if already_built lib/pkgconfig/x265.pc && already_built lib/debug/x265.lib; then
    echo "=== x265: already built, skipping ==="
    exit 0
fi

echo "=== x265 (windows) ==="

# Source and build trees on the container's native FS (WORK_ROOT), not the
# Windows bind mount; patches apply to the export — the submodule stays clean
LOCAL_SRC=$(x265_src)
apply_patches "$LOCAL_SRC" x265
dep_build_dir x265
BUILD_TMP="$PWD"

X265_CMAKE_ARGS=(
    -GNinja
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER=clang
    -DCMAKE_CXX_COMPILER=clang++
    -DCMAKE_ASM_NASM_COMPILER=nasm
    -DCMAKE_C_FLAGS="${TARGET_CFLAGS} ${OPT_FLAGS} -DHAVE_STRING_H=1"
    -DCMAKE_CXX_FLAGS="${TARGET_CFLAGS} ${OPT_FLAGS}"
    -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS"
    ${CMAKE_LLVM_TOOLS}
    -DCMAKE_SYSTEM_NAME=Windows
    -DCMAKE_SYSTEM_PROCESSOR=x86_64
    ${CMAKE_SHARED}
    ${X265_SHARED}
    -DENABLE_TESTS=ON
    -DENABLE_ASSEMBLY=ON
)
cmake "$LOCAL_SRC/source" "${X265_CMAKE_ARGS[@]}" -DENABLE_CLI=ON

# The CLI embeds a version resource (x265.rc). x265's CMakeLists strips <FLAGS>
# and <DEFINES> from the RC rule, so the SDK include dirs cannot be passed as
# flags; clang (which preprocesses the .rc) also reads C_INCLUDE_PATH. The C
# sources already get these dirs first via -isystem, so they are unaffected.
export C_INCLUDE_PATH="${REPO_ROOT}/compat/include:${WINSDK_INC_UM}:${WINSDK_INC_SHARED}:${WINSDK_INC_UCRT}:${MSVC_INCLUDE}"
ninja -j"$JOBS"
ninja install
check_msvc_runtime "$DEPS_PREFIX/lib/x265.lib" MD_DynamicRelease 0

# Tests: TestBench — x265's asm primitives against the C reference
tests_reset x265
tests_add_program x265 test/TestBench
tests_add x265 testbench TestBench

# Debug runtime copy (/MDd, see common.sh): the library and TestBench again.
# _DEBUG also turns on x265's internal consistency checks (X265_CHECK), as in
# any upstream Debug build of x265.
dep_build_dir x265-debugrt
BUILD_DBG="$PWD"
# shellcheck disable=SC2086
cmake "$LOCAL_SRC/source" "${X265_CMAKE_ARGS[@]}" -DENABLE_CLI=OFF ${CMAKE_MSVC_DEBUG_RUNTIME}
ninja -j"$JOBS" x265-static TestBench
install -D -m 644 x265.lib "$MSVC_DEBUG_LIBDIR/x265.lib"
check_msvc_runtime "$MSVC_DEBUG_LIBDIR/x265.lib" MDd_DynamicDebug 2
install -D -m 755 test/TestBench.exe "$DEPS_PREFIX/tests/x265/debug/TestBench.exe"
tests_add x265 testbench-debugrt debug/TestBench

# x265 uses the registry (threadpool.cpp) but blacklists -ladvapi32 from
# Libs.private, so FFmpeg's static link probe fails with RegOpenKeyExA undefined
sed -i 's/^Libs.private:.*/Libs.private: -ladvapi32/' "$DEPS_PREFIX/lib/pkgconfig/x265.pc"

rm -rf "$LOCAL_SRC" "$BUILD_TMP" "$BUILD_DBG"

echo "=== x265: done ==="
