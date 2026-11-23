# Installs (or re-installs after a game or mod update) the Witchspire Dedicated Server + Co-op Overhaul mod.
# Every player and the server machine need the same mod version: gameplay scripts must match exactly.
#
# payload\Script\Mods\...   the mod's own scripts (copied as they are)
# payload\Patches\*.json    exact line patches for the game scripts the mod changes; each is applied to the
#                           original game file and the result is checked against the expected SHA-256.
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$mod = $PSScriptRoot
$gameRoot = Split-Path -Parent $mod
$game = Join-Path $gameRoot 'Hercules\Script'
$payload = Join-Path $mod 'payload'
$backup = Join-Path $mod 'backup\Script'

# Only processes started from THIS Witchspire folder (game or its dedicated server) block the install.
$running = @(Get-Process -Name 'Hercules-Win64-Shipping' -ErrorAction SilentlyContinue | Where-Object {
    -not $_.Path -or $_.Path.StartsWith($gameRoot, [StringComparison]::OrdinalIgnoreCase)
})
if ($running.Count -gt 0) {
    throw 'Witchspire (game or dedicated server) is running. Close it first, then run this again.'
}
if (-not (Test-Path (Join-Path $game 'Core'))) { throw "Witchspire scripts not found at $game. Put the WitchspireCoopMod folder inside the Witchspire install folder." }

$Latin1 = [Text.Encoding]::GetEncoding(28591)   # byte-for-byte text

function Get-Sha256Bytes([byte[]]$bytes) {
    # .NET directly: Get-FileHash is unavailable when Windows PowerShell inherits a PowerShell 7 module path.
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '') } finally { $sha.Dispose() }
}
function Get-Sha256([string]$path) { return Get-Sha256Bytes ([IO.File]::ReadAllBytes($path)) }

# Applies a patch to the original file's bytes; returns the patched bytes (verified) or throws.
function Build-Patched($patch, [string]$originalPath) {
    $text = $Latin1.GetString([IO.File]::ReadAllBytes($originalPath))
    $lines = @([regex]::Matches($text, '[^\n]*\n|[^\n]+') | ForEach-Object { $_.Value })
    $out = New-Object System.Text.StringBuilder
    $pos = 0
    foreach ($h in @($patch.hunks)) {
        $at = [int]$h.at
        for ($i = $pos; $i -lt $at; $i++) { [void]$out.Append($lines[$i]) }
        $remove = @($h.remove)
        for ($k = 0; $k -lt $remove.Count; $k++) {
            if ($lines[$at + $k] -cne $remove[$k]) { throw "Patch for $($patch.path) does not match the game file." }
        }
        foreach ($line in @($h.add)) { [void]$out.Append($line) }
        $pos = $at + $remove.Count
    }
    for ($i = $pos; $i -lt $lines.Count; $i++) { [void]$out.Append($lines[$i]) }
    $bytes = $Latin1.GetBytes($out.ToString())
    if ((Get-Sha256Bytes $bytes) -ne $patch.patched) { throw "Patch for $($patch.path) produced an unexpected result." }
    return , $bytes
}

# 1. Check every game script the mod patches BEFORE changing anything.
$patchDir = Join-Path $payload 'Patches'
$plan = @()
$mismatch = 0
foreach ($file in Get-ChildItem -Recurse -File -Filter '*.json' $patchDir) {
    $patch = Get-Content -Raw $file.FullName | ConvertFrom-Json
    $rel = $patch.path -replace '/', '\'
    $live = Join-Path $game $rel
    $bk = Join-Path $backup $rel
    $hash = if (Test-Path $live) { Get-Sha256 $live } else { '' }
    $backupIsVanilla = (Test-Path $bk) -and ((Get-Sha256 $bk) -eq $patch.vanilla)
    if ($hash -eq $patch.patched) { $plan += @{ Rel = $rel; Action = 'current'; Patch = $patch } }
    elseif ($hash -eq $patch.vanilla) { $plan += @{ Rel = $rel; Action = 'patch'; Patch = $patch; Source = $live } }
    # Patched by an earlier version of this mod: the saved original still matches this game version.
    elseif ($backupIsVanilla) { $plan += @{ Rel = $rel; Action = 'upgrade'; Patch = $patch; Source = $bk } }
    else { Write-Host "  CHANGED BY GAME UPDATE  $rel" -ForegroundColor Yellow; $mismatch++ }
}
if ($mismatch -gt 0 -and -not $Force) {
    Write-Host "$mismatch game file(s) differ from the version this mod was built for. Nothing was changed - an updated mod version is needed." -ForegroundColor Red
    exit 1
}
# Build every patched file in memory first, so a bad patch changes nothing.
foreach ($p in $plan) {
    if ($p.Action -ne 'current') { $p.Bytes = Build-Patched $p.Patch $p.Source }
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

# 3. Patched game scripts (an unmodified original is backed up first; an upgrade keeps the saved original).
foreach ($p in $plan) {
    $rel = $p.Rel
    if ($p.Action -eq 'current') { Write-Host "  up to date   $rel"; continue }
    $live = Join-Path $game $rel
    if ($p.Action -eq 'patch') {
        $bk = Join-Path $backup $rel
        New-Item -ItemType Directory -Force (Split-Path -Parent $bk) | Out-Null
        Copy-Item $live $bk -Force
    }
    [IO.File]::WriteAllBytes($live, $p.Bytes)
    $verb = if ($p.Action -eq 'upgrade') { 'upgraded ' } else { 'patched  ' }
    Write-Host "  $verb   $rel" -ForegroundColor Green
}
Write-Host 'Install complete.' -ForegroundColor Green
