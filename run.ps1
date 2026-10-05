# run.ps1 — runs src/proxmox-enable-sensors.sh on a Proxmox host over SSH (Windows/PowerShell).
#
#   .\run.ps1 <host> [--setup] [proxmox-enable-sensors.sh options]
#
#   .\run.ps1 192.168.0.10 --setup      # installs lm-sensors/drivetemp and applies
#   .\run.ps1 192.168.0.10 --dry-run    # shows the diff, changes nothing
#   .\run.ps1 192.168.0.10              # applies
#   .\run.ps1 192.168.0.10 --status
#   .\run.ps1 192.168.0.10 --revert --purge
#
#   <host> without a user becomes root@<host>. Without <host>, uses $env:PVE_HOST.
#
# src/ is packed with tar.exe (built into Windows 10+) and sent through cmd
# redirection (binary): the PowerShell 5.1 pipe re-encodes data and would corrupt it.
# On the host it is unpacked into a temporary directory, run and removed.
$ErrorActionPreference = 'Stop'

$HostArg = $env:PVE_HOST
$rest = @($args)
if ($rest.Count -gt 0 -and -not "$($rest[0])".StartsWith('-')) {
    $HostArg = "$($rest[0])"
    $rest = @($rest | Select-Object -Skip 1)
}
if (-not $HostArg) {
    Get-Content $PSCommandPath -TotalCount 11 | Select-Object -Skip 1 | ForEach-Object { $_ -replace '^# ?', '' }
    exit 1
}
if ($HostArg -notlike '*@*') { $HostArg = "root@$HostArg" }

$Src = Join-Path $PSScriptRoot 'src'
if (-not (Test-Path (Join-Path $Src 'proxmox-enable-sensors.sh'))) { throw "$Src\proxmox-enable-sensors.sh not found" }

$Setup = $rest -contains '--setup'
$Opts = (@($rest | Where-Object { $_ -ne '--setup' }) -join ' ')

if ($Setup) {
    Write-Host "━━━ Prerequisites on $HostArg ━━━"
    $prereq = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! command -v sensors >/dev/null; then
  apt-get update -qq && apt-get install -y -qq lm-sensors
fi
sensors-detect --auto >/dev/null
modprobe drivetemp || echo "warning: drivetemp module unavailable (no SATA temperatures)"
grep -qx drivetemp /etc/modules || echo drivetemp >> /etc/modules
sensors -j >/dev/null && echo "lm-sensors ok"
'@
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, ($prereq -replace "`r`n", "`n"))
        cmd /c "ssh $HostArg `"bash -s`" < `"$tmp`""
        if ($LASTEXITCODE -ne 0) { throw "failed to install the prerequisites" }
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
} else {
    ssh -n $HostArg 'command -v sensors >/dev/null'
    if ($LASTEXITCODE -ne 0) { throw "lm-sensors is not installed on $HostArg — run again with --setup" }
}

$tar = [IO.Path]::GetTempFileName()
try {
    tar -C "$Src" -cf "$tar" .
    if ($LASTEXITCODE -ne 0) { throw "failed to pack $Src" }
    $remote = "d=`$(mktemp -d) && trap 'rm -rf `$d' EXIT && tar -xf - -C `$d && PVE_SENSORS_SELF='.\run.ps1 $HostArg' bash `$d/proxmox-enable-sensors.sh $Opts"
    cmd /c "ssh $HostArg `"$remote`" < `"$tar`""
    $rc = $LASTEXITCODE
} finally { Remove-Item $tar -ErrorAction SilentlyContinue }
exit $rc
