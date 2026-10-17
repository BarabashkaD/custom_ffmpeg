#!/usr/bin/env bash
# cache_key.sh <platform> deps <dep>...       — key for one deps matrix entry
# cache_key.sh <platform> ffmpeg <profile>... — key for the FFmpeg build
#
# Prints a content hash of everything that determines the build output.
# `git ls-files -s` lists the blob SHA of each tracked file and the commit SHA
# of each submodule (gitlink) — no submodule checkout needed, independent of
# line endings, identical on Windows/Linux/macOS runners. ImageOS/ImageVersion
# (set on GitHub-hosted runners) cover the toolchain and Windows SDK/MSVC.
# Bump CACHE_EPOCH to invalidate every cache by hand.
set -euo pipefail
CACHE_EPOCH=1

platform="$1" kind="$2"
shift 2
cd "$(git rev-parse --show-toplevel)"

case "$platform" in
    windows-x64) platform_files=(build/build_ffmpeg.sh docker compat cmake/GenerateConfig.cmake cmake/FindWindowsSDK.cmake) ;;
    linux-x64)   platform_files=(build/build_linux.sh) ;;
    macos-arm64) platform_files=(build/build_macos.sh) ;;
    *) echo "unknown platform: $platform" >&2; exit 1 ;;
esac

case "$kind" in
    deps)
        # The dep's submodule, its scripts (all platform variants) and patches
        specs=()
        for dep in "$@"; do
            specs+=("sources/$dep" "build/deps/$dep.sh" "build/deps/${dep}_*.sh" "patches/$dep")
            # Extra submodules a dep builds from (test-only included)
            case "$dep" in
                dav1d) specs+=(sources/checkasm) ;;
                libva) specs+=(sources/libva-utils) ;;
                svtav1) specs+=(sources/libaom) ;;
            esac
        done
        specs+=(build/deps/common.sh build/build_deps.sh versions.cmake)
        ;;
    ffmpeg)
        # FFmpeg output depends on every dep too: hash the whole build input
        specs=(sources build patches profiles versions.cmake)
        ;;
    *) echo "unknown kind: $kind" >&2; exit 1 ;;
esac

{
    echo "epoch=$CACHE_EPOCH platform=$platform kind=$kind args=$*"
    echo "runner=${ImageOS:-local}-${ImageVersion:-local}"
    git ls-files -s -- "${specs[@]}" "${platform_files[@]}"
} | git hash-object --stdin | cut -c1-16
