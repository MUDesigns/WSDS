# Developer tool: builds the two setup programs into .\dist
#   "Witchspire Co-op Mod Setup.exe"  - players (mod only)
#   "WSDS Setup.exe"                  - dedicated server (SteamCMD download, WSDS, background service)
# Run BuildPackage.ps1 first so payload\ holds the current mod.
param([switch]$SkipWsds)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$mod = $PSScriptRoot
$src = Join-Path $mod 'source'
$inst = Join-Path $src 'installer'
$dist = Join-Path $mod 'dist'
New-Item -ItemType Directory -Force $dist, (Join-Path $inst 'payload') | Out-Null

function Step($t) { Write-Host "`n=== $t ===" -ForegroundColor Yellow }

if (-not $SkipWsds) {
    Step 'Building WSDS'
    Push-Location (Join-Path $src 'wsds'); cargo build --release; if ($LASTEXITCODE) { throw 'WSDS build failed' }; Pop-Location
}
$wsdsExe = Join-Path $src 'wsds\target\release\wsds.exe'

function New-Payload([string]$zipPath, [string[]]$files, [hashtable]$extra) {
    if (Test-Path $zipPath) { Remove-Item $zipPath }
    $zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
    try {
        $add = {
            param($full, $rel)
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $full, "WitchspireCoopMod/$($rel -replace '\\','/')", 'Optimal')
        }
        foreach ($f in $files) {
            $full = Join-Path $mod $f
            if (Test-Path $full -PathType Container) {
                foreach ($x in Get-ChildItem -Recurse -File $full) { & $add $x.FullName $x.FullName.Substring($mod.Length + 1) }
            } else { & $add $full $f }
        }
        foreach ($k in $extra.Keys) { & $add $extra[$k] $k }
    } finally { $zip.Dispose() }
    '{0}: {1:N1} MB, {2} files' -f (Split-Path -Leaf $zipPath), ((Get-Item $zipPath).Length / 1MB), ([IO.Compression.ZipFile]::OpenRead($zipPath).Entries.Count)
}

Step 'Packing payloads'
$common = @('Install.ps1', 'Uninstall.ps1', 'README.md', 'payload', 'tools')
New-Payload (Join-Path $inst 'payload\client.zip') ($common + @('ClientConfig.json', 'JoinServer.ps1', 'JoinServer.bat')) @{}
New-Payload (Join-Path $inst 'payload\server.zip') ($common + @('ServerInstall.ps1', 'StartServer.ps1', 'StartServer.bat')) @{ 'WSDS.exe' = $wsdsExe }

$flavors = @(
    @{ Feature = 'client'; Name = 'Witchspire Co-op Mod Setup'; Icons = 'icons-client' },
    @{ Feature = 'server'; Name = 'WSDS Setup'; Icons = 'icons-server' }
)
Push-Location $inst
try {
    foreach ($f in $flavors) {
        Step "Building $($f.Name)"
        $env:TAURI_CONFIG = (@{ productName = $f.Name; bundle = @{ icon = @("$($f.Icons)/icon.ico", "$($f.Icons)/icon.png") } } | ConvertTo-Json -Compress -Depth 4)
        $env:CARGO_TARGET_DIR = Join-Path $inst "target-$($f.Feature)"
        (Get-Item build.rs).LastWriteTime = Get-Date   # re-embed icon and version info
        cargo build --release --no-default-features --features $f.Feature
        if ($LASTEXITCODE) { throw "$($f.Name) build failed" }
        Copy-Item (Join-Path $env:CARGO_TARGET_DIR 'release\wscoop-installer.exe') (Join-Path $dist "$($f.Name).exe") -Force
    }
} finally {
    Remove-Item Env:TAURI_CONFIG, Env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue
    Pop-Location
}
Step 'Done'
Get-ChildItem $dist -Filter *.exe | ForEach-Object { '{0,-36} {1,6:N1} MB' -f $_.Name, ($_.Length / 1MB) }
