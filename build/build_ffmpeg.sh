#!/usr/bin/env bash
# build_ffmpeg.sh — configures and builds FFmpeg.
# Works inside the Docker container (default) and natively on Linux/macOS.
#
# Usage: bash /src/build/build_ffmpeg.sh /configs/<platform>-<type>-<profile>.env
#
# Docker mounts expected:
#   /src        — repo root (sources/, compat/, build/, profiles/)
#   /winsdk     — Windows SDK bind mount [win64 only]
#   /artifacts  — output + writable scratch
#   /configs    — generated .env files
#
# Native use (Linux/macOS):
#   REPO_ROOT=/path/to/repo ARTIFACTS_ROOT=/path/to/output \
#     bash build/build_ffmpeg.sh generated/linux-x64-static-full.env
set -euo pipefail

ENV_FILE="${1:?Usage: $0 <config.env>}"
# shellcheck source=/dev/null
source "$ENV_FILE"

# REPO_ROOT: root of the custom_ffmpeg repo.  Default: /src (Docker mount).
REPO_ROOT="${REPO_ROOT:-${SRC_ROOT:-/src}}"
# ARTIFACTS_ROOT: where output and scratch live.  Default: /artifacts (Docker mount).
ARTIFACTS_ROOT="${ARTIFACTS_ROOT:-/artifacts}"
export REPO_ROOT

# shellcheck source=build/lib/paths.sh
source "${REPO_ROOT}/build/lib/paths.sh"

: "${TARGET_PLATFORM:?}"
: "${TARGET_OS:?}"
: "${TARGET_TRIPLE:?}"
: "${ARCH:?}"
: "${BUILD_TYPE:?}"
: "${PROFILE:?}"

echo "=== custom_ffmpeg build ==="
echo "  Platform : ${TARGET_PLATFORM}"
echo "  Type     : ${BUILD_TYPE}"
echo "  Profile  : ${PROFILE}"
echo "==========================="

