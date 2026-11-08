# UI-06: memberships of the fiche as readable grids (Nom, Type, OU; DN in the tooltip) with a local filter and a counter,
# and « Pourquoi membre ? » from the memberOf edges read on demand (GroupPathRead, explicit gesture only).
$script:MembershipLists = @{}
$script:MembershipNested = $null
$script:MembershipUiBound = $false

function Get-DomeniaMembershipControlNames {
    param([ValidateSet('MemberOf','Members')][string]$Kind)
    if ($Kind -eq 'MemberOf') { return [pscustomobject]@{Grid='DgMemberOf';Label='LblMemberOf';Filter='TxtMemberOfFilter';Noun='groupe(s) direct(s)'} }
    return [pscustomobject]@{Grid='DgGroupMembers';Label='LblGroupMembers';Filter='TxtGroupMembersFilter';Noun='membre(s) direct(s)'}
}

function Set-DomeniaMembershipList {
    # Shows the direct memberships read in the fiche (2 000 at most, the total is said). A new object clears the filter of
    # the grid and the groups read for « Pourquoi membre ? ». For the members of a group, the type of each member is read
    # from the local copy in the background (SQLite, no directory request); unknown members stay « Non lu ».
    param([ValidateSet('MemberOf','Members')][string]$Kind,[string[]]$Dns=@(),[string]$ObjectDn='',[bool]$Complete=$true,[string]$Note='')
    $names = Get-DomeniaMembershipControlNames -Kind $Kind
    $all = @($Dns | Where-Object { $_ })
    $rows = [Collections.ObjectModel.ObservableCollection[object]]::new()
    # The row builder returns its array as one object (return ,): assign it, never wrap the call in @().
    $built = ConvertTo-DomeniaMembershipRows -Dns $all -Kind $Kind -Max 2000
    foreach ($row in $built) { $rows.Add($row) }
    $previous = $script:MembershipLists[$Kind]
    $sameObject = (($null -ne $previous) -and ([string]$previous.ObjectDn -ieq $ObjectDn))
    if (($null -ne $previous) -and (-not $sameObject)) { Reset-DomeniaUserAccessDiff }
    $script:MembershipLists[$Kind] = [pscustomobject]@{Rows=$rows;Total=$all.Count;Complete=$Complete;Note=$Note;Noun=$names.Noun;ObjectDn=$ObjectDn;Epoch=[long]$script:SessionEpoch}
    $filter = Get-DomeniaControl $names.Filter
    if (($null -ne $filter) -and (-not $sameObject) -and ([string]$filter.Text)) { $filter.Text = '' }
    if (($Kind -eq 'MemberOf') -and (($null -eq $script:MembershipNested) -or ([string]$script:MembershipNested.ObjectDn -ine $ObjectDn))) {
        $script:MembershipNested = $null
        Show-DomeniaMembershipWhy ''
    }
    $grid = Get-DomeniaControl $names.Grid
    if ($null -ne $grid) { $grid.ItemsSource = $rows }
    Update-DomeniaMembershipFilter -Kind $Kind
    if (($Kind -eq 'MemberOf') -and ($null -ne $script:MembershipNested) -and [bool]$script:MembershipNested.Read) { Add-DomeniaNestedMembershipRows }
    if (($Kind -eq 'Members') -and ($rows.Count -gt 0)) { Start-DomeniaMembershipTypes -ObjectDn $ObjectDn -Dns @($rows | ForEach-Object { [string]$_.Dn }) }
}

function Clear-DomeniaMembershipLists {
    # The fiche is cleared or replaced: no membership of the previous object stays on screen.
    foreach ($kind in @('MemberOf','Members')) {
        $names = Get-DomeniaMembershipControlNames -Kind $kind
        $grid = Get-DomeniaControl $names.Grid
        if ($null -ne $grid) { $grid.ItemsSource = $null }
        [void](Set-DomeniaControlText -Name $names.Label -Text $(if ($kind -eq 'MemberOf') { 'Groupes' } else { 'Membres' }))
    }
    $script:MembershipLists = @{}
    $script:MembershipNested = $null
    Show-DomeniaMembershipWhy ''
    Reset-DomeniaUserAccessDiff
}

