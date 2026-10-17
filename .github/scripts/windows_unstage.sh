#!/usr/bin/env bash
# windows_unstage.sh <tar-dir> <stage-dir>
# CI, inside WSL: unpack the tars of windows_stage.ps1 (<name>.tar →
# <stage-dir>/<name>) onto WSL's ext4. The Windows SDK and MSVC name files in
# mixed case (kernel32.Lib, AdvAPI32.Lib, WinSock2.h) while builds ask for them
# in lower case: Windows file systems — and WSL's 9p view of them — ignore case,
# ext4 does not (and WSL's kernel has no casefold). So every file and directory
# with an upper-case letter in kits/ and msvc/ gets a lower-case symlink next to
# it, as cross toolchains for the MSVC SDK do (xwin, msvc-wine).
set -euo pipefail
tars="$1" stage="$2"

rm -rf "$stage"
for t in "$tars"/*.tar; do
    n=$(basename "$t" .tar)
    mkdir -p "$stage/$n"
    tar -xf "$t" -C "$stage/$n"
done

for tree in kits msvc; do
    [[ -d "$stage/$tree" ]] || continue
    # deepest first: a directory's alias is made after the entries below it
    find "$stage/$tree" -depth -name '*[A-Z]*' ! -type l | while IFS= read -r p; do
        dir=$(dirname "$p") name=$(basename "$p")
        lower=$(printf '%s' "$name" | tr 'A-Z' 'a-z')
        [[ -e "$dir/$lower" || -L "$dir/$lower" ]] || ln -s "$name" "$dir/$lower"
    done
done
# The headers also include each other with other spellings (kernelspecs.h:
# <DriverSpecs.h>, file driverspecs.h): every name an #include asks for gets a
# symlink next to each file whose name differs from it in case only.
hdr_dirs=()
for d in "$stage/kits/Include" "$stage/msvc/include"; do [[ -d "$d" ]] && hdr_dirs+=("$d"); done
if [[ ${#hdr_dirs[@]} -gt 0 ]]; then
    wanted=$(mktemp) files=$(mktemp)
    grep -rhoE '^[[:space:]]*#[[:space:]]*include[[:space:]]*[<"][^>"]+[>"]' "${hdr_dirs[@]}" \
        | sed -E 's/.*[<"]([^>"]+)[>"].*/\1/; s|.*/||' | sort -u > "$wanted"
    find "${hdr_dirs[@]}" -type f > "$files"
    awk -F'\t' 'NR == FNR { l = tolower($0); w[l] = (l in w) ? w[l] "\t" $0 : $0; next }
        { n = $0; sub(/.*\//, "", n); l = tolower(n); if (!(l in w)) next
          d = $0; sub(/\/[^\/]*$/, "", d); k = split(w[l], a, "\t")
          for (i = 1; i <= k; i++) if (a[i] != n) print d "\t" a[i] "\t" n }' "$wanted" "$files" \
        | while IFS=$'\t' read -r dir want real; do
            [[ -e "$dir/$want" || -L "$dir/$want" ]] || ln -s "$real" "$dir/$want"
        done
    rm -f "$wanted" "$files"
fi
echo "staged: $(du -sh "$stage" | cut -f1), $(find "$stage" -type l | wc -l) case aliases, in $stage"
