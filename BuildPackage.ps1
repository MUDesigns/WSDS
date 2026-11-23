# Developer tool: snapshots the currently installed mod into this folder's package layout.
#   payload\Script\Mods\...          new mod scripts (copied as-is by Install.ps1)
#   payload\Patched\<path>           modified copies of game scripts
#   payload\manifest.json            per patched file: SHA-256 of the vanilla original and of the patched copy
# Originals come from backup\Script (taken before the first edit).
$ErrorActionPreference = 'Stop'
$mod = $PSScriptRoot
$game = Join-Path (Split-Path -Parent $mod) 'Hercules\Script'
$payload = Join-Path $mod 'payload'
if (Test-Path $payload) { Remove-Item -Recurse -Force $payload }
New-Item -ItemType Directory -Force $payload | Out-Null

Copy-Item -Recurse (Join-Path $game 'Mods') (Join-Path $payload 'Script\Mods')

$entries = @()
$backupRoot = Join-Path $mod 'backup\Script'
foreach ($orig in Get-ChildItem -Recurse -File $backupRoot) {
    $rel = $orig.FullName.Substring($backupRoot.Length + 1)
    $live = Join-Path $game $rel
    $dest = Join-Path $payload "Patched\$rel"
    New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
    Copy-Item $live $dest
    $entries += [pscustomobject]@{
        Path         = $rel -replace '\\', '/'
        VanillaSha256 = (Get-FileHash $orig.FullName -Algorithm SHA256).Hash
        PatchedSha256 = (Get-FileHash $live -Algorithm SHA256).Hash
    }
}
$entries | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $payload 'manifest.json')
Write-Host "Packaged $((Get-ChildItem -Recurse -File (Join-Path $payload 'Script\Mods')).Count) mod scripts and $($entries.Count) patched game files."
