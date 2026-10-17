# run.ps1 — build and run the consumer test against one prebuilt variant with
# MSVC: {C, C++} x {Release, Debug}.
#
#   .\tests\consumer\run.ps1 -FFmpegRoot prebuilt\windows-x64\static\full [-BuildDir tmp\consumer]
#
# Every combination must build, link and run — including C++ Debug (/MDd) against
# a static build with C++ dependencies (x265, libvpl): FindCustomFFmpeg links
# their debug-runtime copies (<deps>/lib/debug) into /MDd targets. For such a
# build one more C++ tree swaps the runtimes (Debug: /MD, Release: /MDd), so the
# choice must follow the runtime, not the configuration name. A link that
# reports LNK2038 (runtime mismatch) or LNK4098 (conflicting default C
# runtime libraries) fails the test.
#
# The test builds with the toolset the libraries were built with (-Toolset,
# default v143): the newest Visual Studio that has it — VS 2022, or VS 2026
# with its v143 component (needs CMake >= 4.2 for that generator) — unless
# -Generator names one.
param(
    [Parameter(Mandatory)][string]$FFmpegRoot,
    [string]$BuildDir = "tmp/consumer",
    [string]$Generator = "",
    [string]$Toolset = "v143"
)
$ErrorActionPreference = 'Stop'

$genArgs = @('-T', $Toolset)
if (-not $Generator) {
    $generators = @{ 17 = 'Visual Studio 17 2022'; 18 = 'Visual Studio 18 2026' }
    $known = (cmake --help) -join "`n"
    # v143 = MSVC 14.30-14.4x (v142 = 14.2x, v145 = 14.5x)
    $prefix = @{ v142 = '14.2'; v143 = '14.[34]'; v145 = '14.5' }[$Toolset]
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vs = & $vswhere -all -products * -format json | ConvertFrom-Json |
        Sort-Object { [version]$_.installationVersion } -Descending |
        Where-Object {
            $major = ([version]$_.installationVersion).Major
            $generators[$major] -and $known.Contains($generators[$major]) -and
            (Get-ChildItem "$($_.installationPath)\VC\Tools\MSVC" -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "^$prefix" -and (Test-Path "$($_.FullName)\bin\Hostx64\x64\cl.exe") })
        } | Select-Object -First 1
    if (-not $vs) { throw "no Visual Studio with the $Toolset toolset and a generator this CMake knows" }
    $Generator = $generators[([version]$vs.installationVersion).Major]
    $genArgs += "-DCMAKE_GENERATOR_INSTANCE=$($vs.installationPath)"
    Write-Host "Generator: $Generator, toolset $Toolset ($($vs.installationPath))"
}
$src = $PSScriptRoot
$root = (Resolve-Path $FFmpegRoot).Path
$name = (Split-Path (Split-Path $root -Parent) -Leaf) + '-' + (Split-Path $root -Leaf)   # e.g. static-full
$failed = 0

# <label> <build dir> <extra cmake args>
$trees = @(
    @{ Lang = 'C'; Dir = "$name-C"; Args = @('-DCONSUMER_CXX=OFF') },
    @{ Lang = 'CXX'; Dir = "$name-CXX"; Args = @('-DCONSUMER_CXX=ON') }
)

for ($t = 0; $t -lt $trees.Count; $t++) {
    $tree = $trees[$t]
    $b = Join-Path $BuildDir $tree.Dir
    cmake -S $src -B $b -G $Generator -A x64 @genArgs "-DCUSTOM_FFMPEG_ROOT=$root" @($tree.Args)
    if ($LASTEXITCODE -ne 0) { throw "configure failed: $name $($tree.Dir)" }
    $cache = Get-Content "$b/CMakeCache.txt"
    if ($tree.Lang -eq 'CXX' -and -not $tree.Swapped -and
        ($cache | Select-String 'CUSTOM_FFMPEG_DEP_(x265|vpl):FILEPATH=.+\.lib')) {
        # static + C++ deps: also check the runtime-based selection
        $trees += @{ Lang = 'CXX'; Dir = "$name-CXX-swap"; Swapped = $true
                     Args = @('-DCONSUMER_CXX=ON', '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded$<$<CONFIG:Release>:Debug>DLL') }
    }

    foreach ($config in 'Release', 'Debug') {
        $label = $tree.Lang
        if ($tree.Swapped) { $label += $(if ($config -eq 'Debug') { ' /MD' } else { ' /MDd' }) }
        $out = cmake --build $b --config $config 2>&1 | Out-String
        $ok = $LASTEXITCODE -eq 0
        Write-Host $out
        $bad = [regex]::Matches($out, 'LNK(2038|4098)[^\r\n]*') | ForEach-Object Value | Sort-Object -Unique
        if ($bad) {
            Write-Host "Linker reports a C runtime conflict:`n  $($bad -join "`n  ")"
            $ok = $false
        }
        if ($ok) {
            ctest --test-dir $b -C $config --output-on-failure
            $ok = $LASTEXITCODE -eq 0
        }
        Write-Host ("RESULT {0,-16} {1,-8} {2,-7} {3}" -f $name, $label, $config, $(if ($ok) { 'PASS' } else { 'FAIL' }))
        if (-not $ok) { $failed++ }
    }
}
if ($failed) { throw "$failed consumer test configuration(s) failed" }
