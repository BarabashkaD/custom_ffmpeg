# Build issues found and solved

Every problem met while building FFmpeg and its dependencies for
windows-x64 (clang + lld-link, MSVC ABI, in Docker), linux-x64 and
macos-arm64, with its cause and the fix that is now in the repository.
Rationale for the resulting design is in [architecture.md](architecture.md).

Legend: **W** windows-x64, **L** linux-x64, **M** macos-arm64, **CI** GitHub Actions.

## Toolchain and Windows SDK

| | Problem | Cause | Fix |
|---|---|---|---|
| W | Windows SDK headers/libs not found inside the Linux container (`windows.h`, `ole32.lib`, ...) | SDK uses mixed case (`Windows.h`, `Ole32.Lib`); the container file system is case-sensitive | `compat/include` shims (`#include_next` on the real name) and lowercase symlinks for the 7 libraries FFmpeg links (`compat/create_lib_symlinks.sh`) |
| W | `_mm_*` intrinsics became undefined externals at link time | MSVC's `<emmintrin.h>` was found before clang's | clang resource include dir placed before the MSVC include dir |
| W | `-lfoo` not found although `libfoo.a` exists | lld-link in MSVC mode resolves `-lfoo` only as `foo.lib` | libraries installed as `x264.lib`, `vpx.lib`, `z.lib`, `dav1d.lib`, ... |
| W, CI | MSVC/SDK not found on runners and other machines | hard-coded VS paths; `windows-latest` moved to VS 2026; CMake's vswhere call failed with a version range | SDK root from the registry, MSVC via vswhere (PowerShell on CI), only `10.*` SDK dirs with natural sort (CI picked a `wdf` dir), runner pinned to windows-2022, everything overridable |
| W | Newer MSVC STL rejected by the image's clang; libraries built against a newer MSVC not linkable by older toolsets | STL headers require a recent clang; static libs carry the STL version | default toolset v143 (`MSVC_TOOLSET_RANGE` [14.30,14.50)) from any Visual Studio |
| W, CI | autotools and shell scripts in submodules broken (`autoreconf` on libogg, x264 `configure`) | `core.autocrlf=true` checks submodules out with CRLF | `core.autocrlf false` for submodules and CI, `.gitattributes` (`*.sh`, `patches/**` → LF) |

## Dependencies

