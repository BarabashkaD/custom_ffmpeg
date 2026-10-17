#!/usr/bin/env python3
"""Release notes for a GitHub release from the packed archives.

  python tools/release_notes.py <version> <dist-dir> > notes.md

Reads the build-info.txt of each archive (tools/package_release.py) for the
FFmpeg version, the dependencies with their pinned commits and the target
requirements, and lists the archives with their sizes.
"""
import os
import re
import sys
import tarfile
import zipfile

REPO_URL = "https://github.com/BarabashkaD/custom_ffmpeg"


def build_info(path):
    """build-info.txt of an archive as text."""
    if path.endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            name = next(n for n in z.namelist() if n.endswith("share/custom_ffmpeg/build-info.txt"))
            return z.read(name).decode("utf-8")
    with tarfile.open(path) as t:
        member = next(m for m in t.getmembers() if m.name.endswith("share/custom_ffmpeg/build-info.txt"))
        return t.extractfile(member).read().decode("utf-8")


def field(info, key):
    m = re.search(rf"^{key}:\s*(.*)$", info, re.M)
    return m.group(1).strip() if m else "?"


def main():
    version, dist = sys.argv[1], sys.argv[2]
    archives = sorted(f for f in os.listdir(dist) if f.startswith("custom_ffmpeg-") and f.endswith((".zip", ".tar.xz")))
    if not archives:
        sys.exit(f"no archives in {dist}")
    infos = {a: build_info(os.path.join(dist, a)) for a in archives}

    # one full archive per platform: the complete dependency list and target line
    platforms = {}
    for a, info in infos.items():
        plat = field(info, "variant").split()[0]
        if "-full." in a or "-full.tar" in a or plat not in platforms:
            platforms[plat] = info
    any_info = next(iter(infos.values()))
    deps = re.search(r"^dependencies:\n((?:  .*\n?)*)", platforms.get("linux-x64", any_info), re.M)

    out = []
    out.append(f"FFmpeg **{field(any_info, 'ffmpeg')}** and its codec libraries, prebuilt for "
               "Windows (MSVC ABI), Linux and macOS — static or shared, profiles `minimal`, "
               "`lgpl` and `full` — ready for CMake (`cmake/FindCustomFFmpeg.cmake` in every archive).")
    out.append("")
    out.append("## Archives")
    out.append("")
    out.append("| Archive | Size | License |")
    out.append("|---|---|---|")
    for a in archives:
        size = os.path.getsize(os.path.join(dist, a)) / 1e6
        out.append(f"| `{a}` | {size:.0f} MB | {field(infos[a], 'license')} |")
    out.append("")
    out.append("`full` = `lgpl` + x264/x265 and is **GPL**: for GPL-compatible software only. "
               "Proprietary applications use `minimal` or `lgpl` (see `LICENSES.md`). "
               "Every archive carries the license texts of FFmpeg and of each library it links "
               "(`share/licenses/`) and its `share/custom_ffmpeg/build-info.txt`.")
    out.append("")
    out.append("## Requirements")
    out.append("")
    for plat in sorted(platforms):
        out.append(f"- **{plat}**: {field(platforms[plat], 'target')}")
    out.append("- Windows shared builds need the Visual C++ Redistributable (x64).")
    out.append("")
    if deps:
        out.append("## Libraries")
        out.append("")
        out.append("Linked into the `full` builds for Linux; Windows and macOS link the subset "
                   "their platform uses (each archive's `build-info.txt` lists its own).")
        out.append("")
        out.append("| Library | Version @ pinned commit |")
        out.append("|---|---|")
        for line in deps.group(1).splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2:
                out.append(f"| {parts[0]} | {parts[1]} |")
        out.append("")
        out.append("The sources are the submodules of this release's tag (LAME and the AMF headers: "
                   "release archives, URL and SHA-256 in `versions.cmake`).")
        out.append("")
    out.append("## Verification")
    out.append("")
    out.append("`SHA256SUMS` lists the archives' checksums; each archive has a GitHub build "
               "provenance attestation (`gh attestation verify <archive> -R BarabashkaD/custom_ffmpeg`). "
               f"Test coverage per platform: [docs/test-status.md]({REPO_URL}/blob/v{version}/docs/test-status.md).")
    out.append("")
    out.append("H.264/HEVC/AV1 and other codecs may be covered by patents in some countries; "
               "licensing them is up to whoever distributes the application.")
    print("\n".join(out))


if __name__ == "__main__":
    main()
