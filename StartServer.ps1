# Witchspire Dedicated Server launcher.
# Starts a headless (-nullrhi) host from ServerConfig.json and streams its log live in this window.
#   Hotkeys:  S = save now    Q / Ctrl+C = save + graceful shutdown
param(
    [string]$Config = (Join-Path $PSScriptRoot 'ServerConfig.json'),
    [switch]$AllLogs
)

$ErrorActionPreference = 'Stop'
try { $Host.UI.RawUI.WindowTitle = 'Witchspire Dedicated Server' } catch {}

$cfg = Get-Content -Raw -LiteralPath $Config | ConvertFrom-Json
$gameRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $gameRoot 'Hercules\Binaries\Win64\Hercules-Win64-Shipping.exe'))) {
    throw "Witchspire not found next to this folder (expected $gameRoot\Hercules)"
}
. (Join-Path $PSScriptRoot 'ServerInstall.ps1')

$dataDir = $cfg.ServerDataDir
if (-not [IO.Path]::IsPathRooted($dataDir)) { $dataDir = Join-Path $PSScriptRoot $dataDir }
$logDir = Join-Path $dataDir 'Logs'
$controlDir = Join-Path $dataDir 'Saved\WSDS'
New-Item -ItemType Directory -Force $logDir, $controlDir | Out-Null

$verbosity = if ($AllLogs) { 'all' } else { "$($cfg.ConsoleVerbosity)" }

# Lines that are pure noise in a headless host.
$noise = @(
    'Missing OutParms',
    'Cant find angelscript binding',
    'AddGameplayCueData_Internal',
    'NavData RegistrationFailed',
    'SetTimer passed a negative or zero time',
    'Steamworks: Steam',
    'SteamAPI failed to initialize',
    'Steam API failed to initialize',
    'Failed to find object',
    'invalid ShaderMap',
    'LogNiagara',
    'No auth service is available',
    'no usable authentication mechanism',
    'invalid or missing authentication token',
    'exhausted all possible methods of authenticating',
    'WSDS] Command line'
)
$important = 'WSDS|WSCoop|Error|Fatal|Critical|Assert|Login request|Join request|Join succeeded|Closing connection|NotifyAcceptingConnection|NotifyAcceptedConnection|LoadMap:|Browse:|EasyMultiSave|SaveSystem|InitListen|Listen|LogGameMode'

function Write-LogLine([string]$line) {
    foreach ($n in $noise) { if ($line.Contains($n)) { return } }
    if ($verbosity -ne 'all' -and $line -notmatch $important) { return }

    $color = 'Gray'
    if ($line -match 'Fatal|Critical|Assert|Angelscript: Error|: Error:') { $color = 'Red' }
    elseif ($line -match 'Warning') { $color = 'DarkYellow' }
    elseif ($line -match 'PLAYER JOINED|Join succeeded') { $color = 'Green' }
    elseif ($line -match 'PLAYER LEFT|Closing connection') { $color = 'Magenta' }
    elseif ($line -match 'SAVE|EasyMultiSave|SaveSystem') { $color = 'Cyan' }
    elseif ($line -match 'WSDS|WSCoop') { $color = 'White' }
    Write-Host $line -ForegroundColor $color
}

function Send-Control([string]$name) {
    New-Item -ItemType File -Force (Join-Path $controlDir $name) | Out-Null
}
function Clear-Control {
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $controlDir '*.request')
}

$logCmds = 'global Log, LogWSDS Verbose, LogNet Log, LogOnline Log, LogOnlineSession Verbose, LogRedpointEOSNetworking Verbose, LogEasyMultiSave Verbose, LogGameMode Verbose'

$interactive = -not [Console]::IsInputRedirected
if ($interactive) { [Console]::TreatControlCAsInput = $true }
$stopRequested = $false
$quickCrashes = 0