function Update-DomeniaMembershipFilter {
    # Local filter of a membership grid (no request): the counter says what is loaded, what the filter shows and the
    # groups added by the reading of nested groups.
    param([ValidateSet('MemberOf','Members')][string]$Kind)
    $names = Get-DomeniaMembershipControlNames -Kind $Kind
    $list = $script:MembershipLists[$Kind]
    if ($null -eq $list) { return }
    $box = Get-DomeniaControl $names.Filter
    $text = ''
    if ($null -ne $box) { $text = [string]$box.Text }
    if ($text.Length -gt 120) { $text = $text.Substring(0,120) }
    # A filtered copy is shown while the filter has text (Test-DomeniaMembershipRow); the full list otherwise, so that
    # the nested groups and the types read later reach the grid without a new filter pass.
    $grid = Get-DomeniaControl $names.Grid
    $visible = $list.Rows.Count
    if ($text.Trim()) {
        $shown = @($list.Rows | Where-Object { Test-DomeniaMembershipRow $_ $text })
        $visible = $shown.Count
        if ($null -ne $grid) { $grid.ItemsSource = $shown }
    }
    elseif (($null -ne $grid) -and (-not [object]::ReferenceEquals($grid.ItemsSource,$list.Rows))) { $grid.ItemsSource = $list.Rows }
    $direct = @($list.Rows | Where-Object { [string]$_.Membership -eq 'Directe' }).Count
    $nested = $list.Rows.Count - $direct
    $label = Get-DomeniaMembershipLabel -Shown $direct -Total ([int]$list.Total) -Complete ([bool]$list.Complete) -Note ([string]$list.Note) -Noun ([string]$list.Noun)
    if ($nested -gt 0) { $label += ' · ' + $nested + ' groupe(s) imbriqué(s) lu(s)' }
    if ($text.Trim()) { $label += ' · ' + $visible + ' affiché(s) après le filtre' }
    [void](Set-DomeniaControlText -Name $names.Label -Text $label)
}

function Start-DomeniaMembershipTypes {
    # Types of the members of a group from the local copy (LocalIndexRead ResolveNames by DN): read-only, background.
    param([string]$ObjectDn,[string[]]$Dns=@())
    $path = ''
    try { $path = [string](Get-DomeniaLocalDatabasePathForRead) } catch { $path = '' }
    if ((-not $path) -or (-not $Dns.Count)) { return }
    $state = [pscustomobject]@{Epoch=[long]$script:SessionEpoch;ObjectDn=$ObjectDn}
    try {
        $payload = [pscustomobject]@{Action='ResolveNames';Path=$path;BusyTimeoutMs=250;Users=@();Computers=@();Dns=@($Dns | Select-Object -First 2000)}
        [void](Start-UiTask -Name 'Types des membres (copie locale)' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload $payload -CallbackState $state -ReplaceKey 'membership-types' -TimeoutSeconds 30 -SuccessHandler 'Complete-DomeniaMembershipTypes' -ErrorHandler 'Fail-DomeniaMembershipTypes' -TaskClass 'Background')
    } catch { Write-AppLog ('Types des membres non lus : '+$_.Exception.Message) 'WARN' }
}

function Complete-DomeniaMembershipTypes {
    param($Result,$State)
    $list = $script:MembershipLists['Members']
    if (($null -eq $list) -or ($null -eq $State) -or ([long]$State.Epoch -ne [long]$script:SessionEpoch) -or ([string]$list.ObjectDn -ine [string]$State.ObjectDn)) { return }
    $data = Get-DomeniaEffectiveWorkerResult $Result @('Busy','Missing')
    if (($null -eq $data) -or [bool]$data.Busy -or [bool]$data.Missing) { return }
    $types = @{}
    foreach ($object in @(Get-DomeniaMember $data 'Objects' @())) {
        $dn = [string](Get-DomeniaMember $object 'distinguished_name' '')
        $type = [string](Get-DomeniaMember $object 'object_type' '')
        if ($dn -and $type) { $types[$dn] = $type }
    }
    if (-not $types.Count) { return }
    $changed = $false
    foreach ($row in @($list.Rows)) {
        if (([string]$row.Type -eq 'Non lu') -and $types.Contains([string]$row.Dn)) { $row.Type = [string]$types[[string]$row.Dn]; $changed = $true }
    }
    if ($changed) {
        $grid = Get-DomeniaControl 'DgGroupMembers'
        if ($null -ne $grid) { try { $grid.Items.Refresh() } catch { Write-DomeniaSwallowed 'Membership' 'Complete-DomeniaMembershipTypes' $_ } }
    }
}

function Fail-DomeniaMembershipTypes {
    param($Message,$State)
    Write-AppLog ('Types des membres non lus dans la copie locale : '+[string]$Message) 'INFO'
}

function Show-DomeniaMembershipWhy {
    # The answer of « Pourquoi membre ? » under the groups of the fiche ('' hides it).
    param([AllowEmptyString()][string]$Text)
    $label = Get-DomeniaControl 'LblMembershipWhy'
    if ($null -eq $label) { return }
    $label.Text = $Text
    $label.Visibility = if ($Text) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
}

function Get-DomeniaSelectedMembershipRow {
    param([ValidateSet('MemberOf','Members')][string]$Kind)
    $grid = Get-DomeniaControl (Get-DomeniaMembershipControlNames -Kind $Kind).Grid
    if ($null -eq $grid) { return $null }
    try { return $grid.SelectedItem } catch { return $null }
}

