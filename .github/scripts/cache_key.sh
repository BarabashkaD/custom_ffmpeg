#!/usr/bin/env bash
# cache_key.sh <platform> deps <dep>...       — key for one deps matrix entry
# cache_key.sh <platform> ffmpeg <profile>... — key for the FFmpeg build
#
# Prints a content hash of everything that determines the build output.
# `git ls-files -s` lists the blob SHA of each tracked file and the commit SHA
# of each submodule (gitlink) — no submodule checkout needed, independent of
# line endings, identical on Windows/Linux/macOS runners.
# Toolchain: Linux/macOS build with the runner's compilers — ImageOS/ImageVersion
# (set on GitHub-hosted runners). windows-x64 builds in the builder image
# against the host's MSVC and Windows SDK: their versions plus a hash of key
# files (MSVC_VERSION, WINSDK_VERSION, WINSDK_BUILD, WINTOOLS_HASH from the
# "Generate config" step — in-place updates keep the directory names) and the
# builder image's package list (BUILDER_FINGERPRINT, build-image job) replace
# the runner image version, so the weekly runner image update keeps the cache.
# Bump CACHE_EPOCH to invalidate every cache by hand.
set -euo pipefail
CACHE_EPOCH=1

platform="$1" kind="$2"
shift 2
cd "$(git rev-parse --show-toplevel)"

case "$platform" in
    windows-x64)
        # the target environment, not build_ffmpeg.sh: its dep stage only calls
        # build_deps.sh, so FFmpeg-stage changes keep the deps' caches
        # windows_stage.ps1 / windows_unstage.sh decide which SDK/MSVC files
        # (and case aliases) the container sees
        platform_files=(build/lib/target_env.sh docker compat cmake/GenerateConfig.cmake cmake/FindWindowsSDK.cmake
                        .github/scripts/windows_stage.ps1 .github/scripts/windows_unstage.sh)
        runner="${ImageOS:-local}-msvc=${MSVC_VERSION:?run Generate config first}"
        runner+="-sdk=${WINSDK_VERSION:?run Generate config first}-${WINSDK_BUILD:?run Generate config first}"
        runner+="-files=${WINTOOLS_HASH:?run Generate config first}"
        runner+="-image=${BUILDER_FINGERPRINT:?set by the build-image job}"
        ;;
    linux-x64)   platform_files=(build/build_linux.sh);  runner="${ImageOS:-local}-${ImageVersion:-local}" ;;
    macos-arm64) platform_files=(build/build_macos.sh);  runner="${ImageOS:-local}-${ImageVersion:-local}" ;;
    *) echo "unknown platform: $platform" >&2; exit 1 ;;
esac

case "$kind" in
    deps)
        # The deps' submodules (dep_submodules.sh), their scripts (all platform
        # variants) and patches
        specs=()
        for dep in "$@"; do
            specs+=("build/deps/$dep.sh" "build/deps/${dep}_*.sh" "patches/$dep")
        done
        while IFS= read -r p; do specs+=("$p"); done < <(bash .github/scripts/dep_submodules.sh "$@")
        specs+=(build/deps/common.sh build/build_deps.sh build/lib/paths.sh versions.cmake)
        ;;
    ffmpeg)
        # FFmpeg output depends on every dep too: hash the whole build input
        specs=(sources build patches profiles versions.cmake)
        ;;
    *) echo "unknown kind: $kind" >&2; exit 1 ;;
esac

{
    echo "epoch=$CACHE_EPOCH platform=$platform kind=$kind args=$*"
    echo "runner=$runner"
    git ls-files -s -- "${specs[@]}" "${platform_files[@]}"
} | git hash-object --stdin | cut -c1-16
