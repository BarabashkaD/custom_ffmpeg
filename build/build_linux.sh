#!/usr/bin/env bash
# build_linux.sh — entry point for Linux / WSL2 native builds.
# Works both natively and inside the Docker container (no Docker-specific paths).
#
# Usage:
#   bash build/build_linux.sh [dep1 dep2 ...]     # build specific dep(s) only
#   bash build/build_linux.sh                     # build all deps
#   bash build/build_linux.sh --ffmpeg [profile]  # build all deps + FFmpeg
#                                                 # profile defaults to "full"
#   bash build/build_linux.sh --ffmpeg [profile] --shared   # shared FFmpeg (.so/.dylib)
#
# Examples:
#   bash build/build_linux.sh x264
#   bash build/build_linux.sh          # all deps (no FFmpeg)
#   bash build/build_linux.sh --ffmpeg
#   bash build/build_linux.sh --ffmpeg minimal
set -euo pipefail

# ── Prereq check ─────────────────────────────────────────────────────────────
check_prereqs() {
    local missing=()
    # meson: dav1d's only build system
    for tool in clang nasm git make cmake ninja meson pkg-config; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: missing required tools: ${missing[*]}"
        echo ""
        echo "Install with:"
        echo "  Ubuntu/Debian : sudo apt install clang nasm git make cmake ninja-build meson pkg-config autoconf automake libtool"
        echo "  Alpine        : apk add clang nasm git make cmake ninja meson pkgconf autoconf automake libtool"
        echo "  Arch          : sudo pacman -S clang nasm git make cmake ninja meson pkgconf autoconf automake libtool"
        exit 1
    fi
}

check_prereqs

# ── Paths — work both natively and inside Docker ──────────────────────────────
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

VERSIONS_FILE="$REPO_ROOT/versions.cmake"
extract_cmake_var() {
    local var_name="$1"
    sed -nE "s/^set\\(${var_name}[[:space:]]+\"([^\"]+)\"\\).*/\\1/p" "$VERSIONS_FILE" | head -n1
}

export LAME_VERSION="$(extract_cmake_var LAME_VERSION)"
export LAME_URL="$(extract_cmake_var LAME_URL)"
export LAME_TARBALL="$(extract_cmake_var LAME_TARBALL)"
export LAME_SHA256="$(extract_cmake_var LAME_SHA256)"

if [[ -z "${LAME_VERSION}" || -z "${LAME_URL}" || -z "${LAME_TARBALL}" || -z "${LAME_SHA256}" ]]; then
    echo "ERROR: failed to read LAME variables from ${VERSIONS_FILE}"
    exit 1
fi

export DEPS_PREFIX="${DEPS_PREFIX:-$REPO_ROOT/prebuilt/.deps/linux-x64}"
export TMPDIR="${TMPDIR:-/tmp/custom_ffmpeg}"
export DOWNLOADS="${DOWNLOADS:-$TMPDIR/downloads}"

mkdir -p "$DEPS_PREFIX" "$TMPDIR" "$DOWNLOADS"

# ── Compiler flags ────────────────────────────────────────────────────────────
export SRC="$REPO_ROOT/sources"
export DOWNLOADS="$TMPDIR/downloads"
export TARGET_OS="linux"
export TARGET_PLATFORM="linux-x64"
export TARGET_TRIPLE="x86_64-linux-gnu"
export ARCH="x86_64"
export BUILD_TYPE="${BUILD_TYPE:-static}"
export TARGET_CFLAGS=""
export LDFLAGS="-L${DEPS_PREFIX}/lib"

export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${DEPS_PREFIX}/lib/pkgconfig"

echo "=== custom_ffmpeg build (linux) ==="
echo "  Repo   : $REPO_ROOT"
echo "  Prefix : $DEPS_PREFIX"
echo "  Clang  : $(clang --version | head -1)"
echo "  NASM   : $(nasm --version)"
echo "==================================="

# ── Detect --ffmpeg flag ──────────────────────────────────────────────────────
BUILD_FFMPEG=0
FFMPEG_PROFILE="full"
DEPS_ARGS=()

for arg in "$@"; do
    if [[ "$arg" == "--ffmpeg" ]]; then
        BUILD_FFMPEG=1
    elif [[ "$arg" == "--shared" ]]; then
        BUILD_TYPE=shared
    elif [[ "$BUILD_FFMPEG" == 1 && "$arg" != --* ]]; then
        FFMPEG_PROFILE="$arg"
    else
        DEPS_ARGS+=("$arg")
    fi
done

# ── Build deps ────────────────────────────────────────────────────────────────
bash "$REPO_ROOT/build/build_deps.sh" "${DEPS_ARGS[@]+"${DEPS_ARGS[@]}"}"

# ── Optionally build FFmpeg ───────────────────────────────────────────────────
if [[ "$BUILD_FFMPEG" == 1 ]]; then
    GEN_DIR="$REPO_ROOT/generated"
    ENV_FILE="$GEN_DIR/linux-x64-${BUILD_TYPE}-${FFMPEG_PROFILE}.env"

    echo ""
    echo "=== Generating FFmpeg config (linux-x64 / ${BUILD_TYPE} / ${FFMPEG_PROFILE}) ==="
    mkdir -p "$GEN_DIR"
    cmake \
        "-DTARGET_PLATFORM=linux-x64" \
        "-DBUILD_TYPE=${BUILD_TYPE}" \
        "-DPROFILE=${FFMPEG_PROFILE}" \
        "-DOUTPUT_DIR=${GEN_DIR}" \
        "-DPROFILES_DIR=${REPO_ROOT}/profiles" \
        -P "${REPO_ROOT}/cmake/GenerateConfig.cmake"

    echo ""
    echo "=== Building FFmpeg ==="
    # Deps were built above — skip the dep stage inside build_ffmpeg.sh
    SKIP_DEPS=1 \
    ARTIFACTS_ROOT="${ARTIFACTS_ROOT:-$REPO_ROOT/prebuilt}" \
    REPO_ROOT="$REPO_ROOT" \
    bash "$REPO_ROOT/build/build_ffmpeg.sh" "$ENV_FILE"
fi
