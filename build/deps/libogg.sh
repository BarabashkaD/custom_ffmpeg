#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if already_built lib/pkgconfig/ogg.pc; then
    echo "=== libogg: already built, skipping ==="
    exit 0
fi

echo "=== libogg ==="
SRC_DIR=$(dep_src libogg)
dep_build_dir ogg
bash "$SRC_DIR/autogen.sh"
# shellcheck disable=SC2046
bash "$SRC_DIR/configure" \
    $(autotools_cross_flags) \
    ${LINK_FLAGS} \
    AR="$AR" RANLIB="$RANLIB" \
    CC="$CC_CMD" CXX="$CXX_CMD"
make -j"$JOBS"
make install

# Tests: libogg's self tests (built with the library, run by `make check`)
tests_reset libogg
tests_add_program libogg src/test_bitwise src/test_framing
tests_add libogg bitwise test_bitwise
tests_add libogg framing test_framing
echo "=== libogg: done ==="