function Invoke-DomeniaMembershipWhy {
    # « Pourquoi membre ? » on a group of the fiche. A direct group is explained at once; a nested group (listed after
    # « Groupes imbriqués ») by its path in the edges read; otherwise the nested groups are read on this click only
    # (GroupPathRead with this target, the controller giving its own transitive answer).
    $row = Get-DomeniaSelectedMembershipRow -Kind MemberOf
    $list = $script:MembershipLists['MemberOf']
    if (($null -eq $row) -or ($null -eq $list)) { Show-DomeniaMembershipWhy 'Sélectionnez un groupe dans la liste.'; return }
    $nested = $script:MembershipNested
    $read = (($null -ne $nested) -and [bool]$nested.Read -and ([string]$nested.ObjectDn -ieq [string]$list.ObjectDn))
    $why = Get-DomeniaMembershipWhy -Edges $(if ($read) { $nested.Edges } else { $null }) -ObjectDn ([string]$list.ObjectDn) -GroupDn ([string]$row.Dn) -Direct ([string]$row.Membership -eq 'Directe') -Read $read -Truncated $(if ($read) { [bool]$nested.Truncated } else { $false }) -Unread $(if ($read) { @($nested.Unread).Count } else { 0 }) -ServerAnswer $(if ($read -and $nested.ServerAnswers.ContainsKey([string]$row.Dn)) { $nested.ServerAnswers[[string]$row.Dn] } else { $null })
    # A nested group listed here comes from the edges already read: its path is shown at once, without a new request.
    if ([bool]$why.NeedsRead) { Start-DomeniaMembershipPathRead -TargetDn ([string]$row.Dn); return }
    Show-DomeniaMembershipWhy ([string]$why.Text)
}

function Start-DomeniaMembershipPathRead {
    # GroupPathRead on an explicit gesture: the memberOf of this object and of its groups, breadth-first and bounded
    # (2 000 groups, 16 levels, 10 s); with -TargetDn the controller also answers for that group. Never a domain search.
    # Same pinned body as the nested groups of Outils > Audit AD (point 103): the object's memberOf is read again by
    # the worker, ranged values included, rather than taken from the fiche.
    param([string]$TargetDn='')
    $list = $script:MembershipLists['MemberOf']
    if (($null -eq $list) -or (-not [string]$list.ObjectDn)) { Show-DomeniaMembershipWhy 'Ouvrez la fiche dʼun objet avant de lire ses groupes imbriqués.'; return }
    if (($null -eq $script:SelectedObject) -or ([string]$script:SelectedObject.DN -ine [string]$list.ObjectDn)) { Show-DomeniaMembershipWhy 'La fiche affichée a changé : rouvrez-la avant de lire ses groupes imbriqués.'; return }
    $state = [pscustomobject]@{Epoch=[long]$script:SessionEpoch;Generation=[long]$script:SelectedObjectGeneration;ObjectDn=[string]$list.ObjectDn;TargetDn=$TargetDn}
    $payload = [pscustomobject]@{Dn=[string]$list.ObjectDn;Mode='Expand';TargetDn=$TargetDn;MaxNodes=2000;MaxDepth=16;Seconds=10}
    Show-DomeniaMembershipWhy $(if ($TargetDn) { 'Lecture des groupes imbriqués pour expliquer lʼappartenance à « ' + (Get-DomeniaDnDisplayName $TargetDn) + ' »…' } else { 'Lecture des groupes imbriqués…' })
    try {
        $job = Start-UiTask -Name 'Groupes imbriqués' -OperationId 'GroupPathRead' -Code (Get-DomeniaGroupPathWorkerCode) -Payload $payload -CallbackState $state -ReplaceKey 'membership-path' -DisableControls @('BtnMemberOfNested') -TimeoutSeconds 60 -SuccessHandler 'Complete-DomeniaMembershipPathRead' -ErrorHandler 'Fail-DomeniaMembershipPathRead' -TaskClass 'Explicit'
        if (-not $job) { Show-DomeniaMembershipWhy 'Lecture des groupes imbriqués non admise pour lʼinstant : réessayez.' }
    } catch { Fail-DomeniaMembershipPathRead -Message $_.Exception.Message -State $state }
}

function Test-DomeniaMembershipPathCurrent {
    param($State)
    $list = $script:MembershipLists['MemberOf']
    return (($null -ne $State) -and ([long]$State.Epoch -eq [long]$script:SessionEpoch) -and ([long]$State.Generation -eq [long]$script:SelectedObjectGeneration) -and
        ($null -ne $list) -and ([string]$list.ObjectDn -ieq [string]$State.ObjectDn))
}

