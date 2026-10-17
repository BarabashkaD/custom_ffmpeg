# custom_ffmpeg

Reproducible builds of FFmpeg and its codec libraries for **Windows (MSVC ABI)**,
**Linux** and **macOS**, as static or shared libraries, ready to be consumed
from CMake.

- All sources are git submodules pinned to release tags — no system packages,
  no vcpkg/Conan; full control over configure flags.
- Full assembly optimizations (NASM / NEON).
- Windows libraries are cross-compiled with clang/lld in Docker against the
  real Windows SDK and MSVC headers, and link with Visual Studio / Qt.
- The feature set is explicit (`--disable-autodetect`), so a build does not
  depend on what happens to be installed on the build machine.
- Build outputs contain no build-machine paths, user or host names (checked
  on every build).

## Targets and profiles

| Target | ABI | Built on |
|---|---|---|
| `windows-x64` | MSVC (`x86_64-pc-windows-msvc`) | Windows host, Docker (WSL2 backend) |
| `linux-x64` | glibc | Linux / WSL2, natively |
| `macos-arm64` | Apple | macOS, natively |

| Profile | Contents | License |
|---|---|---|
| `minimal` | avutil + swscale | LGPL-2.1+ |
| `lgpl` | all FFmpeg libraries; VP8/VP9 (libvpx), AV1 (SVT-AV1 encoder, dav1d decoder), Opus, Vorbis, WebP, MP3 (LAME), zlib; H.264/HEVC via FFmpeg's decoders, the OS encoders and the GPU vendor encoders; programs `ffmpeg` and `ffprobe` | LGPL-2.1+ |
| `full` | `lgpl` + x264 + x265 | **GPL-2.0+** |

Each profile builds as `static` or `shared`. `ffplay` is not built (it needs
SDL2). OS and GPU integrations enabled explicitly in `lgpl`/`full`:

| | Windows | macOS | Linux |
|---|---|---|---|
| TLS (https) | Schannel | SecureTransport | — |
| HW decoding | D3D11VA, DXVA2, D3D12VA | VideoToolbox | VAAPI, V4L2 M2M |
| OS encoders | Media Foundation (H.264, HEVC, AV1) | VideoToolbox (H.264, HEVC) | VAAPI, V4L2 M2M |
| NVIDIA | NVENC, NVDEC/CUVID, CUDA filters | — | NVENC, NVDEC/CUVID, CUDA filters |
| AMD | AMF (encoders, decoders, filters) | — | AMF |
| Intel | Quick Sync Video (libvpl) | — | Quick Sync Video (libvpl over VAAPI) |
| Capture | DirectShow, GDI, VfW | AVFoundation | V4L2, fbdev, OSS |

The GPU vendor runtimes come with the user's graphics driver and are loaded
at run time: nothing of them is linked or shipped, and without the GPU or
driver these codecs fail with an error when opened. NVENC/NVDEC need an
NVIDIA driver ≥ 531.61 (Windows) / 530.41.03 (Linux). CUDA filters are
compiled by clang to PTX (no CUDA SDK, nothing `nonfree`).

On Linux, libva and libdrm are linked statically, while the VA driver (Intel
`iHD`/`i965`, AMD/Mesa `radeonsi`) comes from the system and is loaded at
run time from the distribution's `dri` directory (`LIBVA_DRIVERS_PATH` and
`LIBVA_DRIVER_NAME` override it). The user needs access to the render node
(`/dev/dri/renderD*`, usually the `render` group).

See [LICENSES.md](LICENSES.md) for what the profile licenses mean for your
application — in short: proprietary applications use `minimal` or `lgpl`
(preferably shared), `full` is for GPL-compatible software only.

Pinned versions: FFmpeg 8.1.3, x264 (stable), x265 4.2, libvpx 1.17.0,
SVT-AV1 4.2.0, dav1d 1.5.4, Opus 1.6.1, libogg 1.3.6, libvorbis 1.3.7,
libwebp 1.6.0, zlib 1.3.2, LAME 3.100, nv-codec-headers 12.1.14.0,
AMF headers 1.5.0, libvpl 2.17.0, libva 2.24.1 and libdrm 2.4.134 (Linux) —
see [versions.cmake](versions.cmake).

## Building

Clone with submodules (shallow is enough):

```sh
git clone --recurse-submodules --shallow-submodules <repository-url>
```

On Windows the submodules must be checked out with LF line endings (the
autotools scripts break with CRLF). If your git converts line endings, run
`git -C sources/<name> config core.autocrlf false` and re-checkout the
submodule.

### Windows target (`windows-x64`)

Prerequisites: Docker Desktop (WSL2 backend), CMake ≥ 3.25, Visual Studio 2022
(any edition, with the x64 C++ tools) and a Windows 10/11 SDK. The SDK and MSVC
are detected automatically (registry / vswhere); override with
`WINSDK_KITS_ROOT`, `MSVC_BASE_DIR` or `VS_VERSION_RANGE` if needed.

