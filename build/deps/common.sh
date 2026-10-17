#!/usr/bin/env bash
# common.sh — sourced by every dep script.
# Provides: CC_CMD, CXX_CMD, OPT_FLAGS, LINK_FLAGS, LINK_FLAGS_X264,
#           autotools_cross_flags(), already_built()
# Requires env: TARGET_OS, DEPS_PREFIX, TARGET_CFLAGS, LDFLAGS
# Optional env: BUILD_TYPE (static|shared, default: static)

: "${TARGET_OS:?common.sh requires TARGET_OS}"
: "${DEPS_PREFIX:?common.sh requires DEPS_PREFIX}"
: "${TARGET_CFLAGS?common.sh requires TARGET_CFLAGS}"   # may be empty
: "${LDFLAGS?common.sh requires LDFLAGS}"                # may be empty

# Parallel jobs: JOBS from env (e.g. to leave room for other builds), else all CPUs
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"
# SRC and DOWNLOADS: prefer env-provided paths (native), fall back to Docker mount points
SRC="${SRC:-/src/sources}"
DOWNLOADS="${DOWNLOADS:-/artifacts/.downloads}"
REPO_ROOT="${REPO_ROOT:-$(cd "$SRC/.." && pwd)}"

# shellcheck source=build/lib/paths.sh
source "${REPO_ROOT}/build/lib/paths.sh"

# Build-machine paths must not end up in the libraries (debug info, __FILE__):
# map every root to the fixed names the Docker build uses
OPT_FLAGS="-O3 $(path_map_flags "${REPO_ROOT}=/src" "${DEPS_PREFIX}=/deps" "${TMPDIR:-/tmp}=/tmp")"

CC_CMD="clang ${TARGET_CFLAGS} ${OPT_FLAGS}"
CXX_CMD="clang++ ${TARGET_CFLAGS} ${OPT_FLAGS}"

# AR/RANLIB: use LLVM tools for Windows to produce COFF-compatible archives
if [[ "$TARGET_OS" == "win64" ]]; then
    AR="${AR:-llvm-ar}"
    RANLIB="${RANLIB:-llvm-ranlib}"
else
    AR="${AR:-ar}"
    RANLIB="${RANLIB:-ranlib}"
fi

# Deps are always static libraries built as position-independent code: one
# deps dir per platform serves both FFmpeg build types — static FFmpeg links
# them into the consumer, shared FFmpeg links them into its .so/.dll/.dylib
# (which needs PIC on Linux). A shared dep next to its .a would also win at
# link time and add a runtime dependency.
# LINK_FLAGS — for autotools and cmake deps (standard --enable/--disable pair)
# LINK_FLAGS_X264 — x264 configure only knows --enable-static / --enable-shared
LINK_FLAGS="--enable-static --disable-shared"
LINK_FLAGS_X264="--enable-static"
CMAKE_SHARED="-DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON"
# x265 ignores BUILD_SHARED_LIBS and builds a shared lib by default; on Windows
# its import lib collides with the static x265.lib ("multiple rules generate
# x265.lib"). ENABLE_PIC defaults to ON on x86_64/arm64 non-Windows.
X265_SHARED="-DENABLE_SHARED=OFF"

# CMake resolves a bare CMAKE_AR=llvm-ar relative to the build dir — pass full paths
if [[ "$TARGET_OS" == "win64" ]]; then
    CMAKE_LLVM_TOOLS="-DCMAKE_AR=$(command -v llvm-ar) -DCMAKE_RANLIB=$(command -v llvm-ranlib)"
fi

# ── MSVC debug runtime copies (win64) ─────────────────────────────────────────
# C++ code compiled against the MSVC STL records its runtime in every object
# (/FAILIFMISMATCH: RuntimeLibrary=MD_DynamicRelease, _ITERATOR_DEBUG_LEVEL=0);
# link.exe refuses to mix it with code built for the debug runtime (/MDd:
# MD_DynamicDebug, level 2 — every MSVC Debug build) — LNK2038. So each C++
# dependency (x265, libvpl) builds its library a second time for the debug
# runtime into lib/debug/ under the same name; FindCustomFFmpeg links that
# copy into targets using /MDd. Same sources and optimisation (-O3, NDEBUG),
# only the runtime differs: -D_DEBUG -D_DLL -D_MT + msvcrtd (= libvpl's own
# "RelWithDebRT" mode). C dependencies do not reference the STL and serve both.
# CMP0091 NEW: the projects' cmake_minimum_required predates CMake 3.15, which
# would ignore CMAKE_MSVC_RUNTIME_LIBRARY.
MSVC_DEBUG_LIBDIR="$DEPS_PREFIX/lib/debug"
CMAKE_MSVC_DEBUG_RUNTIME="-DCMAKE_POLICY_DEFAULT_CMP0091=NEW -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDebugDLL"