function Complete-DomeniaMembershipPathRead {
    param($Result,$State)
    if (-not (Test-DomeniaMembershipPathCurrent $State)) { return }
    try {
        $data = Get-DomeniaEffectiveWorkerResult $Result @('Dn','Nodes','Unread')
        if (($null -eq $data) -or ([string]$data.Dn -ine [string]$State.ObjectDn)) { throw 'Réponse des groupes imbriqués absente ou dʼun autre objet.' }
        $answers = @{}
        if (($null -ne $script:MembershipNested) -and ([string]$script:MembershipNested.ObjectDn -ieq [string]$State.ObjectDn)) { $answers = $script:MembershipNested.ServerAnswers }
        if ([string]$State.TargetDn) { $answers[[string]$State.TargetDn] = Get-DomeniaMember $data 'ServerAnswer' $null }
        # A memberOf of the object read only in part (more values than one range) leaves the walk incomplete too.
        $partial = (-not [bool](Get-DomeniaMember $data 'StartComplete' $true))
        $primary = [string](Get-DomeniaMember (Get-DomeniaMember $data 'PrimaryGroup' $null) 'Name' '')
        $script:MembershipNested = [pscustomobject]@{ObjectDn=[string]$State.ObjectDn;Read=$true;Edges=(ConvertTo-DomeniaGroupPathEdges $data);Unread=@(Get-DomeniaMember $data 'Unread' @());Truncated=([bool](Get-DomeniaMember $data 'Truncated' $false) -or $partial);Bounded=[bool](Get-DomeniaMember $data 'Truncated' $false);StartPartial=$partial;PrimaryGroup=$primary;ServerAnswers=$answers}
        Add-DomeniaNestedMembershipRows
        $nested = $script:MembershipNested
        if ([string]$State.TargetDn) {
            $row = @($script:MembershipLists['MemberOf'].Rows | Where-Object { [string]$_.Dn -ieq [string]$State.TargetDn } | Select-Object -First 1)
            $direct = (($row.Count -eq 1) -and ([string]$row[0].Membership -eq 'Directe'))
            $why = Get-DomeniaMembershipWhy -Edges $nested.Edges -ObjectDn ([string]$State.ObjectDn) -GroupDn ([string]$State.TargetDn) -Direct $direct -Read $true -Truncated ([bool]$nested.Truncated) -Unread (@($nested.Unread).Count) -ServerAnswer $answers[[string]$State.TargetDn]
            Show-DomeniaMembershipWhy ([string]$why.Text)
        }
        else { Show-DomeniaMembershipWhy (Format-DomeniaNestedMembershipSummary) }
    } catch { Fail-DomeniaMembershipPathRead -Message $_.Exception.Message -State $State }
}

function Fail-DomeniaMembershipPathRead {
    param($Message,$State)
    if (-not (Test-DomeniaMembershipPathCurrent $State)) { return }
    Show-DomeniaMembershipWhy ('Groupes imbriqués non lus : ' + [string]$Message + ' Les groupes directs restent affichés.')
}

function Add-DomeniaNestedMembershipRows {
    # The groups reached through other groups join the grid (Appartenance « Imbriquée », via the direct group).
    $list = $script:MembershipLists['MemberOf']
    $nested = $script:MembershipNested
    if (($null -eq $list) -or ($null -eq $nested) -or (-not [bool]$nested.Read)) { return }
    foreach ($row in @($list.Rows | Where-Object { [string]$_.Membership -ne 'Directe' })) { [void]$list.Rows.Remove($row) }
    $direct = @{}
    foreach ($row in @($list.Rows)) { $direct[[string]$row.Dn] = $true }
    $built = Get-DomeniaNestedMembershipRows -Edges $nested.Edges -ObjectDn ([string]$list.ObjectDn) -Max 2000
    foreach ($row in $built) {
        if (-not $direct.ContainsKey([string]$row.Dn)) { $list.Rows.Add($row) }
    }
    Update-DomeniaMembershipFilter -Kind MemberOf
}

function Format-DomeniaNestedMembershipSummary {
    $list = $script:MembershipLists['MemberOf']
    $nested = $script:MembershipNested
    if (($null -eq $list) -or ($null -eq $nested)) { return '' }
    $count = @($list.Rows | Where-Object { [string]$_.Membership -ne 'Directe' }).Count
    $text = $(if ($count -gt 0) { [string]$count + ' groupe(s) imbriqué(s) ajouté(s) à la liste ; « Pourquoi membre ? » montre le chemin de chacun.' } else { 'Aucun groupe imbriqué dans les groupes lus.' })
    $unread = @($nested.Unread)
    if ($unread.Count -gt 0) {
        $reasons = @($unread | Group-Object { [string]$_.Reason } | ForEach-Object { [string]$_.Count + ' ' + ([string]$_.Name).ToLowerInvariant() })
        $text += ' Groupes non lus : ' + ($reasons -join ', ') + '.'
    }
    if ([bool]$nested.Bounded) { $text += ' Lecture bornée (2 000 groupes, 16 niveaux ou 10 s) : la liste peut être incomplète.' }
    if ([bool]$nested.StartPartial) { $text += ' Groupes directs de lʼobjet lus en partie : la liste peut être incomplète.' }
    if ([string]$nested.PrimaryGroup) { return $text + ' Groupe principal : ' + [string]$nested.PrimaryGroup + ' (primaryGroupID, absent de memberOf).' }
    return $text + ' Le groupe principal nʼest pas compris dans memberOf.'
}

