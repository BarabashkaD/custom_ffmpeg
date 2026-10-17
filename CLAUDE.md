# custom_ffmpeg — instructions for Claude Code

Reproducible builds of FFmpeg and its codec libraries for windows-x64 (MSVC
ABI, cross-compiled with clang/lld in Docker), linux-x64 and macos-arm64,
static or shared, consumed from CMake through `cmake/FindCustomFFmpeg.cmake`.

Read first, as needed:
- [README.md](README.md) — targets, profiles, build and test commands
- [docs/architecture.md](docs/architecture.md) — layout, build flows and every
  design decision with its reason
- [docs/build-issues.md](docs/build-issues.md) — problems met, causes and fixes
- [docs/test-status.md](docs/test-status.md) — what is tested where
- [LICENSES.md](LICENSES.md) — licenses of the results per profile

## Repository map

```
versions.cmake        pinned versions: submodule tags, X265_VERSION, LAME and AMF archives (URL + SHA256)
sources/              git submodules on release tags — never modified (see Rules)
patches/<project>/    git patches applied to the exported copy of a source tree
compat/               Windows SDK case-sensitivity shims for the Linux container
docker/Dockerfile     tools only, no build logic
profiles/*.cmake      WHAT FFmpeg includes: minimal, lgpl, full (= lgpl + x264/x265, GPL)
cmake/                runs on the host: FindWindowsSDK, GenerateConfig, FindCustomFFmpeg
build/
  build_ffmpeg.sh     Windows target, inside the container
  build_linux.sh      Linux target, native / WSL2 / container
  build_macos.sh      macOS target, native
  build_deps.sh       runs deps/<dep>_<os>.sh, falls back to deps/<dep>.sh
  lib/paths.sh        export_src, path_map_flags, replace_paths, check_no_local_paths
  deps/               one script per dependency (+ common.sh)
scripts/build.ps1     Windows entry point: image → config → docker run → tests on the host
tests/consumer/       find_package(CustomFFmpeg) → link → run (run.ps1 MSVC, run.sh clang)
tests/deps/           run_dep_tests.py: each dependency's own tests + CLI round trips
tests/fate/           run_fate.sh: FATE; --windows runs make in WSL, .exe natively
tests/hw/             GPU smoke tests (NVIDIA)
tools/                fetch_test_data.sh, test_x264.py
.github/              CI workflow, cache_key.sh
generated/, prebuilt/, tmp/   build outputs, git-ignored
```

## Commands

```powershell
# Windows target (Docker Desktop with the WSL2 backend, VS 2022 + Windows SDK on the host)
.\scripts\build.ps1                                   # static full
.\scripts\build.ps1 -Type shared -Profile lgpl
.\scripts\build.ps1 -OnlyDeps x264                    # one dependency
.\scripts\build.ps1 -Test -TestData <dir> -WslDistro <distro>   # + all dependency tests and FATE
```

```sh
# Linux target
bash build/build_linux.sh                             # all deps
bash build/build_linux.sh x264                        # one dependency
bash build/build_linux.sh --ffmpeg lgpl [--shared]    # all deps + FFmpeg (profile default: full)
python3 tests/deps/run_dep_tests.py prebuilt/.deps/linux-x64 [--data <dir>] [--only dep,dep]
bash tests/fate/run_fate.sh <build-dir> [--samples <dir>/fate-suite]
bash tests/consumer/run.sh prebuilt/linux-x64/static/lgpl
```

macOS: `bash build/build_macos.sh` (same arguments). Test data (optional,
~8 GB): `bash tools/fetch_test_data.sh <dir> [fate|libvpx|opus|dav1d|svtav1|all]`; pass
it with `--data` / `-TestData` or `CUSTOM_FFMPEG_TEST_DATA`.

## Rules

- **Submodules stay untouched.** Builds work on a `git archive` export in
  `WORK_ROOT`/`TMPDIR`. Changes to upstream code go into `patches/<project>/`
  as git patches (LF), applied by `apply_patches` to the export.
- **No machine-specific values** in code, scripts, CI, docs or build outputs:
  no host or user names, IP addresses, absolute paths of the build machine.
  Use parameters, environment variables or auto-detection. Fixed container
  paths (`/src`, `/artifacts`, `/build`, `/winsdk`, `/configs`) are the image's
  contract. `check_no_local_paths` fails the build on a leak — never weaken it.
- **Toolchain:** clang/LLVM only (no GCC, no MinGW). Windows binaries run on
  the Windows host, never under wine.
- **Dependencies** are always static + PIC, one tree per platform
  (`prebuilt/.deps/<platform>`), shared by every build type and profile. Dep
  scripts are idempotent (`already_built`), install their test programs and
  a `tests.tsv` manifest into `<deps>/tests/<dep>/`.
- **Platform-specific behaviour** goes into `<dep>_<os>.sh`
  (`TARGET_OS` = `win64` | `linux` | `macos`), not into if/else in a shared script.
- **Profiles** list every required component (`FFMPEG_REQUIRED*`) and the
  expected license; the build fails when configure drops one. Adding a
  feature means adding it to the required list too.
- **Tests:** a test may be disabled only when it also fails in upstream builds;
  record it with `exclude=` and the reason in the manifest. Otherwise find and
  fix the cause.
- **Line endings:** `.sh`, `.cmake`, patches and submodules LF; `.ps1` CRLF
  (`.gitattributes`). Submodules must be checked out with LF.
- **Versions** change only in `versions.cmake` and the submodule pointer
  together; update the pinned-version lists in README.md and LICENSES.md.

## When changing something

- Build and test the affected dependency or variant on each platform it
  touches: `run_dep_tests.py --only <dep>`, the consumer test, FATE for
  changes in FFmpeg's configuration.
- Keep the docs current: a new design decision → `docs/architecture.md`;
  a problem met and solved → `docs/build-issues.md`; changed test coverage →
  `docs/test-status.md`; user-visible changes → `README.md`.
- New dependency: submodule (or archive + SHA256) in `versions.cmake`, dep
  script(s), test manifest, CI matrix entry and cache key paths, license
  entry in `LICENSES.md`.
- Commit messages: `<area>: <what changed>` in lower case (e.g.
  `libvpx: …`, `build: …`, `docs: …`, `ci: …`).

Personal, machine-specific notes belong in `CLAUDE.local.md` (git-ignored).
