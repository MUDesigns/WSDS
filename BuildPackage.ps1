# Developer tool: snapshots the mod into this folder's package layout.
#   payload\Script\Mods\...        the mod's own scripts (copied as-is by Install.ps1)
#   payload\Patches\<path>.json    exact line patches for the game scripts the mod changes (see
#                                  source\build\make_patches.py); built from the originals in backup\Script
#                                  (taken before the first edit) and the modified scripts.
# -ScriptRoot: the Hercules\Script folder holding the modified scripts (default: this game install).
param([string]$ScriptRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Hercules\Script'))
$ErrorActionPreference = 'Stop'
$mod = $PSScriptRoot
$payload = Join-Path $mod 'payload'
$originals = Join-Path $mod 'backup\Script'

$staging = Join-Path ([IO.Path]::GetTempPath()) "wscoop-patched-$PID"
New-Item -ItemType Directory -Force $staging | Out-Null
try {
    foreach ($orig in Get-ChildItem -Recurse -File $originals) {
        $rel = $orig.FullName.Substring($originals.Length + 1)
        $dest = Join-Path $staging $rel
        New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
        Copy-Item (Join-Path $ScriptRoot $rel) $dest
    }
    if (Test-Path $payload) { Remove-Item -Recurse -Force $payload }
    New-Item -ItemType Directory -Force $payload | Out-Null
    Copy-Item -Recurse (Join-Path $ScriptRoot 'Mods') (Join-Path $payload 'Script\Mods')
    python -I (Join-Path $mod 'source\build\make_patches.py') $originals $staging (Join-Path $payload 'Patches')
    if ($LASTEXITCODE) { throw 'make_patches.py failed' }
} finally {
    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
}
Write-Host "Packaged $((Get-ChildItem -Recurse -File (Join-Path $payload 'Script\Mods')).Count) mod scripts and $((Get-ChildItem -Recurse -File (Join-Path $payload 'Patches')).Count) game script patches."