# R40: compare the group access of the fiche user with a second user. The two reads are the pinned GroupPathRead
# operation (no new worker body), started only by the explicit button; the UI thread never reads the directory.
$script:AccessDiff = $null
$script:AccessDiffSequence = 0L
$script:AccessDiffResult = $null
$script:AccessDiffUiBound = $false

function Reset-DomeniaUserAccessDiff {
    # A new fiche, a new user or a new comparison: no result of the previous comparison stays on screen.
    $script:AccessDiffSequence = [long]$script:AccessDiffSequence + 1
    $script:AccessDiff = $null
    $script:AccessDiffResult = $null
    $box = Get-DomeniaControl 'TxtAccessDiffOther'
    if ($null -ne $box) { try { $box.Text = '' } catch { Write-DomeniaSwallowed 'Membership' 'Reset-DomeniaUserAccessDiff' $_ } }
    $grid = Get-DomeniaControl 'DgAccessDiff'
    if ($null -ne $grid) { $grid.ItemsSource = $null }
    [void](Set-DomeniaControlText 'LblAccessDiffStatus' 'Saisissez lʼidentifiant ou le DN du second utilisateur, puis lancez la comparaison (deux lectures bornées).')
    $copy = Get-DomeniaControl 'BtnAccessDiffCopy'
    if ($null -ne $copy) { try { $copy.IsEnabled = $false } catch { Write-DomeniaSwallowed 'Membership' 'Reset-DomeniaUserAccessDiff' $_ } }
}

function Test-DomeniaUserAccessDiffCurrent {
    # A callback from a previous fiche, session or comparison never writes into the current one.
    param($State)
    if (($null -eq $State) -or ($null -eq $script:AccessDiff)) { return $false }
    if ([long](Get-DomeniaMember $State 'Sequence' 0) -ne [long](Get-DomeniaMember $script:AccessDiff 'Sequence' -1)) { return $false }
    if ([long](Get-DomeniaMember $State 'Epoch' 0) -ne [long]$script:SessionEpoch) { return $false }
    if ([long](Get-DomeniaMember $State 'Generation' -1) -ne [long]$script:SelectedObjectGeneration) { return $false }
    if (($null -eq $script:SelectedObject) -or ([string](Get-DomeniaMember $State 'LeftDn' '') -ine [string]$script:SelectedObject.DN)) { return $false }
    return $true
}

function Start-DomeniaUserAccessDiff {
    # Explicit gesture only. A DN starts the first read at once; a short name is first resolved in the local copy
    # (SQLite, no directory request) and the exact match starts the same two reads.
    $object = $script:SelectedObject
    if (($null -eq $object) -or ([string]$object.Type -ne 'Utilisateur') -or (-not [string]$object.DN)) {
        [void](Set-DomeniaControlText 'LblAccessDiffStatus' 'Ouvrez la fiche dʼun utilisateur avant de comparer ses droits.')
        return
    }
    $box = Get-DomeniaControl 'TxtAccessDiffOther'
    $text = ''
    if ($null -ne $box) { $text = ([string]$box.Text).Trim() }
    if (-not $text) { [void](Set-DomeniaControlText 'LblAccessDiffStatus' 'Saisissez lʼidentifiant ou le DN du second utilisateur.'); return }
    if ($text.Length -gt 2048) { [void](Set-DomeniaControlText 'LblAccessDiffStatus' 'Identifiant ou DN trop long : aucune lecture.'); return }
    $script:AccessDiffSequence = [long]$script:AccessDiffSequence + 1
    $run = [pscustomobject]@{
        Sequence=[long]$script:AccessDiffSequence;Epoch=[long]$script:SessionEpoch;Generation=[long]$script:SelectedObjectGeneration
        LeftDn=[string]$object.DN;LeftName=[string]$object.Name;RightDn='';RightName='';Input=$text;Candidates=@()
        Phase='Start';LeftRead=$null;RightRead=$null
    }
    $script:AccessDiff = $run
    $script:AccessDiffResult = $null
    $grid = Get-DomeniaControl 'DgAccessDiff'
    if ($null -ne $grid) { $grid.ItemsSource = $null }
    $copy = Get-DomeniaControl 'BtnAccessDiffCopy'
    if ($null -ne $copy) { try { $copy.IsEnabled = $false } catch { Write-DomeniaSwallowed 'Membership' 'Start-DomeniaUserAccessDiff' $_ } }
    if (($text.IndexOf('=') -gt 0) -and ($text.IndexOf(',') -gt 0)) {
        $run.RightDn = $text
        $run.RightName = Get-DomeniaDnDisplayName $text
        Start-DomeniaUserAccessDiffRead -Run $run
        return
    }
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $candidates.Add($text)
    if ($text.Contains([string][char]92)) { $short = $text.Split([char]92)[-1]; if ($short) { $candidates.Add($short) } }
    if ($text.Contains('@')) { $short = $text.Split([char]64)[0]; if ($short) { $candidates.Add($short) } }
    $run.Candidates = @($candidates | Select-Object -Unique)
    $path = ''
    try { $path = [string](Get-DomeniaLocalDatabasePathForRead) } catch { $path = '' }
    if (-not $path) { Fail-DomeniaUserAccessDiff -Message 'La copie locale nʼest pas disponible : saisissez le DN du second utilisateur.' -State $run; return }
    $payload = [pscustomobject]@{Action='ResolveNames';Path=$path;BusyTimeoutMs=250;Users=@($run.Candidates);Computers=@();Dns=@()}
    [void](Set-DomeniaControlText 'LblAccessDiffStatus' 'Recherche du second utilisateur dans la copie locale, sans requête AD…')
    try {
        $job = Start-UiTask -Name 'Droits comparés : second utilisateur' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload $payload -CallbackState $run -ReplaceKey 'useraccessdiff-resolve' -DisableControls @('BtnAccessDiffCompare') -TimeoutSeconds 30 -SuccessHandler 'Complete-DomeniaUserAccessDiffResolve' -ErrorHandler 'Fail-DomeniaUserAccessDiff' -TaskClass 'Explicit'
        if (-not $job) { Fail-DomeniaUserAccessDiff -Message 'Recherche du second utilisateur non admise pour lʼinstant : réessayez.' -State $run }
    } catch { Fail-DomeniaUserAccessDiff -Message $_.Exception.Message -State $run }
}

