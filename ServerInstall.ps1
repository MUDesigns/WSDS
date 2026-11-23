# Builds / refreshes the dedicated-server install that StartServer.ps1 runs.
#
# The server install is a thin mirror of the real game folder:
#   * folders (Engine, Binaries, Plugins, Script, Movies, Splash) are directory junctions -> always current
#   * the pak/utoc/ucas archives are hardlinks (same volume, zero extra disk space), refreshed every launch
#   * Content/Paks/~mods holds a SERVER-ONLY config pak (WSServerConfig_P.pak)
#
# The server-only pak overrides Hercules/Config/DefaultEngine.ini with exactly one change:
#   [EpicOnlineServices] NetworkAuthenticationMode=Off
# A headless host has no EOS account and cannot verify EOS ID tokens, and joining clients refuse to send
# them over a direct-IP link. Cooked builds ignore user-level Engine.ini for this section, so the override
# must come from a pak. Because it lives only in the server mirror, players' own game installs are untouched.

function Update-ServerInstall {
    param(
        [Parameter(Mandatory)] [string]$GameRoot,
        [Parameter(Mandatory)] [string]$ModRoot
    )

    $srv = Join-Path $ModRoot 'ServerInstall'
    $repak = Join-Path $ModRoot 'tools\repak.exe'

    function Ensure-Junction([string]$link, [string]$target) {
        if (Test-Path -LiteralPath $link) {
            $item = Get-Item -LiteralPath $link -Force
            if ($item.LinkType -eq 'Junction' -and ($item.Target | Select-Object -First 1) -eq $target) { return }
            # Remove a stale junction (only the link, never the target's contents).
            if ($item.LinkType) { [IO.Directory]::Delete($link) } else { throw "Refusing to replace real folder: $link" }
        }
        New-Item -ItemType Directory -Force (Split-Path -Parent $link) | Out-Null
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    }

    Ensure-Junction (Join-Path $srv 'Engine')                    (Join-Path $GameRoot 'Engine')
    Ensure-Junction (Join-Path $srv 'Hercules\Binaries')         (Join-Path $GameRoot 'Hercules\Binaries')
    Ensure-Junction (Join-Path $srv 'Hercules\Plugins')          (Join-Path $GameRoot 'Hercules\Plugins')
    Ensure-Junction (Join-Path $srv 'Hercules\Script')           (Join-Path $GameRoot 'Hercules\Script')
    Ensure-Junction (Join-Path $srv 'Hercules\Content\Movies')   (Join-Path $GameRoot 'Hercules\Content\Movies')
    Ensure-Junction (Join-Path $srv 'Hercules\Content\Splash')   (Join-Path $GameRoot 'Hercules\Content\Splash')

    # Archives: hardlink each file (re-created every launch so Steam updates are always picked up).
    $srcPaks = Join-Path $GameRoot 'Hercules\Content\Paks'
    $dstPaks = Join-Path $srv 'Hercules\Content\Paks'
    New-Item -ItemType Directory -Force $dstPaks | Out-Null
    Get-ChildItem -LiteralPath $dstPaks -File | Remove-Item -Force
    foreach ($f in Get-ChildItem -LiteralPath $srcPaks -File) {
        New-Item -ItemType HardLink -Path (Join-Path $dstPaks $f.Name) -Target $f.FullName | Out-Null
    }

    # Server-only config pak, regenerated from the game's current DefaultEngine.ini.
    $mods = Join-Path $dstPaks '~mods'
    New-Item -ItemType Directory -Force $mods | Out-Null
    $stage = Join-Path $ModRoot 'tools\_pakstage'
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    $cfgDir = Join-Path $stage 'WSServerConfig_P'
    New-Item -ItemType Directory -Force $cfgDir | Out-Null

    $gamePak = Join-Path $srcPaks 'Hercules-Windows.pak'
    $ini = & $repak get $gamePak 'Hercules/Config/DefaultEngine.ini' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $ini) { throw "Could not read DefaultEngine.ini from $gamePak" }
    $text = ($ini -join "`r`n")
    if ($text -notmatch '(?m)^NetworkAuthenticationMode=') { throw 'NetworkAuthenticationMode not found in DefaultEngine.ini (game changed?)' }
    $text = [regex]::Replace($text, '(?m)^NetworkAuthenticationMode=.*$', 'NetworkAuthenticationMode=Off')
    # Raise the per-client bandwidth cap from the engine default (100 KB/s) for busy areas.
    $rates = "MaxClientRate=1500000`r`nMaxInternetClientRate=1500000`r`n"
    $text += "`r`n`r`n[/Script/RedpointEOSNetworking.RedpointEOSNetDriver]`r`n$rates"
    $text += "`r`n[/Script/OnlineSubsystemRedpointEOS.EOSNetDriver]`r`n$rates"
    $text += "`r`n[/Script/OnlineSubsystemUtils.IpNetDriver]`r`n$rates"
    $text += "`r`n[/Script/Engine.Player]`r`nConfiguredInternetSpeed=1500000`r`nConfiguredLanSpeed=1500000`r`n"
    [IO.File]::WriteAllText((Join-Path $cfgDir 'DefaultEngine.ini'), $text)

    $out = Join-Path $mods 'WSServerConfig_P.pak'
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $mods 'WSServerConfig_P.*')
    & $repak pack --version V11 --mount-point '../../../Hercules/Config/' -q $cfgDir $out | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { throw 'Failed to build WSServerConfig_P.pak' }
    # UE 5.7 IoStore builds silently skip a mod .pak that has no matching .utoc/.ucas, so build the
    # (empty) IoStore companion container as well. Without it the override is never mounted.
    $retoc = Join-Path (Join-Path $ModRoot 'tools') 'retoc.exe'
    & $retoc to-zen --version UE5_7 $out (Join-Path $mods 'WSServerConfig_P.utoc') 2>&1 | Out-Null
    if (-not (Test-Path (Join-Path $mods 'WSServerConfig_P.utoc'))) { throw 'Failed to build WSServerConfig_P.utoc' }
    Remove-Item -Recurse -Force $stage

    return (Join-Path $srv 'Hercules\Binaries\Win64\Hercules-Win64-Shipping.exe')
}
