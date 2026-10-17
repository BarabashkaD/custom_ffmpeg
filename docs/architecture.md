# Architecture

Problems met while building and how they were solved: [build-issues.md](build-issues.md).

## Layout and responsibilities

```
docker/Dockerfile        tools only (Alpine, clang/lld 19, nasm, cmake, ninja, meson, autotools) — no build logic
sources/                 git submodules pinned to release tags (list in versions.cmake)
patches/<project>/       patches applied to an exported copy of the sources (by the dep scripts that need them)
compat/                  case-sensitivity shims for the Windows SDK inside a Linux container
profiles/*.cmake         WHAT to build: libraries, configure flags, per-OS features,
                         required components, expected license
cmake/GenerateConfig     profile + platform → generated/<platform>-<type>-<profile>.env (+ .json on Windows)
cmake/FindWindowsSDK     Windows Kits (registry) and MSVC (vswhere) on the host
cmake/FindCustomFFmpeg   consumer side: imported targets from a prebuilt tree
build/build_ffmpeg.sh    configure + build FFmpeg (Docker for Windows, native otherwise)
build/build_linux.sh,
build/build_macos.sh     native entry points: prerequisites, paths, deps, FFmpeg
build/build_deps.sh      runs build/deps/<dep>_<os>.sh or the generic <dep>.sh
build/lib/paths.sh       source export, path mapping, path-leak check
scripts/build.ps1        Windows entry point: image → config → docker run → tests on the host
tests/consumer/          find_package(CustomFFmpeg) → link → run, C and C++
tests/deps/              run_dep_tests.py: each dependency's own test programs + CLI round trips;
                         meson_tests.py: dav1d-test-data's meson test definitions
tests/fate/              run_fate.sh: FATE for native builds and, via WSL, for the Windows build
tests/hw/                manual GPU smoke tests (NVIDIA)
tools/fetch_test_data.sh test data sets (FATE samples, libvpx/Opus vectors, dav1d-test-data, SVT-AV1 E2E clips)
.github/                 CI workflow and cache-key script
```

## Windows target

```
scripts/build.ps1
  ├─ docker build (once)            → custom-ffmpeg-builder
  ├─ cmake -P GenerateConfig        → generated/windows-x64-<type>-<profile>.env/.json
  └─ docker run
       /src          repository (bind mount)
       /artifacts    prebuilt/ (bind mount)            ← only installed results are written here
       /winsdk/kits  Windows Kits root (read-only)
       /winsdk/msvc  MSVC tools dir (read-only)
       /build        Docker volume custom-ffmpeg-build ← sources exports + build trees
     build_ffmpeg.sh
       ├─ deps: build_deps.sh → <dep>_win64.sh / <dep>.sh
       ├─ FFmpeg: git archive → /build/src/ffmpeg, configure + make in /build
       └─ make install → /artifacts/windows-x64/<type>/<profile>
  └─ tests on the host: run_dep_tests.py (PE binaries run natively);
     -Test: all dependency tests + FATE (make in WSL, every .exe natively via WSL interop)
```

Compiler: `clang --target=x86_64-pc-windows-msvc` with `lld-link`, LLVM
`ar/ranlib/nm/strip`, NASM. Include order: compat shims, clang's resource
headers, MSVC, Windows SDK (clang's intrinsics headers must win over MSVC's).

## Design decisions