while ($true) {
    Clear-Control
    Write-Host 'Refreshing server install (junctions, archive links, server config pak)...' -ForegroundColor DarkGray
    $exe = Update-ServerInstall -GameRoot $gameRoot -ModRoot $PSScriptRoot
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logFile = Join-Path $logDir "server_$stamp.log"

    $argList = @(
        '-nullrhi', '-nosound', '-unattended', '-log',
        "-abslog=`"$logFile`"",
        "-UserDir=`"$dataDir`"",
        "-LogCmds=`"$logCmds`"",
        '-WSDedicated',
        "-WSSlot=`"$($cfg.WorldSlot)`"",
        "-WSWorldName=`"$($cfg.WorldName)`"",
        "-WSLevel=$($cfg.Level)",
        "-WSDifficulty=$($cfg.Difficulty)",
        "-WSAutoSave=$($cfg.AutoSaveSeconds)",
        "-WSHeartbeat=$($cfg.HeartbeatSeconds)",
        "-Port=$($cfg.Port)",
        "-WSTickRate=$($cfg.ServerTickRate)"
    )
    if ($cfg.ExtraArgs) { $argList += ("$($cfg.ExtraArgs)" -split ' ' | Where-Object { $_ }) }
    $coop = $cfg.Coop
    if ($coop) {
        foreach ($p in $coop.PSObject.Properties) { $argList += "-WSCoop_$($p.Name)=$($p.Value)" }
    }

    Write-Host "=== Witchspire Dedicated Server ===" -ForegroundColor Cyan
    Write-Host " World : $($cfg.WorldName)  (slot $($cfg.WorldSlot))"
    Write-Host " Port  : $($cfg.Port)/UDP     Data: $dataDir"
    Write-Host " Log   : $logFile"
    Write-Host " Keys  : [S] save now   [Q]/[Ctrl+C] save + stop" -ForegroundColor Yellow
    Write-Host ""

    $startedAt = Get-Date
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -PassThru -WindowStyle Hidden

    # Wait for the log file to appear, then tail it.
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Test-Path $logFile) -and -not $proc.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }

    $stream = $null; $reader = $null
    if (Test-Path $logFile) {
        $stream = [IO.File]::Open($logFile, 'Open', 'Read', 'ReadWrite,Delete')
        $reader = New-Object IO.StreamReader($stream)
    }

    $shutdownSentAt = $null
    while ($true) {
        if ($reader) {
            while ($null -ne ($line = $reader.ReadLine())) { Write-LogLine $line }
        }
        if ($proc.HasExited) { break }

        while ($interactive -and [Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            $isCtrlC = ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control))
            if ($isCtrlC -or $key.Key -eq 'Q') {
                if (-not $shutdownSentAt) {
                    Write-Host '>>> Graceful shutdown requested (saving world + players)...' -ForegroundColor Yellow
                    Send-Control 'shutdown.request'
                    $shutdownSentAt = Get-Date
                    $stopRequested = $true
                }
            }
            elseif ($key.Key -eq 'S') {
                Write-Host '>>> Save requested...' -ForegroundColor Yellow
                Send-Control 'save.request'
                Start-Sleep -Seconds 3
                Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $controlDir 'save.request')
            }
        }

        if ($shutdownSentAt -and ((Get-Date) - $shutdownSentAt).TotalSeconds -gt 90) {
            Write-Host '>>> Server did not exit within 90s - forcing termination.' -ForegroundColor Red
            Stop-Process -Id $proc.Id -Force
            break
        }
        Start-Sleep -Milliseconds 250
    }

    if ($reader) { while ($null -ne ($line = $reader.ReadLine())) { Write-LogLine $line }; $reader.Dispose() }
    $code = $proc.ExitCode
    if (Test-Path (Join-Path $controlDir 'shutdown.request')) { $stopRequested = $true }
    Write-Host "=== Server process exited (code $code) ===" -ForegroundColor Cyan

    if ($stopRequested -or -not $cfg.AutoRestartOnCrash) { break }
    if (((Get-Date) - $startedAt).TotalSeconds -lt 90) { $quickCrashes++ } else { $quickCrashes = 0 }
    if ($quickCrashes -ge 3) {
        Write-Host 'Server crashed 3 times in a row shortly after starting - not restarting again.' -ForegroundColor Red
        Write-Host "Check the log above / $logFile, fix the cause, then run StartServer again." -ForegroundColor Red
        break
    }
    Write-Host 'Unexpected exit - restarting in 10 seconds (press Q to cancel)...' -ForegroundColor Red
    $cancel = $false
    for ($i = 0; $i -lt 40; $i++) {
        if ($interactive -and [Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Q') { $cancel = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if ($cancel) { break }
}
Clear-Control
