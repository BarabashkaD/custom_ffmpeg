#!/usr/bin/env bash
# libvpl — Intel Video Processing Library dispatcher (Quick Sync Video in
# FFmpeg: h264_qsv, hevc_qsv, av1_qsv, ...). Only the dispatcher is built: it
# loads Intel's runtime (libmfx64-gen.dll / libmfx-gen.so.1.2, shipped with the
# GPU driver) at run time. The command line tools (vpl-inspect, ...) live in a
# separate repository (intel/libvpl-tools) since libvpl 2.11.
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [[ "$TARGET_OS" == "macos" ]]; then
    echo "=== libvpl: Intel QSV does not exist on macOS, skipping ==="
    exit 0
fi

if already_built lib/pkgconfig/vpl.pc \
   && { [[ "$TARGET_OS" != "win64" ]] || already_built lib/debug/vpl.lib; }; then
    echo "=== libvpl: already built, skipping ==="
    exit 0
fi

echo "=== libvpl ==="
LOCAL_SRC=$(dep_src libvpl --fresh)
apply_patches "$LOCAL_SRC" libvpl
dep_build_dir libvpl
BUILD_TMP="$PWD"

CMAKE_CROSS=""
if [[ "$TARGET_OS" == "win64" ]]; then
    CMAKE_CROSS="-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64 $CMAKE_LLVM_TOOLS"
else
    # Linux: the legacy MFXInit path also tries <MFX_MODULES_DIR>/libmfx-gen.so.1.2;
    # upstream defaults it to the install libdir (an absolute build-machine path
    # compiled into libvpl.a). Use the distro location of the GPU runtime instead.
    CMAKE_CROSS="-DMFX_MODULES_DIR=${LIBVPL_MODULES_DIR:-/usr/lib/x86_64-linux-gnu}"
fi

# Static dispatcher (+ PIC). BUILD_TESTS: the dispatcher unit tests (googletest,
# bundled) and the stub runtimes they load instead of a real Intel runtime.
# gtest_discover_tests would run vpl-tests right after linking to list its
# tests (POST_BUILD) — impossible for a Windows .exe in the Linux container;
# PRE_TEST defers that to ctest, which is not used here.
# shellcheck disable=SC2206
VPL_CMAKE_ARGS=(
    -GNinja
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX"
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER=clang
    -DCMAKE_CXX_COMPILER=clang++
    -DCMAKE_C_FLAGS="${TARGET_CFLAGS} ${OPT_FLAGS}"
    -DCMAKE_CXX_FLAGS="${TARGET_CFLAGS} ${OPT_FLAGS}"
    -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS"
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS"
    ${CMAKE_SHARED}
    -DBUILD_TESTS=ON
    -DCMAKE_GTEST_DISCOVER_TESTS_DISCOVERY_MODE=PRE_TEST
    -DBUILD_EXAMPLES=OFF
    -DINSTALL_EXAMPLES=OFF
    ${CMAKE_CROSS}
)
cmake "$LOCAL_SRC" "${VPL_CMAKE_ARGS[@]}"
# Library, unit tests and stub runtimes only: the diagnostic programs
# (mfxinit-test, vpl-timing) need a real Intel runtime and vpl-timing links
# version.lib only for MSVC proper
ninja -j"$JOBS" VPL vpl-tests vplstubrt vplstubrt1x vplstubrt-nofn
cmake --install .

# Environment scripts (etc/vpl/vars.*) are for an installed SDK, not needed here
rm -rf "$DEPS_PREFIX/etc/vpl"

# vpl.pc names no system libraries for clang targeting MSVC (upstream adds them
# for MinGW only) and no C++ runtime (its CXX_LIB is never set), so FFmpeg's
# static link probe for libvpl fails. The dispatcher uses the registry
# (advapi32) and StringFromGUID2 (ole32); the MSVC C++ runtime (msvcprt) and
# uuid are pulled in by /DEFAULTLIB directives in the objects. Linux: libstdc++.
if [[ "$TARGET_OS" == "win64" ]]; then
    sed -i 's/^Libs.private:.*/Libs.private: -ladvapi32 -lole32/' "$DEPS_PREFIX/lib/pkgconfig/vpl.pc"
else
    sed -i 's/^Libs.private:.*/Libs.private: -lstdc++/' "$DEPS_PREFIX/lib/pkgconfig/vpl.pc"
fi

# Tests: vpl-tests (googletest) against the stub runtimes (libvplstubrt*), found
# through ONEVPL_SEARCH_PATH as in upstream's ctest setup. Without -disp:*
# switches only the stub tests run; the GPU tests (-disp:gpu-*) need Intel
# hardware and skip themselves. The tests share a log file in the working
# directory (upstream: RESOURCE_LOCK DISPATCHER_LOG_FILE), so they run in one
# process (serial=*), not in parallel shards.
tests_reset libvpl
tests_add_program libvpl vpl-tests
if [[ "$TARGET_OS" == "win64" ]]; then
    install -m 755 libvplstubrt*.dll "$DEPS_PREFIX/tests/libvpl/"
else
    # keep the soname symlinks: upstream runs the tests from the build dir
    cp -a libvplstubrt*.so* "$DEPS_PREFIX/tests/libvpl/"
fi
tests_add libvpl vpl-tests vpl-tests "" "ONEVPL_SEARCH_PATH={dir}" gtest "serial=*"

BUILD_DBG=""
if [[ "$TARGET_OS" == "win64" ]]; then
    check_msvc_runtime "$DEPS_PREFIX/lib/vpl.lib" MD_DynamicRelease 0

    # Debug runtime copy (/MDd, see common.sh): dispatcher, unit tests and stub
    # runtimes again. The "d" postfix matches upstream's MSVC RelWithDebRT/Debug
    # layout: with _DEBUG the tests expect libvplstubrt64d.dll. The tests get
    # their own directory, so neither test run finds the other's stub runtimes.
    dep_build_dir libvpl-debugrt
    BUILD_DBG="$PWD"
    # shellcheck disable=SC2086
    cmake "$LOCAL_SRC" "${VPL_CMAKE_ARGS[@]}" ${CMAKE_MSVC_DEBUG_RUNTIME} -DCMAKE_RELEASE_POSTFIX=d
    ninja -j"$JOBS" VPL vpl-tests vplstubrt vplstubrt1x vplstubrt-nofn
    install -D -m 644 "$(find . -name vpld.lib | head -n1)" "$MSVC_DEBUG_LIBDIR/vpl.lib"
    check_msvc_runtime "$MSVC_DEBUG_LIBDIR/vpl.lib" MDd_DynamicDebug 2
    mkdir -p "$DEPS_PREFIX/tests/libvpl/debug"
    install -m 755 "$(find . -name vpl-tests.exe | head -n1)" libvplstubrt*d.dll \
        "$DEPS_PREFIX/tests/libvpl/debug/"
    tests_add libvpl vpl-tests-debugrt debug/vpl-tests "" "ONEVPL_SEARCH_PATH={dir}/debug" gtest "serial=*"
fi

rm -rf "$LOCAL_SRC" "$BUILD_TMP" ${BUILD_DBG:+"$BUILD_DBG"}
echo "=== libvpl: done ==="
