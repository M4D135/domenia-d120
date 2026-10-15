# Selection presentation and request identity. No network or timer at module import.
$script:SelectionLoad = $null
$script:SelectionPreloadBound = $false
$script:CurrentObjectRequestState = $null
$script:RenderingObjectWithoutProbes = $false

function Get-DomeniaObjectReadIdentity {
    $credential = $script:Conn.Credential
    if (Get-Command Get-DomeniaRetryCredential -ErrorAction SilentlyContinue) {
        $retry = Get-DomeniaRetryCredential 'OpenAdObject'
        if ($null -ne $retry) { $credential = $retry }
    }
    $reference = 0
    if ($null -ne $credential) { $reference = [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($credential) }
    # Identifies a read context only. No password, token or credential is serialized.
    return ('{0}|{1}|{2}|{3}|{4}' -f [long]$script:SessionEpoch,[string]$script:Conn.BaseDn,[string]$script:Conn.Server,[string]$script:Conn.BindUser,$reference)
}

function Get-DomeniaRowSelectionIdentity {
    # D012: immutable identity of one result row: domain, GUID/SID, type, read account, session and generation.
    # $null when the row has no usable GUID or when the identity rules are not loaded.
    param($Row,[long]$Generation=[long]$script:GlobalSearchGeneration)
    if ($null -eq $Row -or $null -eq (Get-Command New-DomeniaSelectionIdentity -CommandType Function -ErrorAction SilentlyContinue)) { return $null }
    $domain = [string]$script:Conn.BaseDn
    if ([string]::IsNullOrWhiteSpace($domain)) { $domain = [string]$script:Conn.Domain }
    try { return (New-DomeniaSelectionIdentity -Row $Row -Domain $domain -Reader (Get-DomeniaObjectReadIdentity) -Epoch ([long]$script:SessionEpoch) -Generation $Generation) }
    catch { return $null }
}

function Get-DomeniaSelectionContext {
    $grid = Get-DomeniaControl 'DgObjects'
    if ($null -eq $grid -or -not $grid.IsEnabled -or @($grid.SelectedItems).Count -ne 1) { return $null }
    $row = $grid.SelectedItem
    if ($null -eq $row -or [string]::IsNullOrWhiteSpace([string]$row.DN)) { return $null }
    if ([string]$row.Type -notin @('Utilisateur','Machine','Groupe','OU','Conteneur','Objet')) { return $null }
    $guid = ''
    if ($null -ne $row.PSObject.Properties['Guid']) { $guid = [string]$row.Guid }
    # The typed identity is captured once: the target of an operation never follows a later label change.
    $selectionIdentity = Get-DomeniaRowSelectionIdentity -Row $row
    if ($null -ne $selectionIdentity) { $guid = [string]$selectionIdentity.Guid }
    return [pscustomobject]@{
        DN=[string]$row.DN;Type=[string]$row.Type;Name=[string]$row.Name;Guid=$guid
        Epoch=[long]$script:SessionEpoch;Generation=[int]$script:GlobalSearchGeneration
        Identity=(Get-DomeniaObjectReadIdentity);SelectionIdentity=$selectionIdentity
    }
}

function Test-DomeniaSameSelectionContext {
    param($Left,$Right)
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    $leftIdentity = $null; $rightIdentity = $null
    if ($null -ne $Left.PSObject.Properties['SelectionIdentity']) { $leftIdentity = $Left.SelectionIdentity }
    if ($null -ne $Right.PSObject.Properties['SelectionIdentity']) { $rightIdentity = $Right.SelectionIdentity }
    if ($null -ne $leftIdentity -and $null -ne $rightIdentity) {
        # D012: same object (domain and GUID), same type, read account, session and generation; labels do not count.
        return ($Left.DN -ieq $Right.DN -and (Test-DomeniaIdentityCurrent $leftIdentity $rightIdentity))
    }
    return ($Left.DN -ieq $Right.DN -and $Left.Guid -ieq $Right.Guid -and $Left.Type -ceq $Right.Type -and
        $Left.Epoch -eq $Right.Epoch -and $Left.Generation -eq $Right.Generation -and $Left.Identity -ceq $Right.Identity)
}

function Get-DomeniaCurrentSelectionIdentity {
    # C5: Domenia.SelectionIdentity of the current selection, or $null.
    # '' follows the visible page; 'WsSearch' = the single selected result row; any other workspace
    # (Fiche, Assistance poste, Relations) = the object actually loaded in the fiche, never a control label.
    param([string]$Workspace='')
    $page = $Workspace
    if (-not $page) {
        $tabs = Get-DomeniaControl 'WorkspaceTabs'
        try { if ($null -ne $tabs -and $null -ne $tabs.SelectedItem) { $page = [string]$tabs.SelectedItem.Name } } catch { Write-DomeniaSwallowed 'Selection' 'Get-DomeniaCurrentSelectionIdentity' $_ }
    }
    if (-not $page -or $page -eq 'WsSearch') {
        $context = Get-DomeniaSelectionContext
        if ($null -eq $context) { return $null }
        return $context.SelectionIdentity
    }
    $loaded = $script:SelectedObject
    if ($null -eq $loaded -or [string]::IsNullOrWhiteSpace([string]$loaded.DN)) { return $null }
    $load = $script:SelectionLoad
    if ($null -ne $load -and $null -ne $load.PSObject.Properties['SelectionIdentity'] -and $null -ne $load.SelectionIdentity) {
        $captured = $load.SelectionIdentity
        if ([string]$captured.DN -ieq [string]$loaded.DN -and $load.Phase -in @('Ready','Cached')) {
            $loadedGuid = ''
            try { $loadedGuid = ConvertTo-DomeniaGuidText $loaded.Safety.Guid } catch { Write-DomeniaSwallowed 'Selection' 'Get-DomeniaCurrentSelectionIdentity' $_ }
            if ($loadedGuid -and $loadedGuid -ine [string]$captured.Guid) { return $null }
            if ($captured.Epoch -ne [long]$script:SessionEpoch -or $captured.Reader -cne (Get-DomeniaObjectReadIdentity)) { return $null }
            return $captured
        }
    }
    # Fiche opened outside the result grid: identity of the object as read, never of an edited field.
    $row = [pscustomobject]@{Guid='';Type=[string]$loaded.Type;DN=[string]$loaded.DN;Name=[string]$loaded.Name;Login='';Sid=''}
    try { $row.Guid = [string]$loaded.Safety.Guid } catch { Write-DomeniaSwallowed 'Selection' 'Get-DomeniaCurrentSelectionIdentity' $_ }
    if ($null -ne (Get-Command Get-DomeniaEntryFirstString -CommandType Function -ErrorAction SilentlyContinue)) {
        try { $row.Login = [string](Get-DomeniaEntryFirstString $loaded.Entry 'sAMAccountName'); $row.Sid = [string](Get-DomeniaEntryFirstString $loaded.Entry 'objectSid') } catch { Write-DomeniaSwallowed 'Selection' 'Get-DomeniaCurrentSelectionIdentity' $_ }
    }
    return (Get-DomeniaRowSelectionIdentity -Row $row -Generation ([long]$script:SelectedObjectGeneration))
}

function Test-DomeniaSelectionLoadCurrent {
    param($Load = $script:SelectionLoad)
    if ($null -eq $Load) { return $false }
    return (Test-DomeniaSameSelectionContext $Load.Context (Get-DomeniaSelectionContext))
}

function Get-DomeniaObjectResultGuid {
    param($Result)
    if ($null -eq $Result -or $null -eq $Result.Properties) { return '' }
    foreach ($key in @($Result.Properties.Keys)) {
        if ([string]$key -ine 'objectGUID') { continue }
        $value = $Result.Properties[$key]
        if ($value -is [byte[]]) { return ([guid]::new($value)).ToString('D') }
        $items = @($value)
        if ($items.Count -eq 0) { return '' }
        if ($items[0] -is [byte[]]) { return ([guid]::new([byte[]]$items[0])).ToString('D') }
        $parsed = [guid]::Empty
        if ([guid]::TryParse([string]$items[0],[ref]$parsed)) { return $parsed.ToString('D') }
        return ''
    }
    return ''
}

function Assert-DomeniaObjectResultIdentity {
    param($Result,$State)
    if ($null -eq $Result -or $null -eq $Result.Properties) { throw 'Lecture AD sans proprietes.' }
    if ($Result.DN -and [string]$Result.DN -ine [string]$State.Dn) { throw 'La lecture AD concerne une autre cible. Actualisez la liste.' }
    $guid = Get-DomeniaObjectResultGuid $Result
    if (-not $guid) { throw 'GUID absent ou invalide dans la lecture AD. La fiche reste indisponible.' }
    if ($State.ExpectedGuid -and [string]$State.ExpectedGuid -ine $guid) { throw 'Cet objet a ete remplace depuis la recherche (GUID different). Actualisez la liste avant de continuer.' }
    # D012: a read bound to the current selection must match the identity captured at selection time,
    # whatever a request field or a label says afterwards.
    $load = $script:SelectionLoad
    if ($State.SelectionBound -and $null -ne $load -and $null -ne $load.PSObject.Properties['SelectionIdentity'] -and $null -ne $load.SelectionIdentity -and [string]$State.SelectionToken -ceq [string]$load.Token) {
        $pinned = [string]$load.SelectionIdentity.Guid
        if ($State.ExpectedGuid -and [string]$State.ExpectedGuid -ine $pinned) { throw 'La cible de la lecture ne correspond plus a la selection capturee. Actualisez la liste avant de continuer.' }
        if ($guid -ine $pinned) { throw 'Cet objet a ete remplace depuis la recherche (GUID different). Actualisez la liste avant de continuer.' }
    }
}

function Get-DomeniaObjectCacheKey {
    param([string]$DN,[string]$Guid,[string]$Identity)
    # D025: cache-v3 key from the rule (domain, object GUID, hashed reader). The DN is not part of the key; without a
    # real GUID the rule returns an empty key and the object is simply not cached.
    $domain = ''
    if ($null -ne $script:Conn) {
        $domain = [string]$script:Conn.Domain
        if ([string]::IsNullOrWhiteSpace($domain) -and $script:Conn.BaseDn) {
            $domain = @(([string]$script:Conn.BaseDn -split ',') | Where-Object { $_ -match '^\s*DC=' } | ForEach-Object { ($_ -split '=',2)[1].Trim() }) -join '.'
        }
    }
    if ([string]::IsNullOrWhiteSpace($domain)) { $domain = 'unknown' }
    return (Get-DomeniaCacheKey -Domain $domain -Guid $Guid -Reader $Identity -Nature 'Object' -Version 'object')
}

function Get-DomeniaSelectionCachePolicy {
    # Read session facts only; no network request, disk read or cached LoadedAt fallback.
    $record=$script:SelectedObject;$load=$script:SelectionLoad
    $hasSnapshot=($null -ne $record -and -not [string]::IsNullOrWhiteSpace([string]$record.DN))
    $guid=[string](Get-DomeniaMember (Get-DomeniaMember $record 'Safety' $null) 'Guid' (Get-DomeniaMember $record 'Guid' ''))
    $identityMatches=($hasSnapshot -and -not [string]::IsNullOrWhiteSpace($guid))
    if($identityMatches -and $null -ne $load){
        $context=$load.Context
        $identityMatches=([string]$record.DN -ieq [string]$context.DN -and $guid -ieq [string]$context.Guid)
        if($null -ne $context -and $null -ne $context.PSObject.Properties['Epoch']){$identityMatches=($identityMatches -and [long]$context.Epoch -eq [long]$script:SessionEpoch)}
    }
    # Point 11: the attribute duration of the usage profile, as in the object card.
    $freshnessTable=$null;try{$freshnessTable=Get-DomeniaActiveFreshnessTable}catch{$freshnessTable=$null}
    $freshness=Get-DomeniaRecordFreshness $record 'Attributes' -Table $freshnessTable
    $fresh=($freshness.State -eq 'Fresh' -and -not [bool]$script:ShowingCachedObject)
    if($null -ne $load -and [string]$load.Phase -ne 'Ready'){$fresh=$false}
    $reachability=$script:DirectoryReachability
    if($null -ne $reachability -and [long]$reachability.Epoch -ne [long]$script:SessionEpoch){$reachability=$null}
    $offline=[bool](Get-DomeniaMember $reachability 'Offline' $false)
    $outage=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $reachability 'LastOutageUtc' $null)
    if($null -ne $outage -and ($null -eq $freshness.ObservedUtc -or $freshness.ObservedUtc -le $outage)){$fresh=$false}
    $uncertain=($script:WriteState -in @('Unknown','UnknownPending'))
    $policy=Get-DomeniaCacheReadPolicy -HasSnapshot ([bool]$hasSnapshot) -IdentityMatches ([bool]$identityMatches) -FreshReadConfirmed ([bool]$fresh) -Offline ([bool]$offline) -WriteUncertain ([bool]$uncertain)
    $policy | Add-Member -NotePropertyName Offline -NotePropertyValue $offline
    return $policy
}

