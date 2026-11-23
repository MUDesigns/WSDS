# Installs (or re-installs after a game update) the Witchspire Dedicated Server + Co-op Overhaul mod.
# Every player and the server machine need the same mod version: gameplay scripts must match exactly.
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$mod = $PSScriptRoot
$game = Join-Path (Split-Path -Parent $mod) 'Hercules\Script'
$payload = Join-Path $mod 'payload'
$backup = Join-Path $mod 'backup\Script'
if (Get-Process -Name 'Hercules-Win64-Shipping' -ErrorAction SilentlyContinue) {
    throw 'Witchspire (game or dedicated server) is running. Close it first, then run this again.'
}
if (-not (Test-Path (Join-Path $game 'Core'))) { throw "Witchspire scripts not found at $game. Put the WitchspireCoopMod folder inside the Witchspire install folder." }

function Get-Sha256([string]$path) {
    # .NET directly: Get-FileHash is unavailable when Windows PowerShell inherits a PowerShell 7 module path.
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '') } finally { $fs.Dispose(); $sha.Dispose() }
}

# 1. Check every game script the mod patches BEFORE changing anything.
# Assign first: Windows PowerShell 5.1 emits a JSON array as ONE pipeline object.
$manifest = Get-Content -Raw (Join-Path $payload 'manifest.json') | ConvertFrom-Json
$plan = @()
$mismatch = 0
foreach ($e in @($manifest)) {
    $rel = $e.Path -replace '/', '\'
    $live = Join-Path $game $rel
    $hash = if (Test-Path $live) { Get-Sha256 $live } else { '' }
    $bk = Join-Path $backup $rel
    $backupIsVanilla = (Test-Path $bk) -and ((Get-Sha256 $bk) -eq $e.VanillaSha256)
    if ($hash -eq $e.PatchedSha256) { $plan += @{ Rel = $rel; Action = 'current' } }
    elseif ($hash -eq $e.VanillaSha256) { $plan += @{ Rel = $rel; Action = 'patch' } }
    # Patched by an earlier version of this mod: the saved original still matches this game version.
    elseif ($backupIsVanilla) { $plan += @{ Rel = $rel; Action = 'upgrade' } }
    elseif ($Force) { $plan += @{ Rel = $rel; Action = 'patch' } }
    else { Write-Host "  CHANGED BY GAME UPDATE  $rel" -ForegroundColor Yellow; $mismatch++ }
}
if ($mismatch -gt 0) {
    Write-Host "$mismatch game file(s) differ from the version this mod was built for. Nothing was changed - an updated mod version is needed." -ForegroundColor Red
    exit 1
}

# 2. New mod scripts.
$modsDst = Join-Path $game 'Mods'
foreach ($sub in Get-ChildItem (Join-Path $payload 'Script\Mods') -Directory) {
    $dst = Join-Path $modsDst $sub.Name
    New-Item -ItemType Directory -Force $dst | Out-Null
    $wanted = @{}
    foreach ($f in Get-ChildItem -Recurse -File $sub.FullName) {
        $rel = $f.FullName.Substring($sub.FullName.Length + 1)
        $wanted[$rel] = $true
        $target = Join-Path $dst $rel
        New-Item -ItemType Directory -Force (Split-Path -Parent $target) | Out-Null
        Copy-Item $f.FullName $target -Force
    }
    # Remove scripts left over from older mod versions.
    foreach ($f in Get-ChildItem -Recurse -File $dst) {
        if (-not $wanted.ContainsKey($f.FullName.Substring($dst.Length + 1))) { Remove-Item -Force $f.FullName }
    }
}
Write-Host 'Mod scripts installed.' -ForegroundColor Green

# 3. Patched game scripts (originals are backed up first).
foreach ($p in $plan) {
    $rel = $p.Rel
    if ($p.Action -eq 'current') { Write-Host "  up to date   $rel"; continue }
    $live = Join-Path $game $rel
    $bk = Join-Path $backup $rel
    # Only an unmodified game file is backed up; an upgrade keeps the original already saved.
    if ($p.Action -eq 'patch') {
        New-Item -ItemType Directory -Force (Split-Path -Parent $bk) | Out-Null
        Copy-Item $live $bk -Force
    }
    Copy-Item (Join-Path $payload "Patched\$rel") $live -Force
    $verb = if ($p.Action -eq 'upgrade') { 'upgraded ' } else { 'patched  ' }
    Write-Host "  $verb   $rel" -ForegroundColor Green
}
Write-Host 'Install complete.' -ForegroundColor Green
