<#
LangTechDepot installer (Windows).

Installs Syncthing, registers this machine with the LangTechDepot server using the
token you were issued, and leaves you at the folder catalog. Idempotent.

Right-click this file and choose "Run with PowerShell".

No token yet? Register at the URL below and one is emailed to you.
#>

$ErrorActionPreference = 'Stop'

$RegisterUrl = 'https://depot.langtech.cloud'

$HomeDir  = Join-Path $env:LOCALAPPDATA 'LangTechDepot\config'
$DataRoot = Join-Path $env:USERPROFILE 'LangTechDepot'
$GuiUrl   = 'http://127.0.0.1:8384'

New-Item -ItemType Directory -Force $HomeDir, $DataRoot | Out-Null

# Syncthing is installed by winget or placed here by hand, never fetched by
# this script: antivirus dropper heuristics flag scripts that pull down an
# executable and then register it for startup.
function Find-Syncthing {
    $local = Join-Path $PSScriptRoot 'syncthing.exe'
    if (Test-Path $local) { return $local }
    $cmd = Get-Command syncthing.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $shim = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\syncthing.exe'
    if (Test-Path $shim) { return $shim }
    return $null
}

$Exe = Find-Syncthing
if (-not $Exe) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host 'Installing Syncthing via winget...'
        winget install --id Syncthing.Syncthing --silent --accept-source-agreements --accept-package-agreements
        $Exe = Find-Syncthing
    }
    if (-not $Exe) {
        throw "Syncthing not found. Get it from https://syncthing.net/downloads/, put syncthing.exe next to this script, and re-run."
    }
}
Write-Host "Using Syncthing at $Exe"

if (-not (Test-Path (Join-Path $HomeDir 'config.xml'))) {
    & $Exe generate --home $HomeDir --no-default-folder | Out-Null
}
$ApiKey = ([xml](Get-Content (Join-Path $HomeDir 'config.xml'))).configuration.gui.apikey
$Headers = @{ 'X-API-Key' = $ApiKey }

# Start at logon through Task Scheduler - per-user, no service install, no admin.
$TaskName = 'LangTechDepot'
$action  = New-ScheduledTaskAction -Execute $Exe -Argument "serve --no-console --no-browser --home `"$HomeDir`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host 'Waiting for Syncthing...'
$deadline = (Get-Date).AddSeconds(60)
while ($true) {
    try { Invoke-RestMethod "$GuiUrl/rest/system/status" -Headers $Headers | Out-Null; break }
    catch {
        if ((Get-Date) -gt $deadline) { throw 'Syncthing did not start within 60s.' }
        Start-Sleep 2
    }
}

$MyId = (Invoke-RestMethod "$GuiUrl/rest/system/status" -Headers $Headers).myID
$DeviceName = "$env:USERNAME-$env:COMPUTERNAME"

# Name this device for the cluster. It deliberately carries no token: Syncthing
# broadcasts device names to every peer, so a token here would leak to them all.
Invoke-RestMethod -Method Patch "$GuiUrl/rest/config/devices/$MyId" -Headers $Headers -ContentType 'application/json' `
    -Body (@{ name = $DeviceName } | ConvertTo-Json) | Out-Null

Write-Host ''
Write-Host "This machine's device ID: $MyId"
Write-Host "No token yet? Register at $RegisterUrl"
Write-Host ''

$Registration = $null
foreach ($attempt in 1..3) {
    $token = (Read-Host 'Paste your LangTechDepot token').Trim()
    if (-not $token) { Write-Host 'Nothing entered.'; continue }

    $payload = @{ token = $token; deviceID = $MyId; deviceName = $DeviceName } | ConvertTo-Json
    try {
        $Registration = Invoke-RestMethod -Method Post "$RegisterUrl/register" `
            -ContentType 'application/json' -Body $payload
        break
    } catch {
        $reason = 'could not reach the registration server'
        if ($_.ErrorDetails.Message) {
            try { $reason = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { }
        }
        Write-Host "Registration failed: $reason"
        if ($attempt -lt 3) { Write-Host 'Try again.' }
    }
}

if (-not $Registration) {
    Write-Host ''
    Write-Host 'Giving up after 3 attempts. Syncthing is installed and running; re-run this'
    Write-Host "script once you have a working token. Ask for help at $RegisterUrl"
    exit 1
}

# The server tells us its own identity, so nothing about it is hardcoded here.
# introducer=true: the server introduces us to other field machines, so they
# swarm with each other instead of every download crossing the ocean.
try {
    Invoke-RestMethod -Method Post "$GuiUrl/rest/config/devices" -Headers $Headers -ContentType 'application/json' `
        -Body (@{
            deviceID   = $Registration.serverDeviceID
            name       = 'LangTechDepot Server'
            addresses  = @($Registration.serverAddresses)
            introducer = $true
        } | ConvertTo-Json) | Out-Null
} catch {
    Write-Host 'Server device was already configured; leaving it as is.'
}

# Receive-only: a stray local edit gets flagged and reverted, never propagated.
Invoke-RestMethod -Method Patch "$GuiUrl/rest/config/defaults/folder" -Headers $Headers -ContentType 'application/json' `
    -Body (@{ type = 'receiveonly'; path = $DataRoot } | ConvertTo-Json) | Out-Null

Write-Host ''
Write-Host 'Registered.'
Write-Host "Sync data root: $DataRoot"
Write-Host 'The folder catalog will appear within a minute or two.'
Write-Host 'Click Add on the folders you want in the browser window that opens.'
Start-Process $GuiUrl