# ── Stage times ───────────────────────────────────────────────────────────────
# stage <name> ends the running stage and starts the next ("" = none);
# stage_summary prints how long each took (where a build spends its time —
# e.g. the Windows CI build vs Linux/macOS)
STAGE_LOG=()
_stage_name="" _stage_t0=0
stage() {
    local now
    now=$(date +%s)
    [[ -n "$_stage_name" ]] && STAGE_LOG+=("${_stage_name}|$(( now - _stage_t0 ))")
    _stage_name="$1" _stage_t0=$now
}
stage_summary() {
    local e secs total=0
    stage ""
    echo "=== Stage times (${TARGET_PLATFORM} ${BUILD_TYPE} ${PROFILE}) ==="
    for e in "${STAGE_LOG[@]+"${STAGE_LOG[@]}"}"; do
        secs=${e##*|}
        total=$(( total + secs ))
        printf '  %-20s %4d:%02d\n' "${e%|*}" $(( secs / 60 )) $(( secs % 60 ))
    done
    printf '  %-20s %4d:%02d\n' "total" $(( total / 60 )) $(( total % 60 ))
}

stage "environment"
# Directories, cross-compilation flags and the dep scripts' environment
# shellcheck source=build/lib/target_env.sh
source "${REPO_ROOT}/build/lib/target_env.sh"

OUT="${ARTIFACTS_ROOT}/${TARGET_PLATFORM}/${BUILD_TYPE}/${PROFILE}"
# One build dir per variant: full and minimal can be rebuilt incrementally side by side
BUILD_DIR="${BUILD_ROOT}/ffmpeg-${TARGET_PLATFORM}-${BUILD_TYPE}-${PROFILE}"
mkdir -p "$OUT" "$BUILD_DIR"

# ── Build dependencies ────────────────────────────────────────────────────────
# Pass optional dep list from env: ONLY_DEPS="x264 x265" build_ffmpeg.sh ...
if [[ "${SKIP_DEPS:-0}" != "1" ]]; then
    stage "dependencies"
    # shellcheck disable=SC2086
    bash "${REPO_ROOT}/build/build_deps.sh" ${ONLY_DEPS:-}
else
    echo "=== SKIP_DEPS=1 — skipping dependency build stage ==="
fi

# Skip FFmpeg configure/build when only building specific deps
if [[ -n "${ONLY_DEPS:-}" ]]; then
    echo ""
    echo "=== ONLY_DEPS set — skipping FFmpeg configure/build ==="
    stage_summary
    exit 0
fi

stage "sources"

# ── FFmpeg sources ────────────────────────────────────────────────────────────
# win64: export the submodule onto the native FS (export_src: ~1 s via git
# archive vs ~21 s copying ~10k files over the bind mount; incremental-safe).
FFMPEG_SRC="${REPO_ROOT}/sources/ffmpeg"
if [[ "${TARGET_OS}" == "win64" ]]; then
    FFMPEG_SRC="${BUILD_ROOT}/src/ffmpeg"
    export_src "${REPO_ROOT}/sources/ffmpeg" "${FFMPEG_SRC}"
    # The export has no .git: pin the version string version.sh derives from
    # git (e.g. git-2026-06-11-e4c6317) instead of the RELEASE fallback
    if [[ ! -f "${FFMPEG_SRC}/VERSION" ]]; then
        sh "${REPO_ROOT}/sources/ffmpeg/ffbuild/version.sh" "${REPO_ROOT}/sources/ffmpeg" \
            > "${FFMPEG_SRC}/VERSION"
    fi
fi

# Build-machine roots → fixed names in debug info / __FILE__ (same names the
# Docker build uses, so every platform's libraries look alike)
ROOT_MAP=("${BUILD_ROOT}=/build" "${ARTIFACTS_ROOT}=/artifacts" "${REPO_ROOT}=/src")
PATH_MAP_FLAGS="$(path_map_flags "${ROOT_MAP[@]}")"

# ── Configure FFmpeg ──────────────────────────────────────────────────────────
stage "configure"
echo "=== Configuring FFmpeg ==="
cd "$BUILD_DIR"

# config.h embeds the configure command line (avutil_configuration()) and the
# data dir — both carry absolute build paths. Remember the previous config.h so
# the rewrite below can keep its mtime when nothing changed (incremental make).
[[ -f config.h ]] && cp -p config.h config.h.prev

# Windows: LLVM tools produce COFF archives.  Linux/macOS: system binutils —
# Ubuntu's clang package does not install unversioned llvm-ar / llvm-nm.
if [[ "${TARGET_OS}" == "win64" ]]; then
    FFMPEG_AR="llvm-ar"
    FFMPEG_RANLIB="llvm-ranlib"
    FFMPEG_NM="llvm-nm"
    FFMPEG_STRIP="llvm-strip"
else
    FFMPEG_AR="${AR:-ar}"
    FFMPEG_RANLIB="${RANLIB:-ranlib}"
    FFMPEG_NM="${NM:-nm}"
    FFMPEG_STRIP="${STRIP:-strip}"
fi

# x86 SIMD via NASM; macOS ARM64 uses clang's integrated assembler
if [[ "${ARCH}" == "x86_64" ]]; then
    FFMPEG_AS_FLAGS="--x86asmexe=nasm --enable-x86asm"
else
    FFMPEG_AS_FLAGS=""
fi

# Linux shared: libavcodec.so etc. find their sibling FFmpeg libraries next to
# themselves (RUNPATH=$ORIGIN) instead of relying on the executable having
# loaded them first. Escaped for configure's eval (\$), FFmpeg's makefiles
# (LDFLAGS is expanded twice: $$$$ -> $) and the shell (single quotes):
# the value passed is  -Wl,-rpath,'\$\$\$\$ORIGIN'
FFMPEG_EXTRA_LDFLAGS=""
# $ORIGIN/../lib: the programs in bin/ find the libraries in lib/ the same way.
if [[ "${TARGET_OS}" == "linux" && "${BUILD_TYPE}" == "shared" ]]; then
    FFMPEG_EXTRA_LDFLAGS="-Wl,-rpath,'\\\$\\\$\\\$\\\$ORIGIN:\\\$\\\$\\\$\\\$ORIGIN/../lib'"
fi

# Deps are static libraries for both build types: pkg-config must emit
# Libs.private (e.g. -lstdc++ for x265, -lm) — a shared FFmpeg links them in too
PKG_CONFIG_FLAGS="--pkg-config-flags=--static"

# shellcheck disable=SC2086
bash "${FFMPEG_SRC}/configure" \
    --prefix="${OUT}" \
    --target-os="${TARGET_OS}" \
    --arch="${ARCH}" \
    --cc="clang ${TARGET_CFLAGS}" \
    --cxx="clang++ ${TARGET_CFLAGS}" \
    --ld="clang ${TARGET_CFLAGS} ${LDFLAGS}" \
    --ar="${FFMPEG_AR}" \
    --ranlib="${FFMPEG_RANLIB}" \
    --nm="${FFMPEG_NM}" \
    --strip="${FFMPEG_STRIP}" \
    --pkg-config=pkg-config \
    ${PKG_CONFIG_FLAGS} \
    --extra-cflags="-O3 -I${DEPS_PREFIX}/include ${PATH_MAP_FLAGS}" \
    --extra-ldflags="-L${DEPS_PREFIX}/lib ${FFMPEG_EXTRA_LDFLAGS}" \
    --enable-asm \
    ${FFMPEG_AS_FLAGS} \
    ${EXTRA_CONF} \
    "${WINDRES_ARGS[@]+"${WINDRES_ARGS[@]}"}" \
    ${FFMPEG_CONFIGURE_FLAGS}

# Most specific root first (natively BUILD_ROOT ⊂ ARTIFACTS_ROOT ⊂ REPO_ROOT)
replace_paths config.h "${ROOT_MAP[@]}"
if [[ -f config.h.prev ]] && cmp -s config.h config.h.prev; then
    touch -r config.h.prev config.h
fi
rm -f config.h.prev

# configure drops an encoder silently when its link probe fails — fail here instead.
# Libraries are in config.h, codecs/filters in config_components.h (FFmpeg >= 5.1).
# Detected system features are HAVE_* (e.g. vaapi_drm: libva-drm found and linked).
missing=""
for name in ${FFMPEG_REQUIRED_CONFIG:-}; do
    grep -qsE "^#define (CONFIG|HAVE)_${name} 1" config.h config_components.h \
        || missing="${missing} ${name}"
done
if [[ -n "$missing" ]]; then
    echo "ERROR: required components disabled by configure:${missing}" >&2
    echo "       see ${BUILD_DIR}/ffbuild/config.log" >&2
    exit 1
fi
echo "=== Required components enabled: ${FFMPEG_REQUIRED_CONFIG:-<none>} ==="

# The profile states its license: a GPL part enabled by mistake must not end
# up in an LGPL build (or the other way round)
license=$(sed -n 's/^#define FFMPEG_LICENSE "\(.*\)"$/\1/p' config.h)
if [[ -n "${FFMPEG_EXPECTED_LICENSE:-}" && "$license" != "${FFMPEG_EXPECTED_LICENSE}" ]]; then
    echo "ERROR: configure reports license '$license', profile expects '${FFMPEG_EXPECTED_LICENSE}'" >&2
    exit 1
fi
echo "=== License: ${license} ==="

JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"

# ── Build ─────────────────────────────────────────────────────────────────────
echo "=== Building FFmpeg (${JOBS} jobs) ==="
# win64 shared: compat/windows/makedef writes each DLL's .def from the objects
# with $AR/$NM when set (otherwise it needs MSVC's lib.exe/dumpbin.exe). Set
# them on that command only: FFmpeg's quiet mode overrides make's AR with an
# "@printf ..." wrapper, which an exported AR would inherit.
if [[ "${TARGET_OS}" == "win64" && "${BUILD_TYPE}" == "shared" ]]; then
    sed -i.bak "s|^SLIB_CREATE_DEF_CMD=|SLIB_CREATE_DEF_CMD=AR=\"${FFMPEG_AR}\" NM=\"${FFMPEG_NM}\" |" \
        ffbuild/config.mak
    rm -f ffbuild/config.mak.bak
fi
stage "make"
make -j"${JOBS}"
stage "install"
make install
stage "post-install"

# win64 shared: FFmpeg installs the import libs next to the DLLs (bin/);
# consumers (and FindCustomFFmpeg) expect them in lib/
if [[ "${TARGET_OS}" == "win64" && "${BUILD_TYPE}" == "shared" ]]; then
    mv -f "${OUT}"/bin/*.lib "${OUT}/lib/"
fi

# Public headers that include dependency headers: libavutil/hwcontext_amf.h
# includes <AMF/core/*.h>, hwcontext_qsv.h <mfxvideo.h> (libvpl's include/vpl,
# which FindCustomFFmpeg adds as an include dir when present),
# hwcontext_vaapi.h <va/va.h> (libva, Linux). Ship those
# header trees with the artifact, so consumers of the hwcontext API compile
# against the versions FFmpeg was built with (FindCustomFFmpeg exports only
# the artifact's include dir). Only when the feature was configured in.
ship_dep_headers() {   # <header-dir> <config.h name>
    rm -rf "${OUT}/include/$1"
    if grep -q "^#define CONFIG_$2 1" config.h && [[ -d "${DEPS_PREFIX}/include/$1" ]]; then
        cp -a "${DEPS_PREFIX}/include/$1" "${OUT}/include/"
    fi
}
ship_dep_headers AMF AMF
ship_dep_headers vpl LIBVPL
ship_dep_headers va VAAPI

# macOS shared: dylibs carry their install path as install_name, and every
# dependent dylib and program (ffmpeg, ffprobe) records it — make them
# @rpath-relative (relocatable, no build paths). The programs find the dylibs
# through an rpath to ../lib; absolute rpaths into the output are dropped.
if [[ "${TARGET_OS}" == "darwin" && "${BUILD_TYPE}" == "shared" ]]; then
    relink_macho() {    # <Mach-O file>
        # `|| true`: a file without FFmpeg dependencies (libavutil) matches
        # nothing, and under pipefail grep's status 1 would end the build
        { otool -L "$1" | awk 'NR > 1 {print $1}' | grep -F "${OUT}/lib/" || true; } | while read -r dep; do
            install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$1"
        done
        { otool -l "$1" | awk '/cmd LC_RPATH/ {getline; getline; print $2}' | grep -F "${OUT}" || true; } | while read -r rp; do
            install_name_tool -delete_rpath "$rp" "$1"
        done
    }
    for dylib in "${OUT}"/lib/*.dylib; do
        [[ -L "$dylib" ]] && continue
        install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib"
        relink_macho "$dylib"
    done
    for prog in "${OUT}"/bin/*; do
        [[ -f "$prog" && ! -L "$prog" ]] || continue
        relink_macho "$prog"
        # load commands read first: grep -q in a pipe could end otool early
        # (SIGPIPE, a failure under pipefail) and the rpath would be added twice
        loadcmds=$(otool -l "$prog")
        if ! grep -qF '@executable_path/../lib' <<< "$loadcmds"; then
            install_name_tool -add_rpath "@executable_path/../lib" "$prog"
        fi
    done
fi

# Relocatable .pc files: the prefix is a build-time path (/artifacts/... in
# Docker). OUT is <root>/<platform>/<type>/<profile>, deps live in
# <root>/.deps/<platform> — express both relative to ${pcfiledir}. Dep -L
# flags come from the deps' own (already relocated) .pc files as
# <deps>/lib/pkgconfig/../../lib, or from --extra-ldflags as <deps>/lib.
DEPS_LIB_REL="\${pcfiledir}/../../../../.deps/${TARGET_PLATFORM}/lib"
for pc in "${OUT}"/lib/pkgconfig/*.pc; do
    replace_paths "$pc" \
        "${DEPS_PREFIX}/lib/pkgconfig/../../lib=${DEPS_LIB_REL}" \
        "${DEPS_PREFIX}/lib=${DEPS_LIB_REL}" \
        "${OUT}=\${pcfiledir}/../.."
done

# ── Licenses, build info, target checks ───────────────────────────────────────
# share/licenses/: FFmpeg's license texts (GPLv2 only for a GPL build) and
# those of every dependency linked in, by the FFmpeg feature that uses it.
# The list also drives the release packaging (which deps a static archive needs).
LICENSES="${OUT}/share/licenses"
rm -rf "$LICENSES" && mkdir -p "$LICENSES/ffmpeg"
cp "${FFMPEG_SRC}/LICENSE.md" "${FFMPEG_SRC}/COPYING.LGPLv2.1" "$LICENSES/ffmpeg/"
[[ "$license" == GPL* ]] && cp "${FFMPEG_SRC}/COPYING.GPLv2" "$LICENSES/ffmpeg/"
LINKED_DEPS=()
dep_if() {   # <config.h name> <dep>... — the deps behind an enabled feature
    local flag="$1"
    shift
    if grep -qE "^#define (CONFIG|HAVE)_${flag} 1" config.h; then LINKED_DEPS+=("$@"); fi
}
dep_if ZLIB zlib
dep_if LIBX264 x264
dep_if LIBX265 x265
dep_if LIBVPX libvpx
dep_if LIBOPUS opus
dep_if LIBVORBIS libvorbis libogg
dep_if LIBWEBP libwebp
dep_if LIBMP3LAME mp3lame
dep_if LIBSVTAV1 svtav1
dep_if LIBDAV1D dav1d
dep_if FFNVCODEC ffnvcodec
dep_if AMF amf
dep_if LIBVPL libvpl
dep_if VAAPI libva libdrm
for d in "${LINKED_DEPS[@]+"${LINKED_DEPS[@]}"}"; do
    if [[ ! -d "${DEPS_PREFIX}/share/licenses/$d" ]]; then
        echo "ERROR: no license texts for $d in ${DEPS_PREFIX}/share/licenses (rebuild the deps)" >&2
        exit 1
    fi
    cp -R "${DEPS_PREFIX}/share/licenses/$d" "$LICENSES/"
done

# Target system checks: what the outputs need from the user's OS
target_note=""
if [[ "${TARGET_OS}" == "linux" ]]; then
    # newest glibc symbol version the programs and shared libraries import
    glibc_need=$(for f in "${OUT}"/bin/* "${OUT}"/lib/*.so*; do
                     [[ -f "$f" && ! -L "$f" ]] && objdump -T "$f" 2>/dev/null
                 done | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -n 1 || true)
    if [[ -n "$glibc_need" && "$(printf '%s\n%s\n' "$glibc_need" "${GLIBC_MAX_VERSION:?}" | sort -V | tail -n 1)" != "${GLIBC_MAX_VERSION}" ]]; then
        echo "ERROR: outputs need glibc ${glibc_need}, the supported minimum is ${GLIBC_MAX_VERSION}" >&2
        exit 1
    fi
    target_note="glibc ${glibc_need:-(static libraries only)} (supported: ${GLIBC_MAX_VERSION} and newer)"
elif [[ "${TARGET_OS}" == "darwin" ]]; then
    # LC_BUILD_VERSION minos of every program and dylib
    macos_need=$(for f in "${OUT}"/bin/* "${OUT}"/lib/*.dylib; do
                     [[ -f "$f" && ! -L "$f" ]] && otool -l "$f" 2>/dev/null
                 done | awk '/LC_BUILD_VERSION/ { b = 1 } b && $1 == "minos" { print $2; b = 0 }' \
                 | sort -V | tail -n 1 || true)
    if [[ -n "$macos_need" && "$(printf '%s\n%s\n' "$macos_need" "${MACOS_MIN_VERSION:?}" | sort -V | tail -n 1)" != "${MACOS_MIN_VERSION}" ]]; then
        echo "ERROR: outputs need macOS ${macos_need}, the supported minimum is ${MACOS_MIN_VERSION}" >&2
        exit 1
    fi
    target_note="macOS ${MACOS_MIN_VERSION} (Apple silicon)"
elif [[ "${TARGET_OS}" == "win64" ]]; then
    stl=$(sed -nE 's/^#define _MSVC_STL_(VERSION|UPDATE) ([0-9]+).*/\2/p' "${MSVC_INC}/yvals_core.h" | paste -sd. -)
    target_note="Windows SDK ${SDK_VER}, MSVC STL ${stl} (link with MSVC v143 or newer)"
fi

# share/custom_ffmpeg/build-info.txt: what this artifact is and was built with
ffversion=$(sed -nE 's/^#define FFMPEG_VERSION "(.*)"/\1/p' libavutil/ffversion.h)
commit=$(git -C "${REPO_ROOT}" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
mkdir -p "${OUT}/share/custom_ffmpeg"
{
    echo "custom_ffmpeg ${commit}"
    echo "variant:   ${TARGET_PLATFORM} ${BUILD_TYPE} ${PROFILE}"
    echo "ffmpeg:    ${ffversion}"
    echo "license:   ${license}"
    echo "compiler:  $(clang --version | head -n 1)"
    echo "target:    ${target_note}"
    echo "dependencies:"
    for d in "${LINKED_DEPS[@]+"${LINKED_DEPS[@]}"}"; do
        case "$d" in
            libvpx) pc=vpx ;; libvorbis) pc=vorbis ;; libogg) pc=ogg ;; svtav1) pc=SvtAv1Enc ;;
            libvpl) pc=vpl ;; *) pc="$d" ;;
        esac
        v=$(pkg-config --modversion "$pc" 2>/dev/null || true)
        [[ -z "$v" && "$d" == mp3lame ]] && v="${LAME_VERSION:-}"
        [[ -z "$v" && "$d" == amf ]] && v="headers $(sed -nE 's/^#define AMF_VERSION_(MAJOR|MINOR|RELEASE)[[:space:]]+([0-9]+).*/\2/p' \
            "${DEPS_PREFIX}/include/AMF/core/Version.h" | paste -sd. -)"
        printf '  %-10s %s\n' "$d" "${v:-?}"
    done
} > "${OUT}/share/custom_ffmpeg/build-info.txt"
cat "${OUT}/share/custom_ffmpeg/build-info.txt"

