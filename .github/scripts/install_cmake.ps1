# install_cmake.ps1 -Version <x.y.z>
# CI, Windows: put an official CMake release first on PATH for the next steps.
# The runner's CMake (3.31) has no generator for Visual Studio 2026, which the
# windows-2025 image carries (CMake >= 4.2). Downloaded with the job's token
# (GH_TOKEN) from Kitware/CMake's GitHub release and checked against its
# SHA-256 list.
param([Parameter(Mandatory)][string]$Version)
$ErrorActionPreference = "Stop"

$dir = Join-Path $env:RUNNER_TEMP "cmake-$Version"
$zip = "cmake-$Version-windows-x86_64.zip"
$sums = "cmake-$Version-SHA-256.txt"
gh release download "v$Version" -R Kitware/CMake -p $zip -p $sums -D $dir --clobber
if ($LASTEXITCODE -ne 0) { exit 1 }

$expected = (Select-String -Path (Join-Path $dir $sums) -SimpleMatch " $zip").Line.Split(' ')[0]
$actual = (Get-FileHash -Algorithm SHA256 (Join-Path $dir $zip)).Hash
if (-not $expected -or $actual -ne $expected.ToUpper()) {
    Write-Error "SHA-256 mismatch for $zip"; exit 1
}
Expand-Archive (Join-Path $dir $zip) -DestinationPath $dir -Force
$bin = Join-Path $dir "cmake-$Version-windows-x86_64\bin"
$bin >> $env:GITHUB_PATH
& (Join-Path $bin cmake.exe) --version
