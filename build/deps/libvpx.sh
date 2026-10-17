#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/libvpx_tests.sh"

if already_built lib/pkgconfig/vpx.pc; then
    echo "=== libvpx: already built, skipping ==="
    libvpx_tests_refresh
    exit 0
fi

echo "=== libvpx (linux) ==="
SRC_DIR=$(dep_src libvpx)
dep_build_dir vpx

# shellcheck disable=SC2086
CC="$CC_CMD" CXX="$CXX_CMD" AR="$AR" RANLIB="$RANLIB" \
bash "$SRC_DIR/configure" \
    --prefix="$DEPS_PREFIX" \
    --target=x86_64-linux-gcc \
    ${LINK_FLAGS} \
    --enable-pic \
    --disable-docs --enable-examples --enable-unit-tests \
    --as=nasm \
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
