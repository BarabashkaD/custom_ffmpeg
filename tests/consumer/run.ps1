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
param(
    [Parameter(Mandatory)][string]$FFmpegRoot,
    [string]$BuildDir = "tmp/consumer",
    [string]$Generator = "Visual Studio 17 2022"
)
$ErrorActionPreference = 'Stop'
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
    cmake -S $src -B $b -G $Generator -A x64 "-DCUSTOM_FFMPEG_ROOT=$root" @($tree.Args)
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
