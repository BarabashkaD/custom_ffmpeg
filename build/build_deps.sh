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

# ── Licenses ──────────────────────────────────────────────────────────────────
# <prefix>/share/licenses/<dep>/: the license texts of every installed
# dependency (redistributing the binaries requires them). build_ffmpeg.sh
# copies those of the deps a profile links next to FFmpeg's own.
SOURCES="${SRC:-${REPO_ROOT}/sources}"
DOWNLOADS="${DOWNLOADS:-/artifacts/.downloads}"   # as in deps/common.sh

dep_applies() {   # <dep> — built for TARGET_OS (the others' scripts are no-ops)
    case "$1" in
        # macOS: "macos" from build_macos.sh, "darwin" from the generated .env
        ffnvcodec|amf|libvpl) [[ "$TARGET_OS" != "macos" && "$TARGET_OS" != "darwin" ]] ;;
        libdrm|libva)         [[ "$TARGET_OS" == "linux" ]] ;;
        *) true ;;
    esac
}

# header_license <header> — the header's comment block with the license
# grant (for projects that ship no license file: the text lives in the headers)
header_license() {
    # comment blocks: /* ... */ or a run of // lines; the first one granting
    # a license is printed without its comment markers
    awk 'function flush() { if (blk ~ /Permission is hereby granted/) { printf "%s", blk; done = 1 } blk = "" }
         done { exit }
         inc { line = $0; sub(/^[ \t]*\*+\/?[ \t]?/, "", line); blk = blk line "\n"
               if ($0 ~ /\*\//) { inc = 0; flush() } next }
         /^[ \t]*\/\*/ { inc = 1; blk = ""; line = $0; sub(/^[ \t]*\/\*+[ \t]?/, "", line)
                         blk = line "\n"; if ($0 ~ /\*\//) { inc = 0; flush() } next }
         /^[ \t]*\/\// { line = $0; sub(/^[ \t]*\/\/[ \t]?/, "", line); blk = blk line "\n"; inl = 1; next }
         inl { inl = 0; flush() }' "$1"
}

install_licenses() {   # <dep>
    local dep="$1" dest="$DEPS_PREFIX/share/licenses/$1" f found=0
    dep_applies "$dep" || return 0
    rm -rf "$dest" && mkdir -p "$dest"
    case "$dep" in
        mp3lame)    # SourceForge archive (no submodule), kept by mp3lame.sh in DOWNLOADS
            local archive="${DOWNLOADS}/${LAME_TARBALL:?}" sum
            if [[ ! -f "$archive" ]]; then   # built earlier, archive gone: fetch again
                mkdir -p "$DOWNLOADS"
                curl -fsSL -o "$archive" "${LAME_URL:?}"
            fi
            sum=$( (sha256sum "$archive" 2>/dev/null || shasum -a 256 "$archive") | cut -d' ' -f1)
            if [[ "$sum" != "${LAME_SHA256:?}" ]]; then
                echo "ERROR: $archive: SHA-256 mismatch" >&2
                exit 1
            fi
            tar -xzf "$archive" -C "$dest" --strip-components=1 \
                "lame-${LAME_VERSION}/COPYING" "lame-${LAME_VERSION}/LICENSE" && found=1 ;;
        ffnvcodec)  header_license "$DEPS_PREFIX/include/ffnvcodec/nvEncodeAPI.h" > "$dest/LICENSE" ;;
        amf)        header_license "$DEPS_PREFIX/include/AMF/core/Factory.h" > "$dest/LICENSE" ;;
        libdrm)     header_license "$DEPS_PREFIX/include/xf86drm.h" > "$dest/LICENSE" ;;
        *)
            for f in "$SOURCES/$dep"/*; do
                case "$(basename "$f")" in
                    COPYING*|LICENSE*|LICENCE*|PATENTS*|NOTICE*) cp "$f" "$dest/"; found=1 ;;
                esac
            done ;;
    esac
    [[ -s "$dest/LICENSE" ]] && found=1
    if [[ "$found" != 1 ]]; then
        echo "ERROR: no license text found for $dep" >&2
        exit 1
    fi
}

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
    install_licenses "$dep"
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
