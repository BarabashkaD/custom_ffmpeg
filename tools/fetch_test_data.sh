#!/usr/bin/env bash
# fetch_test_data.sh — download / update the test data sets used by the full
# test level into one root directory (one subdirectory per set):
#
#   <root>/fate-suite/   FFmpeg FATE samples   (rsync, ~1.4 GB)
#   <root>/libvpx/       libvpx test vectors   (https, ~6.3 GB, sha1-verified)
#   <root>/opus/         Opus RFC 8251 vectors (https, ~75 MB)
#   <root>/dav1d/        dav1d-test-data at the dav1d release tag (git, ~140 MB)
#   <root>/svtav1/       SVT-AV1 E2E test clips (https, ~430 MB, sha1-verified)
#
# Usage: bash tools/fetch_test_data.sh <root> [fate|libvpx|opus|dav1d|svtav1|all]
#        <root> defaults to $CUSTOM_FFMPEG_TEST_DATA.
# Re-running only transfers what changed or is missing.
set -euo pipefail
root="${1:-${CUSTOM_FFMPEG_TEST_DATA:-}}"
what="${2:-all}"
[[ -n "$root" ]] || { echo "Usage: $0 <root> [fate|libvpx|opus|dav1d|svtav1|all]  (or set CUSTOM_FFMPEG_TEST_DATA)" >&2; exit 1; }
repo="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root"

fetch_fate() {
    command -v rsync >/dev/null || { echo "rsync is required" >&2; exit 1; }
    echo "=== fate-suite -> $root/fate-suite ==="
    mkdir -p "$root/fate-suite"
    # Same options as FFmpeg's `make fate-rsync`
    rsync -rltLW --timeout=60 --contimeout=60 --delete \
        rsync://fate-suite.ffmpeg.org/fate-suite/ "$root/fate-suite/"
    echo "=== fate-suite: $(du -sh "$root/fate-suite" | cut -f1) ==="
}

fetch_libvpx() {
    local list="$repo/sources/libvpx/test/test-data.sha1"
    local base="https://storage.googleapis.com/downloads.webmproject.org/test_data/libvpx"
    local dest="$root/libvpx"
    [[ -f "$list" ]] || { echo "missing $list (submodule not checked out?)" >&2; exit 1; }
    echo "=== libvpx test vectors ($(wc -l < "$list") files) -> $dest ==="
    mkdir -p "$dest"
    # Download only missing or mismatching files, 8 in parallel, verify sha1
    export dest base
    awk '{sub(/^\*/, "", $2); print $1, $2}' "$list" | xargs -P 8 -n 2 sh -c '
        sha="$0"; f="$1"; out="$dest/$f"
        if [ -f "$out" ] && echo "$sha  $out" | sha1sum -c --status 2>/dev/null; then exit 0; fi
        curl -fsSL --retry 3 --max-time 600 -o "$out.part" "$base/$f" &&
        echo "$sha  $out.part" | sha1sum -c --status && mv -f "$out.part" "$out" ||
        { echo "FAILED: $f" >&2; rm -f "$out.part"; exit 255; }'
    echo "=== libvpx: $(ls "$dest" | wc -l) files, $(du -sh "$dest" | cut -f1) ==="
}

fetch_opus() {
    local url="https://opus-codec.org/docs/opus_testvectors-rfc8251.tar.gz"
    local dest="$root/opus"
    if ls "$dest"/testvector01.bit >/dev/null 2>&1; then
        echo "=== opus vectors: present ==="
        return
    fi
    echo "=== opus vectors -> $dest ==="
    mkdir -p "$dest"
    curl -fsSL --retry 3 -o "$dest/vectors.tar.gz" "$url"
    # The archive holds one directory with testvectorNN{.bit,.dec,m.dec}
    tar -xzf "$dest/vectors.tar.gz" -C "$dest" --strip-components=1
    rm -f "$dest/vectors.tar.gz"
    echo "=== opus vectors: $(ls "$dest" | wc -l) files ==="
}

fetch_dav1d() {
    # dav1d-test-data tags follow the dav1d releases: take the tag of the
    # version the dav1d submodule is pinned to (meson.build, no git tags needed)
    local url="https://code.videolan.org/videolan/dav1d-test-data.git"
    local dest="$root/dav1d" tag
    tag=$(sed -nE "s/^[[:space:]]*version:[[:space:]]*'([^']+)'.*/\\1/p" \
        "$repo/sources/dav1d/meson.build" | head -n1)
    [[ -n "$tag" ]] || { echo "cannot read the dav1d version (submodule not checked out?)" >&2; exit 1; }
    echo "=== dav1d-test-data $tag -> $dest ==="
    if [[ -d "$dest/.git" ]]; then
        git -C "$dest" fetch -q --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
        git -C "$dest" checkout -q --force "refs/tags/$tag"
    else
        rm -rf "$dest"
        git -c core.autocrlf=false -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "$url" "$dest"
    fi
    echo "=== dav1d-test-data: $(git -C "$dest" describe --tags), $(du -sh --exclude=.git "$dest" | cut -f1) ==="
}

fetch_svtav1() {
    # SVT-AV1's E2E clips: the list (sha1 *name) and host its TestVectors
    # target uses (test/e2e_test/test_vector_list.txt, test_data_download_worker.cmake)
    local list="$repo/sources/svtav1/test/e2e_test/test_vector_list.txt"
    local base="https://storage.googleapis.com/aom-test-data"
    local dest="$root/svtav1"
    [[ -f "$list" ]] || { echo "missing $list (submodule not checked out?)" >&2; exit 1; }
    echo "=== SVT-AV1 E2E clips ($(wc -l < "$list") files) -> $dest ==="
    mkdir -p "$dest"
    export dest base
    awk '{sub(/^\*/, "", $2); print $1, $2}' "$list" | xargs -P 4 -n 2 sh -c '
        sha="$0"; f="$1"; out="$dest/$f"
        if [ -f "$out" ] && echo "$sha  $out" | sha1sum -c --status 2>/dev/null; then exit 0; fi
        curl -fsSL --retry 3 --max-time 600 -o "$out.part" "$base/$f" &&
        echo "$sha  $out.part" | sha1sum -c --status && mv -f "$out.part" "$out" ||
        { echo "FAILED: $f" >&2; rm -f "$out.part"; exit 255; }'
    echo "=== svtav1: $(ls "$dest" | wc -l) files, $(du -sh "$dest" | cut -f1) ==="
}

case "$what" in
    fate)   fetch_fate ;;
    libvpx) fetch_libvpx ;;
    opus)   fetch_opus ;;
    dav1d)  fetch_dav1d ;;
    svtav1) fetch_svtav1 ;;
    all)    fetch_fate; fetch_libvpx; fetch_opus; fetch_dav1d; fetch_svtav1 ;;
    *) echo "unknown set: $what" >&2; exit 1 ;;
esac
