#!/usr/bin/env bash
# Run inside the Docker container once per build.
# Creates lowercase symlinks for the 6 .lib files that lld-link searches
# by lowercase name on a case-sensitive Linux fs.
#
# Usage: bash /src/compat/create_lib_symlinks.sh <winsdk_lib_um_x64> <out_dir>
#   winsdk_lib_um_x64  — e.g. /winsdk/sdk-lib/um/x64
#   out_dir            — writable dir that will be added to -L (e.g. /tmp/compat-lib)
set -euo pipefail

SRC="${1:?Usage: $0 <winsdk_lib_um_x64> <out_dir>}"
OUT="${2:?Usage: $0 <winsdk_lib_um_x64> <out_dir>}"

mkdir -p "$OUT"

LIBS=(
    advapi32
    ole32
    user32
    ws2_32
    uuid
    oleaut32
    shlwapi
)

for name in "${LIBS[@]}"; do
    # Find the real file (case-insensitive search). -quit, not `| head -1`:
    # with several matches (a staged SDK has lower-case aliases too) head
    # closes the pipe early and find's SIGPIPE fails the script (pipefail)
    real=$(find "$SRC" -maxdepth 1 -iname "${name}.lib" -print -quit)
    if [[ -z "$real" ]]; then
        echo "WARNING: ${name}.lib not found in $SRC — skipping"
        continue
    fi
    target="$OUT/${name}.lib"
    if [[ ! -e "$target" ]]; then
        ln -s "$real" "$target"
        echo "  symlink: ${name}.lib -> $real"
    fi
done

echo "Lib symlinks ready in $OUT"