function Update-DomeniaSelectionReadUi {
    param([string]$Phase='', [string]$Message='')
    $load = $script:SelectionLoad
    if ($null -eq $load) { return }
    if ($Phase) { $load.Phase = $Phase }
    if ($Message) { $load.Message = $Message }
    $context = $load.Context
    $hasData = ($null -ne $script:SelectedObject -and $script:SelectedObject.DN -ieq $context.DN)
    $ready = ($hasData -and $load.Phase -eq 'Ready')
    $cachePolicy=Get-DomeniaSelectionCachePolicy
    $prefixType = [string]$context.Type
    $prefixName = [string]$context.Name
    # The label is derived from the captured identity, never the reverse.
    if (($null -ne $load.PSObject.Properties['SelectionIdentity']) -and ($null -ne $load.SelectionIdentity)) {
        $prefixType = [string]$load.SelectionIdentity.Type
        $prefixName = [string]$load.SelectionIdentity.Name
    }
    $previewSelection = [pscustomobject]@{Type=$prefixType;Name=$prefixName;Guid=[string]$context.Guid;Generation=[string]$script:SelectedObjectGeneration}
    $previewDetail = $null
    if ($hasData) {
        $previewDetail = $script:SelectedObject
        if ($null -ne $previewDetail) {
            if ($null -eq $previewDetail.PSObject.Properties['Guid']) {
                $previewDetail = Add-Member -InputObject $previewDetail -NotePropertyName Guid -NotePropertyValue ([string]$context.Guid) -Force -PassThru
            }
            if ($null -eq $previewDetail.PSObject.Properties['Generation']) {
                $previewDetail = Add-Member -InputObject $previewDetail -NotePropertyName Generation -NotePropertyValue ([string]$script:SelectedObjectGeneration) -Force -PassThru
            }
        }
    }
    $previewLoadState = ConvertTo-DomeniaPreviewLoadState -Phase $load.Phase -Message $load.Message
    $preview = Get-DomeniaSelectionPreview -Selection $previewSelection -LoadState $previewLoadState -Detail $previewDetail -ErrorText $load.Message
    $previewText = ConvertTo-DomeniaSelectionPreviewText -Preview $preview -Maximum 160
    $text = [string]$previewText.Line
    [void](Set-DomeniaControlText 'LblSelectionReadState' $text)
    $readState = Get-DomeniaControl 'LblSelectionReadState'
    if ($null -ne $readState) { $readState.ToolTip = [string]$previewText.Detail+"`r`n"+$cachePolicy.Reason }
    foreach ($kind in @('Object','Computer')) {
        $contentHost = Get-DomeniaControl ($kind + 'ReadContent')
        $empty = Get-DomeniaControl ($kind + 'ReadPlaceholder')
        $title = Get-DomeniaControl ('Lbl' + $kind + 'ReadStatus')
        $retry = Get-DomeniaControl ('Btn' + $kind + 'ReadRetry')
        if ($null -ne $contentHost) { $contentHost.Visibility = if ($hasData) { 'Visible' } else { 'Collapsed' }; $contentHost.IsEnabled = $ready }
        if ($null -ne $empty) { $empty.Visibility = if ($hasData) { 'Collapsed' } else { 'Visible' } }
        if ($null -ne $title) { $title.Text = $text; $title.ToolTip = $(if ($load.Message) { $load.Message } else { $text })+"`r`n"+$cachePolicy.Reason }
        if ($null -ne $retry) { $retry.Visibility = if ($load.Phase -eq 'Failed') { 'Visible' } else { 'Hidden' }; $retry.IsEnabled = ($load.Phase -eq 'Failed' -and -not (Test-DomeniaAccessBusyWrite)) }
    }
    # Avoid toggling child tabs on each phase update or repeated click.
    if ($load.VisibleType -cne $context.Type) {
        Set-VisibleTabsForType -Type $context.Type -PreserveWorkspace
        $load.VisibleType=$context.Type
    }
}

