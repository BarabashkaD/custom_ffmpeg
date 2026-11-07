#!/usr/bin/env bash
# check_macos_dlopen.sh — macOS shared variant: every FFmpeg dylib loads on its
# own, from any directory.
#
#   bash tests/consumer/check_macos_dlopen.sh <variant-dir>
#   e.g. prebuilt/macos-arm64/shared/lgpl  (or the macos-arm64/shared/<profile> folder of an unpacked release archive)
#
# The dylibs have install names and sibling dependencies of the form
# @rpath/<lib>.<major>.dylib. A host that dlopen()s one of them by path (not
# through a linked executable that already carries an rpath) finds the
# siblings only when the dylib itself has an LC_RPATH @loader_path. The check:
#   1. every real lib/*.dylib has LC_RPATH @loader_path and an @rpath install name,
#   2. a small C program dlopen()s each library by full path, RTLD_NOW, without
#      loading any dependency first, from a copy of lib/ in a temporary directory.
set -euo pipefail

variant="${1:?usage: check_macos_dlopen.sh <variant-dir>}"
lib="$variant/lib"
[[ -d "$lib" ]] || { echo "ERROR: no $lib" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

shopt -s nullglob
for f in "$lib"/*.dylib; do
    [[ -L "$f" ]] && continue
    loadcmds="$(otool -l "$f")"
    if ! awk '/cmd LC_RPATH/ {getline; getline; print $2}' <<< "$loadcmds" | grep -qxF '@loader_path'; then
        echo "FAIL: $(basename "$f") has no LC_RPATH @loader_path"; fail=1
    fi
    id="$(otool -D "$f" | tail -n 1)"
    if [[ "$id" != @rpath/* ]]; then
        echo "FAIL: $(basename "$f") install name is not @rpath/…: $id"; fail=1
    fi
done

cat > "$work/probe.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    int bad = 0;
    for (int i = 1; i < argc; ++i) {
        void *h = dlopen(argv[i], RTLD_NOW | RTLD_LOCAL);
        printf("%s: %s\n", argv[i], h ? "ok" : dlerror());
        if (!h) bad = 1;
    }
    return bad;
}
C
clang -o "$work/probe" "$work/probe.c"

# a copy in a fresh directory: nothing from the build tree can help the loader
mkdir "$work/copy"
cp -a "$lib/." "$work/copy/"

# one process per library: an earlier successful load must not hide a missing dependency
# the minimal profile builds avutil and swscale only (CHECK_LIBS="avutil swscale")
read -r -a libs <<< "${CHECK_LIBS:-avutil swresample avcodec avformat swscale avfilter avdevice}"
for name in "${libs[@]}"; do
    # the major-version name (libavcodec.62.dylib), the one consumers load
    path=""
    for c in "$work/copy/lib$name".[0-9]*.dylib; do
        [[ "$(basename "$c")" =~ ^lib${name}\.[0-9]+\.dylib$ ]] && path="$c"
    done
    if [[ -z "$path" ]]; then echo "FAIL: no lib$name.<major>.dylib in $lib"; fail=1; continue; fi
    "$work/probe" "$path" || fail=1
done

if [[ $fail -ne 0 ]]; then echo "macOS dlopen check FAILED"; exit 1; fi
echo "macOS dlopen check passed"
