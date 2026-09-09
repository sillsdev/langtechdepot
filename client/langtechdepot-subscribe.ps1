<#
Subscribe to LangTechDepot folders, or just see what is on offer.

Right-click this file and choose "Run with PowerShell" to list the catalog and
pick folders one at a time. From a PowerShell prompt you can also name one
directly:

  .\langtechdepot-subscribe.ps1               # list, then pick interactively
  .\langtechdepot-subscribe.ps1 <folder-id>   # subscribe to one (receive-only)

No token is needed here. The token is used once, by setup-langtechdepot.ps1,
to join this machine to the cluster. After that the server offers folders and
this script accepts them. If you have not run the installer yet, run it first.
#>

param(
    [string]$FolderId,
    # Skip the "Press Enter to close" pause. For unattended runs only.
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$GuiUrl = 'http://127.0.0.1:8384'

function Wait-BeforeClosing {
    if ($NoPause) { return }
    Write-Host ''
    Read-Host 'Press Enter to close this window' | Out-Null
}

# Right-click "Run with PowerShell" closes the console the instant the script
# ends, so without this an error is on screen for a few milliseconds and then
# gone.
trap {
    Write-Host ''
    Write-Host 'Could not finish:' -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Wait-BeforeClosing
    exit 1
}

# The installer gives Syncthing its own home, so a field machine can still run
# a personal Syncthing alongside. Fall back to the standard locations for a
# machine where Syncthing was installed by hand.
function Get-SyncthingConfig {
    $candidates = @(
        Join-Path $env:LOCALAPPDATA 'LangTechDepot\config\config.xml'
        Join-Path $env:LOCALAPPDATA 'Syncthing\config.xml'
        Join-Path $env:APPDATA 'Syncthing\config.xml'
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) {
            return [pscustomobject]@{
                Path = $path
                Key  = ([xml](Get-Content $path)).configuration.gui.apikey
            }
        }
    }
    throw ("no Syncthing configuration on this machine, so there is nothing to " +
           "subscribe to yet. Run setup-langtechdepot.ps1 first - that is where your " +
           "token goes. Looked in:" + [Environment]::NewLine + "    " +
           ($candidates -join ([Environment]::NewLine + "    ")))
}

$Config  = Get-SyncthingConfig
$Headers = @{ 'X-API-Key' = $Config.Key }

function Api($Method, $Path, $Body) {
    $req = @{ Method = $Method; Uri = "$GuiUrl$Path"; Headers = $Headers; ContentType = 'application/json' }
    if ($null -ne $Body) { $req.Body = ($Body | ConvertTo-Json -Depth 10) }
    try {
        Invoke-RestMethod @req
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 403 -or $status -eq 401) {
            throw ("the Syncthing answering on $GuiUrl is not the LangTechDepot one - it " +
                   "rejected our API key. Another Syncthing is probably already running and " +
                   "holding that port. Close it, then start the LangTechDepot task from Task " +
                   "Scheduler, or just log out and back in.")
        }
        if ($null -eq $status) {
            throw ("nothing is answering at $GuiUrl. Syncthing is not running. Log out and " +
                   "back in to start it, or re-run setup-langtechdepot.ps1. (Config in use: " +
                   "$($Config.Path))")
        }
        throw $_
    }
}

function Get-Catalog {
    $pending = Api Get '/rest/cluster/pending/folders'
    [pscustomobject]@{
        Pending    = $pending
        PendingIds = @(if ($pending) { $pending.PSObject.Properties.Name })
        # { $_.id }, not the "ForEach-Object id" shorthand: with a function call
        # upstream the shorthand binds the wrong parameter set and yields one
        # empty element, which silently emptied this list.
        Have       = @(Api Get '/rest/config/folders' | ForEach-Object { $_.id })
    }
}

function Get-OfferLabel($Catalog, $Id) {
    $label = ($Catalog.Pending.$Id.offeredBy.PSObject.Properties.Value | Select-Object -First 1).label
    if ($label) { $label } else { $Id }
}

function Show-Catalog($Catalog) {
    if (-not $Catalog.PendingIds -and -not $Catalog.Have) {
        Write-Host 'Nothing on offer yet. The catalog takes a minute or two to arrive after'
        Write-Host 'you register - wait a moment and run this again.'
        return
    }
    if ($Catalog.PendingIds) {
        Write-Host ''
        Write-Host 'Available to subscribe:'
        foreach ($fid in $Catalog.PendingIds | Sort-Object) {
            Write-Host ("  {0,-24} {1}" -f $fid, (Get-OfferLabel $Catalog $fid))
        }
    }
    if ($Catalog.Have) {
        Write-Host ''
        Write-Host 'Already subscribed:'
        foreach ($fid in $Catalog.Have | Sort-Object) { Write-Host ("  {0,-24}" -f $fid) }
    }
}

function Add-Subscription($Catalog, $Id) {
    $tpl = Api Get '/rest/config/defaults/folder'
    $offer = $Catalog.Pending.$Id.offeredBy
    $root = if ($tpl.path) { $tpl.path } else { Join-Path $env:USERPROFILE 'LangTechDepot' }

    $tpl.id = $Id
    $tpl.label = Get-OfferLabel $Catalog $Id
    $tpl.path = Join-Path $root $Id
    # share with every device offering it (the server, plus introduced peers)
    $tpl.devices = @($offer.PSObject.Properties.Name | ForEach-Object { @{ deviceID = $_ } })

    Api Post '/rest/config/folders' $tpl | Out-Null
    Write-Host "subscribed to $Id -> $($tpl.path) (receive-only)"
}

$catalog = Get-Catalog

# Named on the command line: subscribe to that one and stop.
if ($FolderId) {
    if ($catalog.Have -contains $FolderId) { throw "already subscribed to $FolderId" }
    if ($catalog.PendingIds -notcontains $FolderId) {
        throw "$FolderId is not on offer (run without arguments to list what is)"
    }
    Add-Subscription $catalog $FolderId
    Wait-BeforeClosing
    exit 0
}

# No argument - the right-click case. List, then let them pick, because
# right-click gives no way to pass a folder ID.
Show-Catalog $catalog
while ($catalog.PendingIds) {
    Write-Host ''
    $choice = (Read-Host 'Folder to subscribe to (Enter to finish)').Trim()
    if (-not $choice) { break }
    if ($catalog.Have -contains $choice) {
        Write-Host "Already subscribed to $choice."
        continue
    }
    if ($catalog.PendingIds -notcontains $choice) {
        Write-Host "No folder called '$choice' on offer. Copy one of the IDs listed above."
        continue
    }
    Add-Subscription $catalog $choice
    $catalog = Get-Catalog
    Show-Catalog $catalog
}

Write-Host ''
Write-Host 'Files arrive under' (Join-Path $env:USERPROFILE 'LangTechDepot')
Write-Host "Progress is on the Syncthing page at $GuiUrl"
Wait-BeforeClosing
