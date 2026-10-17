#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/libvpx_tests.sh"

if already_built lib/pkgconfig/vpx.pc; then
    echo "=== libvpx: already built, skipping ==="
    libvpx_tests_refresh
    exit 0
fi

echo "=== libvpx (macOS/ARM64) ==="

# WORK_ROOT is the physical TMPDIR path (/tmp is a symlink on macOS)
SRC_DIR=$(dep_src libvpx)
dep_build_dir vpx

# Let libvpx auto-detect the ARM64 Darwin target.
# ARM64 uses ARM NEON/SVE assembly handled by the C compiler — do not pass --as=nasm.
# shellcheck disable=SC2086
CC="$CC_CMD" CXX="$CXX_CMD" AR="$AR" RANLIB="$RANLIB" \
bash "$SRC_DIR/configure" \
    --prefix="$DEPS_PREFIX" \
    ${LINK_FLAGS} \
    --enable-pic \
    --disable-docs --enable-examples --enable-unit-tests \
    --extra-cflags="${OPT_FLAGS}"
# vpx_codec_build_config() embeds the configure line (absolute paths)
scrub_build_paths vpx_config.c
make -j"$JOBS"
make install

# Utilities vpxenc / vpxdec (built with --enable-examples)
install -d "$DEPS_PREFIX/bin"
install -m 755 "vpxenc$EXE_SUFFIX" "vpxdec$EXE_SUFFIX" "$DEPS_PREFIX/bin/"

# Tests: test_libvpx (googletest) + manifest, see libvpx_tests.sh
libvpx_tests_install
echo "=== libvpx: done ==="
