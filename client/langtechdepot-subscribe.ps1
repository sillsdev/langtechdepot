<#
List the LangTechDepot folder catalog, or subscribe to one folder.

  .\langtechdepot-subscribe.ps1               # list folders on offer
  .\langtechdepot-subscribe.ps1 <folder-id>   # subscribe (receive-only)
#>
param([string]$FolderId)

$ErrorActionPreference = 'Stop'
$GuiUrl  = 'http://127.0.0.1:8384'
$HomeDir = Join-Path $env:LOCALAPPDATA 'LangTechDepot\config'
$ApiKey  = ([xml](Get-Content (Join-Path $HomeDir 'config.xml'))).configuration.gui.apikey
$Headers = @{ 'X-API-Key' = $ApiKey }

function Api($Method, $Path, $Body) {
    $args = @{ Method = $Method; Uri = "$GuiUrl$Path"; Headers = $Headers; ContentType = 'application/json' }
    if ($null -ne $Body) { $args.Body = ($Body | ConvertTo-Json -Depth 10) }
    Invoke-RestMethod @args
}

$pending = Api Get '/rest/cluster/pending/folders'
$pendingIds = @(if ($pending) { $pending.PSObject.Properties.Name })
$have = @(Api Get '/rest/config/folders' | ForEach-Object id)

if (-not $FolderId) {
    if (-not $pendingIds -and -not $have) { Write-Host 'Nothing on offer yet — give the server a minute after install.' }
    foreach ($fid in $pendingIds | Sort-Object) {
        $label = ($pending.$fid.offeredBy.PSObject.Properties.Value | Select-Object -First 1).label
        Write-Host ("  {0,-24} {1}" -f $fid, $label)
    }
    foreach ($fid in $have | Sort-Object) { Write-Host ("  {0,-24} (already subscribed)" -f $fid) }
    exit 0
}

if ($have -contains $FolderId) { throw "already subscribed to $FolderId" }
if ($pendingIds -notcontains $FolderId) { throw "$FolderId is not on offer (run without arguments to list)" }

$tpl = Api Get '/rest/config/defaults/folder'
$offer = $pending.$FolderId.offeredBy
$label = ($offer.PSObject.Properties.Value | Select-Object -First 1).label
if (-not $label) { $label = $FolderId }
$root = if ($tpl.path) { $tpl.path } else { Join-Path $env:USERPROFILE 'LangTechDepot' }

$tpl.id = $FolderId
$tpl.label = $label
$tpl.path = Join-Path $root $FolderId
# share with every device offering it (the server, plus introduced peers)
$tpl.devices = @($offer.PSObject.Properties.Name | ForEach-Object { @{ deviceID = $_ } })

Api Post '/rest/config/folders' $tpl | Out-Null
Write-Host "subscribed to $FolderId -> $($tpl.path) (receive-only)"
