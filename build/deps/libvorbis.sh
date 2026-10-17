#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if already_built lib/pkgconfig/vorbis.pc; then
    echo "=== libvorbis: already built, skipping ==="
    exit 0
fi

echo "=== libvorbis ==="
SRC_DIR=$(dep_src libvorbis)
dep_build_dir vorbis
bash "$SRC_DIR/autogen.sh"
# shellcheck disable=SC2046
bash "$SRC_DIR/configure" \
    $(autotools_cross_flags) \
    ${LINK_FLAGS} \
    --with-ogg="$DEPS_PREFIX" \
    AR="$AR" RANLIB="$RANLIB" \
    CC="$CC_CMD" CXX="$CXX_CMD"
# configure.ac hardcodes -force_cpusubtype_ALL for darwin; Xcode's ld rejects it
# ("unknown options"). Strip it from the generated Makefiles (no-op elsewhere).
find . -name Makefile -exec sed -i.bak 's/-force_cpusubtype_ALL//g' {} +
make -j"$JOBS"
make install

# Tests: encode/decode round trips (test/test) and the codebook self test —
# built here, run on the host (`make check` would also execute them)
# _USE_MATH_DEFINES: the MSVC headers define M_PI (used by test/util.c) only with it
make -C test -j"$JOBS" "test$EXE_SUFFIX" CPPFLAGS=-D_USE_MATH_DEFINES
tests_reset libvorbis
tests_add_program libvorbis test/test lib/test_sharedbook
tests_add libvorbis write_read test
tests_add libvorbis sharedbook test_sharedbook
echo "=== libvorbis: done ==="