function Start-DomeniaUserAccessDiffRead {
    # First of the two bounded directory reads: the groups of the fiche user. The second read only starts when this
    # one answered for the same user, so an abandoned comparison never leaves a second request in flight.
    param($Run)
    if (-not (Test-DomeniaUserAccessDiffCurrent $Run)) { return }
    $Run.Phase = 'Left'
    [void](Set-DomeniaControlText 'LblAccessDiffStatus' ('Lecture des groupes de « ' + [string]$Run.LeftName + ' » (première des deux lectures)…'))
    $payload = [pscustomobject]@{Dn=[string]$Run.LeftDn;Mode='Expand';TargetDn='';MaxNodes=2000;MaxDepth=16;Seconds=10}
    try {
        $job = Start-UiTask -Name 'Droits comparés : groupes du premier utilisateur' -OperationId 'GroupPathRead' -Code (Get-DomeniaGroupPathWorkerCode) -Payload $payload -CallbackState $Run -ReplaceKey 'useraccessdiff-left' -DisableControls @('BtnAccessDiffCompare') -TimeoutSeconds 60 -SuccessHandler 'Complete-DomeniaUserAccessDiffLeft' -ErrorHandler 'Fail-DomeniaUserAccessDiff' -TaskClass 'Explicit'
        if (-not $job) { Fail-DomeniaUserAccessDiff -Message 'Lecture des groupes non admise pour lʼinstant : réessayez.' -State $Run }
    } catch { Fail-DomeniaUserAccessDiff -Message $_.Exception.Message -State $Run }
}

function Start-DomeniaUserAccessDiffRight {
    # Second of the two bounded reads: the groups of the second user. Nothing else is read after it.
    param($Run)
    if (-not (Test-DomeniaUserAccessDiffCurrent $Run)) { return }
    $Run.Phase = 'Right'
    [void](Set-DomeniaControlText 'LblAccessDiffStatus' ('Lecture des groupes de « ' + [string]$Run.RightName + ' » (seconde des deux lectures)…'))
    $payload = [pscustomobject]@{Dn=[string]$Run.RightDn;Mode='Expand';TargetDn='';MaxNodes=2000;MaxDepth=16;Seconds=10}
    try {
        $job = Start-UiTask -Name 'Droits comparés : groupes du second utilisateur' -OperationId 'GroupPathRead' -Code (Get-DomeniaGroupPathWorkerCode) -Payload $payload -CallbackState $Run -ReplaceKey 'useraccessdiff-right' -DisableControls @('BtnAccessDiffCompare') -TimeoutSeconds 60 -SuccessHandler 'Complete-DomeniaUserAccessDiffRight' -ErrorHandler 'Fail-DomeniaUserAccessDiff' -TaskClass 'Explicit'
        if (-not $job) { Fail-DomeniaUserAccessDiff -Message 'Lecture des groupes non admise pour lʼinstant : réessayez.' -State $Run }
    } catch { Fail-DomeniaUserAccessDiff -Message $_.Exception.Message -State $Run }
}

