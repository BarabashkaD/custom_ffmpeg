#!/usr/bin/env bash
# dav1d — AV1 decoder (meson). One script for all platforms: only the toolchain
# setup differs (win64 cross file vs. native compiler from the environment).
set -euo pipefail
source "$(dirname "$0")/common.sh"

if already_built lib/pkgconfig/dav1d.pc; then
    echo "=== dav1d: already built, skipping ==="
    exit 0
fi

echo "=== dav1d (${TARGET_OS}) ==="

# checkasm, dav1d's asm test framework, is a separate project that meson
# would clone at configure time (subprojects/checkasm.wrap). It comes from the
# sources/checkasm submodule instead (same tag as the wrap): no network access
# during the build, and the pin is part of this repository.
LOCAL_SRC=$(dep_src dav1d --fresh)
export_src "$SRC/checkasm" "$LOCAL_SRC/subprojects/checkasm" >&2
# A dav1d update that moves the wrap must move the submodule too (compared by
# version: a shallow submodule checkout has no tags)
wrap_rev=$(sed -n 's/^revision *= *//p' "$LOCAL_SRC/subprojects/checkasm.wrap")
checkasm_ver=$(sed -nE "s/^[[:space:]]*version:[[:space:]]*'([^']+)'.*/\\1/p" \
    "$LOCAL_SRC/subprojects/checkasm/meson.build" | head -n1)
if [[ "$wrap_rev" != "v$checkasm_ver" ]]; then
    echo "ERROR: sources/checkasm is $checkasm_ver, dav1d's checkasm.wrap wants $wrap_rev" >&2
    exit 1
fi
dep_build_dir dav1d
BUILD_TMP="$PWD"

# meson_list <word>... — a meson array literal of the given words
meson_list() {
    local out="" w
    for w in "$@"; do out+="${out:+, }'$w'"; done
    echo "[$out]"
}

MESON_ENV=()
MESON_CROSS=()
if [[ "$TARGET_OS" == "win64" ]]; then
    # clang in MSVC ABI mode with lld-link (meson: c_ld = lld). The target
    # belongs to the compiler command: meson does not pass c_args when linking
    # and detects the linker style (lld-link) from it. Version resource of the
    # dav1d CLI: llvm-windres needs the PE target and the SDK headers
    # (<windows.h>), like FFmpeg's --windres.
    # shellcheck disable=SC2086
    cat > cross.ini <<EOF
[binaries]
c = $(meson_list clang "--target=${TARGET_TRIPLE}")
c_ld = 'lld'
ar = 'llvm-ar'
strip = 'llvm-strip'
nasm = 'nasm'
windres = $(meson_list llvm-windres --target=pe-x86-64 "-I${REPO_ROOT}/compat/include" \
    "-I${MSVC_INCLUDE}" "-I${WINSDK_INC_UCRT}" "-I${WINSDK_INC_UM}" "-I${WINSDK_INC_SHARED}")
pkg-config = 'pkg-config'

[built-in options]
c_args = $(meson_list ${TARGET_CFLAGS} ${OPT_FLAGS})
c_link_args = $(meson_list ${LDFLAGS})

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
    MESON_CROSS=(--cross-file "$PWD/cross.ini")
else
    MESON_ENV=(CC=clang "CFLAGS=${TARGET_CFLAGS} ${OPT_FLAGS}" "LDFLAGS=${LDFLAGS}")
fi

# Static + PIC library; tools (dav1d CLI) and tests (checkasm, header tests,
# fuzzer regression binaries, seek_stress) are built too. The test data suite
# (dav1d-test-data) is not configured here: run_dep_tests.py evaluates its
# meson test definitions against the installed programs on the target host.
# xxhash muxer off: it is auto-enabled by a system xxhash.h (build-machine
# dependent).
# trim_dsp=false: a release build otherwise drops the C versions of functions
# that always have asm on the target (SSE2 / NEON baseline) — checkasm then has
# no reference and exits 0 without testing anything. Upstream CI tests with
# trim_dsp=false as well; the asm is still selected at run time, the C code is
# only a fallback (and lets the tests run with --cpumask 0).
env "${MESON_ENV[@]+"${MESON_ENV[@]}"}" meson setup "$LOCAL_SRC" . \
    "${MESON_CROSS[@]+"${MESON_CROSS[@]}"}" \
    --prefix="$DEPS_PREFIX" \
    --libdir=lib \
    --buildtype=release \
    --default-library=static \
    -Db_staticpic=true \
    --wrap-mode=nodownload \
    --force-fallback-for=checkasm \
    -Denable_tools=true \
    -Denable_tests=true \
    -Denable_seek_stress=true \
    -Denable_examples=false \
    -Denable_docs=false \
    -Dtestdata_tests=false \
    -Dtrim_dsp=false \
    -Dxxhash_muxer=disabled
grep -q '^#define TRIM_DSP_FUNCTIONS 0' config.h \
    || { echo "ERROR: dav1d config.h: TRIM_DSP_FUNCTIONS is not 0" >&2; exit 1; }

# checkasm is not built by default
ninja -j"$JOBS"
ninja -j"$JOBS" "tests/checkasm$EXE_SUFFIX"
meson install --no-rebuild

# Tests: checkasm (asm vs C for every DSP function), the API header tests, and
# the programs the test data suite runs besides the dav1d CLI: the fuzzer
# drivers (oss-fuzz regression inputs) and seek_stress.
tests_reset dav1d
tests_add_program dav1d tests/checkasm tests/libfuzzer/dav1d_fuzzer \
    tests/libfuzzer/dav1d_fuzzer_mt tests/seek_stress
tests_add dav1d checkasm checkasm
for t in tests/*.h_test"$EXE_SUFFIX"; do
    t="${t%"$EXE_SUFFIX"}"
    tests_add_program dav1d "$t"
    tests_add dav1d "header-$(basename "${t%_test}")" "$(basename "$t")"
done

if [[ "$TARGET_OS" == "win64" ]]; then
    # MSVC naming: lld-link resolves -ldav1d to dav1d.lib only
    mv -f "$DEPS_PREFIX/lib/libdav1d.a" "$DEPS_PREFIX/lib/dav1d.lib"
fi

rm -rf "$LOCAL_SRC" "$BUILD_TMP"
echo "=== dav1d: done ==="
