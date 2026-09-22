# LangTechDepot installer (Windows 11 PowerShell).
#
# Installs Syncthing, registers this machine with the LangTechDepot server 
# using the token you were issued, auto-subscribes to All_Contents_List, 
# and lets you choose folders to install or ignore. 
# Idempotent.

$ErrorActionPreference = "Stop"

# Path definitions
$REGISTER_URL = 'https://depot.langtech.cloud'$HELP_URL     = 'https://sillsdev.github.io/langtechdepot/help.html'

$DATA_ROOT   = Join-Path$HOME "LangTechDepot"
$BIN_DIR     = Join-Path$HOME ".local\bin"
$BIN         = Join-Path$BIN_DIR "syncthing.exe"

New-Item -ItemType Directory -Force -Path $DATA_ROOT,$BIN_DIR | Out-Null

# Prefer a system-wide installed Syncthing if present
$systemSyncthing = Get-Command "syncthing" -ErrorAction SilentlyContinue
if ($systemSyncthing) {
    $BIN =$systemSyncthing.Source
} elseif (-not (Test-Path $BIN)) {
    Write-Host "Downloading Syncthing for Windows..."
    
    $releaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/syncthing/syncthing/releases/latest"
    $asset = $releaseInfo.assets \vert{} Where-Object {$_.name -like "syncthing-windows-amd64-*.zip" } | Select-Object -First 1
    
    if (-not $asset) {
        Write-Error "Failed to find suitable Syncthing Windows 64-bit release."
        exit 1
    }

    $zipPath = Join-Path$env:TEMP "syncthing.zip"
    $extractPath = Join-Path$env:TEMP "syncthing_extract"

    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile$zipPath
    Expand-Archive -Path $zipPath -DestinationPath$extractPath -Force

    $extractedExe = Get-ChildItem -Path$extractPath -Filter "syncthing.exe" -Recurse | Select-Object -First 1
    Move-Item -Path $extractedExe.FullName -Destination$BIN -Force

    Remove-Item -Path $zipPath,$extractPath -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Using Syncthing at $BIN"

# State and config pathing pinned with --home
$CONFIG_DIR   = Join-Path$HOME ".local\state\langtechdepot"
$CATALOG_FILE = Join-Path$DATA_ROOT "All_Contents_List\LangTechDepotFiles.txt"

New-Item -ItemType Directory -Force -Path $CONFIG_DIR | Out-Null

$configFile = Join-Path$CONFIG_DIR "config.xml"
if (-not (Test-Path $configFile)) {
    Start-Process -FilePath $BIN -ArgumentList "generate", "--home", "`"$CONFIG_DIR`"" -NoNewWindow -Wait
}

# -----------------------------------------------------------------------------
# Background Persistence Setup (Windows Task Scheduler)
# -----------------------------------------------------------------------------
$taskName = "LangTechDepot_Syncthing"
$existingTask = Get-ScheduledTask -TaskName$taskName -ErrorAction SilentlyContinue

if (-not $existingTask) {
    Write-Host "Setting up background startup task for LangTechDepot..."
    $action = New-ScheduledTaskAction -Execute$BIN -Argument "serve --no-browser --home `"$CONFIG_DIR`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
    Register-ScheduledTask -TaskName $taskName -Action$action -Trigger $trigger -Settings$settings -Description "LangTechDepot Syncthing Service" | Out-Null
}

# Start Syncthing if it isn't running via task
$syncthingProcess = Get-Process -Name "syncthing" -ErrorAction SilentlyContinue
if (-not $syncthingProcess) {
    Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    # Fallback to direct process launch if task execution was denied/failed
    if (-not (Get-Process -Name "syncthing" -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $BIN -ArgumentList "serve", "--no-browser", "--home", "`"$CONFIG_DIR`"" -WindowStyle Hidden
    }
}

# Read XML Config
[xml]$xml = Get-Content -Path$configFile
$API_KEY  =$xml.configuration.gui.apikey
$GUI_ADDR =$xml.configuration.gui.address
$GUI_URL  = "http://$GUI_ADDR"

$headers = @{
    "X-API-Key" = $API_KEY
}

# Helper function for Syncthing REST API interactions
function Invoke-SyncthingApi {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body =$null
    )
    $uri = "$GUI_URL$Path"
    $params = @{
        Uri     = $uri
        Method  = $Method
        Headers = $headers
    }
    if ($Body) {$params["ContentType"] = "application/json"
        $params["Body"]        = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }
    return Invoke-RestMethod @params
}

Write-Host "Waiting for Syncthing to answer at $GUI_URL..."
$connected =$false
for ($i = 0; $i -lt 30; $i++) {
    try {
        $status = Invoke-SyncthingApi -Method "GET" -Path "/rest/system/status"
        if ($status) { $connected =$true; break }
    } catch {
        Start-Sleep -Seconds 2
    }
}

if (-not $connected) {
    Write-Error "Syncthing did not respond at $GUI_URL within 60s."
    exit 1
}

$MY_ID =$status.myID
$DEVICE_NAME = "$env:USERNAME-$env:COMPUTERNAME"

# Update local device name
$patchBody = @{ name =$DEVICE_NAME }
Invoke-SyncthingApi -Method "PATCH" -Path "/rest/config/devices/$MY_ID" -Body $patchBody | Out-Null

Write-Host ""
Write-Host "This machine's device ID: $MY_ID"

# -----------------------------------------------------------------------------
# Check Server Registration
# -----------------------------------------------------------------------------
$SERVER_ID = ""
try {
    $devices = Invoke-SyncthingApi -Method "GET" -Path "/rest/config/devices"
    foreach ($dev in$devices) {
        if ($dev.name -eq "LangTechDepot Server") {
            $SERVER_ID =$dev.deviceID
            break
        }
    }
} catch {}

if ($SERVER_ID) {
    Write-Host "Already registered with LangTechDepot Server."
} else {
    Write-Host "No token yet? Register at $REGISTER_URL"
    Write-Host ""

    $regSuccess =$false
    for ($attempt = 1; $attempt -le 3; $attempt++) {$TOKEN = Read-Host "Paste your LangTechDepot token"
        $TOKEN =$TOKEN.Trim()
        
        if ([string]::IsNullOrWhiteSpace($TOKEN)) {
            Write-Host "Nothing entered."
            continue
        }

        $regBody = @{
            token      = $TOKEN
            deviceID   = $MY_ID
            deviceName = $DEVICE_NAME
        } | ConvertTo-Json

        try {
            $response = Invoke-RestMethod -Uri "$REGISTER_URL/register" -Method "POST" -ContentType "application/json" -Body $regBody
            Write-Host ""
            Write-Host "Registered."
            $regSuccess =$true
            break
        } catch {
            $errorDetails =$_.Exception.Response
            $reason = "registration failed"
            if ($errorDetails) {
                try {
                    $reader = New-Object System.IO.StreamReader($errorDetails.GetResponseStream())
                    $jsonErr =$reader.ReadToEnd() | ConvertFrom-Json
                    if ($jsonErr.error) { $reason =$jsonErr.error }
                } catch {}
            }
            Write-Host "Registration failed: $reason"
            if ($attempt -lt 3) { Write-Host "Try again." }
        }
    }

    if (-not $regSuccess) {
        Write-Host ""
        Write-Host "Giving up after 3 attempts. Syncthing is installed and running; re-run this"
        Write-Host "script once you have a working token. Ask for help at $HELP_URL"
        exit 1
    }

    $SERVER_ID    =$response.serverDeviceID
    $SERVER_ADDRS =$response.serverAddresses

    $devConfig = @{
        deviceID   = $SERVER_ID
        name       = "LangTechDepot Server"
        addresses  = $SERVER_ADDRS
        introducer = $true
    }
    
    try {
        Invoke-SyncthingApi -Method "POST" -Path "/rest/config/devices" -Body $devConfig | Out-Null
    } catch {}
}

# Set default folder creation mode to receiveonly
$defaultFolderPatch = @{
    type = "receiveonly"
    path = $DATA_ROOT
}
Invoke-SyncthingApi -Method "PATCH" -Path "/rest/config/defaults/folder" -Body $defaultFolderPatch | Out-Null

# -----------------------------------------------------------------------------
# AUTO-SUBSCRIBE: All_Contents_List
# -----------------------------------------------------------------------------
$AUTO_FOLDER_ID   = "All_Contents_List"
$AUTO_FOLDER_PATH = Join-Path $DATA_ROOT$AUTO_FOLDER_ID

Write-Host "Subscribing to $AUTO_FOLDER_ID..."
New-Item -ItemType Directory -Force -Path $AUTO_FOLDER_PATH | Out-Null

$autoFolderPayload = @{
    id               = $AUTO_FOLDER_ID
    label            = "All_Contents_List -- a list of all files available"
    path             = $AUTO_FOLDER_PATH
    type             = "receiveonly"
    rescanIntervalS  = 3600
    fsWatcherEnabled = $true
    devices          = @(@{ deviceID = $SERVER_ID })
}

try {
    Invoke-SyncthingApi -Method "POST" -Path "/rest/config/folders" -Body $autoFolderPayload | Out-Null
} catch {}

Write-Host "Sync data root: $DATA_ROOT"
Write-Host "Automatically subscribed to: $AUTO_FOLDER_ID"
Write-Host "The folder catalog will appear within a minute or two."

# Wait for catalog sync
Write-Host "Waiting for catalog file to sync from server..."
while ((-not (Test-Path $CATALOG_FILE)) -or ((Get-Item$CATALOG_FILE).Length -eq 0)) {
    Start-Sleep -Seconds 2
}

# -----------------------------------------------------------------------------
# Parse Catalog & Get Live Ignored Folders
# -----------------------------------------------------------------------------
$ignored = [System.Collections.Generic.HashSet[string]]::new()
try {
    $devCfg = Invoke-SyncthingApi -Method "GET" -Path "/rest/config/devices/$SERVER_ID"
    if ($devCfg.ignoredFolders) {
        foreach ($item in$devCfg.ignoredFolders) {
            if ($item.id) { [void]$ignored.Add($item.id) }
        }
    }
} catch {}

$availableFolders = @()
$inFoldersSection =$false

foreach ($line in Get-Content -Path$CATALOG_FILE) {
    $line =$line.Trim()
    
    if ($line -like "*Folders available, with their sizes*") {
        $inFoldersSection =$true
        continue
    }
    if ($line -like "*Individual files available*") {
        break
    }
    if (-not $inFoldersSection -or [string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    # Match Regex: Size, Folder_ID, "Description"
    if ($line -match '^\s*(\S+)\s+(\S+)\s+"(.*)"\s*$') {
        $size =$matches[1]
        $fid  =$matches[2]
        $desc =$matches[3]

        if (-not $ignored.Contains($fid)) {$availableFolders += [PSCustomObject]@{
                "Folder ID"   = $fid
                "Size"        = $size
                "Description" = $desc
            }
        }
    }
}

if ($availableFolders.Count -eq 0) {
    Write-Host "No new folders available to display."
    exit 0
}

# -----------------------------------------------------------------------------
# Display Selection GUI via Out-GridView (Native Windows Dialog)
# -----------------------------------------------------------------------------
Write-Host "Displaying selection window..."
$selectedFolders =$availableFolders | Out-GridView `
    -Title "LangTechDepot - Select Folders to SUBSCRIBE (+). Unselected folders will be IGNORED (-)" `
    -OutputMode Multiple

# Build selection lookup
$selectedIDs = [System.Collections.Generic.HashSet[string]]::new()
if ($selectedFolders) {
    foreach ($item in$selectedFolders) {
        [void]$selectedIDs.Add($item."Folder ID")
    }
}

# Process results
foreach ($folder in$availableFolders) {
    $fid  =$folder."Folder ID"
    $desc =$folder."Description"

    # 1. SUBSCRIBE (+)
    if ($selectedIDs.Contains($fid)) {
        $folderPath = Join-Path$DATA_ROOT $fid$folderPayload = @{
            id               = $fid
            label            = $desc
            path             = $folderPath
            type             = "receiveonly"
            rescanIntervalS  = 3600
            fsWatcherEnabled = $true
            devices          = @(@{ deviceID = $SERVER_ID })
        }
        try {
            Invoke-SyncthingApi -Method "POST" -Path "/rest/config/folders" -Body $folderPayload | Out-Null
            Write-Host "Successfully subscribed to: $fid"
        } catch {
            Write-Host "Failed to subscribe to $fid:$_"
        }
    } 
    # 2. IGNORE (-)
    else {
        try {
            $devConfig = Invoke-SyncthingApi -Method "GET" -Path "/rest/config/devices/$SERVER_ID"
            
            if (-not $devConfig.ignoredFolders) {$devConfig | Add-Member -MemberType NoteProperty -Name "ignoredFolders" -Value @()
            }

            $alreadyExists =$false
            foreach ($item in$devConfig.ignoredFolders) {
                if ($item.id -eq$fid) { $alreadyExists =$true; break }
            }

            if (-not $alreadyExists) {$nowStr = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                $newItem = @{
                    id    = $fid
                    label = $desc
                    time  = $nowStr
                }
                
                # Append to array
                $devConfig.ignoredFolders +=$newItem

                Invoke-SyncthingApi -Method "PUT" -Path "/rest/config/devices/$SERVER_ID" -Body $devConfig | Out-Null
                Write-Host "Successfully ignored folder via API: $fid"
            } else {
                Write-Host "Folder already marked as ignored: $fid"
            }
        } catch {
            Write-Host "Warning: Could not ignore $fid via API:$_"
        }
    }
}

Write-Host " "
Write-Host "If you later need to manage the SyncThing system directly,"
Write-Host "open $GUI_URL."
Write-Host "Then if you want to unignore a folder,"
Write-Host "open the Actions menu at the top-right, click Settings"
Write-Host "and then Ignored Folders."
Write-Host "Then you can click Add on any additional folders you want."