| | Dep | Problem | Cause | Fix |
|---|---|---|---|---|
| W | x264 | `configure` emits GNU ld flags (`--dynamicbase`) | x264 targets MinGW | patch `0001-lld-link-msvc-flags.patch` |
| W | x264 | GCC vector cast `(__m128)v4si` rejected | GCC extension unsupported in clang-cl mode | patch `0002-rectangle-msvc-vector-cast.patch` (union cast) |
| W | x264 | no `getopt_long` | MSVC CRT has none | `make HAVE_GETOPT_LONG=0` (builds `extras/getopt.c`) |
| W | x264 | "already built" check compared the superproject gitlink | wrong commit source | reads the submodule's checked-out commit |
| M | x264 | configure failed in CI | macOS `TMPDIR` under `/var/folders` symlink broke relative paths; wrong host mode | physical TMPDIR, correct `--host` |
| all | x265 | no `x265.pc`, wrong version | shallow submodule without tags | build from `git archive` + `x265Version.txt`; `X265_VERSION` in `versions.cmake` |
| W | x265 | MSVC STL requires C++14 | x265 sets `-std=gnu++98` | patch `0001-msvc-stl-cxx14.patch`; first version also applied the flag to C files → C++ only via generator expression |
| W | x265 | resource compiler failed; `strings.h` missing | RC got no include path; MSVC has no `strings.h` | `C_INCLUDE_PATH` for RC; `-DHAVE_STRING_H=1` |
| W | x265 | FFmpeg's link probe failed | missing `advapi32` | `-ladvapi32` in `x265.pc` |
| W | libvpx | VP8/VP9 encoders silently disabled by FFmpeg | `vpx.pc` had `-lm`, no `m.lib` on Windows → probe failed | `-lm` dropped from `vpx.pc`; `FFMPEG_REQUIRED_ENCODERS` check added so this can never pass silently |
| W | libvpx | `float_control_word.asm` not built | clang-msvc lacks the GCC inline-asm path and is not `CONFIG_MSVS` | patch `0001-clang-msvc-float-control-word.patch` |
| W | libvpx | test programs did not link (`-lvpx -lgtest -lvpxrc -lm -lpthread`) | Unix library names | name symlinks and empty `m.lib` / `pthread.lib` in the test build only |
| W | libvpx | `configure` failed in the image | needs `diff` | `diffutils` in the Dockerfile |
| W | libvorbis | `M_PI` undefined | MSVC headers need `_USE_MATH_DEFINES` | `-D_USE_MATH_DEFINES` |
| M | libvorbis | `ld: unknown options: -force_cpusubtype_ALL` (was masked by `make && make install` under `set -e`) | hard-coded for darwin in `configure.ac` | flag removed from the generated Makefiles; `make` and `make install` split so failures stop the build |
| all | opus, libvorbis | submodules left dirty after a build | autogen/configure wrote into the sources | all deps build from `git archive` exports (`dep_src`) |
| W | patches | `git apply` silently skipped files | inside an enclosing repo paths resolve from its top | `GIT_CEILING_DIRECTORIES` |
| W | zlib | no PNG/APNG/EXR on Windows | no system zlib | zlib as a dependency |
| W | SVT-AV1 | MSVC STL error about keyword macros | `definitions.h` redefines `inline`; upstream defines `_ALLOW_KEYWORD_MACROS` only for MSVC, CMake does not treat GNU-driver clang as MSVC | `-D_ALLOW_KEYWORD_MACROS` for C++ |
| W | SVT-AV1 | static library unusable by MSVC `link.exe` | LTO on by default → LLVM bitcode in `.lib` | `SVT_AV1_LTO=OFF` |
| all | SVT-AV1 | build tried to download libaom; output written into the sources | target `all` includes E2E tests (ExternalProject); default output dir `Bin/` | explicit targets, `CMAKE_OUTPUT_DIRECTORY` in the build dir |
| all | SVT-AV1 | 11 `SvtAv1ApiTests` fail | stale expected defaults in `test/api_test/params.h` (expects preset 13 / qp 50, library gives 8 / 35); upstream CI never runs this binary | excluded with the reason in the manifest (`exclude=`) |
| W | dav1d | meson did not find `lld-link`, link flags lost | meson does not pass `c_args` when linking | generated cross file, target inside the compiler entry, `c_ld='lld'`, `llvm-windres` for the CLI resource |
| all | dav1d | checkasm passed while testing nothing | release `trim_dsp` drops the C reference functions | `-Dtrim_dsp=false` (as upstream CI); the script asserts it |
| all | dav1d | configure did a `git clone` | checkasm is a meson wrap | `sources/checkasm` submodule, `--wrap-mode=nodownload` |
| all | dav1d | feature set depended on the build machine | `xxhash_muxer` auto-detected | disabled |
| W | AMF | `vsrc_amf.c` (C) failed to compile | AMF 1.4.36 `DisplayCapture.h`: `extern "C"` without `__cplusplus` guard (configure accepts 1.4.36) | AMF headers 1.5.0 from the release archive (URL + SHA256) |
| W | libvpl | link failed | upstream adds `-Wl,-z,relro,-z,now,-z,noexecstack` for every non-MinGW/non-MSVC compiler | patch `0001-clang-msvc-no-elf-link-flags.patch` |
| W, L | libvpl | undefined symbols in FFmpeg's probe | `vpl.pc` lists system libraries only for MinGW | `-ladvapi32 -lole32` (Windows), `-lstdc++` (Linux) |
| L | libvpl | install path compiled into `libvpl.a` (caught by `check_no_local_paths`) | default `MFX_MODULES_DIR` | set explicitly to the system module dir |
| W | libvpl | CMake ran test executables in the container after linking | gtest discovery at build time | `CMAKE_GTEST_DISCOVER_TESTS_DISCOVERY_MODE=PRE_TEST` |
| W | ffnvcodec | MSBuild `FTK1011` in the consumer test | build dir path > 260 characters | short build dir (host limitation) |
| L | libva | only a shared library was built | `meson.build` hard-codes `shared_library()` | patch `0001-meson-honor-default-library.patch` (`library()`, static + PIC) |
| L | libva | build prefix compiled in as the driver search path | default `driverdir` is relative to the prefix | `driverdir` = the distributions' `dri` dirs (`/usr/lib/<triple>/dri:/usr/lib64/dri:/usr/lib/dri`); the script fails if a `.so` gets installed |
| L | libdrm | data path (`amdgpu.ids`) compiled into the library | vendor libraries enabled by default | core library only, udev off |
| L | libva | no tests or tools in libva itself | they live in libva-utils | libva-utils as a test-only submodule: `vainfo` and `test_va_api` |
| all | libaom (SVT-AV1 E2E) | release tags do not work as the reference decoder | SVT-AV1 compiles against its own copy of `aom/inspection.h`, which matches only the `av1-normative` branch | branch commit pinned as a submodule; built by our script and given to SVT-AV1 as the imported target `aom` (`CMAKE_PROJECT_INCLUDE`), so its ExternalProject download never runs |
| W | libaom | configure: "AOM requires support for C flag: -std=c99" | the check links `-lm`; lld-link has no `m.lib` | empty `m.lib` stub (as for libvpx tests) |
| W | SVT-AV1 | `SvtAv1E2ETests` link failed on `pthread.lib` / `m.lib` | the E2E `CMakeLists` tests `if(MSVC)`, unit/API tests test `if(UNIX)` | stubs via `INTERFACE_LINK_DIRECTORIES` of the imported target (E2E link only) |
| W | x265, libvpl | debug-runtime check never matched | the STL records `MDd_DynamicDebug`, not `MD_DynamicDebug` | expected value fixed in `check_msvc_runtime` |
| W | libvpl | debug-runtime tests did not find their stub runtime | with `_DEBUG` the tests expect `libvplstubrt64d.dll` | `CMAKE_RELEASE_POSTFIX=d` in the debug tree; debug tests in `tests/libvpl/debug` |

