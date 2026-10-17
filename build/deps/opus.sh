#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if already_built lib/pkgconfig/opus.pc; then
    echo "=== opus: already built, skipping ==="
    exit 0
fi

echo "=== opus ==="
SRC_DIR=$(dep_src opus)

# The export has no .git: configure reads the version from package_version
# (otherwise "unknown" in opus.pc and opus_get_version_string()).
# AUTO_UPDATE=no keeps update_version from asking an enclosing repository.
printf 'AUTO_UPDATE=no\nPACKAGE_VERSION="%s"\n' "$(versions_var OPUS_VERSION)" > "$SRC_DIR/package_version"

# autogen.sh downloads the DNN model tarball into the source dir unless it is
# already there (checksum-verified either way): keep a copy in DOWNLOADS so a
# fresh export does not download it again
cp -f "$DOWNLOADS"/opus_data-*.tar.gz "$SRC_DIR/" 2>/dev/null || true
bash "$SRC_DIR/autogen.sh"
cp -f "$SRC_DIR"/opus_data-*.tar.gz "$DOWNLOADS/" 2>/dev/null || true

dep_build_dir opus
# shellcheck disable=SC2046
bash "$SRC_DIR/configure" \
    $(autotools_cross_flags) \
    ${LINK_FLAGS} \
    --disable-docs --enable-extra-programs \
    AR="$AR" RANLIB="$RANLIB" \
    CC="$CC_CMD" CXX="$CXX_CMD"
make -j"$JOBS"
make install

# Utilities: opus_demo (encode/decode raw PCM, also runs the RFC 8251 test
# vectors) and opus_compare
install -d "$DEPS_PREFIX/bin"
install -m 755 "opus_demo$EXE_SUFFIX" "opus_compare$EXE_SUFFIX" "$DEPS_PREFIX/bin/"

# Tests: the unit/API tests `make check` runs (TESTS in Makefile.am)
tests_reset opus
for t in celt/tests/test_unit_cwrs32 celt/tests/test_unit_dft celt/tests/test_unit_mini_kfft \
         celt/tests/test_unit_entropy celt/tests/test_unit_laplace celt/tests/test_unit_mathops \
         celt/tests/test_unit_mdct celt/tests/test_unit_rotation celt/tests/test_unit_types \
         silk/tests/test_unit_LPC_inv_pred_gain tests/test_opus_api tests/test_opus_decode \
         tests/test_opus_encode tests/test_opus_extensions tests/test_opus_padding \
         tests/test_opus_projection; do
    tests_add_program opus "$t"
    tests_add opus "$(basename "$t")" "$(basename "$t")"
done
echo "=== opus: done ==="
