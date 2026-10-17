#!/usr/bin/env bash
# SVT-AV1 — AV1 encoder (libSvtAv1Enc + SvtAv1EncApp), one script for all
# platforms (CMake handles the differences).
set -euo pipefail
source "$(dirname "$0")/common.sh"

if already_built lib/pkgconfig/SvtAv1Enc.pc; then
    echo "=== svtav1: already built, skipping ==="
    exit 0
fi

echo "=== svtav1 (${TARGET_OS}) ==="
SRC_DIR=$(dep_src svtav1)
dep_build_dir svtav1
BUILD_TMP="$PWD"

CMAKE_PLATFORM=()
CXX_EXTRA=""
if [[ "$TARGET_OS" == "win64" ]]; then
    # shellcheck disable=SC2206
    CMAKE_PLATFORM=(-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64 ${CMAKE_LLVM_TOOLS})
    # Source/Lib/Codec/definitions.h does `#define inline __inline` on _WIN32,
    # which the MSVC STL rejects in the C++ tests (xkeycheck.h). Upstream adds
    # _ALLOW_KEYWORD_MACROS for MSVC in test/CMakeLists.txt; clang with the GNU
    # driver is not MSVC to CMake, so pass it here (C++ only: library and app are C)
    CXX_EXTRA="-D_ALLOW_KEYWORD_MACROS"
fi

# ── libaom (test-only) ────────────────────────────────────────────────────────
# SvtAv1E2ETests decodes every encoded stream with libaom's reference decoder
# (inspection API: block sizes, qindex, frame types per frame) and compares the
# result with the encoder's recon. Upstream (test/e2e_test/libaom_dependency.cmake)
# fetches libaom at build time with ExternalProject from the moving branch
# av1-normative and forwards only CMAKE_TOOLCHAIN_FILE (our cross flags would be
# lost). Instead sources/libaom is that branch pinned as a submodule, built here
# with our toolchain, and handed to SVT-AV1 as the imported target `aom` (see
# svtav1_configure): libaom_dependency.cmake then does not attach its download
# to the target, and as only explicit targets are built, the ExternalProject
# never runs. libaom is linked into SvtAv1E2ETests only — not installed, not
# part of the shipped library or of FFmpeg.
#   av1-normative, not a release: SVT-AV1 compiles against its own copy of the
#     libaom headers (third_party/aom/inc), whose inspection.h matches that
#     branch (v1.0.0-errata1 + fixes); the v2/v3 releases changed insp_mi_data
#     and ifd_inspect() — the layout would not match.
#   AOM_TARGET_CPU=generic is the branch's own default ("Forcing generic build
#     for normative branch"): C only, as upstream's E2E runs use it.
#   CONFIG_INSPECTION=1, no encoder/apps/tests/docs: the options upstream passes.
#   CONFIG_ACCOUNTING stays 0: inspection.h's struct layout depends on it.
AOM_BUILD="$BUILD_TMP/libaom"
build_libaom() {
    local src ldflags="$LDFLAGS" stubs=""
    src=$(dep_src libaom)
    if [[ "$TARGET_OS" == "win64" ]]; then
        # -lm / -lpthread, which lld-link resolves only as m.lib / pthread.lib:
        # libaom's configure checks link with -lm, and SvtAv1E2ETests links
        # "pthread m" whenever the compiler is not MSVC (test/e2e_test/
        # CMakeLists.txt; the unit/api tests test UNIX instead). Windows has
        # neither (math is in the UCRT, both use Win32 threads): empty
        # archives, as for libvpx — for libaom's checks and, through the
        # imported target, for the E2E link only
        stubs="$AOM_BUILD-stubs"
        mkdir -p "$stubs"
        "$AR" rcs "$stubs/m.lib"
        "$AR" rcs "$stubs/pthread.lib"
        ldflags+=" -L$stubs"
    fi
    # CMAKE_POLICY_VERSION_MINIMUM: the branch declares cmake_minimum_required(3.5),
    # which CMake 4 rejects without it (3.x ignores the variable)
    cmake -S "$src" -B "$AOM_BUILD" \
        -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_C_FLAGS="${TARGET_CFLAGS} ${OPT_FLAGS}" \
        -DCMAKE_CXX_FLAGS="${TARGET_CFLAGS} ${OPT_FLAGS}" \
        -DCMAKE_EXE_LINKER_FLAGS="$ldflags" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DBUILD_SHARED_LIBS=OFF \
        -DAOM_TARGET_CPU=generic \
        -DCONFIG_AV1_ENCODER=0 \
        -DCONFIG_INSPECTION=1 \
        -DENABLE_DOCS=0 \
        -DENABLE_EXAMPLES=0 \
        -DENABLE_TESTDATA=0 \
        -DENABLE_TESTS=0 \
        -DENABLE_TOOLS=0 \
        "${CMAKE_PLATFORM[@]}"
    ninja -C "$AOM_BUILD" -j"$JOBS" aom
    # Imported target for SVT-AV1 (CMAKE_PROJECT_INCLUDE runs after each
    # project() call — the guard keeps the first definition)
    cat > "$BUILD_TMP/libaom-target.cmake" <<EOF
if(NOT TARGET aom)
    add_library(aom STATIC IMPORTED GLOBAL)
    set_target_properties(aom PROPERTIES IMPORTED_LOCATION
        "$AOM_BUILD/\${CMAKE_STATIC_LIBRARY_PREFIX}aom\${CMAKE_STATIC_LIBRARY_SUFFIX}"
        INTERFACE_LINK_DIRECTORIES "$stubs")
endif()
EOF
}

