# setup-langtechdepot.ps1
# LangTechDepot installer for Windows 11.
#
# Installs Syncthing, registers this machine with the LangTechDepot server,
#   using the token you were issued.
# Auto-subscribes to All_Contents_List, and lets you choose folders to install or ignore,
#   using checkboxes. Run it again later to add folders or take back ignored ones.
# Also installs itself as modify-langtechdepot.bat, for changing folders from a
#   Command Prompt without the dialog - see "Command-line mode" below.
# Idempotent.

# PositionalBinding off: only the two parameters given a Position below take
# bare words, so "modify-langtechdepot add Android_apps" can never land in
# -From or -Self by accident.
[CmdletBinding(PositionalBinding = $false)]
param(
    # What to change when run as "modify-langtechdepot <action> <folder IDs>":
    # add, ignore or list. Empty means the ordinary installer, dialog and all.
    [Parameter(Position = 0)]
    [string]$Action = "",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$FolderIDs = @(),
    [switch]$NoPause,
    # The folder setup-langtechdepot.bat was started from, passed in by the
    # .bat. This script itself runs from a temporary copy, so it cannot find
    # that folder on its own; it is where a hand-placed syncthing.exe lives.
    [string]$From = "",
    # The .bat file this script was carried in, and the name it was started
    # by (without ".bat"), both passed in by the .bat. $Self is what gets
    # copied to modify-langtechdepot.bat; $InvokedAs tells the two names apart.
    [string]$Self = "",
    [string]$InvokedAs = ""
)

$ErrorActionPreference = "Stop"

# The version, e.g. 1.0.1. The number lives only in the git release tag
# (v1.0.1): build-bat.sh asks client/version.sh for it and writes it into
# this exact line of the built .bat, so keep the line exactly in this form.
# Run straight from the repo, the script honestly says "dev".
$LTD_VERSION = "dev"

# Central exit point so -NoPause (passed by setup-langtechdepot.bat, which
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

# -----------------------------------------------------------------------------
# Command-line mode: modify-langtechdepot add|ignore|list [folder IDs]
# -----------------------------------------------------------------------------
# The installer copies its own .bat beside LangTechDepot's syncthing.exe as
# modify-langtechdepot.bat and puts that folder on the user's PATH (see
# "Install modify-langtechdepot" below), so from any new Command Prompt:
#   modify-langtechdepot add Android_apps Keyman   subscribe (un-ignoring if needed)
#   modify-langtechdepot ignore Android_apps       unsubscribe and ignore
#   modify-langtechdepot list                      every folder and its state
# Only the folders named are changed; everything else is left as it is, and
# no dialog is shown. With no arguments it is the ordinary installer. It is
# the same script either way, so there is no second program to keep in step.
$ScriptName = if ($InvokedAs) { $InvokedAs } else { "setup-langtechdepot" }
$Action = $Action.Trim().ToLowerInvariant()
$CliMode = [bool]$Action

function Show-Usage {
    Write-Host "Usage:"
    Write-Host "  $ScriptName add <FolderID> [<FolderID> ...]     subscribe to folders"
    Write-Host "  $ScriptName ignore <FolderID> [<FolderID> ...]  stop syncing folders, and ignore them"
    Write-Host "  $ScriptName list                                show every folder and its state"
    Write-Host "  $ScriptName version                             which version this is"
    Write-Host "  $ScriptName                                     choose folders in a window"
}

if ($CliMode) {
    if ($Action -in @("help", "/?", "/h")) {
        Write-Host "LangTechDepot $LTD_VERSION"
        Show-Usage
        Exit-Script -Code 0
    }
    if ($Action -eq "version") {
        Write-Host "LangTechDepot $LTD_VERSION"
        Exit-Script -Code 0
    }
    if ($Action -notin @("add", "ignore", "list")) {
        Write-Host "${ScriptName}: '$Action' is not something this can do."
        Show-Usage
        Exit-Script -Code 2
    }
    if ($Action -eq "list" -and $FolderIDs.Count -gt 0) {
        Write-Host "${ScriptName}: 'list' takes no folder IDs."
        Show-Usage
        Exit-Script -Code 2
    }
    if ($Action -ne "list" -and $FolderIDs.Count -eq 0) {
        Write-Host "${ScriptName}: '$Action' needs at least one folder ID."
        Show-Usage
        Exit-Script -Code 2
    }
} elseif ($ScriptName -eq "modify-langtechdepot") {
    Write-Host "LangTechDepot $LTD_VERSION"
    Write-Host "modify-langtechdepot: You didn't specify any changes. Please respond to the dialog appearing soon:"
    Write-Host "(For the command-line way, type: modify-langtechdepot help)"
    Write-Host ""
} else {
    Write-Host "LangTechDepot installer $LTD_VERSION"
    Write-Host ""
}

# Progress messages and reading pauses meant for someone watching the
# installer. A command-line run skips them and says only what changed.
function Write-Chatter {
    param([string]$Text = " ")
    if (-not $CliMode) { Write-Host $Text }
}
function Wait-ForReader {
    param([int]$Seconds)
    if (-not $CliMode) { Start-Sleep -Seconds $Seconds }
}

# Path definitions
$REGISTER_URL = "https://depot.langtech.cloud"
$HELP_URL     = "https://depot.langtech.cloud/help.html"

$BIN_DIR    = "$env:LOCALAPPDATA\Programs\Syncthing"
$BIN        = "$BIN_DIR\syncthing.exe"
$CONFIG_DIR = "$env:LOCALAPPDATA\langtechdepot"

# Command-line mode only changes an existing setup; it never starts one.
if ($CliMode -and -not (Test-Path (Join-Path $CONFIG_DIR "config.xml"))) {
    Write-Host "${ScriptName}: LangTechDepot is not set up on this computer yet."
    Write-Host "Run setup-langtechdepot.bat first. More help: $HELP_URL"
    Exit-Script -Code 1
}

New-Item -ItemType Directory -Force -Path $BIN_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $CONFIG_DIR | Out-Null

# Get Syncthing. This script never downloads an executable itself: antivirus
# dropper heuristics flag a script that fetches a binary and then registers it
# to run at startup, and that has already cost this project an installer.
# Syncthing comes from winget, or from a syncthing.exe the user put beside the
# .bat by hand, and is copied to $BIN so the rest of the script, and the
# startup shortcut, always have one fixed path.
function Find-WingetSyncthing {
    # winget unpacks portable packages (Syncthing is one) under this folder
    # when installed with --scope user.
    $root = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (-not (Test-Path $root)) { return $null }
    $exe = Get-ChildItem -Path $root -Directory -Filter "Syncthing.Syncthing_*" -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem -Path $_.FullName -Recurse -Filter "syncthing.exe" -ErrorAction SilentlyContinue } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($exe) { return $exe.FullName }
    return $null
}