```powershell
.\scripts\build.ps1                                # static full
.\scripts\build.ps1 -Type shared -Profile lgpl     # -Type static|shared, -Profile full|lgpl|minimal
.\scripts\build.ps1 -OnlyDeps "x264 x265"          # dependencies only
.\scripts\build.ps1 -Test -TestData <test-data-dir> -WslDistro <distro>     # + all tests (see Testing)
.\scripts\build.ps1 -RebuildImage                  # rebuild the tool image
```

The Docker image contains only tools (clang 19, lld, nasm, cmake, meson,
autotools). Sources are exported into the container with `git archive` and
compiled on the container's file system; build trees live in the Docker
volume `custom-ffmpeg-build` (`-BuildVolume` / `CUSTOM_FFMPEG_BUILD_VOLUME`
to use another), so rebuilds are incremental (`docker volume rm <volume>`
resets them). `-Jobs N` limits parallel compile jobs. After the build, the
x264 tests run on the host; `-Test` runs every dependency test and FATE.

### Linux target (`linux-x64`)

```sh
sudo apt install clang nasm git make cmake ninja-build meson pkg-config autoconf automake libtool python3 curl
bash build/build_linux.sh                         # dependencies only
bash build/build_linux.sh --ffmpeg full           # + FFmpeg (full | lgpl | minimal)
bash build/build_linux.sh --ffmpeg lgpl --shared  # shared libraries
```

### macOS target (`macos-arm64`)

```sh
xcode-select --install
brew install cmake pkg-config autoconf automake libtool ninja meson
bash build/build_macos.sh --ffmpeg full           # [--shared]
```

`JOBS=N` limits parallel compile jobs on Linux and macOS.

### Output

```
prebuilt/
├── <platform>/<static|shared>/<profile>/
│   ├── include/             FFmpeg headers (+ AMF/, vpl/ needed by hwcontext_amf.h / hwcontext_qsv.h)
│   ├── lib/                 libraries (.lib / .a; shared: import .lib, .so, .dylib)
│   ├── lib/pkgconfig/       relocatable .pc files
│   └── bin/                 ffmpeg, ffprobe; Windows shared builds: the DLLs
└── .deps/<platform>/        codec libraries (static, also linked into shared FFmpeg),
                             their command line tools (bin/) and test programs (tests/);
                             Windows: lib/debug/ — the C++ ones for the MSVC debug runtime
```

Static builds need the codec libraries from `.deps/<platform>/lib` at link
time; shared builds contain them (consumers only ship the FFmpeg DLLs / `.so`).
Windows shared builds need the Visual C++ runtime (`VCRUNTIME140.dll`, and
`MSVCP140.dll` for the C++ parts: x265, the libvpl dispatcher) — the VC++
Redistributable.

## Using the libraries

### CMake

```cmake
list(APPEND CMAKE_MODULE_PATH "<custom_ffmpeg>/cmake")
set(CUSTOM_FFMPEG_ROOT "<custom_ffmpeg>/prebuilt/windows-x64/shared/lgpl")

find_package(CustomFFmpeg REQUIRED COMPONENTS avformat avcodec swscale)
target_link_libraries(app PRIVATE CustomFFmpeg::avformat CustomFFmpeg::avcodec CustomFFmpeg::swscale)
# or everything at once: CustomFFmpeg::FFmpeg
```

`FindCustomFFmpeg` reads the `.pc` files: required components are added
automatically (e.g. `swscale` pulls in `avutil`), and a static build gets all
codec and system libraries it needs. A shared build yields `SHARED IMPORTED`
targets; on Windows copy the DLLs next to the executable:

```cmake
add_custom_command(TARGET app POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different $<TARGET_RUNTIME_DLLS:app> $<TARGET_FILE_DIR:app>
    COMMAND_EXPAND_LISTS)
```

Variables: `CUSTOM_FFMPEG_SHARED`, `CUSTOM_FFMPEG_RUNTIME_LIBRARIES` (files to
ship), `CUSTOM_FFMPEG_EXTRA_LIBRARIES` (static: codec + system libraries).
Linux `.so` files carry `RUNPATH=$ORIGIN`, macOS dylibs use `@rpath`.

