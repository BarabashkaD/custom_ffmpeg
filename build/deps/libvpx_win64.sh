#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/libvpx_tests.sh"

if already_built lib/pkgconfig/vpx.pc; then
    echo "=== libvpx: already built, skipping ==="
    libvpx_tests_refresh
    exit 0
fi

echo "=== libvpx (windows) ==="

# Source export + build dir on the container's native FS (WORK_ROOT), not the
# slow Windows bind mount; patches apply to the export — the submodule stays clean
LOCAL_SRC=$(dep_src libvpx --fresh)
apply_patches "$LOCAL_SRC" libvpx
dep_build_dir vpx
BUILD_TMP="$PWD"

# Use x86_64-win64-gcc target: sets Win64 COFF NASM format and correct calling
# convention.  CC/AR/RANLIB come from CC_CMD / common.sh (MSVC ABI clang).
# libvpx has no --cross-prefix option; CROSS stays empty, but LD defaults to
# ${CROSS}gcc — point it at clang explicitly (the image has no gcc).
# LDFLAGS (exported from build_ffmpeg.sh) carries -fuse-ld=lld and Windows SDK
# lib paths; libvpx configure has no --extra-ldflags and reads LDFLAGS from env.
# shellcheck disable=SC2086
CROSS= CC="$CC_CMD" CXX="$CXX_CMD" LD="$CC_CMD" AR="$AR" RANLIB="$RANLIB" STRIP=llvm-strip \
LDFLAGS="$LDFLAGS" \
bash "$LOCAL_SRC/configure" \
    --prefix="$DEPS_PREFIX" \
    --target=x86_64-win64-gcc \
    ${LINK_FLAGS} \
    --disable-docs --enable-examples --disable-tools --enable-unit-tests \
    --as=nasm
# vpx_codec_build_config() embeds the configure line (absolute paths)
scrub_build_paths vpx_config.c

# The gcc-style build links its programs (vpxenc, test_libvpx, ...) with -lvpx
# -lvpxrc -lgtest -lm -lpthread, which lld-link in MSVC mode resolves only as
# <name>.lib: name the archives built in this dir that way (links resolve once
# they are built) and add empty m.lib / pthread.lib — Windows has neither (math
# is in the UCRT, libvpx uses Win32 threads)
for lib in vpx vpxrc gtest; do
    ln -sf "lib$lib.a" "$lib.lib"
done
"$AR" rcs m.lib
"$AR" rcs pthread.lib

make -j"$JOBS"
make install

# Utilities vpxenc / vpxdec (built with --enable-examples)
install -d "$DEPS_PREFIX/bin"
install -m 755 "vpxenc$EXE_SUFFIX" "vpxdec$EXE_SUFFIX" "$DEPS_PREFIX/bin/"

# Tests: test_libvpx (googletest) + manifest, see libvpx_tests.sh
libvpx_tests_install

# MSVC naming: clang/lld-link resolve -lvpx to vpx.lib (lib*.a only in MinGW mode)
mv -f "$DEPS_PREFIX/lib/libvpx.a" "$DEPS_PREFIX/lib/vpx.lib"

# vpx.pc lists -lm, which does not exist on Windows (no m.lib) — FFmpeg's link
# probe then fails and configure silently disables the VP8/VP9 encoders
sed -i 's/ -lm$//' "$DEPS_PREFIX/lib/pkgconfig/vpx.pc"

rm -rf "$LOCAL_SRC" "$BUILD_TMP"
echo "=== libvpx: done ==="
