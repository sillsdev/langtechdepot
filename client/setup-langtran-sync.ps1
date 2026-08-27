<#
LangTran Sync installer (Windows).

Installs Syncthing (via winget when available), runs it at logon, connects it
to the LangTran server, and opens the GUI so the user can pick which folders
to subscribe to. Idempotent: safe to re-run.

No admin rights needed - everything installs per-user.
To run: right-click this file and choose "Run with PowerShell".
#>

$ErrorActionPreference = 'Stop'

# ---- Fill these in after the server is stood up -----------------------------
$ServerDeviceId = 'REPLACE-WITH-SERVER-DEVICE-ID'
$ServerAddress  = 'tcp://sync.lingtransoft.info:22000'   # static address of the CA server
$JoinToken      = 'REPLACE-WITH-JOIN-TOKEN'
# -----------------------------------------------------------------------------

$HomeDir  = Join-Path $env:LOCALAPPDATA 'LangTranSync\config'
$DataRoot = Join-Path $env:USERPROFILE 'LangTran'        # where subscribed folders land
$GuiUrl   = 'http://127.0.0.1:8384'

if ($ServerDeviceId -like 'REPLACE-*' -or $JoinToken -like 'REPLACE-*') {
    throw 'Edit the ServerDeviceId / JoinToken variables at the top of this script first.'
}

New-Item -ItemType Directory -Force $HomeDir, $DataRoot | Out-Null

# Locate syncthing.exe: next to this script, already on PATH / winget shim,
# else install through winget. No raw binary downloads here on purpose -
# antivirus dropper heuristics flag download-and-persist scripts.
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
        throw 'Syncthing not found. Download it from https://syncthing.net/downloads/ and place syncthing.exe next to this script, then re-run.'
    }
}
Write-Host "Using Syncthing at $Exe"

if (-not (Test-Path (Join-Path $HomeDir 'config.xml'))) {
    & $Exe generate --home $HomeDir --no-default-folder | Out-Null
}
$ApiKey = ([xml](Get-Content (Join-Path $HomeDir 'config.xml'))).configuration.gui.apikey
$Headers = @{ 'X-API-Key' = $ApiKey }

# Run at logon via Task Scheduler - no service manager dependency, per-user.
$TaskName = 'LangTran Sync'
$action  = New-ScheduledTaskAction -Execute $Exe -Argument "serve --no-console --no-browser --home `"$HomeDir`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host 'Waiting for Syncthing API...'
$deadline = (Get-Date).AddSeconds(60)
while ($true) {
    try { Invoke-RestMethod "$GuiUrl/rest/system/status" -Headers $Headers | Out-Null; break }
    catch { if ((Get-Date) -gt $deadline) { throw 'Syncthing did not come up within 60s.' }; Start-Sleep 2 }
}

$myId = (Invoke-RestMethod "$GuiUrl/rest/system/status" -Headers $Headers).myID

# Name embeds the join token - the server's auto-accept poller keys on it.
Invoke-RestMethod -Method Patch "$GuiUrl/rest/config/devices/$myId" -Headers $Headers -ContentType 'application/json' `
    -Body (@{ name = "LT-$JoinToken-$env:USERNAME-$env:COMPUTERNAME" } | ConvertTo-Json)

# Server device: introducer=true makes this client auto-learn its peers (swarm).
Invoke-RestMethod -Method Post "$GuiUrl/rest/config/devices" -Headers $Headers -ContentType 'application/json' `
    -Body (@{
        deviceID   = $ServerDeviceId
        name       = 'LangTran Server'
        addresses  = @('dynamic', $ServerAddress)
        introducer = $true
    } | ConvertTo-Json)

# Folders accepted later default to receive-only under the LangTran data root.
Invoke-RestMethod -Method Patch "$GuiUrl/rest/config/defaults/folder" -Headers $Headers -ContentType 'application/json' `
    -Body (@{ type = 'receiveonly'; path = $DataRoot } | ConvertTo-Json)

Write-Host ''
Write-Host "Installed. Device ID: $myId"
Write-Host "Sync data root: $DataRoot"
Write-Host 'Within a minute or two the server will offer the folder catalog.'
Write-Host 'Accept the folders you want in the browser window that opens (Add buttons appear at the top).'
Start-Process $GuiUrl
