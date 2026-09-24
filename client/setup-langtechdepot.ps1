# setup-langtechdepot.ps1
# LangTechDepot installer for Windows 11.
#
# Installs Syncthing, registers this machine with the LangTechDepot server,
#   using the token you were issued.
# Auto-subscribes to All_Contents_List, and lets you choose folders to install or ignore,
#   using checkboxes.
# Idempotent.

param(
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"

# Central exit point so -NoPause (passed by run-setup-langtechdepot.bat, which
# already pauses itself) is honored everywhere the script can stop, instead of
# only at the very end.
function Exit-Script {
    param([int]$Code = 0)
    if (-not $NoPause) {
        Write-Host ""
        Read-Host "Press Enter to close this window"
    }
    exit $Code
}

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
    $asset = $releaseJson.assets | Where-Object {$_.name -like "*windows-amd64*.zip" } | Select-Object -First 1

    $tmpZip = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + ".zip")
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())

    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpZip
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir

    $exePath = Get-ChildItem -Path $tmpDir -Recurse -Filter "syncthing.exe" | Select-Object -First 1
    Copy-Item -Path $exePath.FullName -Destination $BIN -Force
    
    Remove-Item -Path $tmpZip -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Using Syncthing at $BIN"

# Generate config.xml if it does not exist. --gui-address pins the GUI to the
# standard port (8384) instead of letting Syncthing pick a random one, which
# is what config.xml would otherwise get on a fresh install.
$configFile = "$CONFIG_DIR\config.xml"
if (-not (Test-Path $configFile)) {
    Start-Process -FilePath $BIN -ArgumentList "generate", "--home", $CONFIG_DIR, "--gui-address", "127.0.0.1:8384" -NoNewWindow -Wait
}

# Run Syncthing in the background at logon, via a Startup-folder shortcut.
# This deliberately avoids Register-ScheduledTask: on many Windows 11
# machines that cmdlet refuses to run for a standard (non-admin) user
# ("Access is denied", HRESULT 0x80070005) even though the task itself
# would only ever need the current user's own rights - it is a known
# limitation of the ScheduledTasks module, not something wrong with the
# machine. A Startup-folder shortcut needs no elevation, ever, and is the
# closest Windows equivalent of the per-user systemd service the Linux
# script installs.
$startupDir   = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir "LangTechDepot Syncthing.lnk"