function Clear-DomeniaPreloadSelection {
    param([switch]$KeepViews)
    Stop-DomeniaSelectionOpenTimer
    $script:PendingObjectSelection = $null
    $script:SelectionLoad = $null
    Clear-DomeniaCurrentObjectRequest -RequestId ([string]$script:CurrentObjectRequestId)
    foreach ($id in @($script:AsyncJobs.Keys)) {
        $job=$script:AsyncJobs[$id]
        if ($null -ne $job -and -not $job.IsWrite -and [string]$job.ReplaceKey -eq 'object') {
            Request-UiTaskStop -Id ([string]$id) -Silent -Force -Superseded -Reason 'Selection vide ou multiple'
        }
    }
    if (-not $KeepViews) {
        $script:SelectedObject = $null
        $script:LastLoadedEntry = $null
        $script:CurrentCapabilities = @{}
        $script:SelectionResetDn = ''
        Clear-Secrets
        [void](Set-DomeniaControlText 'LblSelectionReadState' 'Selectionnez une ligne pour precharger sa fiche. Double-clic : ouvrir.')
        foreach ($kind in @('Object','Computer')) {
            $contentHost = Get-DomeniaControl ($kind + 'ReadContent')
            if ($null -ne $contentHost) { $contentHost.IsEnabled = $false; $contentHost.Visibility = 'Collapsed' }
        }
        Set-VisibleTabsForType -Type '' -PreserveWorkspace
    }
}