function Complete-DomeniaUserAccessDiffResolve {
    # Exact match only: a partial local answer is never taken for the wanted user. The DN then follows the same path.
    param($Result,$State)
    if (-not (Test-DomeniaUserAccessDiffCurrent $State)) { return }
    try {
        $data = Get-DomeniaEffectiveWorkerResult $Result @('Users')
        if (($null -eq $data) -or [bool](Get-DomeniaMember $data 'Busy' $false) -or [bool](Get-DomeniaMember $data 'Missing' $false)) {
            Fail-DomeniaUserAccessDiff -Message 'La copie locale nʼa pas répondu : saisissez le DN du second utilisateur.' -State $State
            return
        }
        $wanted = @($State.Candidates)
        $match = $null
        foreach ($user in @(Get-DomeniaMember $data 'Users' @())) {
            $login = [string](Get-DomeniaMember $user 'login' '')
            if (-not $login) { continue }
            foreach ($candidate in $wanted) {
                if ([string]$candidate -and ($login -ieq [string]$candidate)) { $match = $user; break }
            }
            if ($null -ne $match) { break }
        }
        $dn = ''
        if ($null -ne $match) { $dn = [string](Get-DomeniaMember $match 'distinguished_name' '') }
        if (-not $dn) {
            Fail-DomeniaUserAccessDiff -Message ('Aucun utilisateur de la copie locale ne porte exactement « ' + [string]$State.Input + ' ». Saisissez le DN du second utilisateur ou actualisez la copie locale.') -State $State
            return
        }
        $State.RightDn = $dn
        $State.RightName = Get-DomeniaDnDisplayName $dn
        Start-DomeniaUserAccessDiffRead -Run $State
    } catch { Fail-DomeniaUserAccessDiff -Message $_.Exception.Message -State $State }
}

function Complete-DomeniaUserAccessDiffLeft {
    # The answer must name the same user; the second read starts only then.
    param($Result,$State)
    if (-not (Test-DomeniaUserAccessDiffCurrent $State)) { return }
    try {
        $data = Get-DomeniaEffectiveWorkerResult $Result @('Dn','Nodes')
        if (($null -eq $data) -or ([string](Get-DomeniaMember $data 'Dn' '') -ine [string]$State.LeftDn)) { throw 'Réponse des groupes du premier utilisateur absente ou dʼun autre objet.' }
        $State.LeftRead = $data
        Start-DomeniaUserAccessDiffRight -Run $State
    } catch { Fail-DomeniaUserAccessDiff -Message $_.Exception.Message -State $State }
}

function Complete-DomeniaUserAccessDiffRight {
    # Both answers are in: compare locally, fill the grid, enable the ticket copy. No other directory read.
    param($Result,$State)
    if (-not (Test-DomeniaUserAccessDiffCurrent $State)) { return }
    try {
        $data = Get-DomeniaEffectiveWorkerResult $Result @('Dn','Nodes')
        if (($null -eq $data) -or ([string](Get-DomeniaMember $data 'Dn' '') -ine [string]$State.RightDn)) { throw 'Réponse des groupes du second utilisateur absente ou dʼun autre objet.' }
        $State.RightRead = $data
        $State.Phase = 'Done'
        $comparison = Compare-DomeniaUserGroupAccess -Left $State.LeftRead -Right $data -LeftDn ([string]$State.LeftDn) -RightDn ([string]$State.RightDn) -LeftLabel ([string]$State.LeftName) -RightLabel ([string]$State.RightName) -MaxDepth 16 -MaxGroups 5000
        $script:AccessDiffResult = $comparison
        $rows = [Collections.ObjectModel.ObservableCollection[object]]::new()
        foreach ($row in @($comparison.Rows)) { $rows.Add($row) }
        $grid = Get-DomeniaControl 'DgAccessDiff'
        if ($null -ne $grid) { $grid.ItemsSource = $rows }
        [void](Set-DomeniaControlText 'LblAccessDiffStatus' ([string]$comparison.Summary + ' ' + [string]$comparison.Note))
        $copy = Get-DomeniaControl 'BtnAccessDiffCopy'
        if ($null -ne $copy) { $copy.IsEnabled = $true }
    } catch { Fail-DomeniaUserAccessDiff -Message $_.Exception.Message -State $State }
}

function Fail-DomeniaUserAccessDiff {
    # A failed or abandoned read never leaves a previous result looking current.
    param($Message,$State)
    if (-not (Test-DomeniaUserAccessDiffCurrent $State)) { return }
    if ($null -ne $script:AccessDiff) { $script:AccessDiff.Phase = 'Failed' }
    [void](Set-DomeniaControlText 'LblAccessDiffStatus' ('Comparaison interrompue : ' + [string]$Message + ' Aucune écriture AD nʼa été faite.'))
    $copy = Get-DomeniaControl 'BtnAccessDiffCopy'
    if ($null -ne $copy) { try { $copy.IsEnabled = $false } catch { Write-DomeniaSwallowed 'Membership' 'Fail-DomeniaUserAccessDiff' $_ } }
}

