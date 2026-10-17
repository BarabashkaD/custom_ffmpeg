#!/usr/bin/env bash
# run.sh — build and run the consumer test against one prebuilt variant
# (Linux/macOS): C and C++ consumers, Release.
#
#   bash tests/consumer/run.sh prebuilt/linux-x64/static/full [build-dir]
#
# CC/CXX from the environment select the compiler (default: CMake's choice).
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$1" && pwd)"
build_dir="${2:-tmp/consumer}"
name="$(basename "$(dirname "$root")")-$(basename "$root")"   # e.g. static-full

for lang in C CXX; do
    cxx=OFF; [[ "$lang" == CXX ]] && cxx=ON
    b="$build_dir/$name-$lang"
    cmake -S "$src" -B "$b" -DCMAKE_BUILD_TYPE=Release \
        -DCUSTOM_FFMPEG_ROOT="$root" -DCONSUMER_CXX="$cxx"
    cmake --build "$b"
    ctest --test-dir "$b" --output-on-failure
    echo "RESULT $name $lang Release PASS"
done
