# Developer tool: uploads files to a Nexus Mods mod page with the Nexus Mods v3 API (Upload API).
# The API key is read from a file (never pass it on the command line or commit it).
#   .\NexusUpload.ps1 -KeyFile $env:USERPROFILE\nexus-api-key.txt -ModId 62 -Version 0.0.1
param(
    [Parameter(Mandatory)] [string]$KeyFile,
    [string]$Game = 'witchspire',
    [Parameter(Mandatory)] [int]$ModId,
    [Parameter(Mandatory)] [string]$Version,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$api = 'https://api.nexusmods.com/v3'
$key = (Get-Content -Raw $KeyFile).Trim()
$headers = @{ apikey = $key; 'User-Agent' = 'WSDS-NexusUpload/0.0.1' }
$dist = Join-Path $PSScriptRoot 'dist'
$stage = Join-Path $dist 'nexus'
New-Item -ItemType Directory -Force $stage | Out-Null

function Zip-One([string]$src, [string]$zipName) {
    $zip = Join-Path $stage $zipName
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path $src -DestinationPath $zip -CompressionLevel Optimal
    return $zip
}

$files = @(
    @{ Path = (Zip-One (Join-Path $dist 'Witchspire Co-op Mod Setup.exe') "Witchspire-Coop-Mod-Setup-$Version.zip")
       Name = 'Co-op Overhaul Setup (players)'; Category = 'main'
       Description = 'Setup program for players: finds your Steam copy of Witchspire and installs the Co-op Overhaul (adds Join Dedicated Server to the main menu). Run it again to update or uninstall.' },
    @{ Path = (Zip-One (Join-Path $dist 'WSDS Setup.exe') "WSDS-Setup-$Version.zip")
       Name = 'WSDS Setup (dedicated server)'; Category = 'main'
       Description = 'Setup program for the server machine: downloads Witchspire with SteamCMD, installs the mod and the WSDS control panel, opens firewall ports and installs a background service.' },
    @{ Path = (Copy-Item (Join-Path $dist "WitchspireCoopMod-$Version-manual.zip") (Join-Path $stage "WitchspireCoopMod-$Version-manual.zip") -PassThru -Force).FullName
       Name = 'Manual install (no setup program)'; Category = 'optional'
       Description = 'The WitchspireCoopMod folder: extract it into your Witchspire folder (next to Hercules) and run Install.ps1. Same mod as the setup program.' }
)

function Api([string]$method, [string]$path, $body) {
    $p = @{ Method = $method; Uri = "$api$path"; Headers = $headers; ContentType = 'application/json' }
    if ($null -ne $body) { $p.Body = ($body | ConvertTo-Json -Depth 6 -Compress) }
    try { return Invoke-RestMethod @p }
    catch {
        $detail = $_.ErrorDetails.Message
        throw "$method $path failed: $($_.Exception.Message) $detail"
    }
}

Write-Host "Looking up $Game mod $ModId..." -ForegroundColor Yellow
$mod = (Api GET "/games/$Game/mods/$ModId" $null).data
Write-Host "  mod '$($mod.name)' id=$($mod.id)"
$existing = @((Api GET "/mods/$($mod.id)/files" $null).data.mod_files)
Write-Host "  $($existing.Count) file(s) already on the page"

foreach ($f in $files) {
    $item = Get-Item $f.Path
    Write-Host "`n=== $($f.Name)  ($([math]::Round($item.Length / 1MB, 1)) MB)" -ForegroundColor Yellow
    if ($existing | Where-Object { $_.name -eq $f.Name }) { Write-Host '  already uploaded - skipped'; continue }
    if ($DryRun) { Write-Host '  dry run - not uploaded'; continue }

    $up = (Api POST '/uploads/multipart' @{ filename = $item.Name; size_bytes = [string]$item.Length }).data
    Write-Host "  upload session $($up.id): $($up.part_presigned_urls.Count) part(s)"
    $fs = [IO.File]::OpenRead($item.FullName)
    $parts = @()
    try {
        $buf = New-Object byte[] $up.part_size_bytes
        for ($i = 0; $i -lt $up.part_presigned_urls.Count; $i++) {
            $n = $fs.Read($buf, 0, $buf.Length)
            $chunk = if ($n -lt $buf.Length) { $buf[0..($n - 1)] } else { $buf }
            $r = Invoke-WebRequest -Method Put -Uri $up.part_presigned_urls[$i] -Body ([byte[]]$chunk) -ContentType 'application/octet-stream' -UseBasicParsing
            $etag = ($r.Headers['ETag'] | Select-Object -First 1) -replace '"', ''
            $parts += "  <Part>`n    <PartNumber>$($i + 1)</PartNumber>`n    <ETag>$etag</ETag>`n  </Part>"
            Write-Host "  part $($i + 1)/$($up.part_presigned_urls.Count) sent ($n bytes)"
        }
    } finally { $fs.Dispose() }
    $xml = "<CompleteMultipartUpload>`n$($parts -join "`n")`n</CompleteMultipartUpload>"
    Invoke-WebRequest -Method Post -Uri $up.complete_presigned_url -Body $xml -ContentType 'application/xml' -UseBasicParsing | Out-Null
    Api POST "/uploads/$($up.id)/finalise" $null | Out-Null
    Write-Host '  finalised; waiting for virus scan...'
    for ($t = 0; $t -lt 90; $t++) {
        $state = (Api GET "/uploads/$($up.id)" $null).data.state
        if ($state -eq 'available') { break }
        Start-Sleep 2
    }
    if ($state -ne 'available') { throw "upload $($up.id) ended in state '$state'" }

    $file = (Api POST '/mod-files' @{
            upload_id = $up.id; mod_id = $mod.id; name = $f.Name; version = $Version; description = $f.Description
            file_category = $f.Category; primary_mod_manager_download = $false; allow_mod_manager_download = $false
            show_requirements_pop_up = $false; update_mod_version = $true
        }).data
    Write-Host "  created mod file $($file.id)" -ForegroundColor Green
}
Write-Host "`nDone. Check https://www.nexusmods.com/$Game/mods/${ModId}?tab=files" -ForegroundColor Green
