#!/usr/bin/env python3
"""Pack one built variant into a self-contained release archive.

  python tools/package_release.py <prebuilt> <platform> <type> <profile> <version> [--out DIR]

<prebuilt> is the build output root (prebuilt/): the variant lives in
<prebuilt>/<platform>/<type>/<profile>, the dependencies in
<prebuilt>/.deps/<platform>. The archive keeps that layout, so the .pc files
and cmake/FindCustomFFmpeg.cmake work unchanged after unpacking:

  custom_ffmpeg-<version>-<platform>-<type>-<profile>/
    <platform>/<type>/<profile>/   the variant (bin, include, lib, share — with
                                   share/licenses and share/custom_ffmpeg/build-info.txt)
    .deps/<platform>/lib/          static only: the dependency libraries this
                                   variant links (from its .pc Libs:), plus their
                                   debug-runtime copies (lib/debug, Windows)
    cmake/FindCustomFFmpeg.cmake
    LICENSE, LICENSES.md, README.txt

A shared variant has its dependencies linked into its DLLs/.so/.dylib: no .deps.
Windows: .zip, Linux/macOS: .tar.xz (keeps symlinks and file modes).
Prints the archive path.
"""
import argparse
import os
import re
import sys
import tarfile
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

README = """custom_ffmpeg {version} — FFmpeg {ffmpeg}, {platform} {type} {profile}

License of this build: {license}. The license texts of FFmpeg and of every
library linked in are in {variant}/share/licenses/ — ship them with your
application. What the profiles mean for your application: LICENSES.md.
Build details (versions, pinned commits, compiler, target requirements):
{variant}/share/custom_ffmpeg/build-info.txt.

Use from CMake:

    list(APPEND CMAKE_MODULE_PATH "<this directory>/cmake")
    set(CUSTOM_FFMPEG_ROOT "<this directory>/{variant}")
    find_package(CustomFFmpeg REQUIRED COMPONENTS avformat avcodec swscale)
    target_link_libraries(app PRIVATE CustomFFmpeg::avformat CustomFFmpeg::avcodec CustomFFmpeg::swscale)

https://github.com/BarabashkaD/custom_ffmpeg
"""


def pc_libs(pc_dir):
    """-l names of the Libs: lines of the variant's .pc files."""
    names = set()
    for f in os.listdir(pc_dir):
        if not f.endswith(".pc"):
            continue
        with open(os.path.join(pc_dir, f), encoding="utf-8") as fh:
            for line in fh:
                if line.startswith(("Libs:", "Libs.private:")):
                    names.update(re.findall(r"(?:^|\s)-l(\S+)", line.split(":", 1)[1]))
    return names


def dep_files(deps_lib, names):
    """Files in <deps>/lib (and lib/debug) that the -l names resolve to."""
    files = []
    for sub in ("", "debug"):
        d = os.path.join(deps_lib, sub)
        if not os.path.isdir(d):
            continue
        for n in sorted(names):
            for cand in (f"{n}.lib", f"lib{n}.a"):
                if os.path.isfile(os.path.join(d, cand)):
                    files.append(os.path.join(sub, cand) if sub else cand)
    return files


def info_value(build_info, key):
    with open(build_info, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith(key + ":"):
                return line.split(":", 1)[1].strip()
    return "?"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prebuilt")
    ap.add_argument("platform")
    ap.add_argument("type", choices=("static", "shared"))
    ap.add_argument("profile")
    ap.add_argument("version", help="release version without the leading v, e.g. 1.0.0")
    ap.add_argument("--out", default=".", help="directory for the archive")
    a = ap.parse_args()

    prebuilt = os.path.abspath(a.prebuilt)
    variant = f"{a.platform}/{a.type}/{a.profile}"
    vdir = os.path.join(prebuilt, *variant.split("/"))
    build_info = os.path.join(vdir, "share", "custom_ffmpeg", "build-info.txt")
    if not os.path.isfile(build_info):
        sys.exit(f"ERROR: {build_info} missing — not a complete build of {variant}")
    if not os.path.isdir(os.path.join(vdir, "share", "licenses", "ffmpeg")):
        sys.exit(f"ERROR: license texts missing in {vdir}/share/licenses")

    name = f"custom_ffmpeg-{a.version}-{a.platform}-{a.type}-{a.profile}"
    entries = []      # (source path, archive path)
    for root, dirs, files in os.walk(vdir):
        dirs.sort()
        for f in sorted(files) + [d for d in dirs if os.path.islink(os.path.join(root, d))]:
            src = os.path.join(root, f)
            entries.append((src, f"{name}/{variant}/{os.path.relpath(src, vdir).replace(os.sep, '/')}"))

    if a.type == "static":
        deps_lib = os.path.join(prebuilt, ".deps", a.platform, "lib")
        libs = dep_files(deps_lib, pc_libs(os.path.join(vdir, "lib", "pkgconfig")))
        for rel in libs:
            entries.append((os.path.join(deps_lib, rel),
                            f"{name}/.deps/{a.platform}/lib/{rel.replace(os.sep, '/')}"))
        print(f"dependency libraries: {', '.join(libs) or '(none)'}", file=sys.stderr)

    entries.append((os.path.join(REPO, "cmake", "FindCustomFFmpeg.cmake"), f"{name}/cmake/FindCustomFFmpeg.cmake"))
    for f in ("LICENSE", "LICENSES.md"):
        entries.append((os.path.join(REPO, f), f"{name}/{f}"))
    readme = README.format(version=a.version, ffmpeg=info_value(build_info, "ffmpeg"),
                           platform=a.platform, type=a.type, profile=a.profile,
                           license=info_value(build_info, "license"), variant=variant)

    os.makedirs(a.out, exist_ok=True)
    if a.platform.startswith("windows"):
        path = os.path.join(a.out, name + ".zip")
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            for src, arc in entries:
                z.write(src, arc)
            z.writestr(f"{name}/README.txt", readme.replace("\n", "\r\n"))
    else:
        path = os.path.join(a.out, name + ".tar.xz")
        readme_path = os.path.join(a.out, name + ".README.txt")
        with open(readme_path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(readme)
        with tarfile.open(path, "w:xz", preset=9) as t:
            def clean(ti):          # no build-machine user/group names in the archive
                ti.uid = ti.gid = 0
                ti.uname = ti.gname = ""
                return ti
            for src, arc in entries:
                t.add(src, arc, recursive=False, filter=clean)
            t.add(readme_path, f"{name}/README.txt", filter=clean)
        os.remove(readme_path)
    print(path)


if __name__ == "__main__":
    main()