# svtav1_configure <build-dir> <testing ON|OFF> — configure one build tree.
#   SVT_AV1_LTO=OFF        on by default for clang >= 12: the static library would
#                          hold LLVM bitcode, which MSVC link.exe consumers cannot read
#   BUILD_SHARED_LIBS      on by default — deps are static + PIC (CMAKE_SHARED)
#   CMAKE_OUTPUT_DIRECTORY defaults to <source>/Bin/<type>: keep outputs in the build dir
#   REPRODUCIBLE_BUILDS    no __DATE__/__TIME__ in the library banner
#   NASM object format     follows CMAKE_SYSTEM_NAME (win64 / elf64)
#   CMAKE_PROJECT_INCLUDE  test trees only: the prebuilt libaom (build_libaom)
svtav1_configure() {
    local aom=()
    [[ "$2" == "ON" ]] && aom=(-DCMAKE_PROJECT_INCLUDE="$BUILD_TMP/libaom-target.cmake")
    cmake -S "$SRC_DIR" -B "$1" \
        -GNinja \
        -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_ASM_NASM_COMPILER=nasm \
        -DCMAKE_C_FLAGS="${TARGET_CFLAGS} ${OPT_FLAGS}" \
        -DCMAKE_CXX_FLAGS="${TARGET_CFLAGS} ${OPT_FLAGS} ${CXX_EXTRA}" \
        -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
        -DCMAKE_OUTPUT_DIRECTORY="$1/Bin" \
        ${CMAKE_SHARED} \
        -DSVT_AV1_LTO=OFF \
        -DREPRODUCIBLE_BUILDS=ON \
        -DBUILD_APPS=ON \
        -DBUILD_TESTING="$2" \
        "${aom[@]}" \
        "${CMAKE_PLATFORM[@]}"
}

