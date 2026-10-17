# disk_space.ps1 — CI diagnostics on Windows runners: free space per drive,
# the WSL distributions' virtual disks (the Docker build lives in them) and the
# file system usage inside WSL. Never fails the job.
Get-PSDrive -PSProvider FileSystem |
    Where-Object { $_.Used -ne $null } |
    ForEach-Object {
        "{0}:  used {1,7:N1} GB  free {2,7:N1} GB" -f $_.Name, ($_.Used / 1GB), ($_.Free / 1GB)
    }

# WSL distributions record their directory in the registry (none on a cache hit)
$distros = Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object { $_.DistributionName }
foreach ($d in $distros) {
    if ($d.BasePath -and (Test-Path $d.BasePath)) {
        $size = (Get-ChildItem $d.BasePath -Recurse -File -ErrorAction SilentlyContinue |
                 Measure-Object Length -Sum).Sum
        "WSL {0}: {1:N1} GB of virtual disk" -f $d.DistributionName, ($size / 1GB)
        wsl.exe -d $d.DistributionName -- df -h / 2>$null
    }
}
exit 0
