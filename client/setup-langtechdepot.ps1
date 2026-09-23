# setup-langtechdepot.ps1
# LangTechDepot installer for Windows 11.
#
# Installs Syncthing, registers this machine with the LangTechDepot server,
#   using the token you were issued.
# Auto-subscribes to All_Contents_List, and lets you choose folders to install or ignore,
#   using checkboxes.
# Idempotent.

$ErrorActionPreference = "Stop"

# Path definitions
$REGISTER_URL = "https://depot.langtech.cloud"
$HELP_URL     = "https://sillsdev.github.io/langtechdepot/help.html"

$DATA_ROOT  = "$HOME\LangTechDepot"
$BIN_DIR    = "$env:LOCALAPPDATA\Programs\Syncthing"
$BIN        = "$BIN_DIR\syncthing.exe"
$CONFIG_DIR = "$env:LOCALAPPDATA\langtechdepot"

New-Item -ItemType Directory -Force -Path $DATA_ROOT | Out-Null
New-Item -ItemType Directory -Force -Path $BIN_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $CONFIG_DIR | Out-Null

# Download Syncthing if not present
if (-not (Test-Path $BIN)) {
    Write-Host "Downloading Syncthing..."
    $releaseJson = Invoke-RestMethod -Uri "https://api.github.com/repos/syncthing/syncthing/releases/latest"
    $asset = $releaseJson.assets \vert{} Where-Object {$_.name -like "*windows-amd64*.zip" } | Select-Object -First 1
    
    $tmpZip = [System.IO.Path]::GetTempFileName() + ".zip"
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile$tmpZip
    Expand-Archive -Path $tmpZip -DestinationPath$tmpDir
    
    $exePath = Get-ChildItem -Path$tmpDir -Recurse -Filter "syncthing.exe" | Select-Object -First 1
    Copy-Item -Path $exePath.FullName -Destination$BIN -Force
    
    Remove-Item -Path $tmpZip -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Using Syncthing at $BIN"

# Generate config.xml if it does not exist
$configFile = "$CONFIG_DIR\config.xml"
if (-not (Test-Path $configFile)) {
    Start-Process -FilePath $BIN -ArgumentList "generate", "--home", "`"$CONFIG_DIR`"" -NoNewWindow -Wait
}

# Setup Windows Scheduled Task to run Syncthing in background on logon
$taskName = "LangTechDepot_Syncthing"
$task = Get-ScheduledTask -TaskName$taskName -ErrorAction SilentlyContinue

if (-not $task) {
    $action  = New-ScheduledTaskAction -Execute$BIN -Argument "serve --no-browser --home `"$CONFIG_DIR`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
    Register-ScheduledTask -TaskName $taskName -Action$action -Trigger $trigger -Settings$settings | Out-Null
}

# Ensure task is running
$taskState = (Get-ScheduledTask -TaskName$taskName).State
if ($taskState -ne "Running") {
    Start-ScheduledTask -TaskName $taskName
}

# Helper functions for REST API
function Get-XmlNodeText {
    param([string]$path, [string]$xpath)
    [xml]$xml = Get-Content -Path$path
    return $xml.SelectSingleNode($xpath).InnerText
}

$API_KEY = Get-XmlNodeText -path$configFile -xpath "//configuration/gui/apikey"
$GUI_ADDR = Get-XmlNodeText -path$configFile -xpath "//configuration/gui/address"
$GUI_URL = "http://$GUI_ADDR"
$SERVER_NAME = "LangTechDepot Server"

function Invoke-SyncthingApi {
    param(
        [string]$Method,
        [string]$Endpoint,
        [object]$Body =$null
    )
    $headers = @{
        "X-API-Key" = $API_KEY
    }
    $uri = "$GUI_URL$Endpoint"
    if ($Body) {
        $jsonBody =$Body | ConvertTo-Json -Depth 10 -Compress
        return Invoke-RestMethod -Uri $uri -Method$Method -Headers $headers -Body$jsonBody -ContentType "application/json"
    } else {
        return Invoke-RestMethod -Uri $uri -Method $Method -Headers$headers
    }
}

Write-Host "Waiting for Syncthing..."
$connected =$false
for ($i = 0; $i -lt 30; $i++) {
    try {
        $status = Invoke-SyncthingApi -Method "GET" -Endpoint "/rest/system/status"
        if ($status.myID) { $connected =$true; break }
    } catch {
        Start-Sleep -Seconds 2
    }
}

if (-not $connected) {
    Write-Error "Syncthing did not answer at $GUI_URL within 60s."
    exit 1
}

$MY_ID =$status.myID
$DEVICE_NAME = "$env:USERNAME-$env:COMPUTERNAME"

# Set Device Name
Invoke-SyncthingApi -Method "PATCH" -Endpoint "/rest/config/devices/$MY_ID" -Body @{ name = $DEVICE_NAME } | Out-Null

Write-Host ""
Write-Host "This machine's device ID: $MY_ID"

# -----------------------------------------------------------------------------
# Check if registered with LangTechDepot Server
# -----------------------------------------------------------------------------
$SERVER_ID = ""
try {
    $devices = Invoke-SyncthingApi -Method "GET" -Endpoint "/rest/config/devices"
    foreach ($dev in$devices) {
        if ($dev.name -eq$SERVER_NAME) {
            $SERVER_ID =$dev.deviceID
            break
        }
    }
} catch {}

if ($SERVER_ID) {
    Write-Host "Already registered with $SERVER_NAME."
    Start-Sleep -Seconds 3
    Write-Host " "
} else {
    Write-Host "No token yet? Register at $REGISTER_URL"
    Write-Host ""
    
    $RESPONSE =$null
    for ($attempt = 1; $attempt -le 3; $attempt++) {$TOKEN = Read-Host "Paste your LangTechDepot token"
        $TOKEN =$TOKEN.Trim()
        if (-not $TOKEN) { Write-Host "Nothing entered."; continue }

        $regBody = @{
            token      = $TOKEN
            deviceID   = $MY_ID
            deviceName = $DEVICE_NAME
        } | ConvertTo-Json

        try {
            $RESPONSE = Invoke-RestMethod -Uri "$REGISTER_URL/register" -Method "POST" -Body $regBody -ContentType "application/json"
            Write-Host ""
            Write-Host "Registered."
            break
        } catch {
            $REASON = "registration failed"
            if ($_.Exception.Response) {
                try {
                    $stream =$_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $errObj =$reader.ReadToEnd() | ConvertFrom-Json
                    if ($errObj.error) { $REASON =$errObj.error }
                } catch {}
            }
            Write-Host "Registration failed: $REASON"
            if ($attempt -lt 3) { Write-Host "Try again." }
        }
    }

    if (-not $RESPONSE) {
        Write-Host ""
        Write-Host "Giving up after 3 attempts. Syncthing is installed and running; re-run this"
        Write-Host "script once you have a working token. Ask for help at $HELP_URL"
        exit 1
    fi

    $SERVER_ID    =$RESPONSE.serverDeviceID
    $SERVER_ADDRS =$RESPONSE.serverAddresses

    Invoke-SyncthingApi -Method "POST" -Endpoint "/rest/config/devices" -Body @{
        deviceID   = $SERVER_ID
        name       = $SERVER_NAME
        addresses  = $SERVER_ADDRS
        introducer = $true
    } | Out-Null
}

# Default Receive-only setup
Invoke-SyncthingApi -Method "PATCH" -Endpoint "/rest/config/defaults/folder" -Body @{
    type = "receiveonly"
    path = $DATA_ROOT
} | Out-Null

# -----------------------------------------------------------------------------
# AUTO-SUBSCRIBE: All_Contents_List
# -----------------------------------------------------------------------------
$AUTO_FOLDER_ID   = "All_Contents_List"
$AUTO_FOLDER_PATH = Join-Path $DATA_ROOT$AUTO_FOLDER_ID
$CATALOG_FILE     = Join-Path$AUTO_FOLDER_PATH "LangTechDepotFiles.txt"

Write-Host "Subscribing to $AUTO_FOLDER_ID, which contains a list"
Write-Host "of all the files available in the Depot"
Write-Host "and the size of each folder you can subscribe to ..."
Write-Host " "
Start-Sleep -Seconds 4
New-Item -ItemType Directory -Force -Path $AUTO_FOLDER_PATH | Out-Null

Invoke-SyncthingApi -Method "POST" -Endpoint "/rest/config/folders" -Body @{
    id              = $AUTO_FOLDER_ID
    label           = "All_Contents_List -- a list of all files available"
    path            = $AUTO_FOLDER_PATH
    type            = "receiveonly"
    rescanIntervalS = 3600
    fsWatcherEnabled= $true
    devices         = @(@{ deviceID = $SERVER_ID })
} | Out-Null

Write-Host "Sync data root: $DATA_ROOT"
Write-Host "Automatically subscribed to: $AUTO_FOLDER_ID"
Write-Host "The folder catalog will appear within a minute or two."
Write-Host " "
Start-Sleep -Seconds 4

Write-Host "Waiting for catalog file to sync from server..."
while (-not (Test-Path $CATALOG_FILE) -or (Get-Item$CATALOG_FILE).Length -eq 0) {
    Start-Sleep -Seconds 2
}

# -----------------------------------------------------------------------------
# GUI Folder Selection Window (.NET Windows Forms DataGridView)
# -----------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-FolderSelectionForm {
    param(
        [string]$CatalogPath,
        [string]$ServerID,
        [bool]$DefaultCheck
    )

    # Fetch live ignored list
    $ignored = [System.Collections.Generic.HashSet[string]]::new()
    try {
        $devCfg = Invoke-SyncthingApi -Method "GET" -Endpoint "/rest/config/devices/$ServerID"
        foreach ($item in$devCfg.ignoredFolders) {
            if ($item.id) { $ignored.Add($item.id) | Out-Null }
        }
    } catch {}

    # Parse catalog file
    $tableData = [System.Collections.ArrayList]::new()
    $inFolders =$false
    
    foreach ($line in (Get-Content$CatalogPath)) {
        $line =$line.Trim()
        if ($line -like "*Folders available, with their sizes*") { $inFolders =$true; continue }
        if ($line -like "*Individual files available*") { break }
        if (-not $inFolders -or -not$line) { continue }

        if ($line -match '^\s*(\S+)\s+(\S+)\s+"(.*)"\s*$') {
            $size =$matches[1]
            $fid  =$matches[2]
            $desc =$matches[3]

            if (-not $ignored.Contains($fid)) {$row = New-Object PSObject -Property @{
                    Subscribe   = $DefaultCheck
                    Size        = $size
                    FolderID    = $fid
                    Description = $desc
                }
                $tableData.Add($row) | Out-Null
            }
        }
    }

    if ($tableData.Count -eq 0) {
        Write-Host "No new folders available to display."
        return $null
    }

    # Build UI Window
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "LangTechDepot - Available Folders"
    $form.Size = New-Object System.Drawing.Size(800, 520)$form.StartPosition = "CenterScreen"

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Check (+) the folders you want to sync. NOTE: All unchecked folders will be IGNORED (-)"
    $label.ForeColor = [System.Drawing.Color]::Red$label.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $label.Dock = "Top"
    $label.Height = 30$label.Padding = New-Object System.Windows.Forms.Padding(10, 5, 0, 0)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = "Fill"
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.AllowUserToAddRows = $false$grid.RowHeadersVisible = $false$grid.SelectionMode = "FullRowSelect"

    # Add columns manually
    $colChk = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colChk.HeaderText = "Subscribe (+)"
    $colChk.Name = "Subscribe"
    $colChk.Width = 90
    $grid.Columns.Add($colChk) | Out-Null

    $colSize = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colSize.HeaderText = "Size"
    $colSize.Name = "Size"
    $colSize.ReadOnly = $true$colSize.Width = 80
    $grid.Columns.Add($colSize) | Out-Null

    $colId = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colId.HeaderText = "Folder ID"
    $colId.Name = "FolderID"
    $colId.ReadOnly = $true$colId.Width = 180
    $grid.Columns.Add($colId) | Out-Null

    $colDesc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDesc.HeaderText = "Description"
    $colDesc.Name = "Description"
    $colDesc.ReadOnly =$true
    $grid.Columns.Add($colDesc) | Out-Null

    # Populate rows
    foreach ($item in $tableData) {$grid.Rows.Add($item.Subscribe, $item.Size, $item.FolderID, $item.Description) | Out-Null
    }

    # Bottom Button Panel
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = "Bottom"
    $panel.Height = 50

    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Select All"
    $btnSelectAll.Location = New-Object System.Drawing.Point(15, 10)$btnSelectAll.Add_Click({
        foreach ($row in$grid.Rows) { $row.Cells["Subscribe"].Value = $true }
    })

    $btnClearAll = New-Object System.Windows.Forms.Button
    $btnClearAll.Text = "Clear All"
    $btnClearAll.Location = New-Object System.Drawing.Point(100, 10)$btnClearAll.Add_Click({
        foreach ($row in$grid.Rows) { $row.Cells["Subscribe"].Value = $false }
    })

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "Apply"
    $btnApply.DialogResult = [System.Windows.Forms.DialogResult]::OK$btnApply.Location = New-Object System.Drawing.Point(590, 10)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel$btnCancel.Location = New-Object System.Drawing.Point(680, 10)

    $panel.Controls.AddRange(@($btnSelectAll,$btnClearAll, $btnApply,$btnCancel))
    $form.Controls.AddRange(@($grid, $label,$panel))
    $form.AcceptButton =$btnApply
    $form.CancelButton =$btnCancel

    $dialogResult =$form.ShowDialog()

    if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    # Extract chosen selections
    $results = [System.Collections.ArrayList]::new()
    foreach ($row in $grid.Rows) {$results.Add(@{
            Subscribe   = [bool]$row.Cells["Subscribe"].Value
            Size        = $row.Cells["Size"].Value
            FolderID    = $row.Cells["FolderID"].Value
            Description = $row.Cells["Description"].Value
        }) | Out-Null
    }

    return $results
}

$selections = Show-FolderSelectionForm -CatalogPath$CATALOG_FILE -ServerID $SERVER_ID -DefaultCheck$false

if (-not $selections) {
    Write-Host "Operation cancelled."
    exit 0
}

# -----------------------------------------------------------------------------
# Process choices: Checked = Subscribe, Unchecked = Ignore
# -----------------------------------------------------------------------------
$existingFolders = [System.Collections.Generic.HashSet[string]]::new()
try {
    $foldersCfg = Invoke-SyncthingApi -Method "GET" -Endpoint "/rest/config/folders"
    foreach ($fld in$foldersCfg) {
        if ($fld.id) { $existingFolders.Add($fld.id) | Out-Null }
    }
} catch {
    Write-Host "Warning: Could not fetch active folders list."
}

foreach ($item in$selections) {
    $fid   =$item.FolderID
    $desc  =$item.Description
    $isSub =$item.Subscribe

    # 1. SUBSCRIBE (+)
    if ($isSub) {$folderPath = Join-Path $DATA_ROOT$fid
        try {
            Invoke-SyncthingApi -Method "POST" -Endpoint "/rest/config/folders" -Body @{
                id              = $fid
                label           = $desc
                path            = $folderPath
                type            = "receiveonly"
                rescanIntervalS = 3600
                fsWatcherEnabled= $true
                devices         = @(@{ deviceID = $SERVER_ID })
            } | Out-Null
            Write-Host "Successfully subscribed to: $fid"
        } catch {
            Write-Host "Failed to subscribe to $fid"
        }
    }
    # 2. IGNORE (-)
    else {
        # Step A: Delete if actively subscribed
        if ($existingFolders.Contains($fid)) {
            try {
                Invoke-SyncthingApi -Method "DELETE" -Endpoint "/rest/config/folders/$fid" | Out-Null
                Write-Host "Removed active subscription for: $fid"
            } catch {
                Write-Host "Warning: Could not remove active folder $fid"
            }
        }

        # Step B: Append folder ID to server's ignoredFolders array
        try {
            $devConfig = Invoke-SyncthingApi -Method "GET" -Endpoint "/rest/config/devices/$SERVER_ID"
            $curIgnores =$devConfig.ignoredFolders
            if (-not $curIgnores) {$curIgnores = @() }

            $alreadyExists =$false
            foreach ($ig in$curIgnores) {
                if ($ig.id -eq$fid) { $alreadyExists =$true; break }
            }

            if (-not $alreadyExists) {$nowStr = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                $newIgnore = @{
                    id    = $fid
                    label = $desc
                    time  = $nowStr
                }
                
                # Convert to ArrayList to handle array appending smoothly
                $ignoresList = [System.Collections.ArrayList]::$curIgnores
                $ignoresList.Add($newIgnore) \vert{} Out-Null$devConfig.ignoredFolders = $ignoresList

                Invoke-SyncthingApi -Method "PUT" -Endpoint "/rest/config/devices/$SERVER_ID" -Body $devConfig | Out-Null
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

exit 0