**MSVC Debug builds:** static `full` and `lgpl` builds work in Debug (`/MDd`)
as well as Release (`/MD`), from C and C++. Their C++ dependencies (x265, the
libvpl dispatcher) record the MSVC runtime they were compiled for, and
`link.exe` refuses to mix runtimes (`LNK2038`). So each of them is built twice:
`.deps/<platform>/lib/<name>.lib` for the release runtime and
`.deps/<platform>/lib/debug/<name>.lib` for the debug runtime (same code and
optimisation, only the runtime differs). `FindCustomFFmpeg` links the copy that
matches each target's runtime — its `MSVC_RUNTIME_LIBRARY` (the CMake default
is `/MDd` in Debug, `/MD` otherwise), or the Debug configuration for projects
that still set `/MD` `/MDd` through flags (policy CMP0091 OLD) — and keeps the
release `msvcrt.lib` default library out of `/MDd` links. Without CMake, put
`.deps/<platform>/lib/debug` before `.deps/<platform>/lib` in the Debug library
directories and add `/NODEFAULTLIB:msvcrt.lib`. The libraries are built for the
DLL runtime; the static runtime (`/MT`, `/MTd`) is not supported.

### pkg-config

The `.pc` files are relocatable (`${pcfiledir}`):

```sh
PKG_CONFIG_PATH=prebuilt/linux-x64/static/lgpl/lib/pkgconfig pkg-config --static --libs libavcodec
```

## Testing

What has been tested on which platform and configuration:
[docs/test-status.md](docs/test-status.md).

- `tests/consumer/` — a small project that uses only `find_package(CustomFFmpeg)`,
  checks the expected encoders/decoders and the library license at run time.
  ```powershell
  .\tests\consumer\run.ps1 -FFmpegRoot prebuilt\windows-x64\static\full   # MSVC: C/C++ x Release/Debug
  ```
  ```sh
  bash tests/consumer/run.sh prebuilt/linux-x64/shared/lgpl               # clang: C/C++
  ```
- `tests/deps/run_dep_tests.py` — every codec library is tested with its own
  means: its test programs (x264/dav1d checkasm, x265 TestBench, libvpx and
  SVT-AV1 googletest suites (unit, API, E2E against the libaom reference
  decoder), libvpl dispatcher tests, libdrm tests, libva's test_va_api, Opus/Ogg/Vorbis/zlib
  unit tests, …) and round trips through its own command line tools (x264,
  x265, vpxenc/vpxdec, SvtAv1EncApp, dav1d, cwebp/dwebp, lame, opus_demo).
  Windows programs run natively on the Windows host.
  ```sh
  python tests/deps/run_dep_tests.py prebuilt/.deps/<platform> [--data <test-data>] [--only dep,dep] [--jobs N]
  ```
- FATE, FFmpeg's own test suite: `tests/fate/run_fate.sh <build-dir>
  [--samples <test-data>/fate-suite]`. The Windows build runs it from WSL —
  make and the test scripts in Linux, every `.exe` natively on Windows
  (`build.ps1 -Test`).
- Test data (optional, the full test level): `bash tools/fetch_test_data.sh
  <dir> [fate|libvpx|opus|dav1d|svtav1|all]` downloads the FATE samples
  (~1.4 GB), the libvpx test vectors (~6.3 GB), the Opus RFC 8251 vectors,
  dav1d-test-data and the SVT-AV1 E2E clips (~430 MB) into one directory; point `--data` /
  `CUSTOM_FFMPEG_TEST_DATA` at it. Without data, the tests that need it are
  skipped.
- `tests/hw/nvidia_smoke.py <ffmpeg-root>` — NVENC/NVDEC/CUDA filter smoke
  test on a machine with an NVIDIA GPU (skips cleanly without one). AMD AMF,
  Intel QSV and VAAPI need their GPUs; without them the encoders fail cleanly.
- Every FFmpeg build fails if a required component was disabled by configure,
  if the license differs from the profile's, or if build-machine paths ended
  up in the outputs.

## CI

GitHub Actions (`.github/workflows/build.yml`) builds and tests every
dependency per platform (its own tests, without test vectors), then FFmpeg for
each build type × profile in parallel jobs, runs the consumer tests and FATE
(Linux with the cached FATE samples, macOS without samples). Results are
cached by content (submodule commits, scripts, patches, profiles, runner
image), so unchanged variants finish in minutes; dependency and consumer tests run
on cache hits too (FATE needs a fresh build tree).
Manual runs can select platforms, build types and profiles; documentation-only
pull requests skip CI.

## Customizing

- **Profiles:** `profiles/*.cmake` declare libraries, configure flags,
  per-platform features (`FFMPEG_CONFIGURE_EXTRA_<WINDOWS|LINUX|MACOS>`),
  required components and the expected license. Start from
  `profiles/custom.cmake.example`.
- **Versions:** check out another tag in `sources/<name>`, commit the submodule
  and update the list in `versions.cmake`.

More details on the design: [docs/architecture.md](docs/architecture.md).

## License

The build system is MIT-licensed ([LICENSE](LICENSE)). FFmpeg and the codec
libraries keep their own licenses — see [LICENSES.md](LICENSES.md).
