# shellcheck shell=bash
# test_libvpx manifest — sourced by libvpx.sh, libvpx_win64.sh and libvpx_macos.sh
# (not a dependency script itself: build_deps.sh runs only <dep>.sh / <dep>_<os>.sh).
#
# Encoder/decoder tests read the libvpx test vectors from LIBVPX_TEST_DATA_PATH
# — {data}/libvpx when available.
#
# Memory: parallel shards are limited to the available memory, 3 GB per shard
# (shard_mem_gb); the big single tests are kept out of the shards:
#   serial=          1-2 GB tests (fit the shard budget, but a shard already
#                    holds its own working set): one process at a time after
#                    the shards
#   needs_mem_gb.N=  above the shard budget: alone after the shards, only when
#                    >= N GB are available right before the test (measured
#                    peak + margin); reported as "not run" otherwise
#
# Peaks measured with libvpx v1.17.0 on x86_64 (Windows peak working set and
# Linux VmHWM agree within 0.1 GB; same tests with and without vectors —
# the heavy ones use synthetic frames). All other tests stay below 1.2 GB.
#   EncodeAPI.ConfigLargeTargetBitrateVp9   5.2 GB  (12383x8192 VP9 encoder)
#   VP9FrameSizeTestsLarge.ValidSizes       1.9 GB
#   C/CopyFrameTest, C/ExtendBorderTest     1.2 GB  (16383x16383 buffers)
#   VP9/RealtimeTest.IntegerOverflowLarge   ~20 GB  (16384x16384 realtime
#       encode + decode)
# Upstream skips both large-frame tests only in Chromium builds (GTEST_SKIP
# under CHROMIUM: "the allocator is unable to provide the space"); outside
# Chromium IntegerOverflowLarge gets OOM-killed on smaller machines too
# (https://bugs.gentoo.org/867088, open since libvpx 1.12).
libvpx_tests_manifest() {
    : > "$DEPS_PREFIX/tests/libvpx/tests.tsv"
    tests_add libvpx test_libvpx test_libvpx "" "LIBVPX_TEST_DATA_PATH={data}/libvpx" gtest \
        "shard_mem_gb=3;serial=VP9FrameSizeTestsLarge.*:C/CopyFrameTest.*:C/ExtendBorderTest.*;needs_mem_gb.6=EncodeAPI.ConfigLargeTargetBitrateVp9;needs_mem_gb.24=VP9/RealtimeTest.IntegerOverflowLarge/*"
}

# libvpx_tests_install — copy test_libvpx from the build dir and write the manifest
libvpx_tests_install() {
    tests_reset libvpx
    tests_add_program libvpx test_libvpx
    libvpx_tests_manifest
}

# libvpx_tests_refresh — when libvpx is already built, rewrite only the manifest:
# a changed manifest (e.g. new memory limits) reaches existing prebuilt trees
# without a rebuild; a stale one once let a ~20 GB test run in a parallel shard
libvpx_tests_refresh() {
    if [[ -f "$DEPS_PREFIX/tests/libvpx/test_libvpx$EXE_SUFFIX" ]]; then
        libvpx_tests_manifest
        echo "=== libvpx: test manifest refreshed ==="
    fi
}
