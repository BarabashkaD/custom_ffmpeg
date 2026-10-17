# target_env.sh — sourced by build/build_ffmpeg.sh: the target's build
# environment shared by the dependency and the FFmpeg stage — directories,
# cross-compilation flags (Windows SDK / MSVC in the container) and the
# variables the dep scripts inherit.
# Kept apart from the FFmpeg stage on purpose: the Windows deps' CI cache key
# hashes this file, not build_ffmpeg.sh (.github/scripts/cache_key.sh).
#
# Needs: REPO_ROOT, ARTIFACTS_ROOT and TARGET_PLATFORM, TARGET_OS,
# TARGET_TRIPLE, ARCH (from the generated .env).
# Sets:  DEPS_PREFIX, COMPAT_TMPLIB, BUILD_ROOT, TMPDIR, TARGET_CFLAGS, LDFLAGS,
#        EXTRA_CONF, WINDRES_ARGS, NASM_FLAGS (+ MSVC_INC, WINSDK_INC on win64).

DEPS_PREFIX="${ARTIFACTS_ROOT}/.deps/${TARGET_PLATFORM}"
COMPAT_TMPLIB="${ARTIFACTS_ROOT}/.compat-lib"

# BUILD_ROOT: build trees + TMPDIR. win64 runs in Docker where /src and
# /artifacts are Windows bind mounts — compiling on them is ~5x slower (CI:
# make 39 min vs 7 min on Linux), so build on the container's native FS.
# build.ps1 mounts a named volume at /build to keep incremental rebuilds.
if [[ "${TARGET_OS}" == "win64" ]]; then
    BUILD_ROOT="${BUILD_ROOT:-/build}"
else
    BUILD_ROOT="${BUILD_ROOT:-${ARTIFACTS_ROOT}/.build}"
fi

export TMPDIR="${BUILD_ROOT}/tmp"
mkdir -p "$DEPS_PREFIX" "$COMPAT_TMPLIB" "$TMPDIR"

# ── Compiler flags ────────────────────────────────────────────────────────────
# TARGET_CFLAGS: cross-compilation flags only (--target, -isystem).
# Optimization (-O3) is added separately so build_deps.sh can combine them.
TARGET_CFLAGS=""
LDFLAGS=""
EXTRA_CONF=""
WINDRES_ARGS=()
NASM_FLAGS=""

if [[ "${TARGET_OS}" == "win64" ]]; then
    # Resolve SDK version from the kits root mounted at /winsdk/kits
    SDK_VER=$(ls /winsdk/kits/Include | grep -E '^[0-9]' | sort -rV | awk 'NR==1')
    echo "  Windows SDK : ${SDK_VER}"

    WINSDK_INC=/winsdk/kits/Include/${SDK_VER}
    WINSDK_LIB=/winsdk/kits/Lib/${SDK_VER}
    MSVC_INC=/winsdk/msvc/include
    MSVC_LIB_DIR=/winsdk/msvc/lib/x64

    # clang's own headers must precede the MSVC ones (clang-cl order): MSVC's
    # <emmintrin.h> etc. declare SSE intrinsics as extern functions, which
    # then fail to link (undefined symbol: _mm_setzero_si128).
    CLANG_INC="$(clang -print-resource-dir)/include"

    TARGET_CFLAGS="--target=${TARGET_TRIPLE} \
        -isystem ${REPO_ROOT}/compat/include \
        -isystem ${CLANG_INC} \
        -isystem ${MSVC_INC} \
        -isystem ${WINSDK_INC}/ucrt \
        -isystem ${WINSDK_INC}/um \
        -isystem ${WINSDK_INC}/shared"

    # Lowercase symlinks for .lib files lld-link searches by lowercase name
    bash "${REPO_ROOT}/compat/create_lib_symlinks.sh" "${WINSDK_LIB}/um/x64" "$COMPAT_TMPLIB"

    LDFLAGS="-fuse-ld=lld \
        -L${MSVC_LIB_DIR} \
        -L${WINSDK_LIB}/ucrt/x64 \
        -L${WINSDK_LIB}/um/x64 \
        -L${COMPAT_TMPLIB} \
        -L${DEPS_PREFIX}/lib"

    # NASM output format for Windows x64 PE
    NASM_FLAGS="-f win64"

    EXTRA_CONF="--enable-cross-compile --cross-prefix=llvm-"
    # Shared builds compile a version resource into each DLL: llvm-windres
    # preprocesses the .rc with clang and needs the PE target + SDK headers
    WINDRES_ARGS=(--windres="llvm-windres --target=pe-x86-64 -I${REPO_ROOT}/compat/include \
-I${MSVC_INC} -I${WINSDK_INC}/ucrt -I${WINSDK_INC}/um -I${WINSDK_INC}/shared")

elif [[ "${TARGET_OS}" == "linux" ]]; then
    LDFLAGS="-L${DEPS_PREFIX}/lib"
    NASM_FLAGS="-f elf64"

elif [[ "${TARGET_OS}" == "darwin" ]]; then
    TARGET_CFLAGS="--target=${TARGET_TRIPLE}"
    LDFLAGS="-L${DEPS_PREFIX}/lib"
    NASM_FLAGS="-f macho64"
    EXTRA_CONF="--enable-cross-compile"
fi

export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${DEPS_PREFIX}/lib/pkgconfig"

# Export all vars so build_deps.sh and individual dep scripts can inherit them
export TARGET_OS TARGET_TRIPLE ARCH DEPS_PREFIX TARGET_CFLAGS LDFLAGS
export LAME_VERSION LAME_URL LAME_TARBALL LAME_SHA256
# SRC for dep scripts = sources/ subdirectory of the repo root
export SRC="${REPO_ROOT}/sources"
# Export resolved SDK paths so dep scripts (x264.sh etc.) can reference them
if [[ "${TARGET_OS}" == "win64" ]]; then
    export MSVC_INCLUDE="${MSVC_INC}"
    export MSVC_LIB="${MSVC_LIB_DIR}"
    export WINSDK_INC_UCRT="${WINSDK_INC}/ucrt"
    export WINSDK_INC_UM="${WINSDK_INC}/um"
    export WINSDK_INC_SHARED="${WINSDK_INC}/shared"
    export WINSDK_INC_WINRT="${WINSDK_INC}/winrt"
    export WINSDK_LIB_UCRT="${WINSDK_LIB}/ucrt/x64"
    export WINSDK_LIB_UM="${WINSDK_LIB}/um/x64"
fi
