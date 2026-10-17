#!/usr/bin/env bash
# dep_submodules.sh <dep>... — the submodules a set of dependencies builds from,
# one path per line: sources/<dep> when it is a submodule (mp3lame and amf come
# from archives) plus the extra submodules a dep needs (test-only included).
# Used by the CI to check out only these, and by cache_key.sh for its key.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

for dep in "$@"; do
    paths=("sources/$dep")
    case "$dep" in
        dav1d)  paths+=(sources/checkasm) ;;
        libva)  paths+=(sources/libva-utils) ;;
        svtav1) paths+=(sources/libaom) ;;
    esac
    for p in "${paths[@]}"; do
        # Submodules are named after their path in .gitmodules
        if git config -f .gitmodules --get "submodule.$p.path" >/dev/null; then
            echo "$p"
        fi
    done
done | awk '!seen[$0]++'
