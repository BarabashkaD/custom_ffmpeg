# windows_stage.ps1 -Out <dir> [-Deps]
# CI, Windows: pack what every compile and link in the container reads — the
# Windows SDK and MSVC headers/libraries, compat/ and (-Deps, FFmpeg jobs) the
# dependency tree — into a few tar files on the Windows side (native NTFS).
# The WSL step unpacks them onto WSL's ext4 and mounts them into the container
# at the usual paths (/winsdk/kits, /winsdk/msvc, /src/compat,
# /artifacts/.deps/<platform>): read through WSL's 9p drive mounts, every
# #include of every compile was a slow round trip to Windows.
# Needs KITS_ROOT, MSVC_ROOT, WINSDK_VERSION from windows_config.ps1.
param(
    [Parameter(Mandatory)][string]$Out,
    [switch]$Deps
)
$ErrorActionPreference = "Stop"
# Windows' own bsdtar (Git's GNU tar may come first on PATH)
$tar = Join-Path $env:SystemRoot "System32\tar.exe"
New-Item -ItemType Directory -Force $Out | Out-Null

function Pack([string]$name, [string]$dir, [string[]]$tarArgs) {
    $file = Join-Path $Out "$name.tar"
    & $tar -cf $file -C $dir @tarArgs
    if ($LASTEXITCODE -ne 0) { Write-Error "tar failed: $name"; exit 1 }
    "{0,-8} {1,7:N0} MB" -f $name, ((Get-Item $file).Length / 1MB)
}

$v = $env:WINSDK_VERSION
Pack kits $env:KITS_ROOT @(
    "Include/$v/ucrt", "Include/$v/um", "Include/$v/shared", "Include/$v/winrt",
    "Lib/$v/ucrt/x64", "Lib/$v/um/x64")
# lib/x64 without what a native C/C++ link never uses: PDBs, /clr:pure CRT,
# .NET Core variants, clang fuzzer runtimes, Store/UWP/enclave libraries
Pack msvc $env:MSVC_ROOT @(
    "--exclude", "lib/x64/*.pdb", "--exclude", "lib/x64/msvcurt*",
    "--exclude", "lib/x64/*_netcore*", "--exclude", "lib/x64/clang_rt.*",
    "--exclude", "lib/x64/store", "--exclude", "lib/x64/uwp", "--exclude", "lib/x64/enclave",
    "include", "lib/x64")
Pack compat (Resolve-Path compat).Path @(".")
if ($Deps) {
    # headers, libraries, .pc files and license texts — not the deps' tools
    # and test programs
    $root = (Resolve-Path prebuilt/.deps/windows-x64).Path
    $parts = @("include", "lib") + @("share/licenses" | Where-Object { Test-Path (Join-Path $root $_) })
    Pack deps $root $parts
}
