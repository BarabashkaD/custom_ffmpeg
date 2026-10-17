# Test status

Supported platforms and build configurations, and how far each compiled
repository has been tested on each of them.

Revision: `v1-prep` @ `b4405cf` (2026-10-17), full test level: test data from
`tools/fetch_test_data.sh` (fate-suite, libvpx test vectors, Opus RFC 8251
vectors, dav1d-test-data, SVT-AV1 E2E clips).

| Platform | Test host |
|---|---|
| windows-x64 | Windows 11 x64; built in Docker, tests run natively (FATE: make in WSL, `.exe` on Windows) |
| linux-x64 | Ubuntu 24.04 (WSL2) |
| macos-arm64 | not tested at this revision |

**Legend**

| Badge | Meaning |
|---|---|
| ![all passed][pass] | every test available for the repository was run and passed |
| ![partial][partial] | everything that was run passed; some tests were not run (listed in *Not run*) |
| ![headers][headers] | header-only package, nothing to run on its own; runtime is covered under [Hardware acceleration](#hardware-acceleration) |
| ![not tested][untested] | supported, not tested at this revision |
| — | not built for this platform |

Tests disabled upstream (googletest `DISABLED_`) are not part of the suite and
are not counted.

## Platforms and configurations

| Platform | Toolchain | FFmpeg build types | Profiles | Dependencies |
|---|---|---|---|---|
| windows-x64 | clang + lld-link, MSVC ABI | static, shared (DLL) | minimal, lgpl, full | static; x265 and libvpl also as a debug-runtime (`/MDd`) copy |
| linux-x64 | clang | static, shared (`.so`) | minimal, lgpl, full | static + PIC |
| macos-arm64 | Apple clang | static, shared (`.dylib`) | minimal, lgpl, full | static + PIC |

## FFmpeg

FFmpeg n8.1.3. Tests: FATE with fate-suite samples (includes FFmpeg's
checkasm) and the consumer test (`tests/consumer`: `find_package` → link →
run; Windows: C/C++ × Release/Debug, plus C++ with swapped MSVC runtimes for
lgpl/full; Linux: C/C++).

| Configuration | windows-x64 | linux-x64 | macos-arm64 | Not run |
|---|---|---|---|---|
| static full | ![all passed][pass]<br>FATE 5398/5398, consumer 6/6 | ![all passed][pass]<br>FATE 5402/5402, consumer 2/2 | ![not tested][untested] | |
| static lgpl | ![all passed][pass]<br>FATE 5345/5345, consumer 6/6 | ![all passed][pass]<br>FATE 5349/5349, consumer 2/2 | ![not tested][untested] | |
| static minimal | ![partial][partial]<br>consumer 4/4 | ![partial][partial]<br>consumer 2/2 | ![not tested][untested] | FATE |
| shared full | ![partial][partial]<br>consumer 4/4 | ![partial][partial]<br>consumer 2/2 | ![not tested][untested] | FATE |
| shared lgpl | ![partial][partial]<br>consumer 4/4 | ![partial][partial]<br>consumer 2/2 | ![not tested][untested] | FATE |
| shared minimal | ![partial][partial]<br>consumer 4/4 | ![partial][partial]<br>consumer 2/2 | ![not tested][untested] | FATE |

## Hardware acceleration

Runtime tests on real hardware (lgpl and full). Every feature below is
enabled in the build, and the build fails if configure turns any of them
off.

| Feature | windows-x64 | linux-x64 | macos-arm64 | Not run |
|---|---|---|---|---|
| NVIDIA NVENC / NVDEC / CUDA filters | ![partial][partial]<br>`tests/hw/nvidia_smoke.py` 7/8 | ![not tested][untested] | — | windows: `av1_nvenc` |
| AMD AMF | ![not tested][untested] | ![not tested][untested] | — | |
| Intel QSV (libvpl) | ![not tested][untested] | ![not tested][untested] | — | |
| VAAPI | — | ![not tested][untested] | — | |
| D3D11VA / DXVA2 / D3D12VA | ![not tested][untested] | — | — | |
| Media Foundation encoders | ![not tested][untested] | — | — | |
| V4L2 M2M | — | ![not tested][untested] | — | |
| VideoToolbox / AudioToolbox | — | — | ![not tested][untested] | |

## Dependencies

Each library is tested with its own test programs and command line tools
(`tests/deps/run_dep_tests.py`), not through FFmpeg.

| Repository | Version | windows-x64 | linux-x64 | macos-arm64 | Tests run | Not run |
|---|---|---|---|---|---|---|
| zlib | 1.3.2 | ![partial][partial] | ![partial][partial] | ![not tested][untested] | `zlib_static_example`; minigzip round trip | CMake install / `find_package` / `add_subdirectory` tests; linux: `zlib_static_example64` |
| libogg | 1.3.6 | ![all passed][pass] | ![all passed][pass] | ![not tested][untested] | `test_bitwise`, `test_framing` | |
| libvorbis | 1.3.7 | ![all passed][pass] | ![all passed][pass] | ![not tested][untested] | `test` (write/read), `test_sharedbook` | |
| opus | 1.6.1 | ![all passed][pass] | ![all passed][pass] | ![not tested][untested] | 16 unit and API tests; RFC 8251 vectors (12 × mono/stereo × 5 rates); `opus_demo` round trip | |
| libvpx | 1.17.0 | ![partial][partial] | ![partial][partial] | ![not tested][untested] | `test_libvpx` with test vectors: 12068 passed; `vpxenc`/`vpxdec` VP8/VP9 round trip | `VP9/RealtimeTest.IntegerOverflowLarge/*`; 25 tests skipped at run time; tool and example scripts (`test/*.sh`) |
| x264 | stable @ `b35605a` | ![all passed][pass] | ![all passed][pass] | ![not tested][untested] | `checkasm8`, `checkasm10`; `x264` encode | |
| x265 | 4.2 | ![partial][partial] | ![partial][partial] | ![not tested][untested] | `TestBench` (windows: release and debug runtime); `x265` encode | encode lists in `source/test/` (regression, smoke, rate control, save/load) |
| libwebp | 1.6.0 | ![partial][partial] | ![partial][partial] | ![not tested][untested] | `cwebp`/`dwebp` lossy and lossless round trip | fuzz targets (`tests/fuzzer`) |
| mp3lame | 3.100 | ![partial][partial] | ![partial][partial] | ![not tested][untested] | `lame` wav → mp3 → wav round trip | `make test` (`testcase.wav` reference comparison) |
| SVT-AV1 | 4.2.0 | ![partial][partial] | ![partial][partial] | ![not tested][untested] | `SvtAv1UnitTests` 12072; `SvtAv1ApiTests` 59; `SvtAv1E2ETests` 326 (libaom reference decoder); `SvtAv1EncApp` encode | `SvtAv1ApiTests`: `EncParamEncModeTest`, `EncParamIntraPeridLenTest`, `EncParamHierarchicalLvlTest`, `EncParamQPTest`, `EncParamRateCtrlModeTest`, `EncParamSceneChangeDectTest`, `EncParamTargetBitRateTest`, `EncParamMinQPAllowTest`, `EncParamLevelTest`, `EncParamScreenContentModeTest`, `EncParamEnableAltRefsTest` |
| dav1d | 1.5.4 | ![all passed][pass] | ![all passed][pass] | ![not tested][untested] | checkasm; public header tests; dav1d-test-data 1705/1705 (8, 10, 12 bit, multi, seek stress, oss-fuzz); `dav1d` decode | |
| ffnvcodec | n12.1.14.0 | ![headers][headers] | ![headers][headers] | — | | |
| AMF | 1.5.0 | ![headers][headers] | ![headers][headers] | — | header set and version check | |
| libvpl | 2.17.0 | ![partial][partial] | ![partial][partial] | — | `vpl-tests` 708 passed (windows: release and debug runtime) | windows: 309, linux: 308 tests skipped at run time |
| libdrm | 2.4.134 | — | ![all passed][pass] | — | `hash`, `drmsl`, `drmdevice` | |
| libva | 2.24.1 | — | ![partial][partial] | — | | `vainfo`, `test_va_api` |

### Built for tests only

Not part of the build output; used to build or check the test programs above.

| Repository | Version | windows-x64 | linux-x64 | macos-arm64 | Used by | Not run |
|---|---|---|---|---|---|---|
| checkasm | 1.2.0 | ![partial][partial] | ![partial][partial] | ![not tested][untested] | dav1d checkasm | own tests (`tests/`) |
| libaom | av1-normative @ `3fc443c` | ![partial][partial] | ![partial][partial] | ![not tested][untested] | `SvtAv1E2ETests` reference decoder | own test suite (`test_libaom`) |
| libva-utils | 2.24.0 | — | ![partial][partial] | — | libva tests | `vainfo`, `test_va_api` |

[pass]: https://img.shields.io/badge/tests-all_passed-brightgreen
[partial]: https://img.shields.io/badge/tests-partial-yellow
[headers]: https://img.shields.io/badge/headers-only-blue
[untested]: https://img.shields.io/badge/not_tested-lightgrey