function Clear-DomeniaSelectionEverywhere {
    # Field report 2026-10-05: once the list no longer holds the selected row (list reset, new search, empty
    # selection), nothing of the former object stays displayed: search line, object card, Assistance poste, Relations.
    try{Clear-DomeniaLiveProbeIntent}catch{Write-DomeniaSwallowed 'Selection' 'Clear-DomeniaSelectionEverywhere' $_}
    Clear-DomeniaPreloadSelection
    try{Reset-DomeniaSelectionBoundViews}catch{Write-DomeniaSwallowed 'Selection' 'Clear-DomeniaSelectionEverywhere' $_}
    $script:SelectedObject=$null
    $text='Aucun objet sélectionné : choisissez une ligne dans Rechercher.'
    foreach($kind in @('Object','Computer')){
        $title=Get-DomeniaControl ('Lbl'+$kind+'ReadStatus');if($null -ne $title){$title.Text=$text;$title.ToolTip=$text}
        $empty=Get-DomeniaControl ($kind+'ReadPlaceholder');if($null -ne $empty){$empty.Visibility='Visible'}
        $retry=Get-DomeniaControl ('Btn'+$kind+'ReadRetry');if($null -ne $retry){$retry.Visibility='Hidden'}
    }
    [void](Set-DomeniaControlText 'LblLinkContext' 'Aucune sélection.')
    try{Clear-DomeniaRelationsSelection}catch{Write-DomeniaSwallowed 'Selection' 'Clear-DomeniaSelectionEverywhere' $_}
    try{Update-DomeniaSearchActionStates}catch{Write-DomeniaSwallowed 'Selection' 'Clear-DomeniaSelectionEverywhere' $_}
}

