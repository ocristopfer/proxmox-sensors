# run.ps1 — roda o proxmox-enable-sensors.sh num host Proxmox via SSH (Windows/PowerShell).
#
#   .\run.ps1 <host> [--setup] [opções do proxmox-enable-sensors.sh]
#
#   .\run.ps1 192.168.0.10 --setup      # instala lm-sensors/drivetemp e aplica
#   .\run.ps1 192.168.0.10 --dry-run    # mostra o diff, não altera nada
#   .\run.ps1 192.168.0.10              # aplica
#   .\run.ps1 192.168.0.10 --status
#   .\run.ps1 192.168.0.10 --revert --purge
#
#   <host> sem usuário vira root@<host>. Sem <host>, usa $env:PVE_HOST.
#
# Os arquivos vão por redirecionamento do cmd (binário): o pipe do PowerShell 5.1
# re-codifica o texto e estragaria os acentos e os fins de linha do script.
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

$Script = Join-Path $PSScriptRoot 'proxmox-enable-sensors.sh'
if (-not (Test-Path $Script)) { throw "não achei $Script" }

$Setup = $rest -contains '--setup'
$Opts = (@($rest | Where-Object { $_ -ne '--setup' }) -join ' ')

if ($Setup) {
    Write-Host "━━━ Pré-requisitos em $HostArg ━━━"
    $prereq = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! command -v sensors >/dev/null; then
  apt-get update -qq && apt-get install -y -qq lm-sensors
fi
sensors-detect --auto >/dev/null
modprobe drivetemp || echo "aviso: modulo drivetemp indisponivel (sem temperatura de SATA)"
grep -qx drivetemp /etc/modules || echo drivetemp >> /etc/modules
sensors -j >/dev/null && echo "lm-sensors ok"
'@
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, ($prereq -replace "`r`n", "`n"))
        cmd /c "ssh $HostArg `"bash -s`" < `"$tmp`""
        if ($LASTEXITCODE -ne 0) { throw "falha instalando os pré-requisitos" }
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
} else {
    ssh -n $HostArg 'command -v sensors >/dev/null'
    if ($LASTEXITCODE -ne 0) { throw "lm-sensors não está instalado em $HostArg — rode de novo com --setup" }
}

cmd /c "ssh $HostArg `"bash -s -- $Opts`" < `"$Script`""
exit $LASTEXITCODE
