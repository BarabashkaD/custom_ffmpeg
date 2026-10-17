# build.ps1 — main entry point on Windows
# Usage:
#   .\scripts\build.ps1                                   # windows-x64, static, full
#   .\scripts\build.ps1 -Type shared -Profile lgpl        # -Type static|shared, -Profile full|lgpl|minimal
#   .\scripts\build.ps1 -OnlyDeps "x264 x265"             # dependencies only
#   .\scripts\build.ps1 -Test [-TestData <dir>]           # + all dependency tests and FATE
#   .\scripts\build.ps1 -Test -Jobs 2 -SkipDepTests       # FATE only, 2 parallel jobs (less RAM)
# Linux / macOS targets build natively: build/build_linux.sh, build/build_macos.sh
param(
    [string]$Platform       = "windows-x64",
    [string]$Type           = "static",
    [string]$Profile        = "full",
    [string]$ArtifactsDir   = "",
    [string]$OnlyDeps       = "",   # e.g. "x264" or "x264 x265" — skips FFmpeg build
    [switch]$RebuildImage,
    [switch]$Test,                  # all dependency tests + FATE (see section 5)
    [switch]$SkipDepTests,          # with -Test: FATE only (dependency tests already ran for this deps tree)
    [string]$TestData       = $env:CUSTOM_FFMPEG_TEST_DATA,   # fate-suite/, libvpx/, opus/ (tools/fetch_test_data.sh)
    [string]$WslDistro      = "",   # WSL distribution for FATE; default distribution if empty
    [string]$BuildVolume    = $(if ($env:CUSTOM_FFMPEG_BUILD_VOLUME) { $env:CUSTOM_FFMPEG_BUILD_VOLUME } else { "custom-ffmpeg-build" }),
    [int]$Jobs              = 0     # parallel compile jobs in the container and parallel test
                                    # processes on the host; 0 = all CPUs
)

$Root        = Resolve-Path "$PSScriptRoot\.."
$GenDir      = "$Root\generated"
$ConfigFile  = "$GenDir\$Platform-$Type-$Profile.env"
if (-not $ArtifactsDir) { $ArtifactsDir = "$Root\prebuilt" }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── 1. Docker image ───────────────────────────────────────────────────────────
$ImageName = "custom-ffmpeg-builder"
$existing  = docker images -q $ImageName 2>$null
if (-not $existing -or $RebuildImage) {
    Write-Host "Building Docker image '$ImageName'..."
    docker build -t $ImageName "$Root\docker"
} else {
    Write-Host "Docker image '$ImageName' exists. Use -RebuildImage to rebuild."
}

# ── 2. Generate .env config ───────────────────────────────────────────────────
Write-Host "Generating config: $ConfigFile"
New-Item -ItemType Directory -Force $GenDir | Out-Null

cmake `
    "-DTARGET_PLATFORM=$Platform" `
    "-DBUILD_TYPE=$Type" `
    "-DPROFILE=$Profile" `
    "-DOUTPUT_DIR=$GenDir" `
    "-DPROFILES_DIR=$Root\profiles" `
    -P "$Root\cmake\GenerateConfig.cmake"

# ── 3. Docker volumes ─────────────────────────────────────────────────────────
$Volumes = @(
    "-v", "${Root}:/src",
    "-v", "${ArtifactsDir}:/artifacts",
    "-v", "${GenDir}:/configs:ro"
)

if ($Platform -eq "windows-x64") {
    # Read cmake-generated JSON to get SDK mount paths (no execution policy required)
    $sdk = Get-Content "$GenDir\$Platform-$Type-$Profile.json" -Raw | ConvertFrom-Json
    $WINSDK_HOST_KITS_ROOT = $sdk.WINSDK_HOST_KITS_ROOT
    $MSVC_HOST_DIR         = $sdk.MSVC_HOST_DIR

    # 2 bind mounts — SDK version and sub-paths are resolved inside the container
    $Volumes += "-v", "${WINSDK_HOST_KITS_ROOT}:/winsdk/kits:ro"
    $Volumes += "-v", "${MSVC_HOST_DIR}:/winsdk/msvc:ro"

    # Build trees live on a named volume (native Linux FS inside Docker's VM):
    # compiling on the Windows bind mount is several times slower. The volume
    # persists between runs, so rebuilds stay incremental. -BuildVolume (or
    # CUSTOM_FFMPEG_BUILD_VOLUME) separates checkouts that build side by side.
    # Reset with: docker volume rm <volume>
    $Volumes += "-v", "${BuildVolume}:/build"

    Write-Host "Windows Kits: $WINSDK_HOST_KITS_ROOT"
    Write-Host "MSVC        : $MSVC_HOST_DIR"
}

# ── 4. Docker run ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Starting Docker build ($Platform / $Type / $Profile)..."

$DockerEnv = @()
if ($OnlyDeps) { $DockerEnv += "-e", "ONLY_DEPS=$OnlyDeps" }
if ($Test)     { $DockerEnv += "-e", "FFMPEG_TESTS=1" }
if ($Jobs -gt 0) { $DockerEnv += "-e", "JOBS=$Jobs" }

docker run --rm @Volumes @DockerEnv `
    $ImageName `
    bash /src/build/build_ffmpeg.sh "/configs/$Platform-$Type-$Profile.env"

if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker build failed (exit code $LASTEXITCODE)"
    exit $LASTEXITCODE
}

Write-Host ""

# ── 5. Tests — the Windows binaries run natively on this host ─────────────────
# Default: x264 checkasm. -Test: every dependency test (tests/deps) and FFmpeg's
# FATE: make + test scripts run in WSL, each .exe starts natively on Windows
# through WSL interop (tests/fate/run_fate.sh --windows).
if ($Platform -eq "windows-x64") {
    $python = if (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" } else { "python" }
    $DepsDir = "$ArtifactsDir\.deps\$Platform"
    $depArgs = @("$Root\tests\deps\run_dep_tests.py", $DepsDir)
    if ($TestData) { $depArgs += "--data", $TestData }
    if (-not $Test) { $depArgs += "--only", "x264" }
    if ($Jobs -gt 0) { $depArgs += "--jobs", $Jobs }

    if (-not ($Test -and $SkipDepTests)) {
        Write-Host "=== Dependency tests ==="
        & $python @depArgs
        if ($LASTEXITCODE -ne 0) { Write-Error "Dependency tests failed"; exit 1 }
    }

    if ($Test -and -not $OnlyDeps) {
        $variant = "ffmpeg-$Platform-$Type-$Profile"
        $wslArgs = if ($WslDistro) { @("-d", $WslDistro) } else { @() }
        $tree = & wsl @wslArgs wslpath -u ("$ArtifactsDir\.fate\$variant" -replace '\\', '/')
        $runner = & wsl @wslArgs wslpath -u ("$Root\tests\fate\run_fate.sh" -replace '\\', '/')
        $fateArgs = @($runner, $tree, "--windows")
        if ($Jobs -gt 0) { $fateArgs += "--jobs", $Jobs }
        if ($TestData -and (Test-Path "$TestData\fate-suite")) {
            $fateArgs += "--samples", (& wsl @wslArgs wslpath -u ("$TestData\fate-suite" -replace '\\', '/'))
        }
        Write-Host "=== FATE ($variant) ==="
        & wsl @wslArgs bash @fateArgs
        if ($LASTEXITCODE -ne 0) { Write-Error "FATE failed"; exit 1 }
    }
}

Write-Host "Done. Artifacts: $ArtifactsDir\$Platform\$Type\$Profile\"
