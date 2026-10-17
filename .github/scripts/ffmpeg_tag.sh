#!/usr/bin/env bash
# ffmpeg_tag.sh — fetch the release tag of the FFmpeg submodule. A shallow
# submodule clone has no tags, and FFmpeg's version string (ffmpeg -version,
# av_version_info, build-info.txt) would be the commit hash instead of the tag
# (build_ffmpeg.sh stops on that).
set -euo pipefail
rel=$(cat sources/ffmpeg/RELEASE)
case "$rel" in *git*) exit 0 ;; esac   # a development snapshot: no tag
git -C sources/ffmpeg fetch -q --depth 1 origin "refs/tags/n$rel:refs/tags/n$rel"
git -C sources/ffmpeg describe --tags --exact-match
