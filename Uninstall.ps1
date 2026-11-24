# Removes the mod: restores every original game script and deletes the mod's own scripts.
# Server data (ServerData\) and the server mirror (ServerInstall\) are left alone.
$ErrorActionPreference = 'Stop'
$mod = $PSScriptRoot
$gameRoot = Split-Path -Parent $mod
$game = Join-Path $gameRoot 'Hercules\Script'
$backup = Join-Path $mod 'backup\Script'
# Only this game folder counts (its game or its server mirror), not another Witchspire install.
$running = @(Get-Process -Name 'Hercules-Win64-Shipping' -ErrorAction SilentlyContinue | Where-Object {
    -not $_.Path -or $_.Path.StartsWith($gameRoot, [StringComparison]::OrdinalIgnoreCase)
})
if ($running.Count -gt 0) {
    throw 'Witchspire (game or dedicated server) is running. Close it first, then run this again.'
}
foreach ($orig in Get-ChildItem -Recurse -File $backup) {
    $rel = $orig.FullName.Substring($backup.Length + 1)
    Copy-Item $orig.FullName (Join-Path $game $rel) -Force
    Write-Host "  restored $rel"
}
foreach ($name in 'WSDedicated', 'WSCoop') {
    $dir = Join-Path $game "Mods\$name"
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir; Write-Host "  removed Mods\$name" }
}
$mods = Join-Path $game 'Mods'
if ((Test-Path $mods) -and -not (Get-ChildItem $mods)) { Remove-Item $mods }
Write-Host 'Uninstalled. (Steam > Verify integrity also restores all original files.)' -ForegroundColor Green