if (-not (Test-Path $shortcutPath)) {
    $wshShell = New-Object -ComObject WScript.Shell
    $shortcut = $wshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath       = $BIN
    $shortcut.Arguments        = "serve --no-browser --home `"$CONFIG_DIR`""
    $shortcut.WorkingDirectory = $BIN_DIR
    $shortcut.WindowStyle      = 7   # Minimized - a console app can't be fully hidden via a shortcut
    $shortcut.Description      = "Runs LangTechDepot's Syncthing in the background at logon"
    $shortcut.Save()
}

# Make sure it's running right now too, not just at the next logon.
if (-not (Get-Process -Name "syncthing" -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath $BIN -ArgumentList "serve", "--no-browser", "--home", $CONFIG_DIR -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

# Helper functions for REST API
function Get-XmlNodeText {
    param([string]$path, [string]$xpath)
    [xml]$xml = Get-Content -Path $path
    return $xml.SelectSingleNode($xpath).InnerText
}

$API_KEY = Get-XmlNodeText -path $configFile -xpath "//configuration/gui/apikey"
$GUI_ADDR = "127.0.0.1:8384"
$GUI_URL = "http://$GUI_ADDR"
$SERVER_NAME = "LangTechDepot Server"

function Invoke-SyncthingApi {
    param(
        [string]$Method,
        [string]$Endpoint,
        [object]$Body = $null
    )
    $headers = @{
        "X-API-Key" = $API_KEY
    }
    $uri = "$GUI_URL$Endpoint"
    if ($Body) {
        $jsonBody = $Body | ConvertTo-Json -Depth 10 -Compress
        return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -Body $jsonBody -ContentType "application/json"
    } else {
        return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers
    }
}

Write-Host "Waiting for Syncthing..."
$connected = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        $status = Invoke-SyncthingApi -Method "GET" -Endpoint "/rest/system/status"
        if ($status.myID) { $connected = $true; break }
    } catch {
        Start-Sleep -Seconds 2
    }
}

if (-not $connected) {
    Write-Error "Syncthing did not answer at $GUI_URL within 60s."
    Exit-Script -Code 1
}

$MY_ID = $status.myID
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
    foreach ($dev in $devices) {
        if ($dev.name -eq $SERVER_NAME) {
            $SERVER_ID = $dev.deviceID
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
    
    $RESPONSE = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $TOKEN = Read-Host "Paste your LangTechDepot token"
        $TOKEN = $TOKEN.Trim()
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
                    $stream = $_.Exception.Response.GetResponseStream()
                    $reader = [System.IO.StreamReader]::new($stream)
                    $errObj = $reader.ReadToEnd() | ConvertFrom-Json
                    if ($errObj.error) { $REASON = $errObj.error }
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
        Exit-Script -Code 1
    }

    $SERVER_ID    = $RESPONSE.serverDeviceID
    $SERVER_ADDRS = $RESPONSE.serverAddresses

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
$AUTO_FOLDER_PATH = Join-Path $DATA_ROOT $AUTO_FOLDER_ID
$CATALOG_FILE     = Join-Path $AUTO_FOLDER_PATH "LangTechDepotFiles.txt"

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
    fsWatcherEnabled = $true
    devices         = @(@{ deviceID = $SERVER_ID })
} | Out-Null

Write-Host "Sync data root: $DATA_ROOT"
Write-Host "Automatically subscribed to: $AUTO_FOLDER_ID"
Write-Host "The folder catalog will appear within a minute or two."
Write-Host " "
Start-Sleep -Seconds 4

Write-Host "Waiting for catalog file to sync from server..."
while (-not (Test-Path $CATALOG_FILE) -or (Get-Item $CATALOG_FILE).Length -eq 0) {
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
        foreach ($item in $devCfg.ignoredFolders) {
            if ($item.id) { $ignored.Add($item.id) | Out-Null }
        }
    } catch {}

    # Parse catalog file
    $tableData = [System.Collections.ArrayList]::new()
    $inFolders = $false

    foreach ($line in (Get-Content $CatalogPath)) {
        $line = $line.Trim()
        if ($line -like "*Folders available, with their sizes*") { $inFolders = $true; continue }
        if ($line -like "*Individual files available*") { break }
        if (-not $inFolders -or -not $line) { continue }

        if ($line -match '^\s*(\S+)\s+(\S+?)\s*"(.*)"\s*$') {
            $size = $matches[1]
            $fid  = $matches[2]
            $desc = $matches[3]

            if (-not $ignored.Contains($fid)) {
                $row = New-Object PSObject -Property @{
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
    $form.Size = [System.Drawing.Size]::new(800, 520)
    $form.MinimumSize = [System.Drawing.Size]::new(500, 300)
    $form.StartPosition = "CenterScreen"
    # Launched from a console host, this window otherwise opens behind the
    # console and never gets focus. Forcing TopMost briefly on Shown pulls it
    # to the front once, then releases it so it behaves like a normal window.
    $form.Add_Shown({
        $form.Activate()
        $form.TopMost = $false
    })
    $form.TopMost = $true

    $instructionText = "Check (+) the folders you want to sync. NOTE: All unchecked folders will be IGNORED (-)"
    $noteIndex = $instructionText.IndexOf("NOTE:")

    $label = New-Object System.Windows.Forms.RichTextBox
    $label.Text = $instructionText
    $label.Font = [System.Drawing.Font]::new("Segoe UI", 9)
    $label.Dock = "Top"
    $label.Height = 30
    $label.Padding = [System.Windows.Forms.Padding]::new(10, 5, 0, 0)
    $label.ReadOnly = $true
    $label.TabStop = $false
    $label.BorderStyle = "None"
    $label.BackColor = [System.Drawing.SystemColors]::Control
    $label.Cursor = [System.Windows.Forms.Cursors]::Default

    # Colour and bold only the "NOTE: ..." clause; leave the lead-in sentence
    # in the default colour/weight.
    $label.Select($noteIndex, $instructionText.Length - $noteIndex)
    $label.SelectionColor = [System.Drawing.Color]::Red
    $label.SelectionFont = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $label.Select(0, 0)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = "Fill"
    $grid.AllowUserToAddRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = "FullRowSelect"

    # Add columns manually
    $colChk = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colChk.HeaderText = "Subscribe (+)"
    $colChk.Name = "Subscribe"
    $colChk.Width = 90
    $colChk.AutoSizeMode = "AllCells"
    $grid.Columns.Add($colChk) | Out-Null

    $colSize = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colSize.HeaderText = "Size"
    $colSize.Name = "Size"
    $colSize.ReadOnly = $true
    $colSize.AutoSizeMode = "AllCells"
    $grid.Columns.Add($colSize) | Out-Null

    $colId = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colId.HeaderText = "Folder ID"
    $colId.Name = "FolderID"
    $colId.ReadOnly = $true
    $colId.AutoSizeMode = "AllCells"
    $grid.Columns.Add($colId) | Out-Null

    $colDesc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDesc.HeaderText = "Description"
    $colDesc.Name = "Description"
    $colDesc.ReadOnly = $true
    $colDesc.AutoSizeMode = "Fill"
    $grid.Columns.Add($colDesc) | Out-Null

    # Populate rows
    foreach ($item in $tableData) {
        $grid.Rows.Add($item.Subscribe, $item.Size, $item.FolderID, $item.Description) | Out-Null
    }

    # Bottom Button Panel
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = "Bottom"
    $panel.Height = 50
    # Anchor distances for the buttons below are computed against this width
    # the moment each button is added to $panel.Controls - which happens
    # before $panel itself is docked to the form. Without setting it here,
    # $panel would still have WinForms' small default un-docked width, and
    # the right-anchored buttons would end up positioned off past the real,
    # wider form once docking actually kicks in.
    $panel.Width = $form.ClientSize.Width

    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Select All"
    $btnSelectAll.Location = [System.Drawing.Point]::new(15, 10)
    $btnSelectAll.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    $btnSelectAll.Add_Click({
        foreach ($row in $grid.Rows) { $row.Cells["Subscribe"].Value = $true }
    })

    $btnClearAll = New-Object System.Windows.Forms.Button
    $btnClearAll.Text = "Clear All"
    $btnClearAll.Location = [System.Drawing.Point]::new(100, 10)
    $btnClearAll.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    $btnClearAll.Add_Click({
        foreach ($row in $grid.Rows) { $row.Cells["Subscribe"].Value = $false }
    })

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "Apply"
    $btnApply.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnApply.Location = [System.Drawing.Point]::new(590, 10)
    $btnApply.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.Location = [System.Drawing.Point]::new(680, 10)
    $btnCancel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $panel.Controls.AddRange(@($btnSelectAll, $btnClearAll, $btnApply, $btnCancel))
    $form.Controls.AddRange(@($grid, $label, $panel))
    $form.AcceptButton = $btnApply
    $form.CancelButton = $btnCancel

    $dialogResult = $form.ShowDialog()

    if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    # Extract chosen selections
    $results = [System.Collections.ArrayList]::new()
    foreach ($row in $grid.Rows) {
        $results.Add(@{
            Subscribe   = [bool]$row.Cells["Subscribe"].Value
            Size        = $row.Cells["Size"].Value
            FolderID    = $row.Cells["FolderID"].Value
            Description = $row.Cells["Description"].Value
        }) | Out-Null
    }

    return $results
}

$selections = Show-FolderSelectionForm -CatalogPath $CATALOG_FILE -ServerID $SERVER_ID -DefaultCheck $false

if (-not $selections) {
    Write-Host "Operation cancelled."
    Exit-Script -Code 0
}

# -----------------------------------------------------------------------------
# Process choices: Checked = Subscribe, Unchecked = Ignore
# -----------------------------------------------------------------------------
$existingFolders = [System.Collections.Generic.HashSet[string]]::new()
try {
    $foldersCfg = Invoke-SyncthingApi -Method "GET" -Endpoint "/rest/config/folders"
    foreach ($fld in $foldersCfg) {
        if ($fld.id) { $existingFolders.Add($fld.id) | Out-Null }
    }
} catch {
    Write-Host "Warning: Could not fetch active folders list."
}

foreach ($item in $selections) {
    $fid   = $item.FolderID
    $desc  = $item.Description
    $isSub = $item.Subscribe

    # 1. SUBSCRIBE (+)
    if ($isSub) {
        $folderPath = Join-Path $DATA_ROOT $fid
        try {
            Invoke-SyncthingApi -Method "POST" -Endpoint "/rest/config/folders" -Body @{
                id              = $fid
                label           = $desc
                path            = $folderPath
                type            = "receiveonly"
                rescanIntervalS = 3600
                fsWatcherEnabled = $true
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
            $curIgnores = $devConfig.ignoredFolders
            if (-not $curIgnores) { $curIgnores = @() }

            $alreadyExists = $false
            foreach ($ig in $curIgnores) {
                if ($ig.id -eq $fid) { $alreadyExists = $true; break }
            }

            if (-not $alreadyExists) {
                $nowStr = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                $newIgnore = @{
                    id    = $fid
                    label = $desc
                    time  = $nowStr
                }

                # Append via array concatenation, which returns a new array -
                # simpler and safer here than trying to grow $curIgnores in place.
                $devConfig.ignoredFolders = @($curIgnores) + $newIgnore

                Invoke-SyncthingApi -Method "PUT" -Endpoint "/rest/config/devices/$SERVER_ID" -Body $devConfig | Out-Null
                Write-Host "Successfully ignored folder via API: $fid"
            } else {
                Write-Host "Folder already marked as ignored: $fid"
            }
        } catch {
            Write-Host "Warning: Could not ignore $fid via API: $_"
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

Exit-Script -Code 0