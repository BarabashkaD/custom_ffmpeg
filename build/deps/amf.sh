#!/usr/bin/env bash
# amf.sh — AMD Advanced Media Framework: public headers only.
#
# FFmpeg needs nothing but the headers (AMF/core, AMF/components) at build
# time; the runtime (amfrt64.dll on Windows, libamfrt64.so.1 on Linux) comes
# with the AMD driver and is loaded with LoadLibrary/dlopen when an AMF codec
# is opened, so there is no library, no .pc file and no link-time dependency.
# Source: the official AMF-headers-<tag>.tar.gz release asset (made by the AMF
# repository's publish-header workflow from amf/public/include) — the
# repository itself is >1 GB of binaries and samples. Pinned in versions.cmake.
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [[ "$TARGET_OS" != "win64" && "$TARGET_OS" != "linux" ]]; then
    echo "=== amf: not used on ${TARGET_OS}, skipping ==="
    exit 0
fi

VERSION=$(versions_var AMF_HEADERS_VERSION)
URL=$(versions_var AMF_HEADERS_URL)
TARBALL=$(versions_var AMF_HEADERS_TARBALL)
SHA256=$(versions_var AMF_HEADERS_SHA256)
[[ -n "$VERSION" && -n "$URL" && -n "$TARBALL" && -n "$SHA256" ]] \
    || { echo "ERROR: AMF_HEADERS_* missing in versions.cmake" >&2; exit 1; }

# Version.h of the installed headers as "major.minor.release" — re-install
# when the pin in versions.cmake moves
installed_version() {
    local h="$DEPS_PREFIX/include/AMF/core/Version.h"
    [[ -f "$h" ]] || return 0
    sed -nE 's/^#define AMF_VERSION_(MAJOR|MINOR|RELEASE)[[:space:]]+([0-9]+).*/\2/p' "$h" \
        | tr '\n' '.' | sed 's/\.$//'
}

if [[ "$(installed_version)" == "$VERSION" ]]; then
    echo "=== amf: headers ${VERSION} already installed, skipping ==="
    exit 0
fi

echo "=== amf (headers ${VERSION}) ==="
ARCHIVE="$DOWNLOADS/$TARBALL"
if [[ ! -f "$ARCHIVE" ]]; then
    echo "  Downloading ${TARBALL}..."
    curl -fsSL -o "$ARCHIVE" "$URL"
fi
echo "  Verifying checksum..."
check_sha256 "$SHA256" "$ARCHIVE"

SRC_DIR="$WORK_ROOT/amf-src"
rm -rf "$SRC_DIR" && mkdir -p "$SRC_DIR"
tar xzf "$ARCHIVE" -C "$SRC_DIR"
HDR_DIR=$(find "$SRC_DIR" -mindepth 2 -maxdepth 2 -type d -name AMF | head -n1)
[[ -n "$HDR_DIR" && -f "$HDR_DIR/core/Version.h" ]] \
    || { echo "ERROR: unexpected layout of ${TARBALL} (no AMF/core/Version.h)" >&2; exit 1; }

rm -rf "$DEPS_PREFIX/include/AMF"
mkdir -p "$DEPS_PREFIX/include"
cp -R "$HDR_DIR" "$DEPS_PREFIX/include/AMF"
# Plain read-only headers whatever the archive's modes/owner were
find "$DEPS_PREFIX/include/AMF" -type d -exec chmod 755 {} +
find "$DEPS_PREFIX/include/AMF" -type f -exec chmod 644 {} +

[[ "$(installed_version)" == "$VERSION" ]] \
    || { echo "ERROR: Version.h says $(installed_version), versions.cmake pins ${VERSION}" >&2; exit 1; }
echo "  Installed $(find "$DEPS_PREFIX/include/AMF" -name '*.h' | wc -l | tr -d ' ') headers into include/AMF"
echo "=== amf: done ==="