# Tests: SvtAv1UnitTests (SIMD kernels against the C reference) and
# SvtAv1ApiTests (encoder API). BUILD_TESTING adds -DSVT_AV1_UNIT_TEST_BUILD=1
# globally, i.e. also to the library. In v4.2.0 the define only
#   - makes svt_aom_library_built_for_unit_tests() return 1 (all targets) and
#   - keeps the C reference functions on aarch64 (CONFIG_ARM_NEON_IS_GUARANTEED=0
#     in EbConfigMacros.h) instead of the Neon-only devirtualized dispatch.
# On x86_64 one build therefore serves both: the tests run the very objects that
# get installed. On aarch64 (or when a new release uses the define elsewhere)
# the library/app come from a build without tests and the tests from a second
# tree. SvtAv1E2ETests (encoder -> libaom decoder round trips) links the pinned
# libaom (build_libaom). Only explicit targets are built: `all` would also run
# upstream's libaom ExternalProject download.
EXPECTED_DEFINE_USERS="Source/API/EbConfigMacros.h Source/Lib/Codec/common_dsp_rtcd.c Source/Lib/Codec/common_dsp_rtcd.h"
DEFINE_USERS=$(cd "$SRC_DIR" && grep -rl SVT_AV1_UNIT_TEST_BUILD Source | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
TEST_TARGETS=(SvtAv1UnitTests SvtAv1ApiTests SvtAv1E2ETests)
build_libaom
if [[ "$ARCH" == "x86_64" && "$DEFINE_USERS" == "$EXPECTED_DEFINE_USERS" ]]; then
    LIB_BUILD="$BUILD_TMP/build"
    TEST_BUILD="$LIB_BUILD"
    svtav1_configure "$LIB_BUILD" ON
    ninja -C "$LIB_BUILD" -j"$JOBS" SvtAv1Enc SvtAv1EncApp "${TEST_TARGETS[@]}"
else
    echo "svtav1: separate test build (ARCH=$ARCH, SVT_AV1_UNIT_TEST_BUILD used in: $DEFINE_USERS)"
    LIB_BUILD="$BUILD_TMP/build"
    TEST_BUILD="$BUILD_TMP/build-tests"
    svtav1_configure "$LIB_BUILD" OFF
    ninja -C "$LIB_BUILD" -j"$JOBS" SvtAv1Enc SvtAv1EncApp
    svtav1_configure "$TEST_BUILD" ON
    ninja -C "$TEST_BUILD" -j"$JOBS" "${TEST_TARGETS[@]}"
fi
# The upstream download must not have run (it would replace the pinned libaom)
if [[ -n "$(ls -A "$TEST_BUILD/libaom/src/DepLibAom" 2>/dev/null)" ]]; then
    echo "ERROR: svtav1: libaom ExternalProject was built" >&2
    exit 1
fi

# Install only the library (Development) and SvtAv1EncApp (Runtime): the test
# programs and the vendored googletest have install rules without a component
cmake --install "$LIB_BUILD" --component Development
cmake --install "$LIB_BUILD" --component Runtime

# Runner: one gtest manifest entry per program, sharded (--jobs).
# SvtAv1UnitTests: ~17000 tests, ~40 min at 2 shards on 4 CPUs.
# SvtAv1ApiTests: 11 EncParam*Test.run_paramter_check tests compare against
# stale expectations in test/api_test/params.h (e.g. default enc_mode
# MAX_ENC_PRESET=13 and qp 50, while the library defaults are ENC_M8 and
# DEFAULT_QP=35 in Source/Lib/Globals/enc_settings.c; hierarchical_levels,
# intra_period_length, level, ... ranges changed too). They fail the same way in
# any build of v4.2.0: upstream CI builds SvtAv1ApiTests but never runs it
# (.gitlab/workflows/*/.gitlab-ci.yml run only SvtAv1UnitTests and
# SvtAv1E2ETests) — excluded; the other EncParam tests still run.
SVTAV1_API_STALE="EncParamEncModeTest.*:EncParamIntraPeridLenTest.*:EncParamHierarchicalLvlTest.*"
SVTAV1_API_STALE+=":EncParamQPTest.*:EncParamRateCtrlModeTest.*:EncParamSceneChangeDectTest.*"
SVTAV1_API_STALE+=":EncParamTargetBitRateTest.*:EncParamMinQPAllowTest.*:EncParamLevelTest.*"
SVTAV1_API_STALE+=":EncParamScreenContentModeTest.*:EncParamEnableAltRefsTest.*"
tests_reset svtav1
tests_add_program svtav1 "$TEST_BUILD/Bin/SvtAv1UnitTests" "$TEST_BUILD/Bin/SvtAv1ApiTests" \
    "$TEST_BUILD/Bin/SvtAv1E2ETests"
tests_add svtav1 unit_tests SvtAv1UnitTests "" "" gtest
tests_add svtav1 api_tests SvtAv1ApiTests "" "" gtest "exclude=$SVTAV1_API_STALE"
# SvtAv1E2ETests: test clips from <data>/svtav1 (tools/fetch_test_data.sh svtav1,
# = upstream's TestVectors target); only the generated colour-bar source and
# the bitstream test need none. Without data a clip test fails with
#   "open_source return error:-2147479547" (EB_ErrorBadParameter: fopen failed) or,
#   as a death test (child output not in the report), naming its clip
#   ("test vector: <clip>") — both count as missing data.
SVTAV1_E2E_MISSING="open_source return error:-2147479547"
SVTAV1_E2E_MISSING+="|$(awk '{sub(/^\*/, "", $2); print $2}' "$SRC_DIR/test/e2e_test/test_vector_list.txt" | paste -sd'|' -)"
tests_add svtav1 e2e_tests SvtAv1E2ETests "" "SVT_AV1_TEST_VECTOR_PATH={data}/svtav1" gtest \
    "missing_data=$SVTAV1_E2E_MISSING"

rm -rf "$SRC_DIR" "$BUILD_TMP" "$WORK_ROOT/libaom-src"
echo "=== svtav1: done ==="