# check_msvc_runtime <lib> <RuntimeLibrary> <_ITERATOR_DEBUG_LEVEL> — fail unless
# the archive's STL mismatch records name exactly this runtime
check_msvc_runtime() {
    local expect found
    expect=$(printf 'RuntimeLibrary=%s\n_ITERATOR_DEBUG_LEVEL=%s\n' "$2" "$3" | LC_ALL=C sort)
    found=$(grep -aoE 'RuntimeLibrary=[A-Za-z_]+|_ITERATOR_DEBUG_LEVEL=[0-9]' "$1" | LC_ALL=C sort -u)
    if [[ "$found" != "$expect" ]]; then
        echo "ERROR: $1: MSVC runtime records [$(echo $found)], expected [$(echo $expect)]" >&2
        exit 1
    fi
    echo "  $(basename "$1"): $(echo $found)"
}

mkdir -p "$DEPS_PREFIX" "$DOWNLOADS"

# WORK_ROOT: source exports + build trees. Physical path (macOS /tmp is a
# symlink to /private/tmp, which some configure scripts trip over).
mkdir -p "${TMPDIR:-/tmp}"
WORK_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"

# dep_src <name> [--fresh] — export sources/<name> to WORK_ROOT/<name>-src and
# print the path (see export_src in build/lib/paths.sh). Builds then never
# write into the submodule (autogen/configure), and source paths baked into
# the objects are relative to a sibling build dir. --fresh re-exports even at
# the same commit — required before applying patches.
dep_src() {
    local dest="$WORK_ROOT/$1-src"
    [[ "${2:-}" == "--fresh" ]] && rm -rf "$dest"
    export_src "$SRC/$1" "$dest" >&2
    echo "$dest"
}

# ── Test programs ─────────────────────────────────────────────────────────────
# Each dep installs its own test programs into DEPS_PREFIX/tests/<dep>/ with a
# manifest (tests.tsv: name, program, args, env — tab separated) that
# tests/deps/run_dep_tests.py runs on the host: Windows .exe files then run on
# real Windows, not in the Linux build container. Placeholders in args/env:
# {data} = test data root (optional sets: skipped without it), {tmp} = scratch,
# {dir} = the test's own directory (tests/<dep>/).
# Program names are given without .exe; the runner adds it on Windows.
EXE_SUFFIX=""
[[ "$TARGET_OS" == "win64" ]] && EXE_SUFFIX=".exe"

# tests_reset <dep> — start an empty test dir + manifest for <dep>
tests_reset() {
    rm -rf "$DEPS_PREFIX/tests/$1"
    mkdir -p "$DEPS_PREFIX/tests/$1"
    : > "$DEPS_PREFIX/tests/$1/tests.tsv"
}

# tests_add_program <dep> <built-program>... — copy test executables (path
# without .exe; the suffix is added for Windows)
tests_add_program() {
    local dep="$1" p
    shift
    for p in "$@"; do
        install -m 755 "$p$EXE_SUFFIX" "$DEPS_PREFIX/tests/$dep/"
    done
}

# tests_add <dep> <name> <program> [args] [env K=V;K=V] [kind] [opts]
#   kind: plain (exit code decides, default) | gtest (googletest binary: run
#   sharded, failures caused by missing test data count as skipped)
#   opts (gtest, ';'-separated):
#     shard_mem_gb=<N>                parallel shards limited to available RAM / N
#     serial=<pattern:pattern>        memory-heavy tests: run one process at a
#                                     time after the parallel shards
#     needs_mem_gb.<N>=<pattern:...>  serial, and run only when >= N GB RAM are
#                                     available right before the test; skipped
#                                     otherwise (N = measured peak + margin)
#     exclude=<pattern:pattern>       never run (only for tests that fail in
#                                     the official upstream build too)
#     missing_data=<text|text>        more failure-message texts that mean "test
#                                     data missing" (skipped when run without data)
tests_add() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "${4:-}" "${5:-}" "${6:-plain}" "${7:-}" \
        >> "$DEPS_PREFIX/tests/$1/tests.tsv"
}

