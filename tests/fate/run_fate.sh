#!/usr/bin/env bash
# run_fate.sh — run FFmpeg's FATE test suite in a configured FFmpeg build tree.
#
#   bash tests/fate/run_fate.sh <ffmpeg-build-dir> [--samples DIR] [--jobs N]
#        [--ignore FILE] [--windows] [--log FILE]
#
# --samples   fate-suite directory; without it only the tests that need no
#             samples run (internal tests, checkasm, generated-data round trips)
# --ignore    file with test names (without "fate-"), one per line, "#" comments;
#             every entry must say why — passed to FATE as ignored tests
# --windows   the tree holds a Windows build (run from WSL): make and the test
#             scripts run in WSL, every .exe runs natively on Windows through
#             WSL interop. Programs get Windows paths (target path/samples),
#             which tests/fate/wsl-exec.sh maps back for starting them.
# Prints a summary and exits non-zero if any test failed.
set -uo pipefail

build_dir=""; samples=""; jobs="$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 2)"
ignore_file=""; windows=0; log=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --samples) samples="$2"; shift 2 ;;
        --jobs)    jobs="$2"; shift 2 ;;
        --ignore)  ignore_file="$2"; shift 2 ;;
        --windows) windows=1; shift ;;
        --log)     log="$2"; shift 2 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)  build_dir="$1"; shift ;;
    esac
done
[[ -d "$build_dir" && -f "$build_dir/ffbuild/config.mak" ]] || {
    echo "Usage: $0 <ffmpeg-build-dir> [options]  (configured FFmpeg build dir)" >&2; exit 2; }
build_dir="$(cd "$build_dir" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
log="${log:-$build_dir/fate.log}"

make_args=(-C "$build_dir" -k -j"$jobs")
[[ -n "$samples" ]] && make_args+=(SAMPLES="$(cd "$samples" && pwd)")

if [[ -n "$ignore_file" ]]; then
    ignored=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ignore_file" | grep -v '^$' | paste -sd' ' -)
    [[ -n "$ignored" ]] && make_args+=(IGNORE_TESTS="$ignored")
fi

if [[ "$windows" == 1 ]]; then
    command -v wslpath >/dev/null || { echo "--windows needs WSL (wslpath)" >&2; exit 2; }
    # Tree exported from the build container (build_ffmpeg.sh FFMPEG_TESTS=1).
    # configure records SRC_PATH=src (the tree's own symlink, re-pointed at
    # <export>/src/ffmpeg by the export); only the top Makefile includes the
    # container's absolute source path — point it at that symlink
    inc=$(sed -n 's|^include \(/.*\)/Makefile$|\1|p' "$build_dir/Makefile")
    if [[ -n "$inc" && ! -d "$inc" && -f "$build_dir/src/Makefile" ]]; then
        sed -i "s|^include $inc/Makefile\$|include src/Makefile|" "$build_dir/Makefile"
    fi
    # The exported sources have no .git: keep git from finding an enclosing
    # repository (prebuilt/ inside the project) — fate-source would check that
    export GIT_CEILING_DIRECTORIES="$(cd "$build_dir/.." && pwd)"
    # An absolute SRC_PATH (configure run without the symlink) is re-pointed too
    src_recorded=$(sed -n 's/^SRC_PATH=//p' "$build_dir/ffbuild/config.mak")
    src_here="$(cd "$build_dir/.." && pwd)/src/ffmpeg"
    if [[ "$src_recorded" == /* && ! -d "$src_recorded" && -d "$src_here" ]]; then
        grep -rlF "$src_recorded" "$build_dir/ffbuild" "$build_dir/Makefile" 2>/dev/null |
            while read -r f; do sed -i "s|$src_recorded|$src_here|g" "$f"; done
    fi
    # Programs see Windows paths; the build tree and samples must be on a
    # Windows drive (/mnt/<x>/...) so that both sides reach the same files
    make_args+=(TARGET_EXEC="$here/wsl-exec.sh" TARGET_PATH="$(wslpath -m "$build_dir")")
    # Samples relative to the build tree (the programs' working directory):
    # filtergraphs take them as movie=<path>, where the ':' of "D:/…" would
    # end the file name. Another drive has no relative path — Windows form then
    if [[ -n "$samples" ]]; then
        samples_abs="$(cd "$samples" && pwd)"
        if [[ "${samples_abs#/mnt/}" != "$samples_abs" &&
              "$(cut -d/ -f3 <<< "$samples_abs")" == "$(cut -d/ -f3 <<< "$build_dir")" ]]; then
            make_args+=(TARGET_SAMPLES="$(realpath -m --relative-to="$build_dir" "$samples_abs")")
        else
            make_args+=(TARGET_SAMPLES="$(wslpath -m "$samples_abs")")
        fi
    fi
fi

echo "=== FATE: $build_dir  (samples: ${samples:-none}, jobs: $jobs, windows: $windows) ==="
start=$(date +%s)
make "${make_args[@]}" fate > "$log" 2>&1
status=$?
secs=$(( $(date +%s) - start ))

total=$(grep -c '^TEST ' "$log" || true)
failed=$(grep -oE "^make: \*\*\* \[[^]]*: fate-[^]]+\]" "$log" | sed -E 's/.*: (fate-[^]]+)\]/\1/' | sort -u || true)
nfailed=$(printf '%s\n' "$failed" | grep -c . || true)
echo "=== FATE: $total tests, $nfailed failed, ${secs}s (log: $log) ==="
if [[ "$nfailed" -gt 0 ]]; then
    printf '  %s\n' $failed | head -50
    exit 1
fi
exit $status
