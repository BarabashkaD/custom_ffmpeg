#!/usr/bin/env bash
# paths.sh — path helpers shared by build_ffmpeg.sh and the dep scripts.
# Keeps build-machine paths (home dirs, checkout locations, user and host
# names) out of the produced libraries and makes the build location-independent.

# path_map_flags <from>=<to>... — compiler flags that rewrite <from> to <to> in
# debug info and __FILE__. Adds the physical path too when it differs (macOS:
# /tmp -> /private/tmp). Identity maps are skipped.
path_map_flags() {
    local pair from to phys flags=""
    for pair in "$@"; do
        from="${pair%%=*}" to="${pair#*=}"
        [[ -z "$from" || "$from" == "$to" ]] && continue
        flags+=" -ffile-prefix-map=${from}=${to}"
        phys="$(cd "$from" 2>/dev/null && pwd -P)" || phys=""
        [[ -n "$phys" && "$phys" != "$from" ]] && flags+=" -ffile-prefix-map=${phys}=${to}"
    done
    echo "$flags"
}

# replace_paths <file> <from>=<to>... — rewrite literal paths inside a text file.
# Pairs are applied in the given order: pass the most specific path first.
replace_paths() {
    local file="$1" pair from to
    shift
    for pair in "$@"; do
        from="${pair%%=*}" to="${pair#*=}"
        [[ -z "$from" || "$from" == "$to" ]] && continue
        sed -i.bak "s|${from}|${to}|g" "$file"
        rm -f "$file.bak"
    done
}

# export_src <git-dir> <dest> — export the committed tree (HEAD) of a source
# checkout into <dest> with `git archive`. Reading a few pack files is far
# faster than copying thousands of files over a bind mount, the export never
# writes into the submodule (autogen/configure leave it clean), and relative
# paths from a sibling build dir carry no build-machine location.
# Skipped when <dest> already holds the same commit; git archive stamps every
# file with the commit time, so make stays incremental across runs.
export_src() {
    local src="$1" dest="$2" sha
    sha=$(git -C "$src" rev-parse HEAD)
    if [[ "$(cat "$dest/.src-sha" 2>/dev/null)" == "$sha" ]]; then
        return 0
    fi
    echo "=== export $(basename "$src") ${sha:0:8} -> $dest ==="
    rm -rf "$dest" && mkdir -p "$dest"
    git -C "$src" archive --format=tar HEAD | tar -x -C "$dest"
    echo "$sha" > "$dest/.src-sha"
}

# check_no_local_paths <dir>... — fail if build-machine specifics leaked into
# the outputs (libraries, headers, .pc files, binaries): the checkout root,
# $HOME, the host name. Paths the Docker build uses on purpose (/src,
# /artifacts, /build, /deps, /tmp, /root) are not considered local.
check_no_local_paths() {
    local patterns=() p dir f found=0
    for p in "${REPO_ROOT:-}" "${HOME:-}" "$(hostname 2>/dev/null)"; do
        case "$p" in
            ""|/|/src|/artifacts|/build|/deps|/tmp|/root) continue ;;
        esac
        [[ ${#p} -ge 6 ]] && patterns+=("$p")
    done
    [[ ${#patterns[@]} -eq 0 ]] && { echo "=== Path check: nothing local to look for ==="; return 0; }

    for dir in "$@"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' f; do
            for p in "${patterns[@]}"; do
                if grep -a -q -F -- "$p" "$f"; then
                    echo "LEAK: '$p' in $f" >&2
                    found=1
                fi
            done
        done < <(find "$dir" -type f \( -name '*.a' -o -name '*.lib' -o -name '*.pc' \
                    -o -name '*.h' -o -name '*.so*' -o -name '*.dylib' -o -name '*.dll' \
                    -o -name '*.cmake' -o -name '*.la' -o -path '*/bin/*' \) -print0)
    done
    if [[ $found -ne 0 ]]; then
        echo "ERROR: build-machine paths/names found in build outputs (see LEAK lines)" >&2
        return 1
    fi
    echo "=== Path check: no build-machine paths in $* ==="
}