# scrub_build_paths <file>... — rewrite build-machine roots in generated files
# that get compiled in (e.g. libvpx's vpx_config.c holds the configure command
# line). Same fixed names as the debug-info map; most specific root first.
scrub_build_paths() {
    local f
    for f in "$@"; do
        replace_paths "$f" "${DEPS_PREFIX}=/deps" "${WORK_ROOT}=/tmp" "${TMPDIR:-/tmp}=/tmp" "${REPO_ROOT}=/src"
    done
}

# dep_build_dir <name> — fresh, empty build dir next to the source exports; cd into it
dep_build_dir() {
    local dir="$WORK_ROOT/$1-build"
    rm -rf "$dir" && mkdir -p "$dir" && cd "$dir"
}

export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$DEPS_PREFIX/lib/pkgconfig"

autotools_cross_flags() {
    if [[ "$TARGET_OS" == "win64" ]]; then
        echo "--host=x86_64-w64-mingw32 --prefix=$DEPS_PREFIX"
    else
        echo "--prefix=$DEPS_PREFIX --with-pic"
    fi
}

# already_built <marker-file-relative-to-DEPS_PREFIX>...
# Returns 0 (true) if any marker exists — dep was built in a previous run.
# Prefer the .pc file: it is installed last and its name does not depend on the
# platform (libtool names win64 static libs ogg.lib, not libogg.a).
# Example: already_built lib/pkgconfig/ogg.pc
already_built() {
    local marker
    for marker in "$@"; do
        [[ -f "$DEPS_PREFIX/$marker" ]] && return 0
    done
    return 1
}

# versions_var <NAME> — value of set(NAME "...") in versions.cmake
versions_var() {
    sed -nE "s/^set\\($1[[:space:]]+\"([^\"]+)\"\\).*/\\1/p" "$REPO_ROOT/versions.cmake" | head -n1
}

# x265_src — fresh export of the x265 submodule plus x265Version.txt; prints the path.
# x265's cmake/Version.cmake takes X265_LATEST_TAG from git describe (a -D value
# is overwritten).  The shallow submodule clone has no tags → empty version →
# x265.pc is not installed (FFmpeg finds x265 only via pkg-config) and the
# Windows .rc version parsing crashes CMake.  Without .git, Version.cmake reads
# x265Version.txt instead — the supported path for release tarballs.
x265_src() {
    local dest tag sha
    dest=$(dep_src x265 --fresh)
    # Exact tag on HEAD when the checkout has tags, else the pin from versions.cmake
    tag=$(git -C "$SRC/x265" describe --tags --exact-match 2>/dev/null) \
        || tag=$(versions_var X265_VERSION)
    [[ -n "$tag" ]] || { echo "ERROR: x265 version unknown (X265_VERSION in versions.cmake)" >&2; exit 1; }
    sha=$(git -C "$SRC/x265" rev-parse HEAD)
    printf 'releasetag: %s\nreleasetagdistance: 0\nrepositorychangeset: %s\n' \
        "$tag" "$sha" > "$dest/x265Version.txt"
    echo "$dest"
}

# apply_patches <dir> <name> — apply patches/<name>/*.patch to an exported tree.
# The ceiling stops git from discovering an enclosing repository (WORK_ROOT can
# sit inside this checkout): inside one, git apply resolves paths from that
# repo's top and silently skips files outside the current directory.
apply_patches() {
    local p
    for p in "$REPO_ROOT"/patches/"$2"/*.patch; do
        [[ -f "$p" ]] || continue
        GIT_CEILING_DIRECTORIES="$(dirname "$1")" git -C "$1" apply "$p"
    done
}

# check_sha256 <expected-hex> <file>
# Portable SHA-256 verification: sha256sum (Linux/Alpine) or shasum -a 256 (macOS)
check_sha256() {
    local expected="$1" file="$2"
    if command -v sha256sum &>/dev/null; then
        echo "${expected}  ${file}" | sha256sum -c -
    else
        echo "${expected}  ${file}" | shasum -a 256 -c -
    fi
}