stage "path check"
check_no_local_paths "${OUT}" "${DEPS_PREFIX}"

# ── Test build (FFMPEG_TESTS=1, win64) ────────────────────────────────────────
# FATE drives tests with make + shell scripts. For the Windows build that runs
# in WSL (tests/fate/run_fate.sh --windows), which starts every .exe natively
# on Windows — but has neither the compiler nor the SDK of this container. So
# build everything FATE executes here (programs, tools, test programs,
# checkasm; the test data generators as static host programs that run on any
# Linux), then export the tree to ARTIFACTS_ROOT/.fate/<variant>: on the
# Windows drive, reachable from both WSL and Windows. The .d dependency files
# (container header paths) are dropped, so make in WSL considers everything up
# to date and only runs tests; run_fate.sh points the recorded source path at
# the exported sources (<export>/src/ffmpeg).
if [[ "${TARGET_OS}" == "win64" && "${FFMPEG_TESTS:-0}" == "1" ]]; then
    stage "FATE prerequisites"
    echo "=== Building FATE prerequisites ==="
    # The API test programs (tests/api) are not part of "build"; their list
    # exists only inside the Makefile — expose it through a helper target
    printf 'fate-apitestprogs: $(APITESTPROGS)\n' > fate-prereq.mak
    make -j"${JOBS}" -f Makefile -f fate-prereq.mak build checkasm fate-apitestprogs
    rm -f fate-prereq.mak
    make -j"${JOBS}" HOSTLDFLAGS=-static tests/audiogen tests/videogen tests/rotozoom \
        tests/tiny_psnr tests/tiny_ssim tests/base64 tests/audiomatch

    variant="$(basename "${BUILD_DIR}")"
    fate_root="${ARTIFACTS_ROOT}/.fate"
    echo "=== Exporting FATE tree -> ${fate_root}/${variant} ==="
    rm -rf "${fate_root:?}/${variant}" "${fate_root}/src"
    mkdir -p "${fate_root}"
    tar -C "${BUILD_ROOT}" -cf - "${variant}" src/ffmpeg | tar -C "${fate_root}" -xf -
    find "${fate_root}/${variant}" -name '*.d' -delete
    ln -sfn ../src/ffmpeg "${fate_root}/${variant}/src"
    # Files written here belong to root (Docker records that in NTFS metadata),
    # but FATE runs as the WSL user and writes into the tree (logs, test outputs)
    chmod -R a+rwX "${fate_root}/${variant}"
fi

echo ""
echo "=== FFmpeg build complete ==="
echo "    Output: $OUT"
ls "${OUT}/lib/" 2>/dev/null || true
stage_summary