function Enter-DomeniaSelectionContext {
    param($Context)
    Stop-DomeniaSelectionOpenTimer
    $script:PendingObjectSelection = $null
    # Invalidate before asking the engine to stop. Late callbacks cannot restore old data.
    Clear-DomeniaCurrentObjectRequest -RequestId ([string]$script:CurrentObjectRequestId)
    $script:SelectedObjectGeneration = [int64]$script:SelectedObjectGeneration + 1
    $script:SelectedObject = $null
    $script:LastLoadedEntry = $null
    $script:DraftState = $null
    $script:CurrentCapabilities = @{}
    $script:SelectionResetDn = $Context.DN
    $script:ActiveLinkProbeId = 'invalidated-' + [guid]::NewGuid().ToString('N')
    $script:ActiveLinkProbeComputer = ''
    foreach ($id in @($script:AsyncJobs.Keys)) {
        $job = $script:AsyncJobs[$id]
        if ($null -eq $job -or $job.IsWrite) { continue }
        if ((([string]$job.ReplaceKey) -in @('object','secrets','computerdiag','permissions','presence-selected','inventory','software','wmi')) -or (([string]$job.ReplaceKey) -like 'lastuser:*')) {
            Request-UiTaskStop -Id ([string]$id) -Silent -Force -Superseded -Reason 'Nouvelle selection'
        }
    }
    Clear-Secrets
    Reset-DomeniaSelectionBoundViews -Dn ([string]$Context.DN) -Type ([string]$Context.Type) -Name ([string]$Context.Name) -Guid ([string]$Context.Guid)
    # FO-07 : la vue vient d'etre videe pour le nouvel objet (D085). Si ce poste a deja ete inventorie dans
    # cette session, sa derniere lecture est reprise ici, avec son age : les lignes rendues appartiennent
    # au nouvel objet, jamais au precedent.
    if (([string]$Context.Type) -eq 'Machine') { try { [void](Show-DomeniaCachedInventory -Computer ([string]$Context.Name)) } catch { Write-DomeniaSwallowed 'Selection' 'Enter-DomeniaSelectionContext' $_ } }
    # D012: the fiche keeps the immutable identity captured at selection time.
    $captured = $null
    if ($null -ne $Context.PSObject.Properties['SelectionIdentity']) { $captured = $Context.SelectionIdentity }
    $script:SelectionLoad = [pscustomobject]@{Context=$Context;Token=[guid]::NewGuid().ToString('N');Phase='Queued';Message='';VisibleType='';SelectionIdentity=$captured}
    # Old form data stay hidden. Full clearing/rendering is done only for the final debounced read.
    Update-DomeniaSelectionReadUi
}