## FFmpeg

| | Problem | Cause | Fix |
|---|---|---|---|
| all | build broke on FFmpeg 8.0 | `postproc` removed upstream | removed from profiles and FindCustomFFmpeg |
| all | encoders silently missing | configure drops a component when its link probe fails | `FFMPEG_REQUIRED*` per profile, checked in `config.h` / `config_components.h` |
| all | features differed between machines | autodetection | `--disable-autodetect` + explicit per-OS feature lists |
| all | `-lstdc++` etc. missing in static link probes | pkg-config without `--static` omits `Libs.private` | `--pkg-config-flags=--static` |
| all | build-machine paths in outputs (2115 strings in `libavcodec.a` natively) | debug info / `__FILE__`, `avutil_configuration()`, `vpx_codec_build_config()`, `.pc` prefixes, `.la` files | `-ffile-prefix-map`, scrubbed `config.h` / `vpx_config.c`, `${pcfiledir}` in `.pc`, `.la` removed, `check_no_local_paths` fails the build |
| all | wrong version string (`8.0.git`) | export has no `.git` | `VERSION` file in the export |
| W | very slow build (CI: configure 2:13, make 39 min) | compiling on the Windows bind mount | build on the container file system (`/build` volume), sources via `git archive` |
| W shared | DLL version resources failed | `llvm-windres` without target/SDK includes | `--target=pe-x86-64` + SDK include dirs |
| W shared | `.def` generation produced garbage | an exported `AR` inherited make's quiet-mode `@printf` override | `AR`/`NM` written into `SLIB_CREATE_DEF_CMD` |
| W shared | consumers did not find import libraries | FFmpeg puts them next to the DLLs | moved from `bin/` to `lib/` |
| L shared | `.so` did not find sibling libraries | no RUNPATH | `RUNPATH=$ORIGIN` (escaped through configure eval, make and shell) |
| M shared | absolute build paths in dylibs | default install names | `install_name` → `@rpath/` |
| all | public `hwcontext_amf.h` / `hwcontext_qsv.h` did not compile for consumers | they include AMF / libvpl headers not in the artifact | `include/AMF`, `include/vpl` shipped; FindCustomFFmpeg adds `include/vpl` |
| L | same for `hwcontext_vaapi.h` | it includes `<va/va.h>` | `include/va` shipped |
| L | required-component check could not express `vaapi_drm` | it is a `HAVE_` feature, not a component | the check also accepts `HAVE_<NAME>` |

## Consumers