if (-not (Test-Path $BIN)) {
    $source = $null

    # 1. A copy the user placed beside the .bat by hand.
    if ($From) {
        $handPlaced = Join-Path $From "syncthing.exe"
        if (Test-Path $handPlaced) { $source = $handPlaced }
    }

    # 2. One that winget installed earlier.
    if (-not $source) { $source = Find-WingetSyncthing }

    # 3. Ask winget for it. --scope user needs no administrator rights, and a
    #    machine-scope install leaves syncthing.exe unreadable to normal users.
    if (-not $source) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "Installing Syncthing with winget..."
            # winget reports failure through its exit code, not an exception,
            # and "already installed" also counts as failure - so the result
            # is judged by whether syncthing.exe is there afterwards.
            & winget install --id Syncthing.Syncthing --exact --scope user --silent `
                --accept-package-agreements --accept-source-agreements
            $source = Find-WingetSyncthing
        } else {
            Write-Host "winget is not available on this computer."
        }
    }

    if (-not $source) {
        Write-Host ""
        Write-Host "Could not get Syncthing onto this computer."
        Write-Host "Download Syncthing for Windows (64-bit) from https://syncthing.net/downloads/"
        Write-Host "take syncthing.exe out of it, put it in the same folder as"
        Write-Host "setup-langtechdepot.bat, and double-click the .bat again."
        Write-Host "More help: $HELP_URL"
        Exit-Script -Code 1
    }

    Copy-Item -Path $source -Destination $BIN -Force
}
Write-Chatter "Using Syncthing at $BIN"

# Helper functions for reading/writing values in config.xml.
#
# Both load the file with XmlDocument.Load and PreserveWhitespace = $true,
# never with [xml](Get-Content ...). Two reasons:
#  - Without PreserveWhitespace, XmlDocument.Save re-indents the WHOLE file,
#    and writes every empty element (e.g. <urUniqueID></urUniqueID>) as an
#    open tag, a line break, indentation and a close tag. Syncthing then reads
#    that line break and indentation as the field's value, and saves it back
#    as <urUniqueID>&#xA;        </urUniqueID>. This damage was long blamed on
#    Syncthing; it came from here. With PreserveWhitespace, Save writes the
#    file back exactly as it was read, apart from the node we changed.
#  - Windows PowerShell's Get-Content reads a UTF-8 file that has no
#    byte-order mark (as config.xml is) in the local ANSI code page, which
#    garbles non-ASCII device and folder names. XmlDocument.Load reads UTF-8.
# (The document is built inside each function rather than returned from a
# shared helper, because PowerShell would unroll a returned XmlDocument into
# its child nodes.)
function Get-XmlNodeText {
    param([string]$path, [string]$xpath)
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($path)
    return $xml.SelectSingleNode($xpath).InnerText
}

function Set-XmlNodeText {
    param([string]$path, [string]$xpath, [string]$value)
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($path)
    $node = $xml.SelectSingleNode($xpath)
    if ($node) {
        $node.InnerText = $value
        $xml.Save($path)
    }
}

# ============================================================================
# CLEAN-UP FOR CONFIGS DAMAGED BY EARLIER VERSIONS OF THIS INSTALLER - START
# ----------------------------------------------------------------------------
# Earlier versions of Set-XmlNodeText (above) re-indented config.xml and so
# split every empty element over two lines. Syncthing stored that line break
# and indentation as the field's value, and has written it out ever since as
# e.g. <encryptionPassword>&#xA;        </encryptionPassword>. The helper is
# fixed, so a fresh install no longer gets this damage, but machines set up
# with an older installer keep it until something clears it.
#
# Test-ConfigNeedsRepair says whether config.xml still carries that damage;
# Repair-CorruptedEmptyXmlFields turns it back into clean empty elements.
# The repair edits config.xml directly, so it must only be run while
# Syncthing is NOT running. Both read (and the repair writes) UTF-8
# explicitly: Get-Content/Set-Content in Windows PowerShell would use the
# ANSI code page and garble non-ASCII names.
#
# TO REMOVE once no field machine still has an old-installer config: delete
# these two functions and the block near the end of this script that calls
# them (search for "CLEAN-UP FOR CONFIGS DAMAGED BY EARLIER VERSIONS").
$DamagedEmptyElement = '<(\w+)([^>]*)>&#xA;\s*</\1>'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Test-ConfigNeedsRepair {
    param([string]$path)
    $raw = [System.IO.File]::ReadAllText($path, $Utf8NoBom)
    return ($raw -match $DamagedEmptyElement)
}

function Repair-CorruptedEmptyXmlFields {
    param([string]$path)
    $raw = [System.IO.File]::ReadAllText($path, $Utf8NoBom)
    $fixed = $raw -replace $DamagedEmptyElement, '<$1$2></$1>'
    if ($fixed -ne $raw) {
        [System.IO.File]::WriteAllText($path, $fixed, $Utf8NoBom)
    }
}
# CLEAN-UP FOR CONFIGS DAMAGED BY EARLIER VERSIONS OF THIS INSTALLER - END
# ============================================================================

# Syncthing's command-line arguments for our instance. Start-Process in
# Windows PowerShell joins an argument array with spaces and no quoting, so a
# profile path with a space in it (C:\Users\Ana Silva\...) would split in two;
# the path is quoted here by hand instead.
$HomeArg  = "--home `"$CONFIG_DIR`""
# --no-console hides the console window Syncthing would otherwise keep open
# (on Windows 11 24H2 and later Syncthing hides it anyway). Without it, the
# Startup shortcut leaves a console on the taskbar at every logon, and
# closing that window stops syncing.
$ServeArgs = "serve --no-browser --no-console $HomeArg"

# Generate config.xml if it does not exist. "generate" has no flag to set the
# GUI address directly (that only exists on "serve" and "cli"), so the
# address is patched into the freshly written config.xml afterward instead -
# the standard port (8384), or, when something else already listens there,
# a free one (see "Which port our Syncthing's page is on" below).
$configFile = "$CONFIG_DIR\config.xml"
if (-not (Test-Path $configFile)) {
    Start-Process -FilePath $BIN -ArgumentList "generate $HomeArg" -NoNewWindow -Wait
    Set-XmlNodeText -path $configFile -xpath "//configuration/gui/address" -value "127.0.0.1:8384"
}

# Our Syncthing, told apart from any other on the machine - the user's own,
# SyncTrayzor's, another account's - by the --home on its command line.
# Get-Process -Name syncthing cannot tell them apart. (Syncthing runs as a
# monitor process plus a child with the same command line; both match.)
function Get-OurSyncthing {
    # --home followed by exactly our folder: quoted (this version), or bare
    # and then a space or the end (earlier versions, which did not quote it).
    $dir = [regex]::Escape([System.IO.Path]::GetFullPath($CONFIG_DIR).TrimEnd('\'))
    $homePattern = '(^|\s)--home[\s=]+("' + $dir + '\\?"|' + $dir + '\\?(\s|$))'
    try {
        return @(Get-CimInstance -ClassName Win32_Process -Filter "Name='syncthing.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine -match $homePattern })
    } catch {
        # WMI unavailable: fall back to the program's path, which is ours
        # far more often than not.
        return @(Get-Process -Name "syncthing" -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -ieq $BIN } |
            ForEach-Object { [PSCustomObject]@{ ProcessId = $_.Id } })
    }
}

function Stop-OurSyncthing {
    foreach ($p in @(Get-OurSyncthing)) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    # Give Windows a moment to release config.xml and the GUI port.
    Start-Sleep -Seconds 2
}

function Start-OurSyncthing {
    Start-Process -FilePath $BIN -ArgumentList $ServeArgs -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

# Which port our Syncthing's page is on. 8384 is Syncthing's usual port, but
# a Syncthing the user runs for themselves may already hold it, and two
# cannot share one. So, whenever ours is not running yet, the port in our
# config.xml is checked first: if something else is listening there, ours
# moves to 8384 if that is free, or else to any free port. Everything below
# reads the address back from config.xml rather than assuming 8384.
function Test-PortInUse {
    param([int]$Port)
    # Two checks, because Windows lets a program bind 127.0.0.1:N while
    # another holds 0.0.0.0:N: first, does anything answer there at all...
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $attempt = $client.BeginConnect([System.Net.IPAddress]::Loopback, $Port, $null, $null)
        if ($attempt.AsyncWaitHandle.WaitOne(1500) -and $client.Connected) { return $true }
    } catch {
    } finally {
        $client.Close()
    }
    # ...and second, could Syncthing take the address itself?
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.ExclusiveAddressUse = $true
        $listener.Start()
        $listener.Stop()
        return $false
    } catch {
        return $true
    }
}

function Get-FreePort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    return $port
}

function Get-GuiPort {
    $addr = [string](Get-XmlNodeText -path $configFile -xpath "//configuration/gui/address")
    if ($addr -match ':(\d+)$') { return [int]$matches[1] }
    return 0
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

# Rewritten on every run, so a shortcut made by an earlier version picks up
# the current arguments (--no-console in particular).
try {
    $wshShell = New-Object -ComObject WScript.Shell
    $shortcut = $wshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath       = $BIN
    $shortcut.Arguments        = $ServeArgs
    $shortcut.WorkingDirectory = $BIN_DIR
    $shortcut.WindowStyle      = 7   # Minimized, in case --no-console is ever not honoured
    $shortcut.Description      = "Runs LangTechDepot's Syncthing in the background at logon"
    $shortcut.Save()
} catch {
    Write-Host "Note: could not create the Startup shortcut for Syncthing: $_"
}

# Make sure it's running right now too, not just at the next logon - first
# moving it off a port something else has taken (see Test-PortInUse above).
if (@(Get-OurSyncthing).Count -eq 0) {
    $guiPort = Get-GuiPort
    if (-not $guiPort -or (Test-PortInUse $guiPort)) {
        if (-not (Test-PortInUse 8384)) { $guiPort = 8384 } else { $guiPort = Get-FreePort }
        Set-XmlNodeText -path $configFile -xpath "//configuration/gui/address" -value "127.0.0.1:$guiPort"
    }
    Start-OurSyncthing
}

# Helper functions for REST API
$API_KEY  = Get-XmlNodeText -path $configFile -xpath "//configuration/gui/apikey"
$GUI_ADDR = [string](Get-XmlNodeText -path $configFile -xpath "//configuration/gui/address")
$guiHost  = "127.0.0.1"
$guiPort  = Get-GuiPort
if ($GUI_ADDR -match '^(.*):\d+$' -and $matches[1] -notin @("", "0.0.0.0", "[::]", "::", "localhost", "127.0.0.1")) {
    # Someone pointed it at a particular address on purpose; use that.
    $guiHost = $matches[1]
}
$GUI_URL = "http://${guiHost}:$guiPort"
# The same page, as people are told about it. "localhost" reads as "this
# computer" to someone who is not a network engineer. Syncthing itself stays
# bound to 127.0.0.1 and this script talks to it there: "localhost" can mean
# the IPv6 address ::1 first, where nothing is listening. Browsers quietly
# fall back to 127.0.0.1, so the friendly name works for people.
if ($guiHost -eq "127.0.0.1") { $GUI_PAGE = "http://localhost:$guiPort" } else { $GUI_PAGE = $GUI_URL }
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
        # Sent as UTF-8 bytes. Given a string, Windows PowerShell's
        # Invoke-RestMethod encodes it as ISO-8859-1 unless the content type
        # names a charset, which mangles any name outside Latin-1.
        $jsonBody = $Body | ConvertTo-Json -Depth 10 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
        return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -Body $bytes -ContentType "application/json; charset=utf-8"
    } else {
        return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers
    }
}

