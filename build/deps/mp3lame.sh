#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

: "${LAME_VERSION:?mp3lame.sh requires LAME_VERSION}"
: "${LAME_URL:?mp3lame.sh requires LAME_URL}"
: "${LAME_TARBALL:?mp3lame.sh requires LAME_TARBALL}"
: "${LAME_SHA256:?mp3lame.sh requires LAME_SHA256}"

# LAME installs no .pc file; libtool names the win64 static lib mp3lame.lib
if already_built lib/libmp3lame.a lib/mp3lame.lib; then
    echo "=== mp3lame: already built, skipping ==="
    exit 0
fi

echo "=== mp3lame ==="
ARCHIVE="$DOWNLOADS/$LAME_TARBALL"

if [[ ! -f "$ARCHIVE" ]]; then
    echo "  Downloading LAME ${LAME_VERSION}..."
    curl -fsSL -o "$ARCHIVE" "$LAME_URL"
fi

echo "  Verifying checksum..."
check_sha256 "$LAME_SHA256" "$ARCHIVE"

cd "$WORK_ROOT"
rm -rf "lame-${LAME_VERSION}"
tar xf "$ARCHIVE"
cd "lame-${LAME_VERSION}"

# shellcheck disable=SC2046
./configure \
    $(autotools_cross_flags) \
    ${LINK_FLAGS} \
    AR="$AR" RANLIB="$RANLIB" \
    CC="$CC_CMD" CXX="$CXX_CMD"
make -j"$JOBS"
make install
echo "=== mp3lame: done ==="
