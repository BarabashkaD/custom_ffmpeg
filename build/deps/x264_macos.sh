#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if already_built lib/libx264.a; then
    echo "=== x264: already built, skipping ==="
    exit 0
fi

echo "=== x264 (macOS/ARM64) ==="

SRC_DIR=$(dep_src x264)
dep_build_dir x264

# ARM64 assembly uses the system assembler (clang), not NASM
CC="$CC_CMD" \
AR="${AR:-ar}" \
RANLIB="${RANLIB:-ranlib}" \
bash "$SRC_DIR/configure" \
    --prefix="$DEPS_PREFIX" \
    --cross-prefix= \
    ${LINK_FLAGS_X264} \
    --enable-pic \
    --extra-cflags="${OPT_FLAGS}"

make -j"$JOBS"
make -j"$JOBS" checkasm
make install

# Tests: SIMD (checkasm, 8- and 10-bit) — run by tests/deps/run_dep_tests.py;
# the x264 CLI is installed into bin/ by make install
tests_reset x264
tests_add_program x264 checkasm8 checkasm10
tests_add x264 checkasm8 checkasm8
tests_add x264 checkasm10 checkasm10
echo "=== x264: done ==="