function Restore-DomeniaRefusedSelection {
    param([string]$DN)
    $g = Get-DomeniaControl 'DgObjects'
    if ($null -eq $g) { return }
    $old = [bool]$script:SuppressGridSelectionEvents
    $script:SuppressGridSelectionEvents = $true
    try {
        $g.SelectedItem = $null
        foreach ($r in @($g.Items)) { if ([string]$r.DN -ieq $DN) { $g.SelectedItem = $r; break } }
    } finally { $script:SuppressGridSelectionEvents = $old }
}

function Retry-DomeniaSelectedObjectRead {
    if (-not (Test-DomeniaSelectionLoadCurrent) -or (Test-DomeniaAccessBusyWrite)) { return }
    # Retry the AD read only. This button does not repeat ping, CIM, or an AD write.
    Queue-DomeniaSelectedObjectOpen -Immediate -Force -ReadOnlyRetry
}

function Initialize-DomeniaSelectionPreload {
    if ($script:SelectionPreloadBound) { return }
    $script:SelectionPreloadBound = $true
    foreach ($name in @('BtnObjectReadRetry','BtnComputerReadRetry')) {
        $button = Get-DomeniaControl $name
        if ($null -ne $button) { $button.Add_Click({ Retry-DomeniaSelectedObjectRead }) }
    }
    if ($null -ne $script:Window) {
        $script:Window.Add_Closed({ Stop-DomeniaSelectionOpenTimer; $script:SelectionLoad=$null; $script:PendingObjectSelection=$null; $script:CurrentObjectRequestState=$null })
    }
}