| | Problem | Cause | Fix |
|---|---|---|---|
| W | static `full`/`lgpl` + MSVC C++ Debug: `LNK2038` (`_ITERATOR_DEBUG_LEVEL`, `RuntimeLibrary`) | x265 and the libvpl dispatcher are C++ built against the release CRT/STL | see [MSVC Debug](#msvc-debug) |
| W | `LNK4098` (`msvcrt.lib` conflicts) in every `/MDd` link, C included | CMake-built C deps (zlib, libwebp, SVT-AV1) carry `/DEFAULTLIB:msvcrt.lib` | `/NODEFAULTLIB:msvcrt.lib` for `/MDd` targets (FindCustomFFmpeg) |
| all | static consumers missing system libraries | hand-written lists drift | FindCustomFFmpeg reads `Libs:` / `Requires(.private):` from the `.pc` files |
| all | a GPL part could slip into an LGPL build | no check | `FFMPEG_EXPECTED_LICENSE` at build time + `avutil_license()` in the consumer test |

## Tests

| | Problem | Cause | Fix |
|---|---|---|---|
| W, L | test runs killed / host out of memory | libvpx large-frame tests (`IntegerOverflowLarge` ~20 GB; fails upstream on smaller machines, gentoo #867088) and one process per CPU | gtest sharded by available RAM (`shard_mem_gb`), heavy tests serial, `needs_mem_gb.N=` skips; `--jobs`, `build.ps1 -Jobs` also for tests |
| W, L | ~9140 false failures of `test_libvpx` without test data | missing input file followed by md5 assertions not recognised as missing data | a gtest case is SKIP when any of its failures has a missing-data marker (no `--data` only) |
| W | FATE for the Windows build | FATE is make + shell; no wine allowed | make in WSL, every `.exe` runs natively through WSL interop (`run_fate.sh --windows`) |
| W, L | `test_libvpx` OOM-killed (7.4 GB RSS in a 7.8 GB WSL VM) although the manifest had memory options | the installed `tests.tsv` predated the options and was never rewritten: the dependency counted as built | test manifest refreshed on every libvpx script run (`build/deps/libvpx_tests.sh`) |
| W, L | a memory-gated test could start after free memory had dropped | `needs_mem_gb` was checked once at the start | checked right before each such test; gates set from measured peaks (`ConfigLargeTargetBitrateVp9` 5.2 GB → 6) |
| W, L | inflated pass counts (libvpx +1037, SVT-AV1 unit +4985) | gtest lists `DISABLED_` tests in the XML as `notrun`; they were counted as passed | reported separately as "disabled upstream" |
| W, L | SVT-AV1 E2E tests without data reported as failures | the death tests' reports do not contain the child's "file not found" message | `missing_data=` option: extra missing-data markers per manifest entry |
| M, CI | `SvtAv1UnitTests` `NEON/SADTestSubSample16bit.SADTestSubSample16bit/1` failed on macOS arm64 (passes when run filtered) | test bug in v4.2.0 `test/SadTest.cc`: `SADTestBase16bit::prepare_data()` zeroes only `MAX_SB_SIZE` (128) of the `MAX_BLOCK_SIZE` (16384) `ref_` samples for `SRC_MAX`, so the result depends on heap contents (upstream issue #2384) | upstream fix 11032898 (MR !2762, after v4.2.0) as patch `patches/svtav1/0001-sadtest-init-ref-src-max.patch`, applied on all platforms |
| L, CI | `SvtAv1UnitTests` `AVX512_ForwardTransformTest.av1_frwd_txfm_kernels` failed on a runner with AVX-512 (AVX-512 tests are filtered out on CPUs without it — never run before) | test bug in v4.2.0 `test/ForwardtransformTests.cc`: `memset` with an element count zeroes ¼ of the `int32_t` buffers that are then compared whole — heap-dependent | upstream fix c9c5940f (MR !2673, after v4.2.0) as `patches/svtav1/0002-forwardtransformtest-fill-n.patch`; `run_dep_tests.py` now prints the CPU's AVX-512 flags and the failure messages |
| L, CI | `SvtAv1ApiTests` `OnTheFlyRejectTest.*` failed now and then by its 15 s watchdog (once on an AVX-512 runner, once on an AMD EPYC without AVX-512); reproducible on any machine with 4 test copies pinned to one CPU (~1 % of runs), all three tests of the suite | real library deadlock in v4.2.0, still on upstream master: `pic_manager_process.c` posts the started picture to rate control and only then reads its parent PCS (`released_pics`, `decode_order`); in low delay the single PPCS can already be reused for the next frame, a reference is never released and picture decision blocks on `ref_buffer_available_semaphore` (caught under gdb) | patch `patches/svtav1/0003-picture-manager-no-ppcs-read-after-post.patch` marks the released references before the post; 0 failures in 10800 stressed runs (13 of 3600 before) |
| W | libwebp CLI round trip: "Cannot read input picture file 'in.ppm'" | `cwebp` on Windows reads its input through WIC (falling back to WebP only); WIC has no PPM codec — upstream behaviour | the test feeds a BMP on Windows, PPM elsewhere |
| L | `vainfo` / `test_va_api` fail on machines without a GPU render node (CI, WSL) | no access to `/dev/dri` | exit code 77 means SKIP in `run_dep_tests.py` |
| W | Windows FATE wrote nothing (`Permission denied`), 0 tests | Docker records root and mode 755 in the files' NTFS metadata; FATE in WSL runs as the user, and WSL's drive mount without `metadata` ignores `chmod` | `chmod -R a+rwX` of the exported tree inside the container |
| W | Windows FATE: `make` included `/build//mnt/.../src/ffmpeg/ffmpeg/Makefile` | `run_fate.sh` expected an absolute `SRC_PATH`, but configure records `SRC_PATH=src` (symlink); every "src" substring was replaced | only the top `Makefile`'s `include` is rewritten (to `src/Makefile`) |
| W | Windows FATE: 7 API test programs failed to compile in WSL | `tests/api/*` are not part of `make build`; WSL has no compiler/SDK | built in the container through a helper target on `$(APITESTPROGS)` |
| W | Windows FATE: 16 tests with `movie=` / `amovie=` failed ("Failed to avformat_open_input 'D'") | `movie=D:/…` — the filtergraph parser ends the file name at `:` | samples passed relative to the build tree |
| W | Windows FATE: `fate-source` failed | the exported sources sit inside the project repository, so `git grep` checked that repository | `GIT_CEILING_DIRECTORIES` at the export root |

## CI

| Problem | Cause | Fix |
|---|---|---|
| Windows Docker builds impossible on hosted runners | Windows runners run Windows containers | Docker daemon inside WSL2 on the runner |
| GHCR image tag rejected | uppercase repository owner | lowercase computed in a step (`lower()` does not exist in expressions) |
| env vars missing inside WSL | not forwarded | `WSLENV` |
| executables not runnable after `download-artifact` | exec bit lost | restored before tests |
| `-DPROFILE=$p` passed literally | PowerShell quoting | quoted argument |
| Node 20 deprecation | old action versions | actions on Node 24 |
| stale steps after the test rework (`checkasm8`, `test_x264`) | replaced by `run_dep_tests.py` | removed |
| builder image push to ghcr.io: `403 permission_denied` | the container package still belonged to the repository it was first pushed from | package deleted; the workflow recreates it for this repository |
| macOS svtav1: `CMAKE_PLATFORM[@]: unbound variable` | macOS bash 3.2 treats `"${a[@]}"` of an empty array as unset under `set -u` | `${a[@]+"${a[@]}"}` (as elsewhere in the scripts) |
| macOS x265: `install: test/TestBench: No such file or directory` | x265 builds TestBench only with `ENABLE_ASSEMBLY`, which the script turned off on arm64 | assembly on (upstream's default on AArch64; also NEON speed) |
| `macos-14` runner deprecated | — | `xcode-27` (macOS 27, Apple silicon) |
| macOS lgpl/full: "metal requested but not found" (Xcode 27 runner) | since Xcode 26 the Metal compiler is a separate component | CI installs it (`xcodebuild -downloadComponent MetalToolchain`); `build_macos.sh` stops early with that command when it is missing |
| macOS shared: build ended silently after `make install` | `otool -L … | grep` of a dylib without FFmpeg dependencies (libavutil) matched nothing; under `pipefail` grep's status 1 ended the script | `|| true` on that grep |
| macOS shared: `LEAK` of the build path in `bin/ffmpeg`, `bin/ffprobe` | only the dylibs were made `@rpath`-relative; the programs still loaded them by absolute path | the programs relinked too (`@rpath/…` + rpath `@executable_path/../lib`); absolute rpaths into the output dropped |
| Linux shared: `bin/ffmpeg` did not start without `LD_LIBRARY_PATH`; a joint `-rpath $ORIGIN:$ORIGIN/../lib` gave `$$ORIGIN` in the programs | the programs carried `RUNPATH=$ORIGIN` (the `.so` are in `../lib`); make expands the library link line twice, the program link line once | `--extra-ldsoflags` (`$ORIGIN`) and `--extra-ldexeflags` (`$ORIGIN/../lib`) with their own escaping |
| `opus.pc` and `opus_get_version_string()` said "unknown" | opus takes its version from git (`update_version`); the export has no `.git` | `package_version` written from `OPUS_VERSION` (`AUTO_UPDATE=no`) |
| macOS: `ld: warning: object file … was built for newer macOS version (27.0) than being linked (12.0)` | FFmpeg's triple said `macos12`, the deps followed the runner (27) | `MACOS_MIN_VERSION` for the triple and `MACOSX_DEPLOYMENT_TARGET` of every build; minos checked |
| Windows deps jobs failed in setup-wsl: `wsl.exe --update` → `Forbidden (403)` | windows-2022 has only WSL1, so setup-wsl updates WSL; the update queries the GitHub API unauthenticated (rate limit per shared runner IP, likely) and retries without delay | `windows-2025` (WSL2 preinstalled, no update) |
| Windows jobs on `windows-2025` failed at once: "vswhere: no Visual Studio with the x64 C++ toolset found" | the `windows-2025` label moved to the image with Visual Studio 2026 (only its MSVC 14.44 component, no VS 2022) | MSVC found by toolset version in every Visual Studio install (VS 2026's v143 component); consumer test picks the Visual Studio that has v143 (`-T v143`), CMake 4.2 installed on the runner for the VS 2026 generator |
| Windows staged SDK/MSVC: "No working C compiler" — `lld-link: could not open 'kernel32.lib'`, then `'DriverSpecs.h' file not found` | the SDK names files in mixed case (`kernel32.Lib`) and its headers include each other in other spellings; NTFS and WSL's 9p view ignore case, ext4 does not (WSL's kernel has no casefold) | `windows_unstage.sh`: lower-case symlinks for every mixed-case file/directory plus a symlink for every spelling an `#include` of the SDK/MSVC headers asks for (as xwin and msvc-wine do) |
| Release draft v1.0.0-rc.1: FFmpeg version `1041abd` instead of `n8.1.3` (title, `build-info.txt`, `ffmpeg -version`, `av_version_info()`) | CI clones the submodules shallow without tags; FFmpeg's `version.sh` falls back from `git describe --tags` to the commit hash | CI fetches the release tag (`.github/scripts/ffmpeg_tag.sh`); `build_ffmpeg.sh` stops when the version string of a release is not `n<RELEASE>` |
| Linux shared lgpl in CI, once: `cannot create fftools/resources/graph.html.gz: Directory nonexistent` | FFmpeg race (n8.1.3, still on master): the `%.html.gz` / `%.css.min` rules of `fftools/resources` have no order-only dependency on their directory; in a parallel out-of-tree build GZIP can run before any object there creates it | `build_ffmpeg.sh` creates `fftools/resources` before `make` |
| macOS FFmpeg jobs stopped in the dependency stage: `awk: can't open file …/include/ffnvcodec/nvEncodeAPI.h` | `install_licenses` skipped the NVIDIA/AMD/Intel headers only for `TARGET_OS=darwin` (the generated .env); `build_macos.sh` exports `macos` | both names accepted |
| Windows FFmpeg lgpl/full in CI: "no license texts for zlib" although the deps had installed them | the staged deps tree (`windows_stage.ps1 -Deps`) carried only `include` and `lib`, not `share/licenses` | `share/licenses` staged too |
| `compat/create_lib_symlinks.sh` ended the build silently on the staged SDK | `find … \| head -1` with two matches (file + lower-case alias): head closed the pipe, find's SIGPIPE failed the script under `pipefail` | `find … -print -quit` |
| Windows FFmpeg full/lgpl took 40+ min in CI (Linux: ~5.5 min) | the container read the SDK/MSVC headers and libraries, `compat/include` (first `-isystem`: a lookup for every `#include`) and the deps tree through WSL's 9p drive mounts | staged onto WSL's ext4 (`windows_stage.ps1`) and mounted from there |
| ~2.5 min setup per Windows job (all 18 submodules, WSL, Docker), 14 deps jobs | every job checked out every submodule; small deps had a job each | only the needed submodules; small deps grouped (7 jobs) |
| weekly runner image update would rebuild every Windows cache | the key held the runner image version | key from the MSVC/SDK versions, a hash of key MSVC/SDK files and the builder image package list |

## Local environment (not code issues)

| Problem | Fix |
|---|---|
| Submodule `.git` file got an absolute `gitdir:` after a failed `git submodule update` retry; WSL could not open it | rewrote to the relative path |
| Test runs killed by the agent host for low memory | heavy jobs serialized (at most two at a time), `--jobs 1–2` |
| A job waited ~2 h for a free build slot while newer jobs kept taking it | FIFO queue for the slots |
| A script edited while bash was running it failed with `syntax error` at the end | bash reads scripts incrementally — edit only when no run uses them |
| A Windows path with backslashes passed through `wsl -- wslpath` came out as `/`; `rsync` started copying the WSL root | forward slashes, guard in the script |
| `git submodule add --depth 1 -b <branch>` checked out the default branch | clone the branch first, then add the existing repository |
| No real VAAPI test possible in WSL | the vgem/d3d12 device fails `vaInitialize` even with the distribution's own libva — environment limit; FFmpeg fails cleanly without a VA device |
| SVT-AV1 E2E with data ~20× slower in WSL than on Windows (2.5 h vs 7 min) | clips read from the Windows drive over the WSL file bridge; keep test data on the native file system on Linux |

## MSVC Debug

Static `full` and `lgpl` builds failed to link into MSVC C++ Debug (`/MDd`)
programs with `LNK2038` (142 mismatches): `x265.lib` and `vpl.lib` are the only
C++ libraries, and their objects record `RuntimeLibrary=MD_DynamicRelease` and
`_ITERATOR_DEBUG_LEVEL=0`. Silencing the check (`_ALLOW_*_MISMATCH`) would mix
two STL layouts and two heaps, so the fix builds both libraries a second time
for the debug runtime:

- `.deps/<platform>/lib/debug/x265.lib`, `.../debug/vpl.lib`: same sources and
  `-O3`, only `-D_DEBUG -D_DLL -D_MT` and `msvcrtd` (`MultiThreadedDebugDLL`,
  CMP0091 forced because both projects predate it); `check_msvc_runtime`
  verifies the records of both copies; `already_built` requires both.
- `FindCustomFFmpeg` links the copy matching each target's
  `MSVC_RUNTIME_LIBRARY` (evaluated with `$<GENEX_EVAL:…>` — a genex-valued
  property is otherwise returned unevaluated and picked the release copy), or
  the Debug configuration when the caller has CMP0091 OLD.
- `tests/consumer/run.ps1`: C and C++ × Release and Debug must pass, plus a C++
  tree with swapped runtimes; `LNK2038`/`LNK4098` in the link output fails the
  run (an incremental rerun skips the link and hides warnings — the tests use
  clean build dirs).

The static CRT (`/MT`, `/MTd`) is not supported; FindCustomFFmpeg warns.

## Open issues

| | Issue | Notes |
|---|---|---|
| L | NASM objects in Linux static libraries embed the absolute `TMPDIR` source path | `-ffile-prefix-map` does not apply to nasm; harmless with the default `/tmp/custom_ffmpeg` and in Docker; `check_no_local_paths` fails the build when `TMPDIR` is under `$HOME` (seen with SVT-AV1); likely also x264, libvpx, dav1d |
| all | other dependencies can keep a stale `tests.tsv` after their manifest line changes | only libvpx refreshes its manifest without a rebuild |
| all | `VP9/RealtimeTest.IntegerOverflowLarge` never runs on the test machines | needs ~20 GB (`needs_mem_gb.24`) |
| W, L | AVX-512 code paths tested only by chance | the local test CPU has no AVX-512; CI runners have it only sometimes (the tests filter themselves out without it; `run_dep_tests.py` logs the CPU's flags) |
| all | VAAPI, QSV and AMF not tested on hardware | no Intel/AMD GPU available; NVIDIA tested with `tests/hw/nvidia_smoke.py` |
