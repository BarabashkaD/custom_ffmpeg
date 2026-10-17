#!/usr/bin/env bash
# build_deps.sh — aggregator: builds all FFmpeg dependencies in dependency order.
#
# Can build all deps or a specific subset:
#   bash build_deps.sh                          # all deps
#   bash build_deps.sh libogg libvorbis opus    # only these three
#
# Each dep script is idempotent — skips if the output .a already exists.
#
# Required env (exported by build_ffmpeg.sh):
#   TARGET_OS, TARGET_TRIPLE, ARCH, DEPS_PREFIX
#   TARGET_CFLAGS, LDFLAGS
#   LAME_VERSION, LAME_URL, LAME_TARBALL, LAME_SHA256
set -euo pipefail

: "${TARGET_OS:?}"
: "${DEPS_PREFIX:?}"

DEPS_DIR="$(dirname "$0")/deps"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=build/lib/paths.sh
source "${REPO_ROOT}/build/lib/paths.sh"

# Dependency order matters: libogg before libvorbis, libdrm before libva
ALL_DEPS=(
    zlib
    libogg
    libvorbis
    opus
    libvpx
    x264
    x265
    libwebp
    mp3lame
    svtav1
    dav1d
    ffnvcodec
    amf
    libdrm
    libva
    libvpl
)

# Build list: the requested deps (all without arguments), always in ALL_DEPS
# order — callers may list them in any order (CI groups several in one job)
BUILD_LIST=()
for dep in "$@"; do
    case " ${ALL_DEPS[*]} " in
        *" $dep "*) ;;
        *) echo "ERROR: unknown dependency '$dep' (known: ${ALL_DEPS[*]})" >&2; exit 1 ;;
    esac
done
for dep in "${ALL_DEPS[@]}"; do
    case " $* " in
        *" $dep "*) BUILD_LIST+=("$dep") ;;
        *) [[ $# -eq 0 ]] && BUILD_LIST+=("$dep") ;;
    esac
done

echo "======================================"
echo " Building dependencies"
echo " Platform : ${TARGET_OS}"
echo " Prefix   : ${DEPS_PREFIX}"
echo " Deps     : ${BUILD_LIST[*]}"
echo "======================================"

for dep in "${BUILD_LIST[@]}"; do
    platform_script="$DEPS_DIR/${dep}_${TARGET_OS}.sh"
    generic_script="$DEPS_DIR/${dep}.sh"
    if [[ -f "$platform_script" ]]; then
        script="$platform_script"
    elif [[ -f "$generic_script" ]]; then
        script="$generic_script"
    else
        echo "ERROR: unknown dependency '${dep}' (no script found in ${DEPS_DIR})" >&2
        exit 1
    fi
    bash "$script"
done

# Relocatable outputs: .pc files point at ${pcfiledir} instead of the absolute
# install prefix; libtool .la files only record absolute paths (pkg-config is
# used for linking), so they are dropped
for pc in "$DEPS_PREFIX"/lib/pkgconfig/*.pc; do
    [[ -f "$pc" ]] && replace_paths "$pc" "${DEPS_PREFIX}=\${pcfiledir}/../.."
done
find "$DEPS_PREFIX/lib" -name '*.la' -delete 2>/dev/null || true

check_no_local_paths "$DEPS_PREFIX"

echo ""
echo "======================================"
echo " All requested dependencies ready"
echo " Prefix: $DEPS_PREFIX"
echo "======================================"
