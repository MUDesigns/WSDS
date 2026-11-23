# Joins a Witchspire dedicated server by IP using the settings in ClientConfig.json.
#
# The game is started directly (not through Steam) on purpose: started through Steam, the game logs in
# to Epic Online Services automatically, and an EOS-logged-in client refuses to join a direct-IP server.
# Your characters on the server are tied to this PC/Windows profile (a stable id is generated once and
# kept in your local save folder). Steam overlay and achievements are unavailable in these sessions.
param(
    [string]$Config = (Join-Path $PSScriptRoot 'ClientConfig.json'),
    [string]$Server,
    [string]$Name
)
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -Raw -LiteralPath $Config | ConvertFrom-Json
$address = if ($Server) { $Server } else { "$($cfg.ServerAddress):$($cfg.Port)" }
$player = if ($Name) { $Name } else { "$($cfg.PlayerName)" }

$exe = Join-Path (Split-Path -Parent $PSScriptRoot) 'Hercules\Binaries\Win64\Hercules-Win64-Shipping.exe'
if (-not (Test-Path $exe)) { throw "Game executable not found: $exe" }

Write-Host "Joining $address as '$player'..." -ForegroundColor Cyan
Start-Process -FilePath $exe -ArgumentList @("-WSConnect=$address", "-WSName=`"$player`"")