### Entry points and scripts
| Decision | Reason |
|---|---|
| Docker only for the Windows target | Linux and macOS build natively; a container would be an extra layer there |
| One entry point per target OS (`build_ffmpeg.sh` in Docker, `build_linux.sh`, `build_macos.sh`) | different prerequisites and paths; no Windows SDK logic in the native builds |
| Dependency scripts `build/deps/<dep>_<os>.sh` with fallback to `<dep>.sh` | a clean split per platform instead of if/else inside one script |
| `SRC`, `DOWNLOADS`, `AR`, `RANLIB` taken from the environment with defaults | the same scripts run natively and in the container |
| `already_built` checks the dependency's `.pc` file | libtool names libraries differently on win64 (`ogg.lib`, not `libogg.a`); the `.pc` file is installed last |
| Windows SDK passed as two read-only mounts (`/winsdk/kits`, `/winsdk/msvc`); the SDK version is detected in the container | one directory listing instead of a mount per version |
| Generated config: `.env` (bash, LF) for the container, `.json` for PowerShell | `ConvertFrom-Json` needs no execution-policy exception |
| Docker volume `custom-ffmpeg-build` for `/build` | build trees survive `docker run --rm`, rebuilds stay incremental; reset with `docker volume rm custom-ffmpeg-build` |
| Native builds work in `TMPDIR` (default `/tmp/custom_ffmpeg`) | a checkout on a Windows drive under WSL carries root ownership written by Docker, which blocks writes from WSL |
| `JOBS`, `build.ps1 -Jobs` / `-BuildVolume` | several builds side by side (CI, parallel work) without a shared build tree; `-Jobs` also limits parallel test processes |

### Reproducibility
| Decision | Reason |
|---|---|
| Submodules on release tags (x264: `stable` branch) | builds are reproducible; versions documented in `versions.cmake` |
| Submodules checked out with LF line endings | CRLF in `Makefile.am` breaks autoreconf (libogg); with `core.autocrlf=true` the submodules have to be checked out again |
| `X265_VERSION` in `versions.cmake`, `x265Version.txt` written into the export | a shallow submodule checkout has no tags; x265 needs its version for `x265.pc` |
| `--disable-autodetect` + explicit per-OS features in the profile | the feature set does not depend on the build machine |
| Required components per profile (`FFMPEG_REQUIRED*`), checked in `config.h` / `config_components.h` as `CONFIG_<NAME>` or `HAVE_<NAME>` | configure silently drops components whose probe fails (e.g. libvpx with a stray `-lm`); the build fails instead. Some features (`vaapi_drm`) are `HAVE_` flags, not components |
| Expected license per profile | a GPL part cannot slip into an LGPL build |
| zlib as a dependency | PNG/APNG/EXR on every platform (Windows has no system zlib) |
| TLS from the OS only (Schannel, SecureTransport) | no extra TLS dependency; Linux builds have no https |
| Minimum platforms: Windows 10 + VS 2022, glibc 2.39, macOS 27 (Apple silicon) | current systems only; older baselines (e.g. glibc of RHEL 9 / Ubuntu 22.04) can be added later if needed |

### Privacy and portability
| Decision | Reason |
|---|---|
| `-ffile-prefix-map` of every build root to fixed names (`/src`, `/artifacts`, `/build`, `/deps`, `/tmp`) | no home directory / user name in debug info or `__FILE__` |
| Scrub paths in FFmpeg's `config.h` and libvpx's `vpx_config.c` | both embed the configure command line (`avutil_configuration()`, `vpx_codec_build_config()`); `config.h` keeps its mtime when unchanged |
| Relocatable `.pc` files (`${pcfiledir}`), no libtool `.la` files | outputs can be moved and contain no absolute paths |
| `check_no_local_paths` after every build | fails on the checkout root, `$HOME` or the host name in libraries, headers, `.pc` files, binaries |
| SDK/MSVC from registry/vswhere, overridable (`WINSDK_KITS_ROOT`, `MSVC_BASE_DIR`, `VS_VERSION_RANGE`) | no hard-coded install paths; default VS 2022 because the image's clang must accept the MSVC STL headers and consumers' toolsets must not be older than the headers used |