function Copy-DomeniaUserAccessDiffTicket {
    # Copies the comparison already on screen; no new read.
    if ($null -eq $script:AccessDiffResult) { [void](Set-DomeniaControlText 'LblAccessDiffStatus' 'Aucune comparaison à copier : lancez dʼabord la comparaison.'); return }
    try {
        $text = Format-DomeniaUserAccessDiffTicket -Comparison $script:AccessDiffResult -When ([datetime]::Now.ToString('dd/MM/yyyy HH:mm'))
        Set-ClipboardSafe $text
        Set-Status 'Comparaison des droits copiée pour le ticket.'
    } catch { [void](Set-DomeniaControlText 'LblAccessDiffStatus' ('Copie impossible : ' + $_.Exception.Message)) }
}

function Register-DomeniaUserAccessDiffUi {
    # Binds the explicit compare and copy gestures once; no control, no binding.
    if ([bool]$script:AccessDiffUiBound) { return }
    $compare = Get-DomeniaControl 'BtnAccessDiffCompare'
    if ($compare -is [Windows.Controls.Primitives.ButtonBase]) { $compare.Add_Click({ try { Start-DomeniaUserAccessDiff } catch { [void](Set-DomeniaControlText 'LblAccessDiffStatus' ('Comparaison impossible : ' + $_.Exception.Message)) } }) }
    $copy = Get-DomeniaControl 'BtnAccessDiffCopy'
    if ($copy -is [Windows.Controls.Primitives.ButtonBase]) { $copy.Add_Click({ try { Copy-DomeniaUserAccessDiffTicket } catch { [void](Set-DomeniaControlText 'LblAccessDiffStatus' ('Copie impossible : ' + $_.Exception.Message)) } }) }
    $script:AccessDiffUiBound = $true
}

function Register-DomeniaMembershipUi {
    # Context menus, filters and the « Groupes imbriqués » button of the membership grids. Returns the number of
    # controls wired (Register-DomeniaContextMenus counts them).
    $applied = 0
    foreach ($kind in @('MemberOf','Members')) {
        $names = Get-DomeniaMembershipControlNames -Kind $kind
        $grid = Get-DomeniaControl $names.Grid
        if ($null -ne $grid) {
            $menu = New-Object System.Windows.Controls.ContextMenu
            $kindText = $kind
            [void]$menu.Items.Add((New-DomeniaMenuItem -Header 'Rechercher cet objet' -Action ([scriptblock]::Create('$r = Get-DomeniaSelectedMembershipRow -Kind ' + $kindText + '; if ($null -ne $r) { Start-DomeniaSearchFor -Term ([string]$r.Dn) }'))))
            [void]$menu.Items.Add((New-DomeniaMenuItem -Header 'Copier le DN' -Action ([scriptblock]::Create('$r = Get-DomeniaSelectedMembershipRow -Kind ' + $kindText + '; if ($null -ne $r) { Set-ClipboardSafe ([string]$r.Dn); Set-Status "DN copié." }'))))
            if ($kind -eq 'MemberOf') {
                [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
                [void]$menu.Items.Add((New-DomeniaMenuItem -Header 'Pourquoi membre ?' -Action { try { Invoke-DomeniaMembershipWhy } catch { Show-DomeniaMembershipWhy ('Explication impossible : ' + $_.Exception.Message) } }))
                [void]$menu.Items.Add((New-DomeniaMenuItem -Header 'Afficher les groupes imbriqués' -Action { try { Start-DomeniaMembershipPathRead } catch { Show-DomeniaMembershipWhy ('Lecture impossible : ' + $_.Exception.Message) } }))
            }
            $grid.ContextMenu = $menu
            $applied++
        }
        if (-not [bool]$script:MembershipUiBound) {
            $box = Get-DomeniaControl $names.Filter
            if ($box -is [Windows.Controls.TextBox]) {
                if ($kind -eq 'MemberOf') { $box.Add_TextChanged({ try { Update-DomeniaMembershipFilter -Kind MemberOf } catch { Write-DomeniaSwallowed 'Membership' 'Register-DomeniaMembershipUi' $_ } }) }
                else { $box.Add_TextChanged({ try { Update-DomeniaMembershipFilter -Kind Members } catch { Write-DomeniaSwallowed 'Membership' 'Register-DomeniaMembershipUi' $_ } }) }
            }
        }
    }
    if (-not [bool]$script:MembershipUiBound) {
        $nestedButton = Get-DomeniaControl 'BtnMemberOfNested'
        if ($nestedButton -is [Windows.Controls.Primitives.ButtonBase]) { $nestedButton.Add_Click({ try { Start-DomeniaMembershipPathRead } catch { Show-DomeniaMembershipWhy ('Lecture impossible : ' + $_.Exception.Message) } }) }
    }
    $script:MembershipUiBound = $true
    try { Register-DomeniaUserAccessDiffUi } catch { Write-DomeniaSwallowed 'Membership' 'Register-DomeniaMembershipUi' $_ }
    return $applied
}