Write-Chatter "Waiting for Syncthing..."
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
    # Write-Host, not Write-Error: with ErrorActionPreference Stop, Write-Error
    # would end the script here without the help line.
    Write-Host "Syncthing did not answer at $GUI_URL within 60 seconds."
    Write-Host "Restarting the computer and running this again usually fixes it."
    Write-Host "More help: $HELP_URL"
    Exit-Script -Code 1
}

$MY_ID = $status.myID
$DEVICE_NAME = "$env:USERNAME-$env:COMPUTERNAME"

# Set Device Name
Invoke-SyncthingApi -Method "PATCH" -Endpoint "/rest/config/devices/$MY_ID" -Body @{ name = $DEVICE_NAME } | Out-Null

Write-Chatter ""
Write-Chatter "This machine's device ID: $MY_ID"

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
    Write-Chatter "Already registered with $SERVER_NAME."
    Wait-ForReader -Seconds 3
    Write-Chatter " "
} elseif ($CliMode) {
    # Asking for a token in the middle of a command would be a surprise.
    Write-Host "${ScriptName}: this computer is not registered with LangTechDepot yet."
    Write-Host "Run setup-langtechdepot.bat and enter your token first. More help: $HELP_URL"
    Exit-Script -Code 1
} else {
    Write-Host "No token yet? Register at $REGISTER_URL/signup?os=windows"
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
            # UTF-8 bytes, for the same reason as in Invoke-SyncthingApi: a
            # string body goes out as ISO-8859-1, and a user or computer name
            # outside Latin-1 would then never register.
            $regBytes = [System.Text.Encoding]::UTF8.GetBytes($regBody)
            $RESPONSE = Invoke-RestMethod -Uri "$REGISTER_URL/register" -Method "POST" -Body $regBytes -ContentType "application/json; charset=utf-8"
            Write-Host ""
            Write-Host "Registered."
            break
        } catch {
            $REASON = "registration failed"
            # The server answers an error as {"error": "..."}. Depending on
            # the response, Windows PowerShell has either read that body into
            # ErrorDetails.Message already (leaving the stream spent) or left
            # it in the stream, so both are tried, in that order.
            $errText = $null
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $errText = $_.ErrorDetails.Message
            } elseif ($_.Exception.Response) {
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    if ($stream.CanSeek) { $stream.Position = 0 }
                    $errText = ([System.IO.StreamReader]::new($stream)).ReadToEnd()
                } catch {}
            } elseif ($_.Exception.Message) {
                # No answer at all: no connection, DNS, a proxy...
                $REASON = $_.Exception.Message
            }
            if ($errText) {
                try {
                    $errObj = $errText | ConvertFrom-Json
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

    # NOTE: encryptionPassword is not a valid field on this top-level device
    # registry object (it only exists on a per-folder device-share entry -
    # see the /rest/config/folders calls further down), so it is not sent
    # here; Syncthing's REST API would silently drop it.
    Invoke-SyncthingApi -Method "POST" -Endpoint "/rest/config/devices" -Body @{
        deviceID   = $SERVER_ID
        name       = $SERVER_NAME
        addresses  = $SERVER_ADDRS
        introducer = $true
    } | Out-Null
}

# -----------------------------------------------------------------------------
# Install modify-langtechdepot
# -----------------------------------------------------------------------------
# A copy of the very .bat this run came from, under a second name, beside
# LangTechDepot's syncthing.exe; and that folder on the user's PATH, so
# "modify-langtechdepot ..." works in any Command Prompt opened afterwards.
# Re-copied on every run, so it is always the installer that last ran. Both
# are per-user and need no administrator rights. Neither is fatal: the
# installer's real job gets done without them.
function Add-ToUserPath {
    param([string]$Dir)
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
        # Read the raw text, so entries such as %USERPROFILE%\... stay
        # unexpanded, and write it back as the same REG_EXPAND_SZ type.
        # [Environment]::Get/SetEnvironmentVariable would expand them all
        # and turn the value into a plain string.
        $raw = [string]$key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $entries = @($raw -split ";" | Where-Object { $_ })
        $already = $entries | Where-Object {
            [Environment]::ExpandEnvironmentVariables($_).TrimEnd("\") -ieq $Dir.TrimEnd("\")
        }
        if (-not $already) {
            $key.SetValue("Path", ((@($entries) + $Dir) -join ";"), [Microsoft.Win32.RegistryValueKind]::ExpandString)
            # Tell Windows the environment changed, so Command Prompts opened
            # from now on see the new PATH without logging out. .NET sends
            # that notice after any change to a user variable, so clearing a
            # variable that does not exist is the simplest way to send it.
            [Environment]::SetEnvironmentVariable("LANGTECHDEPOT_PATH_NOTICE", $null, "User")
        }
        $key.Close()
    } catch {
        Write-Host "Note: could not add $Dir to your PATH: $_"
    }
}

$ModifyBat = Join-Path $BIN_DIR "modify-langtechdepot.bat"
if ($Self -and (Test-Path $Self)) {
    try {
        # When this run IS modify-langtechdepot.bat, it is already in place.
        if ([System.IO.Path]::GetFullPath($Self) -ine [System.IO.Path]::GetFullPath($ModifyBat)) {
            Copy-Item -Path $Self -Destination $ModifyBat -Force
        }
    } catch {
        Write-Host "Note: could not install modify-langtechdepot: $_"
    }
}
if (Test-Path $ModifyBat) { Add-ToUserPath -Dir $BIN_DIR }

# Which version last ran here, so a later version can tell what it is
# upgrading from if that ever matters.
try {
    [System.IO.File]::WriteAllText((Join-Path $CONFIG_DIR "installed-version.txt"), "$LTD_VERSION`r`n", $Utf8NoBom)
} catch {}

# -----------------------------------------------------------------------------
# Where LangTechDepot's synced files live
# -----------------------------------------------------------------------------
# Chosen once via a folder picker (so it can go on a different drive, an
# external disk, etc.) and then remembered by saving it into Syncthing's own
# "default folder" setting - the same setting the Syncthing web GUI itself
# uses to pre-fill the path when she clicks "Add Folder". That makes it a
# single shared source of truth: on later runs we just read back whatever is
# there, which also means if she changes it herself in the GUI, this script
# picks up that change too, rather than silently overriding it.
#
# Syncthing keeps each folder's own path fixed once that folder is created,
# so this only prompts until a place has been chosen - picking somewhere
# different on a later run would only affect brand-new folders and leave
# existing ones right where they already are. "Chosen" is read from that
# same setting, not from whether config.xml existed before this run: a first
# run that stopped earlier (at the token prompt, say) has a config.xml but
# never asked, and the next run must ask.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Two places, kept apart on purpose:
#   $HOME_BASE   %USERPROFILE%\LangTechDepot - always here, pinned in Explorer.
#                Holds READ-ME.txt, "Change my Assets", "Am I up-to-date..."
#                and "Assets". It is the one place anyone is ever told to look.
#   $DATA_ROOT   where Syncthing puts the synced folders (the Assets). By
#                default $HOME_BASE\Assets, a real folder; if the user picks
#                somewhere else (another drive, a USB disk, a NoBackup folder),
#                "Assets" in $HOME_BASE is a shortcut to it instead.
# So the instructions are the same for everyone, and on a machine whose
# Assets live on a USB disk, the support items do not vanish when the disk
# is unplugged.
$HOME_BASE      = Join-Path $HOME "LangTechDepot"
$DEFAULT_ASSETS = Join-Path $HOME_BASE "Assets"

function Test-SamePath {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    try {
        return ([System.IO.Path]::GetFullPath($A).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($B).TrimEnd('\'))
    } catch {
        return $false   # not a usable path at all
    }
}

# Syncthing leaves this setting empty in a new config (some versions say "~",
# the home folder). This script never saves any of those, nor the home folder
# itself, so each means the question has not been answered yet.
$savedRoot = [string](Invoke-SyncthingApi -Method "GET" -Endpoint "/rest/config/defaults/folder").path
$locationChosen = $savedRoot -and ($savedRoot.Trim() -notin @("~", "~\", "~/")) -and
    -not (Test-SamePath $savedRoot $HOME)

if ($locationChosen) {
    $DATA_ROOT = $savedRoot
} elseif ($CliMode) {
    # Never a dialog in command-line mode; the usual place it is.
    $DATA_ROOT = $DEFAULT_ASSETS
} else {
    $defaultRoot = $DEFAULT_ASSETS

    # The chooser opens on the suggested Assets folder itself, so just
    # clicking OK takes it. It has to exist to be preselected; if something
    # else is chosen, the empty one is tidied away again below. (Opening on
    # $HOME instead, as this once did, meant a plain OK scattered everything
    # loose in the user's home folder.)
    $madeDefault = -not (Test-Path $defaultRoot)
    New-Item -ItemType Directory -Force -Path $defaultRoot | Out-Null

    # The dialog's own text area holds only about two short lines (and its
    # size cannot be changed from Windows PowerShell), so the fuller
    # explanation goes in the console just before it opens.
    Write-Host ""
    Write-Host "Next: where to keep your LangTechDepot Assets - the folders of files"
    Write-Host "that come from the depot. Click OK for the suggested place:"
    Write-Host "    $defaultRoot"
    Write-Host "or pick another drive, such as a USB disk; a folder called"
    Write-Host "LangTechDepot will be made there."
    Write-Host ""
    Start-Sleep -Seconds 5

    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = "Where should your LangTechDepot Assets be kept? Click OK for the suggested place."
    $folderDialog.ShowNewFolderButton = $true
    $folderDialog.SelectedPath = $defaultRoot

    # FolderBrowserDialog has no TopMost property of its own (it's a Win32
    # wrapper, not a Form) and no owner window, so - same problem as the
    # folder-selection dialog further down this script - it can open behind
    # the console and never get focus. A tiny invisible TopMost form as its
    # owner is the standard workaround.
    $ownerForm = New-Object System.Windows.Forms.Form
    $ownerForm.FormBorderStyle = "None"
    $ownerForm.ShowInTaskbar = $false
    $ownerForm.StartPosition = "Manual"
    $ownerForm.Location = New-Object System.Drawing.Point(-2000, -2000)
    $ownerForm.Size = New-Object System.Drawing.Size(1, 1)
    $ownerForm.Opacity = 0
    $ownerForm.TopMost = $true
    $ownerForm.Show()

    $result = $folderDialog.ShowDialog($ownerForm)
    $ownerForm.Close()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $folderDialog.SelectedPath) {
        $picked = $folderDialog.SelectedPath
        if (Test-SamePath $picked $HOME_BASE) {
            # The home folder itself: the Assets go in their usual place in it.
            $DATA_ROOT = $DEFAULT_ASSETS
        } elseif ((Split-Path $picked -Leaf) -in @("LangTechDepot", "Assets")) {
            $DATA_ROOT = $picked
        } else {
            # Whatever else was picked - a drive, a USB disk, a NoBackup
            # folder - the files go in a folder called LangTechDepot there,
            # never loose in it. On a disk someone carries or lends, that
            # name says what it is.
            $DATA_ROOT = [System.IO.Path]::Combine($picked, "LangTechDepot")
        }
        # The Assets are always a folder of their own, never the home folder
        # $HOME_BASE itself (the layout before version 1.1): picking the
        # user's own profile folder, for one, makes $picked\LangTechDepot,
        # which is exactly $HOME_BASE.
        if (Test-SamePath $DATA_ROOT $HOME_BASE) {
            $DATA_ROOT = $DEFAULT_ASSETS
            Write-Host "That is where the LangTechDepot folder itself goes, so the Assets will be"
            Write-Host "kept in the Assets folder inside it: $DATA_ROOT"
        }
    } else {
        $DATA_ROOT = $defaultRoot
        Write-Host "No folder chosen - using the default location: $DATA_ROOT"
    }
    if ($madeDefault -and -not (Test-SamePath $DATA_ROOT $defaultRoot) -and
        -not (Get-ChildItem -Path $defaultRoot -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -Path $defaultRoot -ErrorAction SilentlyContinue
    }
}

New-Item -ItemType Directory -Force -Path $DATA_ROOT | Out-Null

# Default Receive-only setup - also what the Syncthing GUI's own "Add
# Folder" button offers as a starting path, per the comment block above.
Invoke-SyncthingApi -Method "PATCH" -Endpoint "/rest/config/defaults/folder" -Body @{
    type = "receiveonly"
    path = $DATA_ROOT
} | Out-Null

# -----------------------------------------------------------------------------
# Make the LangTechDepot folder easy to find and use
# -----------------------------------------------------------------------------
# The programs live out of sight in AppData; $HOME_BASE (see above) is the
# part people use. It gets:
#   Assets                                     the synced folders: a real folder,
#                                              or a shortcut when they are elsewhere
#   READ-ME.txt                                what this is and what to do
#   Change my Assets.lnk                       modify-langtechdepot: the dialog
#   Am I up-to-date, and advanced management   the Syncthing page in a browser
# and is pinned to File Explorer's Quick access. The files are rewritten on
# every run, so they stay current and come back if deleted. The pin is done
# once only (a marker file in $CONFIG_DIR remembers it), so someone who unpins
# it is not overruled on the next run. None of this is fatal.
New-Item -ItemType Directory -Force -Path $HOME_BASE | Out-Null
$ChangeLink  = Join-Path $HOME_BASE "Change my Assets.lnk"
$GuiLink     = Join-Path $HOME_BASE "Am I up-to-date, and advanced management.url"
$ReadMe      = Join-Path $HOME_BASE "READ-ME.txt"
$AssetsLink  = Join-Path $HOME_BASE "Assets.lnk"
$PinnedMark  = Join-Path $CONFIG_DIR "pinned-to-quick-access.txt"

# Where the Assets are, relative to the home folder:
#   in its Assets folder (the default), elsewhere (shortcut), or - on a
#   machine set up before version 1.1 - directly in the home folder itself.
$AssetsHere   = Test-SamePath $DATA_ROOT $DEFAULT_ASSETS
$OldLayout    = Test-SamePath $DATA_ROOT $HOME_BASE
$AssetsAway   = -not ($AssetsHere -or $OldLayout)

# Tidy items earlier versions made: the shortcut's old name, and the three
# support items that 1.0.x wrote beside the synced folders wherever they were.
try {
    $stale = @(Join-Path $HOME_BASE "Change my folders.lnk")
    if (-not $OldLayout) {
        foreach ($n in @("READ-ME.txt", "Change my folders.lnk", "Am I up-to-date, and advanced management.url")) {
            $stale += (Join-Path $DATA_ROOT $n)
        }
    }
    foreach ($f in $stale) { if (Test-Path -LiteralPath $f -PathType Leaf) { Remove-Item -LiteralPath $f } }
} catch {
    Write-Host "Note: could not tidy items left by an earlier version: $_"
}

# "Assets": a shortcut only when the Assets are kept somewhere else.
try {
    if ($AssetsAway) {
        # An empty Assets folder (from the chooser's suggestion) would sit
        # beside the shortcut under the same name; a non-empty one is left.
        if ((Test-Path -LiteralPath $DEFAULT_ASSETS -PathType Container) -and
            -not (Get-ChildItem -LiteralPath $DEFAULT_ASSETS -Force)) {
            Remove-Item -LiteralPath $DEFAULT_ASSETS
        }
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut($AssetsLink)
        $lnk.TargetPath  = $DATA_ROOT
        $lnk.Description = "Your LangTechDepot Assets, kept at $DATA_ROOT"
        $lnk.Save()
    } elseif (Test-Path -LiteralPath $AssetsLink) {
        Remove-Item -LiteralPath $AssetsLink
    }
} catch {
    Write-Host "Note: could not create the 'Assets' shortcut: $_"
}

if ($AssetsHere) {
    $assetsText = @"
  Assets
      The LangTechDepot folders you chose, such as Android_apps or Keyman.
"@
} elseif ($AssetsAway) {
    $assetsText = @"
  Assets
      A shortcut to the LangTechDepot folders you chose, such as
      Android_apps or Keyman. They are kept at:
      $DATA_ROOT
"@
} else {
    $assetsText = @"
  The other folders here (such as Android_apps or Keyman)
      The LangTechDepot folders you chose.
"@
}
$listPath = "Assets\All_Contents_List\LangTechDepotFiles.txt"
if ($OldLayout) { $listPath = "All_Contents_List\LangTechDepotFiles.txt" }

try {
    $readMeText = @"
LangTechDepot
=============
(Set up by LangTechDepot version $LTD_VERSION.)

In this folder:

$assetsText
      Each is kept up to date from the LangTechDepot server, automatically,
      whenever this computer is on the internet. Please don't change or
      delete files inside them: they are a copy of what is on the server.
      To change an installer, copy it somewhere else first.

      $listPath
      lists every file available in the depot, and the size of each folder.

  Change my Assets
      Add folders, take back ones you ignored, or stop ones you no longer
      need. Opens the same list of folders you saw when you installed.

  Am I up-to-date, and advanced management
      Opens the Syncthing page ($GUI_PAGE) in your web browser.
      When every folder there says "Up to Date", you have everything -
      check this before you travel.

For Command Prompt users:
  modify-langtechdepot list                 every folder and its state
  modify-langtechdepot add <FolderID>       subscribe to a folder
  modify-langtechdepot ignore <FolderID>    stop syncing a folder

Help: $HELP_URL
"@
    # Notepad on older Windows 10 shows LF-only text as one long line.
    $readMeText = ($readMeText -replace "`r?`n", "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($ReadMe, $readMeText, (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Write-Host "Note: could not write $ReadMe : $_"
}

try {
    # An Internet shortcut: double-clicking it opens the default browser.
    $urlText = "[InternetShortcut]`r`nURL=$GUI_PAGE/`r`n"
    [System.IO.File]::WriteAllText($GuiLink, $urlText, [System.Text.Encoding]::ASCII)
} catch {
    Write-Host "Note: could not create the shortcut to the Syncthing page: $_"
}

if (Test-Path $ModifyBat) {
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut($ChangeLink)
        $lnk.TargetPath       = $ModifyBat
        $lnk.WorkingDirectory = $BIN_DIR
        $lnk.Description      = "Choose which LangTechDepot folders this computer keeps"
        $lnk.Save()
    } catch {
        Write-Host "Note: could not create the 'Change my Assets' shortcut: $_"
    }
}

# Pinned once. A marker naming another folder means an earlier version
# pinned the synced folders themselves; pin the home folder now instead.
# Read and written as UTF-8: $HOME_BASE holds the user's name, which
# Get-Content/Set-Content would pass through the ANSI code page.
$pinnedBefore = (Test-Path $PinnedMark) -and
    ([System.IO.File]::ReadAllText($PinnedMark, $Utf8NoBom).Contains("$HOME_BASE "))
if (-not $pinnedBefore) {
    try {
        $shell = New-Object -ComObject Shell.Application
        # Quick access, as a shell namespace. Skip the pin if the folder is
        # already listed there, so this never toggles an existing pin off.
        $quick = $shell.Namespace("shell:::{679f85cb-0220-4080-b29b-5540cc05aab6}")
        $listed = $false
        if ($quick) {
            foreach ($it in $quick.Items()) { if (Test-SamePath $it.Path $HOME_BASE) { $listed = $true } }
        }
        if (-not $listed) { $shell.Namespace($HOME_BASE).Self.InvokeVerb("pintohome") }
        [System.IO.File]::WriteAllText($PinnedMark, "Pinned $HOME_BASE to Quick access on $(Get-Date -Format s)`r`n", $Utf8NoBom)
    } catch {
        Write-Host "Note: could not pin $HOME_BASE in File Explorer: $_"
    }
}

# Adds or removes one folder ID in the server device's ignoredFolders list.
# We still GET first because we need the current list to change - but we
# PATCH just the ignoredFolders field back, rather than PUTting the whole
# device object. A PUT here would round-trip every other field on the device
# (addresses, introducer, paused, etc.) through us, and if Syncthing changed
# any of those between our GET and our PUT (e.g. the user editing something
# in the GUI at the same time, or Syncthing updating its own connection state)
# we'd silently clobber that change. PATCH only touches the field we name.
# Syncthing's PATCH replaces the whole array, so the full new list is sent.
function Set-FolderIgnored {
    param([string]$FolderID, [string]$Label, [bool]$Ignore)

    $devConfig = Invoke-SyncthingApi -Method "GET" -Endpoint "/rest/config/devices/$SERVER_ID"
    $curIgnores = @($devConfig.ignoredFolders | Where-Object { $_ })
    $isIgnored = [bool]($curIgnores | Where-Object { $_.id -eq $FolderID })

    if ($Ignore) {
        if ($isIgnored) { Write-Host "Folder already marked as ignored: $FolderID"; return }
        $newIgnore = @{
            id    = $FolderID
            label = $Label
            # Invariant culture: the ":" in a .NET format string is the
            # culture's time separator, which is not ":" everywhere.
            time  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        }
        # Array concatenation returns a new array - simpler and safer here
        # than trying to grow $curIgnores in place.
        $updated = @($curIgnores) + $newIgnore
        Invoke-SyncthingApi -Method "PATCH" -Endpoint "/rest/config/devices/$SERVER_ID" -Body @{ ignoredFolders = $updated } | Out-Null
        Write-Host "Successfully ignored folder via API: $FolderID"
    } else {
        if (-not $isIgnored) { return }
        # @(...) keeps an empty result an empty array, so the last ignore can
        # be removed and Syncthing receives [] rather than null.
        $updated = @($curIgnores | Where-Object { $_.id -ne $FolderID })
        Invoke-SyncthingApi -Method "PATCH" -Endpoint "/rest/config/devices/$SERVER_ID" -Body @{ ignoredFolders = $updated } | Out-Null
        Write-Host "No longer ignoring: $FolderID"
    }
}

# -----------------------------------------------------------------------------
# AUTO-SUBSCRIBE: All_Contents_List
# -----------------------------------------------------------------------------
$AUTO_FOLDER_ID   = "All_Contents_List"
$AUTO_FOLDER_PATH = Join-Path $DATA_ROOT $AUTO_FOLDER_ID

# Already subscribed (a re-run): leave the folder exactly as it is. POSTing
# it again would replace its device list with the server alone, dropping the
# peers the introducer has added since - the LAN sharing G5 depends on. Its
# own path is used, too, in case it is not where $DATA_ROOT says.
$autoFolder = $null
try {
    # foreach, not a pipeline: Windows PowerShell can pass a whole JSON array
    # down a pipeline as one object.
    foreach ($fld in (Invoke-SyncthingApi -Method "GET" -Endpoint "/rest/config/folders")) {
        if ($fld.id -eq $AUTO_FOLDER_ID) { $autoFolder = $fld; break }
    }
} catch {}

if ($autoFolder) {
    if ($autoFolder.path) { $AUTO_FOLDER_PATH = $autoFolder.path }
} else {
    Write-Chatter "Subscribing to $AUTO_FOLDER_ID, which contains a list"
    Write-Chatter "of all the files available in the Depot"
    Write-Chatter "and the size of each folder you can subscribe to ..."
    Write-Chatter " "
    Wait-ForReader -Seconds 4
    New-Item -ItemType Directory -Force -Path $AUTO_FOLDER_PATH | Out-Null

    # encryptionPassword IS a valid field on this per-folder device-share entry
    # (unlike the top-level device registry entry above, where it's silently
    # ignored). "" means this device is trusted and gets the files unencrypted,
    # which is Syncthing's default anyway; it is spelled out here for clarity.
    Invoke-SyncthingApi -Method "POST" -Endpoint "/rest/config/folders" -Body @{
        id              = $AUTO_FOLDER_ID
        label           = "All_Contents_List -- a list of all files available"
        path            = $AUTO_FOLDER_PATH
        type            = "receiveonly"
        rescanIntervalS = 3600
        fsWatcherEnabled = $true
        devices         = @(@{ deviceID = $SERVER_ID; encryptionPassword = "" })
    } | Out-Null

    Write-Chatter "Sync data root: $DATA_ROOT"
    Write-Chatter "Automatically subscribed to: $AUTO_FOLDER_ID"
    Write-Chatter "The folder catalog will appear within a minute or two."
    Write-Chatter " "
    Wait-ForReader -Seconds 4
}
$CATALOG_FILE = Join-Path $AUTO_FOLDER_PATH "LangTechDepotFiles.txt"

# The catalog folder is never ignored: the installer cannot build its list
# without it. Older versions let the dialog untick it; undo that here.
try {
    Set-FolderIgnored -FolderID $AUTO_FOLDER_ID -Label $AUTO_FOLDER_ID -Ignore $false
} catch {
    Write-Host "Note: could not take $AUTO_FOLDER_ID off the ignore list: $_"
}

if (-not (Test-Path $CATALOG_FILE) -or (Get-Item $CATALOG_FILE).Length -eq 0) {
    Write-Host "Waiting for catalog file to sync from server..."
}
$catalogTimeoutSeconds = 180
$catalogWaited = 0
while (-not (Test-Path $CATALOG_FILE) -or (Get-Item $CATALOG_FILE).Length -eq 0) {
    Start-Sleep -Seconds 2
    $catalogWaited += 2
    if ($catalogWaited -ge $catalogTimeoutSeconds) {
        Write-Host ""
        Write-Warning "Still waiting for the folder catalog after $catalogTimeoutSeconds seconds."
        Write-Host "Syncthing is running, but hasn't finished syncing $AUTO_FOLDER_ID from the server yet."
        Write-Host "Open $GUI_PAGE and check the Folders list and any red or yellow notices there."
        Write-Host "Syncthing will keep running in the background - once $AUTO_FOLDER_ID shows"
        Write-Host "'Up to Date' there, just run this installer again to pick your folders."
        Exit-Script -Code 1
    }
}

# -----------------------------------------------------------------------------
# What is on offer, and what this device already has
# -----------------------------------------------------------------------------
# Shared by the dialog and by command-line mode. Each returns a plain array;
# callers wrap the call in @(...), since PowerShell unrolls a returned
# collection and a single item would otherwise stop being an array.

# Folders listed in the catalog file, in catalog order.
function Get-CatalogEntries {
    param([string]$CatalogPath)
    $entries = [System.Collections.ArrayList]::new()
    $inFolders = $false
    # UTF-8 explicitly: Windows PowerShell's Get-Content would read the
    # descriptions in the ANSI code page and garble anything non-ASCII.
    foreach ($line in [System.IO.File]::ReadAllLines($CatalogPath, [System.Text.Encoding]::UTF8)) {
        $line = $line.Trim()
        if ($line -like "*Folders available, with their sizes*") { $inFolders = $true; continue }
        if ($line -like "*Individual files available*") { break }
        if (-not $inFolders -or -not $line) { continue }

        if ($line -match '^\s*(\S+)\s+(\S+?)\s*"(.*)"\s*$') {
            $entries.Add([PSCustomObject]@{
                Size        = $matches[1]
                FolderID    = $matches[2]
                Description = $matches[3]
            }) | Out-Null
        }
    }
    return $entries.ToArray()
}

# IDs of the folders this device syncs now.
function Get-SubscribedFolderIds {
    $ids = [System.Collections.ArrayList]::new()
    try {
        foreach ($fld in (Invoke-SyncthingApi -Method "GET" -Endpoint "/rest/config/folders")) {
            if ($fld.id) { $ids.Add([string]$fld.id) | Out-Null }
        }
    } catch {}
    return $ids.ToArray()
}

# IDs of the folders this device has told the server to stop offering.
function Get-IgnoredFolderIds {
    param([string]$ServerID)
    $ids = [System.Collections.ArrayList]::new()
    try {
        $devCfg = Invoke-SyncthingApi -Method "GET" -Endpoint "/rest/config/devices/$ServerID"
        foreach ($item in $devCfg.ignoredFolders) {
            if ($item.id) { $ids.Add([string]$item.id) | Out-Null }
        }
    } catch {}
    return $ids.ToArray()
}

# A catalog that arrived but lists no folders (cut short, or in a shape the
# parser does not know) must not look like "Operation cancelled.": that is a
# problem on the depot's side, and the user needs to hear so.
$offeredEntries = @(Get-CatalogEntries -CatalogPath $CATALOG_FILE | Where-Object { $_.FolderID -ne $AUTO_FOLDER_ID })
if ($offeredEntries.Count -eq 0) {
    Write-Host ""
    Write-Host "The list of folders arrived, but no folders could be read from it:"
    Write-Host "    $CATALOG_FILE"
    Write-Host "This is a problem with the list on the depot, not with your computer."
    Write-Host "Syncthing keeps running and will fetch a corrected list by itself;"
    Write-Host "please run this again later. More help: $HELP_URL"
    if (-not $CliMode -or $Action -eq "list") { Exit-Script -Code 1 }
    # add/ignore can still act on folders this computer already knows.
}

# -----------------------------------------------------------------------------
# GUI Folder Selection Window (.NET Windows Forms DataGridView)
# -----------------------------------------------------------------------------

function Show-FolderSelectionForm {
    param(
        [string]$CatalogPath,
        [string]$ServerID,
        # Never listed: the installer needs this folder's catalog file to
        # build this very list, so it is not the user's to untick (which
        # would ignore it). Command-line mode refuses to ignore it, too.
        [string]$CatalogID
    )

    # What this device already has, so the list opens showing it as it is.
    # Starting every row unticked would make "Apply" unsubscribe the user from
    # everything they chose on an earlier run.
    $ignored = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($id in @(Get-IgnoredFolderIds -ServerID $ServerID)) { $ignored.Add($id) | Out-Null }

    $subscribed = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($id in @(Get-SubscribedFolderIds)) { $subscribed.Add($id) | Out-Null }

    # Every folder in the catalog is listed; ignored ones are held back until
    # the user asks to see them.
    $shownRows  = [System.Collections.ArrayList]::new()
    $hiddenRows = [System.Collections.ArrayList]::new()

    foreach ($entry in @(Get-CatalogEntries -CatalogPath $CatalogPath)) {
        $fid = $entry.FolderID
        if ($fid -eq $CatalogID) { continue }

        if ($subscribed.Contains($fid))  { $status = "subscribed" }
        elseif ($ignored.Contains($fid)) { $status = "ignored" }
        else                             { $status = "new" }

        $row = [PSCustomObject]@{
            Subscribe   = $subscribed.Contains($fid)
            Status      = $status
            Size        = $entry.Size
            FolderID    = $fid
            Description = $entry.Description
        }
        if ($status -eq "ignored") { $hiddenRows.Add($row) | Out-Null }
        else                       { $shownRows.Add($row) | Out-Null }
    }
    # (An empty catalog never gets this far; see $offeredEntries above.)

    # Build UI Window
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "LangTechDepot $LTD_VERSION - Available Folders    (Space ticks, Enter applies, Esc cancels)"
    $form.Size = [System.Drawing.Size]::new(800, 520)
    # Wide enough that the left-hand buttons never slide under Apply/Cancel,
    # which are anchored to the right edge.
    $form.MinimumSize = [System.Drawing.Size]::new(660, 300)
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

    $colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colStatus.HeaderText = "Now"
    $colStatus.Name = "Status"
    $colStatus.ReadOnly = $true
    $colStatus.AutoSizeMode = "AllCells"
    $grid.Columns.Add($colStatus) | Out-Null

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

    # Populate rows. Ignored folders, when shown, are greyed so they stand
    # out from the rest; ticking one un-ignores it on Apply.
    $addRow = {
        param($item)
        $idx = $grid.Rows.Add($item.Subscribe, $item.Status, $item.Size, $item.FolderID, $item.Description)
        if ($item.Status -eq "ignored") {
            $grid.Rows[$idx].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
        }
    }
    foreach ($item in $shownRows) { & $addRow $item }

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

    # Adds the ignored folders to the list in place, rather than reopening the
    # window, so ticks the user has already made are kept. One use only.
    $btnShowIgnored = New-Object System.Windows.Forms.Button
    $btnShowIgnored.Text = "Also display ignored folders"
    $btnShowIgnored.AutoSize = $true
    $btnShowIgnored.Location = [System.Drawing.Point]::new(185, 10)
    $btnShowIgnored.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    if ($hiddenRows.Count -eq 0) {
        $btnShowIgnored.Text = "No ignored folders"
        $btnShowIgnored.Enabled = $false
    }
    $btnShowIgnored.Add_Click({
        foreach ($item in $hiddenRows) { & $addRow $item }
        $btnShowIgnored.Enabled = $false
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

    $panel.Controls.AddRange(@($btnSelectAll, $btnClearAll, $btnShowIgnored, $btnApply, $btnCancel))
    $form.Controls.AddRange(@($grid, $label, $panel))
    $form.AcceptButton = $btnApply
    $form.CancelButton = $btnCancel

    # Keyboard: Up/Down move between folders and Space ticks or unticks one.
    # Left alone, the grid takes Enter for itself (it just moves down a row)
    # and Esc only undoes the last tick, so neither ever reaches the form's
    # Apply/Cancel buttons. Marking them as the grid's own input keys sends
    # them to its KeyDown, where they do what the buttons say. EndEdit first,
    # so a tick made with Space just before Enter is not lost.
    $grid.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter -or
            $e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $e.IsInputKey = $true }
    })
    $grid.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.Handled = $true
            $e.SuppressKeyPress = $true
            $grid.EndEdit() | Out-Null
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $e.Handled = $true
            $e.SuppressKeyPress = $true
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        }
    })

    $dialogResult = $form.ShowDialog()

    if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
        $script:FolderFormCancelled = $true
        return $null
    }

    # A tick still being edited (made with Space, say) counts too.
    $grid.EndEdit() | Out-Null

    # Extract chosen selections. Ignored folders that were never displayed
    # are not returned, so they are left exactly as they are.
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

if ($CliMode) {
    # The same list of changes the dialog would hand back, but naming only
    # the folders given on the command line - anything not named is left
    # exactly as it is. Everything is checked before anything is changed, so
    # one mistyped ID changes nothing at all.
    $catalogEntries = @(Get-CatalogEntries -CatalogPath $CATALOG_FILE)
    $subscribedNow  = @(Get-SubscribedFolderIds)
    $ignoredNow     = @(Get-IgnoredFolderIds -ServerID $SERVER_ID)

    if ($Action -eq "list") {
        $fmt = "  {0,-11} {1,8}  {2,-28} {3}"
        Write-Host ($fmt -f "Now", "Size", "Folder ID", "Description")
        $listed = @()
        foreach ($e in $catalogEntries) {
            $state = if ($subscribedNow -contains $e.FolderID) { "subscribed" }
                     elseif ($ignoredNow -contains $e.FolderID) { "ignored" }
                     else { "new" }
            Write-Host ($fmt -f $state, $e.Size, $e.FolderID, $e.Description)
            $listed += $e.FolderID
        }
        # Anything this device still has that the catalog no longer lists.
        foreach ($id in ($subscribedNow + $ignoredNow)) {
            if ($listed -contains $id) { continue }
            $state = if ($subscribedNow -contains $id) { "subscribed" } else { "ignored" }
            Write-Host ($fmt -f $state, "", $id, "(not in the catalog)")
            $listed += $id
        }
        Exit-Script -Code 0
    }

    $known = @($catalogEntries | ForEach-Object { $_.FolderID }) + $subscribedNow + $ignoredNow
    $selections = [System.Collections.ArrayList]::new()
    $chosen = @()
    $problems = 0
    foreach ($want in $FolderIDs) {
        # Folder IDs are case-sensitive to Syncthing, but nobody should have
        # to get the capitals right at a command prompt.
        $fid = $known | Where-Object { $_ -ceq $want } | Select-Object -First 1
        if (-not $fid) { $fid = $known | Where-Object { $_ -ieq $want } | Select-Object -First 1 }
        if (-not $fid) {
            Write-Host "${ScriptName}: there is no folder called '$want'. Type '$ScriptName list' to see them all."
            $problems++
            continue
        }
        if ($Action -eq "ignore" -and $fid -eq $AUTO_FOLDER_ID) {
            Write-Host "${ScriptName}: $AUTO_FOLDER_ID cannot be ignored - it holds the list of"
            Write-Host "everything available, and LangTechDepot always subscribes to it again."
            $problems++
            continue
        }
        if ($chosen -contains $fid) { continue }
        $chosen += $fid
        $entry = $catalogEntries | Where-Object { $_.FolderID -ceq $fid } | Select-Object -First 1
        $size = ""
        $desc = $fid
        if ($entry) { $size = $entry.Size; $desc = $entry.Description }
        $selections.Add(@{
            Subscribe   = ($Action -eq "add")
            Size        = $size
            FolderID    = $fid
            Description = $desc
        }) | Out-Null
    }
    if ($problems) {
        Write-Host "Nothing was changed."
        Exit-Script -Code 1
    }
} else {
    $script:FolderFormCancelled = $false
    $selections = Show-FolderSelectionForm -CatalogPath $CATALOG_FILE -ServerID $SERVER_ID -CatalogID $AUTO_FOLDER_ID

    if ($script:FolderFormCancelled) {
        Write-Host "Operation cancelled."
        Exit-Script -Code 0
    }
    if (-not $selections) {
        # Applied with nothing listed (every folder ignored, none shown).
        Write-Host "Nothing to change."
        Exit-Script -Code 0
    }
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

# (Set-FolderIgnored, used below, is defined above the All_Contents_List
# section, which needs it too.)

# Counted so that command-line mode can end with a failing exit code.
$Failures = 0

foreach ($item in $selections) {
    $fid   = $item.FolderID
    $desc  = $item.Description
    $isSub = $item.Subscribe

    # 1. SUBSCRIBE (+)
    if ($isSub) {
        if ($existingFolders.Contains($fid)) {
            # Already subscribed: leave its settings alone rather than
            # re-creating it.
            Write-Host "Already subscribed to: $fid"
        } else {
            $folderPath = Join-Path $DATA_ROOT $fid
            try {
                # encryptionPassword = "" as for the All_Contents_List folder
                # above: schema-valid, Syncthing's default, spelled out for
                # clarity.
                Invoke-SyncthingApi -Method "POST" -Endpoint "/rest/config/folders" -Body @{
                    id              = $fid
                    label           = $desc
                    path            = $folderPath
                    type            = "receiveonly"
                    rescanIntervalS = 3600
                    fsWatcherEnabled = $true
                    devices         = @(@{ deviceID = $SERVER_ID; encryptionPassword = "" })
                } | Out-Null
                Write-Host "Successfully subscribed to: $fid"
            } catch {
                Write-Host "Failed to subscribe to $fid"
                $Failures++
            }
        }
        # A folder ticked after "Also display ignored folders" comes off the
        # ignore list too, so the configuration does not contradict itself.
        try {
            Set-FolderIgnored -FolderID $fid -Label $desc -Ignore $false
        } catch {
            Write-Host "Warning: Could not un-ignore $fid via API: $_"
            $Failures++
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
                $Failures++
            }
        }

        # Step B: Add folder ID to server's ignoredFolders array
        try {
            Set-FolderIgnored -FolderID $fid -Label $desc -Ignore $true
        } catch {
            Write-Host "Warning: Could not ignore $fid via API: $_"
            $Failures++
        }
    }
}

# ============================================================================
# CLEAN-UP FOR CONFIGS DAMAGED BY EARLIER VERSIONS OF THIS INSTALLER
# ----------------------------------------------------------------------------
# See Test-ConfigNeedsRepair / Repair-CorruptedEmptyXmlFields near the top of
# this script. Only a machine first set up with an older installer has this
# damage, so on most runs nothing is found and Syncthing is left running.
# When there is damage, Syncthing has to be stopped first - it holds
# config.xml open and would overwrite our fix the next time it saves - and
# then restarted the same way it was started earlier in this script.
if (Test-ConfigNeedsRepair -path $configFile) {
    Write-Host " "
    Write-Host "Tidying up config.xml (left untidy by an earlier version of this installer)..."
    # Only OUR Syncthing (see Get-OurSyncthing): any other Syncthing on this
    # computer is someone else's and is left running.
    Stop-OurSyncthing

    Repair-CorruptedEmptyXmlFields -path $configFile

    # Restart the same way it's started earlier in this script (see the
    # "Make sure it's running right now too" block above).
    Start-OurSyncthing
}
# ============================================================================

if ($CliMode) {
    if ($Failures) {
        Write-Host "${ScriptName}: $Failures change(s) failed - see above."
        Exit-Script -Code 1
    }
    Write-Host "Done. Progress is on the Syncthing page at $GUI_PAGE"
    Exit-Script -Code 0
}

Write-Host " "
Write-Host "Your LangTechDepot folder is $HOME_BASE"
Write-Host "(in File Explorer, under Quick access). In it:"
if ($AssetsAway) {
    Write-Host "  'Assets' - a shortcut to the folders you chose, kept at"
    Write-Host "     $DATA_ROOT"
} elseif ($AssetsHere) {
    Write-Host "  'Assets' - the folders you chose."
}
if (Test-Path $ModifyBat) {
    Write-Host "  'Change my Assets' - add folders, or take back ones you ignored"
    Write-Host "     (click 'Also display ignored folders' in the list to see them)."
} else {
    Write-Host "  To add folders later, or take back ones you ignored, run this"
    Write-Host "  installer again."
}
Write-Host "  'Am I up-to-date, and advanced management' - opens the Syncthing"
Write-Host "     page, $GUI_PAGE, where each folder says when it is Up to Date."
Write-Host "  READ-ME.txt - all of this, for later."
if (Test-Path $ModifyBat) {
    Write-Host " "
    Write-Host "In a Command Prompt opened from now on, you can also type, for example:"
    Write-Host "    modify-langtechdepot list"
    Write-Host "    modify-langtechdepot add Android_apps"
    Write-Host "    modify-langtechdepot ignore Android_apps"
}

Exit-Script -Code 0