### Sources and build trees
| Decision | Reason |
|---|---|
| Every dependency builds from a `git archive` export (`dep_src`) | autogen/configure/patches never touch the submodules; reading pack files is fast through a bind mount |
| FFmpeg sources also exported with `git archive`, plus a `VERSION` file | ~1 s instead of ~21 s for copying 10k files; file times are the commit time, so make stays incremental; without `.git` FFmpeg's `version.sh` would report the release string instead of `git-<date>-<hash>` |
| `--pkg-config-flags=--static` for static builds | otherwise configure ignores `Libs.private` (`-lstdc++` for x265 and similar) |
| Windows: build on the container's file system (`/build`) | compiling on the Windows bind mount was much slower (CI: configure 2:13 vs 0:40) |
| Patches applied with `GIT_CEILING_DIRECTORIES` | inside an enclosing repository `git apply` would resolve paths from its top and skip files |
| One build dir per platform/type/profile | variants rebuild incrementally side by side |

### Windows specifics
| Decision | Reason |
|---|---|
| `compat/include` shims (`#include_next` on the real name) and lowercase symlinks for 7 SDK `.lib` files | the SDK uses mixed-case names, the container file system is case-sensitive |
| `x264.lib`, `vpx.lib`, `z.lib` naming | `lld-link` in MSVC mode resolves `-lfoo` only as `foo.lib` |
| x264: `--host=x86_64-w64-mingw32`, `make HAVE_GETOPT_LONG=0` | configure derives `SYS=WINDOWS` from the host triple; the make variable compiles `extras/getopt.c`, a case configure does not cover |
| checkasm and all test programs run on the Windows host | PE binaries do not run in the container (no wine) |
| Empty `m.lib` / `pthread.lib` for libaom and `SvtAv1E2ETests` | their CMake files link `pthread m` for every non-MSVC compiler |
| libvpl debug-runtime copy with `CMAKE_RELEASE_POSTFIX=d`, its tests in `tests/libvpl/debug` | with `_DEBUG` the tests expect `libvplstubrt64d.dll` (upstream's Debug layout); a separate directory keeps the two stub runtimes apart |
| Shared builds need the VC++ Redistributable | `avcodec-*.dll` imports `MSVCP140.dll` (x265 is C++) and `VCRUNTIME140.dll`; everything else is a system DLL |
| x264 patches (`lld-link` flags, vector cast), x265 C++14, libvpx `float_control_word.asm` | x264's configure targets MinGW; the MSVC STL needs C++14; clang-msvc lacks the GCC inline-asm path |
| `vpx.pc` without `-lm`, `x265.pc` with `-ladvapi32` | otherwise FFmpeg's link probes fail and disable the encoders |
| Shared: `llvm-windres --target=pe-x86-64` with SDK includes | DLL version resources |
| Shared: `AR`/`NM` set on `SLIB_CREATE_DEF_CMD` | `makedef` needs them; an exported `AR` would inherit make's quiet-mode `@printf` wrapper |
| Shared: import libraries moved from `bin/` to `lib/` | conventional layout expected by consumers |
| dav1d: meson cross file generated at build time; the target sits in the compiler entry (`['clang','--target=x86_64-pc-windows-msvc']`), `c_ld='lld'` | meson does not pass `c_args` when linking; this way it detects `lld-link` |
| SVT-AV1: `-D_ALLOW_KEYWORD_MACROS` for C++ | `definitions.h` redefines `inline`; upstream adds the define for MSVC only, and CMake does not treat clang's GNU driver as MSVC |
| libvpl: patch limits `-Wl,-z,relro,...` to non-Windows; `vpl.pc` gets `-ladvapi32 -lole32` | `lld-link` rejects ELF linker flags; upstream lists system libraries only for MinGW |
| AMF headers 1.5.0 (configure accepts 1.4.36) | 1.4.36's `DisplayCapture.h` has an unguarded `extern "C"` that breaks the C build of `vsrc_amf.c` |

### macOS specifics
| Decision | Reason |
|---|---|
| libvorbis: `-force_cpusubtype_ALL` removed from the generated Makefiles | `configure.ac` hard-codes it for darwin; the Xcode linker rejects it |
| x265 with its AArch64 assembly | upstream's default on arm64 (NEON, dot product, i8mm; SVE checks fail on Apple clang and are skipped); TestBench exists only with assembly |
| CI on `xcode-27` runners | macOS 27 on Apple silicon, the minimum supported version; GitHub names macOS images by Xcode version |

### Codec dependencies
| Decision | Reason |
|---|---|
| SVT-AV1 for AV1 encoding, dav1d for AV1 decoding (both BSD, also in `lgpl`) | FFmpeg's native `av1` decoder works only with a hwaccel; libaom is far slower, rav1e needs a Rust toolchain |
| SVT-AV1 E2E tests: libaom `av1-normative` as a test-only submodule, handed to SVT-AV1 as the imported target `aom` (`CMAKE_PROJECT_INCLUDE`) | upstream downloads that branch through ExternalProject at build time (unpinned, without our cross flags); libaom releases do not match SVT-AV1's copy of `aom/inspection.h`; only explicit targets are built, so the ExternalProject never runs |
| SVT-AV1 `SVT_AV1_LTO=OFF` | LTO puts LLVM bitcode into the static library, which MSVC `link.exe` consumers cannot read |
| SVT-AV1: one build for library and tests on x86_64 | `BUILD_TESTING` defines `SVT_AV1_UNIT_TEST_BUILD` for the library too; on x86_64 that only changes a self-check (verified against the source by the script); aarch64 builds the shipped library without tests |
| dav1d `trim_dsp=false` | a release build drops the C reference functions and checkasm then exits 0 without testing anything (upstream CI does the same) |
| dav1d's checkasm as a submodule (`sources/checkasm`) | meson would `git clone` it at configure time; pinned and offline instead |
| NVIDIA/AMD: headers only; Intel: the MIT dispatcher | the vendor runtimes come with the GPU driver and are loaded at run time — no link dependency, LGPL-compatible |
| nv-codec-headers 12.1 | FFmpeg 8.1's main supported API line and the first with AV1; newer lines raise the minimum driver for `#ifdef`-gated extras |
| `cuda-llvm`: CUDA filters compiled by clang to PTX | no CUDA SDK, nothing `nonfree` |
| AMF headers from the official release archive (URL + SHA256) | the AMF repository is ~1.4 GB of binaries and samples |
| Linux: VAAPI (libva + libva-drm) and libdrm built static; QSV on Linux through libvpl over VAAPI | the VA driver comes from the system and is loaded at run time; libva's driver search path points at the distribution's `dri` directories, not the build prefix |
| libva: patch `shared_library` → `library` in meson | upstream forces shared libraries; our deps are static + PIC |
| libdrm core library only (no vendor libraries, no udev) | FFmpeg needs only the core; the vendor parts would compile data paths (`amdgpu.ids`) into the library |
| libvpl `MFX_MODULES_DIR` set explicitly on Linux | the default compiles the install path into `libvpl.a` (caught by the path-leak check) |
| Public hwcontext headers' dependencies shipped (`include/AMF`, `include/vpl`, `include/va`) | `hwcontext_amf.h` / `hwcontext_qsv.h` / `hwcontext_vaapi.h` include them; consumers get only the artifact's include dir |

### Tests
| Decision | Reason |
|---|---|
| Each dependency tested with its own test programs and CLI tools, not through FFmpeg | FFmpeg has FATE; library bugs show up where the library's authors test them |
| Test programs + `tests.tsv` manifest installed by the dep scripts, run on the host | Windows binaries run natively (no wine), Linux/macOS ones in place |
| googletest suites sharded by available memory; memory-heavy cases serial; `needs_mem_gb.N` cases checked right before they run, skipped with a note when memory is short | libvpx's large-frame tests: `ConfigLargeTargetBitrateVp9` 5.2 GB, `IntegerOverflowLarge` ~20 GB (also fails upstream on smaller machines); peaks measured per test in `build/deps/libvpx_tests.sh` |
| Test manifests refreshed even when the dependency is already built (libvpx) | a stale `tests.tsv` without the memory options let `IntegerOverflowLarge` run in a shard (OOM) |
| `DISABLED_` googletest cases reported separately | gtest lists them in the XML as not run; they were counted as passed |
| Tests excluded only when they fail in upstream builds too, with the reason in the manifest | e.g. 11 SvtAv1ApiTests with stale expected defaults (upstream CI never runs that binary) |
| Upstream fixes of test code not yet in a release applied as patches (SVT-AV1 `SadTest.cc`, upstream 11032898) | a test reading uninitialized memory fails at random (macOS arm64 CI); the fix touches only the test, the shipped library stays the release |
| Exit status 77 means SKIP | `vainfo` / `test_va_api` without access to `/dev/dri` (CI, WSL) are skipped, not failed |
| Without test data, a googletest case failing with "file open failed" is a SKIP | the missing file is followed by cascading md5 assertions |
| FATE for the Windows build from WSL | FATE is make + shell; the programs still run natively on Windows through WSL interop |
| Windows FATE tree: API test programs built in the container, tree made writable, samples passed relative to the tree, `GIT_CEILING_DIRECTORIES` | WSL has no compiler/SDK; Docker records root as owner; `movie=D:/…` splits at the `:`; `fate-source` would `git grep` the enclosing repository |
| Test data outside the repository (`CUSTOM_FFMPEG_TEST_DATA`) | ~8 GB; CI caches only the FATE samples |

### Shared libraries
| Decision | Reason |
|---|---|
| Dependencies always static + PIC | one deps tree serves both build types; shared FFmpeg contains them |
| Linux `RUNPATH=$ORIGIN` | each `.so` finds its sibling FFmpeg libraries |
| macOS `install_name` → `@rpath/` | relocatable dylibs without build paths |

### Consumers
| Decision | Reason |
|---|---|
| `FindCustomFFmpeg` parses `Libs:` / `Requires(.private):` of the `.pc` files | the exact library list for each profile and platform, no hand-maintained lists |
| win64: C++ deps (x265, libvpl) built a second time for the debug runtime → `.deps/<platform>/lib/debug/<name>.lib` | their objects record the MSVC runtime (`RuntimeLibrary`, `_ITERATOR_DEBUG_LEVEL`); `/MDd` consumers (every MSVC Debug build) cannot link the release copy (LNK2038). Same sources and `-O3`, only `-D_DEBUG -D_DLL -D_MT` + `msvcrtd` (libvpl's own "RelWithDebRT" mode); C deps serve both runtimes. The dep scripts verify the records of both copies |
| `FindCustomFFmpeg` picks the copy by the target's MSVC runtime, not the configuration | genex on `MSVC_RUNTIME_LIBRARY` (CMP0091 OLD: the Debug configuration): a Debug build with the release runtime or a Release build with `/MDd` gets the matching copy; `/MDd` links also get `/NODEFAULTLIB:msvcrt.lib` (CMake-built C deps name the release CRT, LNK4098) |
| `lgpl` profile | GPL cannot be avoided by shared linking; proprietary consumers get H.264/HEVC through FFmpeg's decoders and the OS encoders |

### Licensing
| Decision | Reason |
|---|---|
| `LICENSE` (MIT) covers the build system only; [LICENSES.md](../LICENSES.md) explains the result per profile | the built libraries carry their own licenses; patches are under the license of the project they patch |
| No `--enable-version3` | no dependency needs it; `full` stays GPL-2.0+, not GPLv3 |

### CI
| Decision | Reason |
|---|---|
| Deps matrix per platform, then FFmpeg per type × profile | parallel jobs instead of sequential builds |
| Each deps job runs that dependency's tests (also on cache hits); FATE on fresh static builds | CI has no test vectors except the cached FATE samples (Linux) |
| Cache keys from `git ls-files -s` + runner image | content-based, independent of line endings, no submodule checkout needed |
| Concurrency cancels stale PR runs; docs-only PRs skip CI | saves runner time |
| GitHub Actions on Node 24 versions (checkout v5, upload-artifact v6, download-artifact v7, cache v5) | Node 20 actions are deprecated |
