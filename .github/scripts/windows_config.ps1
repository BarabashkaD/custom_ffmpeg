# windows_config.ps1 -Type <static|shared> -Profile <name>
# CI, Windows host: generate the build config (cmake/GenerateConfig.cmake) and
# export the host toolchain to the following steps (GITHUB_ENV):
#   KITS_ROOT, MSVC_ROOT          SDK / MSVC dirs mounted into the container
#   MSVC_VERSION, WINSDK_VERSION  detected by cmake/FindWindowsSDK.cmake
#   WINSDK_BUILD                  servicing build of that SDK (10.1.26100.xxxx):
#                                 updates land in the same Include/<version> dir
#   WINTOOLS_HASH                 hash of a few MSVC / SDK files the outputs use
# The versions are part of the cache key (.github/scripts/cache_key.sh).
param(
    [Parameter(Mandatory)][string]$Type,
    [Parameter(Mandatory)][string]$Profile
)
$ErrorActionPreference = "Stop"

cmake -DTARGET_PLATFORM=windows-x64 "-DBUILD_TYPE=$Type" "-DPROFILE=$Profile" `
      -DOUTPUT_DIR=generated -DPROFILES_DIR=profiles -P cmake/GenerateConfig.cmake
if ($LASTEXITCODE -ne 0) { exit 1 }

$sdk = Get-Content -Raw "generated/windows-x64-$Type-$Profile.json" | ConvertFrom-Json
if (-not $sdk.WINSDK_HOST_KITS_ROOT -or -not $sdk.MSVC_HOST_DIR -or
    -not $sdk.WINSDK_VERSION -or -not $sdk.MSVC_VERSION) {
    Write-Error "Windows SDK / MSVC not detected"; exit 1
}

# The SDK installer's newest uninstall entry of this SDK line
$line = ($sdk.WINSDK_VERSION -split '\.')[2]
$build = Get-ItemProperty -ErrorAction SilentlyContinue `
        HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*,
        HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\* |
    Where-Object { $_.DisplayName -like 'Windows Software Development Kit*' -and
                   $_.DisplayVersion -like "10.1.$line.*" } |
    ForEach-Object { [version]$_.DisplayVersion } |
    Sort-Object -Descending | Select-Object -First 1
if (-not $build) {
    Write-Warning "Windows SDK servicing build not found in the registry"
    $build = "unknown"
}

# Content of files that end up in the outputs: in-place servicing of MSVC or the
# SDK changes them without renaming the version directories
$sdkLib = "$($sdk.WINSDK_HOST_KITS_ROOT)/Lib/$($sdk.WINSDK_VERSION)"
$files = @(
    "$($sdk.MSVC_HOST_DIR)/include/yvals_core.h",
    "$($sdk.MSVC_HOST_DIR)/lib/x64/msvcrt.lib",
    "$($sdk.MSVC_HOST_DIR)/lib/x64/msvcprt.lib",
    "$sdkLib/ucrt/x64/ucrt.lib",
    "$sdkLib/um/x64/kernel32.lib"
)
$hashes = foreach ($f in $files) {
    if (-not (Test-Path $f)) { Write-Error "toolchain file not found: $f"; exit 1 }
    (Get-FileHash -Algorithm SHA256 $f).Hash
}
$stream = [IO.MemoryStream]::new([Text.Encoding]::ASCII.GetBytes($hashes -join "`n"))
$toolsHash = (Get-FileHash -Algorithm SHA256 -InputStream $stream).Hash.Substring(0, 16).ToLower()

$vars = [ordered]@{
    KITS_ROOT      = $sdk.WINSDK_HOST_KITS_ROOT
    MSVC_ROOT      = $sdk.MSVC_HOST_DIR
    MSVC_VERSION   = $sdk.MSVC_VERSION
    WINSDK_VERSION = $sdk.WINSDK_VERSION
    WINSDK_BUILD   = "$build"
    WINTOOLS_HASH  = $toolsHash
}
foreach ($k in $vars.Keys) {
    "$k=$($vars[$k])" >> $env:GITHUB_ENV
    Write-Host ("{0,-15}: {1}" -f $k, $vars[$k])
}
