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

function Get-DomeniaSelectionContext {
    $grid = Get-DomeniaControl 'DgObjects'
    if ($null -eq $grid -or -not $grid.IsEnabled -or @($grid.SelectedItems).Count -ne 1) { return $null }
    $row = $grid.SelectedItem
    if ($null -eq $row -or [string]::IsNullOrWhiteSpace([string]$row.DN)) { return $null }
    if ([string]$row.Type -notin @('Utilisateur','Machine','Groupe','OU','Conteneur','Objet')) { return $null }
    $guid = ''
    if ($null -ne $row.PSObject.Properties['Guid']) { $guid = [string]$row.Guid }
    return [pscustomobject]@{
        DN=[string]$row.DN;Type=[string]$row.Type;Name=[string]$row.Name;Guid=$guid
        Epoch=[long]$script:SessionEpoch;Generation=[int]$script:GlobalSearchGeneration
        Identity=(Get-DomeniaObjectReadIdentity)
    }
}

function Test-DomeniaSameSelectionContext {
    param($Left,$Right)
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    return ($Left.DN -ieq $Right.DN -and $Left.Guid -ieq $Right.Guid -and $Left.Type -ceq $Right.Type -and
        $Left.Epoch -eq $Right.Epoch -and $Left.Generation -eq $Right.Generation -and $Left.Identity -ceq $Right.Identity)
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
}

function Get-DomeniaObjectCacheKey {
    param([string]$DN,[string]$Guid,[string]$Identity)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Identity))).Replace('-','') }
    finally { $sha.Dispose() }
    return ('object-v2|{0}|{1}|{2}' -f $hash,$Guid.ToLowerInvariant(),$DN.ToLowerInvariant())
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
    $prefix = $context.Type + ' : ' + $context.Name
    $text = switch ($load.Phase) {
        'Queued' { $prefix + ' | Preparation de la fiche...' }
        'Loading' { $prefix + ' | Lecture AD en arriere-plan...' }
        'Cached' { $prefix + ' | Cache affiche, validation AD en cours.' }
        'Ready' { $prefix + ' | Fiche AD chargee.' }
        'Paused' { $prefix + ' | Lecture suspendue pendant une ecriture.' }
        'Failed' { $prefix + ' | Lecture non confirmee. Reessayer la lecture.' }
        default { $prefix }
    }
    [void](Set-DomeniaControlText 'LblSelectionReadState' $text)
    foreach ($kind in @('Object','Computer')) {
        $contentHost = Get-DomeniaControl ($kind + 'ReadContent')
        $empty = Get-DomeniaControl ($kind + 'ReadPlaceholder')
        $title = Get-DomeniaControl ('Lbl' + $kind + 'ReadStatus')
        $retry = Get-DomeniaControl ('Btn' + $kind + 'ReadRetry')
        if ($null -ne $contentHost) { $contentHost.Visibility = if ($hasData) { 'Visible' } else { 'Collapsed' }; $contentHost.IsEnabled = $ready }
        if ($null -ne $empty) { $empty.Visibility = if ($hasData) { 'Collapsed' } else { 'Visible' } }
        if ($null -ne $title) { $title.Text = $text; $title.ToolTip = if ($load.Message) { $load.Message } else { $text } }
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
        if ([string]$job.ReplaceKey -in @('object','secrets','computerdiag','permissions','presence-selected') -or [string]$job.ReplaceKey -like 'lastuser:*') {
            Request-UiTaskStop -Id ([string]$id) -Silent -Force -Superseded -Reason 'Nouvelle selection'
        }
    }
    Clear-Secrets
    $script:SelectionLoad = [pscustomobject]@{Context=$Context;Token=[guid]::NewGuid().ToString('N');Phase='Queued';Message='';VisibleType=''}
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
