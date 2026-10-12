# Workstation, fleet and software dashboards (decision David 2026-10-07). Each board is a set of widgets drawn by
# Domenia-Widgets.UI.ps1 from the data of its provider (Domenia-Board*.ps1); this module feeds them and keeps the
# fleet scope and analyses. Only data already read: no extra request to the workstation.
$script:DashboardModuleRoot = $PSScriptRoot
function Clear-DomeniaDashboards {
    # Another object is selected: the workstation and software boards forget the previous data and their undo steps
    # (FI-11: the only moment the undo of a workstation layout is cleared).
    $script:LastComputerDashboardResult = $null
    foreach ($board in @('Computer','Software')) { $state = Get-DomeniaBoardState $board; $state.Data = $null; Clear-DomeniaBoardUndo -Board $board }
    [void](Set-DomeniaControlText 'LblComputerDashboard' 'Lancez un inventaire (Rapide ou Complet) : le tableau de bord se remplit avec ses resultats.')
    [void](Set-DomeniaControlText 'LblSoftwareDashboard' 'Chargez les logiciels pour afficher la synthese.')
    Show-DomeniaBoard -Board Computer -Quiet -EmptyText 'Lancez un inventaire rapide ou complet : chaque widget se remplit avec ses resultats.'
    $software = Get-DomeniaControl 'PnlSoftwareDashboard'
    if ($null -ne $software) { $software.Children.Clear() }
}
function Get-DomeniaInventoryValue {
    param($Rows,[string]$Category,[string]$Item)
    # Empty answers ('(vide)' before 2026-10-07, words since) are left to the dashboard's own wording.
    foreach ($row in @($Rows)) { if ([string]$row.Category -eq $Category -and [string]$row.Item -eq $Item) { $text = [string]$row.Value; if ($text -match '^\(vide\)$|^Non renseigne$|^Non fourni|^Aucun$|^\s*$') { return '' }; return $text } }
    return ''
}
function Get-DomeniaCategorySummary {
    # Items of one inventory category without its 'Etat' line; when empty, the 'Etat' text ("Aucun ...") is kept.
    param($Rows,[string]$Category)
    $items = @($Rows | Where-Object { [string]$_.Category -eq $Category -and [string]$_.Item -ne 'Etat' })
    $state = @($Rows | Where-Object { [string]$_.Category -eq $Category -and [string]$_.Item -eq 'Etat' } | Select-Object -First 1)
    return [pscustomobject]@{ Items = $items; Count = $items.Count; State = $(if ($state.Count) { [string]$state[0].Value } else { '' }); Read = ($items.Count -gt 0 -or $state.Count -gt 0) }
}
function New-DomeniaDashboardSection {
    # Section title in the display face, aligned with the card edges; cards flow below it.
    param($Host_,[string]$Title,[string]$Subtitle = '')
    $section = New-Object System.Windows.Controls.StackPanel
    $section.Margin = [System.Windows.Thickness]::new(0,$(if ($Host_.Children.Count) { 18 } else { 6 }),0,0)
    $header = New-DomeniaChartText -Text $Title -Size 17 -Weight SemiBold -Key 'TextColor' -Display
    $header.Margin = [System.Windows.Thickness]::new(7,0,0,$(if ($Subtitle) { 0 } else { 4 }))
    [void]$section.Children.Add($header)
    if ($Subtitle) { $sub = New-DomeniaChartText -Text $Subtitle -Size 12 -Key 'MutedColor'; $sub.Margin = [System.Windows.Thickness]::new(7,1,0,4); [void]$section.Children.Add($sub) }
    $wrap = New-Object System.Windows.Controls.WrapPanel
    [void]$section.Children.Add($wrap)
    [void]$Host_.Children.Add($section)
    return $wrap
}
function Get-DomeniaEntryFileTimeUtc {
    # AD large integer (pwdLastSet, lastLogonTimestamp, LAPS expiration) or date, as UTC; $null when absent.
    param($Entry,[string]$Name)
    $raw = $null; try { $raw = Get-DeProp $Entry $Name $null } catch { return $null }
    if ($null -eq $raw -or [string]$raw -eq '') { return $null }
    if ($raw -is [datetime]) { return $raw.ToUniversalTime() }
    $ticks = $null
    try { $ticks = ConvertFrom-DomeniaLargeInteger $raw } catch { }
    if ($null -eq $ticks) { $parsed = 0L; if ([long]::TryParse([string]$raw,[ref]$parsed)) { $ticks = $parsed } }
    if ($null -eq $ticks -or $ticks -le 0 -or $ticks -eq [long]::MaxValue) { return $null }
    try { return [datetime]::FromFileTimeUtc($ticks) } catch { return $null }
}
function Get-DomeniaFleetScope {
    # The home overview follows the OU chosen in the Rechercher tree (decision David 2026-10-08): one scope for the
    # whole application, no picker of its own. The domain root means the whole indexed domain (consultation only).
    $scope = $null
    try { $scope = Get-DomeniaSearchScope -Mode OU } catch { return $null }
    if ($null -eq $scope) { return $null }
    $dn = ([string]$scope.BaseDn).Trim()
    $whole = [bool]$scope.IsDomain
    $subtree = ([string]$scope.Scope -ne 'OneLevel')
    $name = if ($whole) { 'Tout le domaine' } else { (($dn -split '(?<!\\),')[0] -replace '^(OU|CN)=','') }
    return [pscustomobject]@{
        Dn = $(if ($whole) { '' } else { $dn })
        Subtree = $(if ($whole) { $true } else { $subtree })
        Name = $name
        Path = $dn
        Key = $(if ($whole) { '*' } else { $dn.ToLowerInvariant() + '|' + $(if ($subtree) { 'Subtree' } else { 'OneLevel' }) })
    }
}
function Get-DomeniaWindowsLifecycleTable {
    # End-of-service table delivered with the modules (FO-08), read once and passed to the rules. Updated by a new
    # delivery only, never downloaded. Absent or unreadable: $null, the end dates are then unknown (never critical).
    if ($script:DomeniaWindowsLifecycleRead) { return $script:DomeniaWindowsLifecycle }
    $script:DomeniaWindowsLifecycleRead = $true
    $script:DomeniaWindowsLifecycle = $null
    try {
        $root = [string]$script:DashboardModuleRoot
        if (-not $root) { return $null }
        $path = Join-Path $root 'Domenia-WindowsLifecycle.json'
        if (-not [IO.File]::Exists($path)) { Write-AppLog 'Table des fins de service absente : dates de fin inconnues.' 'WARN'; return $null }
        $table = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | ConvertFrom-Json
        if (([string]$table.Format -ne 'DomeniaWindowsLifecycle/1') -or (@($table.Entries).Count -eq 0)) { Write-AppLog 'Table des fins de service illisible : dates de fin inconnues.' 'WARN'; return $null }
        $script:DomeniaWindowsLifecycle = $table
    } catch { try { Write-AppLog ('Table des fins de service illisible : ' + $_.Exception.Message) 'WARN' } catch { } }
    return $script:DomeniaWindowsLifecycle
}
function Get-DomeniaObservationMaxAgeDays {
    $days = 30
    try { $days = [int](Get-CfgValue 'Dashboard' 'ObservationMaxAgeDays' 30) } catch { $days = 30 }
    if ($days -lt 1) { $days = 30 }
    return [Math]::Min(3650,$days)
}
function Test-DomeniaFleetDashboardShown {
    $tabs = Get-DomeniaControl 'WorkspaceTabs'
    if ($null -eq $tabs -or $null -eq $tabs.SelectedItem) { return $false }
    return ([string]$tabs.SelectedItem.Name -eq 'TabDashboard')
}
function Test-DomeniaFleetAwaitingScope {
    # At startup Rechercher restores its remembered OU a moment after the window opens. Until then the scope is the
    # domain root, which is not computed first: the overview waits for the OU (smooth startup).
    $c = $script:Continuity
    if ($null -eq $c -or -not [bool]$c.Restoring -or [bool]$c.SelectedRestored) { return $false }
    $dn = ([string]$script:SelectedBranchDn).Trim()
    return ((-not $dn) -or $dn -ieq ([string]$script:Conn.BaseDn).Trim())
}
function Request-DomeniaFleetRefresh {
    # Recomputes the overview when it is on screen and its OU or data changed; otherwise it is recomputed when Accueil
    # is shown again. -Force: the data changed (analysis finished, base saved, new session).
    param([switch]$Force)
    if ($Force) { $script:FleetStale = $true }
    if (-not (Test-DomeniaFleetDashboardShown)) { return }
    if (Test-DomeniaFleetAwaitingScope) {
        $script:FleetAwaitingRestore = $true
        [void](Set-DomeniaControlText 'LblFleetDashboard' 'En attente de l OU memorisee dans Rechercher...')
        return
    }
    $scope = Get-DomeniaFleetScope
    if ($null -eq $scope) { return }
    # First steps (UX-20): their state is read from the session each time Accueil is shown, without any request.
    try { Update-DomeniaFirstSteps } catch { }
    # The same OU is still being computed: its end decides (data changed meanwhile is computed again then).
    $job = [string]$script:FleetJobId
    if ($job -and [string]$script:FleetPendingKey -ceq [string]$scope.Key -and $null -ne $script:AsyncJobs -and $script:AsyncJobs.Contains($job)) { return }
    if (-not [bool]$script:FleetStale -and [string]$script:FleetComputedKey -ceq [string]$scope.Key) { return }
    Start-DomeniaFleetDashboard -Quiet
}
function Start-DomeniaFleetDashboard {
    # Home dashboard (decision David 2026-10-07): aggregates of the local index, read in the background. The worker
    # filters the OU and groups the workstations in SQL by the boundaries of the rules (Get-DomeniaFleetQueryPlan);
    # a new request replaces the one still running. An automatic request (-Quiet) is a background task: it never
    # takes over the global Annuler button.
    param([switch]$Quiet)
    $path = [string]$script:DatabaseScopedPath
    if (-not $path) { if (-not $Quiet) { Set-Status 'Aucune base autonome active : vue dʼensemble indisponible.' 'WARN' }; return }
    $scope = Get-DomeniaFleetScope
    if ($null -eq $scope) { if (-not $Quiet) { Set-Status 'Connectez-vous pour calculer la vue dʼensemble.' 'WARN' }; return }
    $state = [pscustomobject]@{ Path = $path; Epoch = [long]$script:SessionEpoch; Key = [string]$scope.Key; Scope = [string]$scope.Dn; Subtree = [bool]$scope.Subtree; Name = [string]$scope.Name; ScopePath = [string]$scope.Path }
    # The selected workstation keeps its observations for its own board, even outside the OU.
    $keys = @()
    try { if (($null -ne $script:SelectedObject) -and ([string]$script:SelectedObject.Type -eq 'Machine') -and [string]$script:SelectedObject.DN) { $keys = @(([string]$script:SelectedObject.DN).ToLowerInvariant()) } } catch { $keys = @() }
    $plan = Get-DomeniaFleetQueryPlan -Now ([datetime]::Now) -ObservationMaxAgeDays (Get-DomeniaObservationMaxAgeDays)
    $job = $null
    try {
        [void](Initialize-DomeniaWinSqliteNative)
        $job = Start-UiTask -Name 'Vue d ensemble du parc' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload ([pscustomobject]@{ Action='FleetStats'; Path=$path; BusyTimeoutMs=250; Scope=[string]$scope.Dn; Subtree=[bool]$scope.Subtree; Plan=$plan; Keys=$keys; ScopeKey=[string]$scope.Key }) -CallbackState $state -ReplaceKey 'fleet:stats' -SuccessHandler 'Complete-DomeniaFleetDashboard' -ErrorHandler 'Fail-DomeniaFleetDashboard' -TimeoutSeconds 60 -TaskClass $(if ($Quiet) { 'Background' } else { 'Explicit' })
    } catch {
        $script:FleetPendingKey = ''; $script:FleetJobId = ''
        [void](Set-DomeniaControlText 'LblFleetDashboard' ('Vue dʼensemble non calculée : ' + $_.Exception.Message))
        if (-not $Quiet) { throw }
        return
    }
    if (-not $job) {
        $script:FleetPendingKey = ''; $script:FleetJobId = ''
        [void](Set-DomeniaControlText 'LblFleetDashboard' 'Vue dʼensemble non calculée : calcul non admis pour lʼinstant, réessayez avec lʼicône dʼactualisation.')
        return
    }
    # Computed only once drawn (Complete): a cancelled or refused calculation is tried again at the next display.
    $script:FleetPendingKey = [string]$scope.Key; $script:FleetJobId = [string]$job; $script:FleetStale = $false
    [void](Set-DomeniaControlText 'LblFleetDashboard' ('Calcul de la vue dʼensemble depuis la base locale : ' + [string]$scope.Name + '...'))
}
function Fail-DomeniaFleetDashboard {
    param($Message,$State)
    if ($null -ne $State -and [long]$State.Epoch -ne [long]$script:SessionEpoch) { return }
    # A replaced calculation (other OU) does not overwrite the text of the current one.
    if ($null -ne $State -and [string]$State.Key -cne [string]$script:FleetPendingKey) { return }
    # The next display of Accueil tries again.
    $script:FleetPendingKey = ''; $script:FleetJobId = ''; $script:FleetComputedKey = ''
    [void](Set-DomeniaControlText 'LblFleetDashboard' ('Vue dʼensemble non calculée : ' + [string]$Message))
}
function Update-DomeniaFleetScopeText {
    # One status line (UI-03): clickable OU path, number of workstations, age of the local base.
    param($Scope,[int]$Count = -1,[string]$LastSyncUtc = '')
    if ($null -eq $Scope) { return }
    $parts = New-Object System.Collections.ArrayList
    if (-not [string]$Scope.Dn) { [void]$parts.Add('Tout le domaine indexé (consultation)') }
    elseif (-not [bool]$Scope.Subtree) { [void]$parts.Add('sans les sous-OU') }
    else { [void]$parts.Add('et ses sous-OU') }
    if ($Count -ge 0) { [void]$parts.Add([string]$Count + ' poste' + $(if ($Count -gt 1) { 's' } else { '' }) + ' actif' + $(if ($Count -gt 1) { 's' } else { '' }) + ' dans la base') }
    $sync = ConvertFrom-DomeniaUtcText $LastSyncUtc
    if ($null -ne $sync) { [void]$parts.Add('base à jour ' + (Format-DomeniaAge -FromUtc $sync -NowUtc ([datetime]::UtcNow))) }
    elseif ($Count -ge 0) { [void]$parts.Add('base autonome jamais mise à jour') }
    $label = Get-DomeniaControl 'LblFleetScope'
    $text = ($parts -join ' · ')
    if ([string]$Scope.Dn) { $text = ' · ' + $text }
    [void](Set-DomeniaControlText 'LblFleetScope' $text)
    if ($null -ne $label) { $label.ToolTip = [string]$Scope.Path + "`r`n" + ('Ce nombre vient de la base locale : les postes désactivés et ceux que la base nʼa pas encore lus nʼy sont pas. La recherche, elle, interroge lʼannuaire en direct et compte tous les postes.') }
    $crumbs = Get-DomeniaControl 'PnlFleetCrumbs'
    if ($null -eq $crumbs) { return }
    $crumbs.Children.Clear()
    if (-not [string]$Scope.Dn) { return }
    # OU path from the domain down ('Postes > Lyon'); each part selects its OU in the Rechercher tree (UI-03).
    $dnParts = @(([string]$Scope.Dn) -split '(?<!\\),')
    $segments = New-Object System.Collections.ArrayList
    for ($j = $dnParts.Count - 1; $j -ge 0; $j--) {
        if ([string]$dnParts[$j] -notmatch '^(?i:OU|CN)=') { continue }
        [void]$segments.Add([pscustomobject]@{ Name = (([string]$dnParts[$j] -replace '^(?i:OU|CN)=','') -replace '\\(.)','$1'); Dn = (@($dnParts[$j..($dnParts.Count - 1)]) -join ',') })
    }
    for ($i = 0; $i -lt $segments.Count; $i++) {
        if ($i -gt 0) { $separator = New-Object System.Windows.Controls.TextBlock; $separator.Text = ' › '; $separator.FontSize = 15; $separator.VerticalAlignment = [System.Windows.VerticalAlignment]::Center; $separator.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty,'MutedColor'); [void]$crumbs.Children.Add($separator) }
        $block = New-Object System.Windows.Controls.TextBlock
        $block.FontSize = 15; $block.FontWeight = [System.Windows.FontWeights]::SemiBold; $block.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $link = New-Object System.Windows.Documents.Hyperlink
        [void]$link.Inlines.Add([string]$segments[$i].Name)
        $link.Tag = [string]$segments[$i].Dn
        $link.ToolTip = 'Choisir cette OU dans Rechercher : ' + [string]$segments[$i].Dn
        $link.Add_Click({ param($s,$e) try { Select-DomeniaFleetScopeOu -Dn ([string]$s.Tag) } catch { } })
        [void]$block.Inlines.Add($link)
        [void]$crumbs.Children.Add($block)
    }
}
function Show-DomeniaFleetScopeSource {
    # The OU is chosen in the Rechercher tree, the only OU filter of the application.
    Select-DomeniaWorkspace -Workspace 'WsSearch'
    $tree = Get-DomeniaControl 'TvDirectory'
    if ($null -ne $tree -and $tree.IsEnabled) { [void]$tree.Focus() }
    Set-Status 'Choisissez lʼOU dans lʼarbre de Rechercher : la vue dʼensemble de lʼaccueil la suit.'
}
function Select-DomeniaFleetScopeOu {
    # A part of the OU path of Accueil selects that OU in the Rechercher tree, as a click on its node does: Rechercher
    # lists that OU and the overview follows it. A node the tree does not show yet only opens the tree.
    param([string]$Dn)
    $target = ([string]$Dn).Trim()
    $node = $null
    if ($target) {
        # Get-DomeniaRealizedTreeNodes returns its array as one object (return ,$array): enumerated as Continuity does.
        try { foreach ($candidate in (Get-DomeniaRealizedTreeNodes)) { if (($candidate -is [System.Windows.Controls.TreeViewItem]) -and ($null -ne $candidate.Tag) -and ([string]$candidate.Tag.DN -ieq $target)) { $node = $candidate; break } } } catch { $node = $null }
    }
    if (($null -eq $node) -or (-not $node.IsEnabled)) { Show-DomeniaFleetScopeSource; return }
    Select-DomeniaWorkspace -Workspace 'WsSearch'
    if (-not $node.IsSelected) { $node.IsSelected = $true }
    try { $node.BringIntoView() } catch { }
    $name = (([string]$target -split '(?<!\\),')[0] -replace '^(?i:OU|CN)=','') -replace '\\(.)','$1'
    Set-Status ('OU ' + $name + ' choisie dans Rechercher : la vue dʼensemble de lʼaccueil la suit.')
}
function Show-DomeniaFleetAnalyzeSource {
    # "Analyser ces postes dans Rechercher" (UI-03): the active workstations of the OU shown on Accueil become the
    # Rechercher list, from the local base rows (no request); Pinger, Détecter or Analyser la liste start from it at the
    # operator's click. The whole domain is never listed this way: Rechercher opens on its OU tree.
    $scope = $null
    try { $scope = Get-DomeniaFleetScope } catch { $scope = $null }
    $last = $script:FleetLast
    $targets = @()
    if (($null -ne $scope) -and [string]$scope.Dn -and ($null -ne $last) -and ([string]$last.Scope -ieq [string]$scope.Dn) -and ([bool]$last.Subtree -eq [bool]$scope.Subtree)) { $targets = @($last.Targets | Where-Object { $null -ne $_ }) }
    if ($targets.Count) {
        Show-DomeniaFleetTargetsInSearch -Targets $targets -Label ([string]$scope.Name)
        Set-Status ([string]$targets.Count + ' poste(s) de ' + [string]$scope.Name + ' dans Rechercher (base locale, sans requête) : Pinger, Détecter ou Analyser la liste se lancent depuis la liste.')
        return
    }
    Select-DomeniaWorkspace -Workspace 'WsSearch'
    Set-Status 'Rechercher : affichez les postes de lʼOU, puis Pinger, Détecter ou Analyser la liste.'
}
function Merge-DomeniaFleetObservations {
    # The base snapshot may be older than the observations read since (save still queued, analysis running): the most
    # recent observation of each workstation is kept, so the widgets never go back in time.
    param($Stored,$Current)
    if ($null -eq $Stored) { $Stored = @{} }
    if ($null -eq $Current) { return $Stored }
    foreach ($key in @($Current.Keys)) {
        $mine = $Current[$key]
        if ($null -eq $mine) { continue }
        $known = $Stored[$key]
        if ($null -eq $known -or [string]::CompareOrdinal([string]$mine.CheckedUtc,[string]$known.CheckedUtc) -gt 0) { $Stored[$key] = $mine }
    }
    return $Stored
}
function Request-DomeniaSelectedObservation {
    # FI-04, workstation side: the overview loads the observations of its OU only. A selected workstation that lies
    # elsewhere gets its own from the local base: the row of its DN, GUID-checked against the index and recent enough,
    # read once per workstation and session in the background (no network, nothing sent to the workstation).
    $selected = $script:SelectedObject
    if (($null -eq $selected) -or ([string]$selected.Type -ne 'Machine')) { return $false }
    $dn = ([string]$selected.DN).Trim()
    if (-not $dn) { return $false }
    $key = $dn.ToLowerInvariant()
    if (($null -ne $script:FleetObservations) -and $script:FleetObservations.ContainsKey($key)) { return $false }
    $path = [string]$script:DatabaseScopedPath
    if (-not $path) { return $false }
    if ($null -eq $script:FleetSelectedReads) { $script:FleetSelectedReads = @{} }
    $marker = [string]$script:SessionEpoch + '|' + $key
    if ($script:FleetSelectedReads.ContainsKey($marker)) { return $false }
    $script:FleetSelectedReads[$marker] = $true
    $state = [pscustomobject]@{ Epoch = [long]$script:SessionEpoch; Key = $key }
    $job = $null
    try {
        [void](Initialize-DomeniaWinSqliteNative)
        $plan = Get-DomeniaFleetQueryPlan -Now ([datetime]::Now) -ObservationMaxAgeDays (Get-DomeniaObservationMaxAgeDays)
        $job = Start-UiTask -Name 'Relevés du poste sélectionné' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload ([pscustomobject]@{ Action = 'FleetStats'; Path = $path; BusyTimeoutMs = 250; Scope = ''; Subtree = $true; Plan = $plan; Keys = @($key); ObservationsOnly = $true }) -CallbackState $state -ReplaceKey 'fleet:selected' -SuccessHandler 'Complete-DomeniaSelectedObservation' -ErrorHandler 'Fail-DomeniaSelectedObservation' -TimeoutSeconds 30 -TaskClass 'Background'
    } catch { $job = $null }
    # Not started (engine busy or closing): tried again at the next display of the board.
    if (-not $job) { [void]$script:FleetSelectedReads.Remove($marker) }
    return [bool]$job
}
function Complete-DomeniaSelectedObservation {
    param($Result,$State)
    if (($null -ne $State) -and ([long]$State.Epoch -ne [long]$script:SessionEpoch)) { return }
    $data = Get-DomeniaEffectiveWorkerResult $Result @('Presence')
    if (($null -eq $data) -or [bool]$data.Busy) { Fail-DomeniaSelectedObservation 'base occupee' $State; return }
    $found = @{}
    foreach ($item in @($data.Presence)) {
        if (($null -eq $item) -or ($null -eq $item.PSObject.Properties['observation']) -or ($null -eq $item.observation)) { continue }
        $found[([string]$item.object_key).ToLowerInvariant()] = $item.observation
    }
    if (-not $found.Count) { return }
    $script:FleetObservations = Merge-DomeniaFleetObservations -Stored $found -Current $script:FleetObservations
    # The board of the selected workstation shows them at once while it is still that workstation.
    if (($null -ne $script:SelectedObject) -and $found.ContainsKey(([string]$script:SelectedObject.DN).ToLowerInvariant())) { try { Show-DomeniaBoard -Board Computer -Quiet } catch { } }
}
function Fail-DomeniaSelectedObservation {
    param($Message,$State)
    if (($null -eq $State) -or ([long]$State.Epoch -ne [long]$script:SessionEpoch) -or ($null -eq $script:FleetSelectedReads)) { return }
    # A locked or unreadable base is tried again at the next display of the board.
    [void]$script:FleetSelectedReads.Remove([string]$State.Epoch + '|' + [string]$State.Key)
}
function Save-DomeniaFleetSnapshot {
    # FO-10: first calculation of the day for this OU: its directory figures are kept locally (no network, no task).
    param($Scope,$Board)
    if (($null -eq $Scope) -or ($null -eq $Board) -or ($null -eq $Board.PSObject.Properties['Snapshot'])) { return $false }
    $snapshot = $Board.Snapshot
    if ([bool]$snapshot.Taken) { return $false }
    $marker = [string]$Scope.Key + '|' + [string]$snapshot.Day
    if ($null -eq $script:FleetSnapshotQueued) { $script:FleetSnapshotQueued = @{} }
    if ($script:FleetSnapshotQueued.ContainsKey($marker)) { return $false }
    $figures = ConvertTo-Json -InputObject $snapshot.Figures -Compress
    $row = [pscustomobject]@{ ScopeKey = [string]$Scope.Key; ScopeDn = [string]$Scope.Dn; Day = [string]$snapshot.Day; TakenAt = [datetime]::UtcNow.ToString('o'); Machines = [int]$snapshot.Figures.Machines; Figures = $figures }
    $queued = $false
    try { $queued = [bool](Queue-DomeniaMetadata -Kind FleetSnapshot -Key $marker -Row $row) } catch { $queued = $false }
    if ($queued) { $script:FleetSnapshotQueued[$marker] = $true }
    return $queued
}
function Complete-DomeniaFleetDashboard {
    param($Result,$State)
    if ($null -ne $State -and [long]$State.Epoch -ne [long]$script:SessionEpoch) { return }
    $panel = Get-DomeniaControl 'PnlFleetDashboard'
    if ($null -eq $panel) { return }
    # A calculation replaced by a newer one (other OU) is not shown.
    if ($null -ne $State -and [string]$State.Key -cne [string]$script:FleetPendingKey) { return }
    $data = Get-DomeniaEffectiveWorkerResult $Result @('Types','Machines')
    if ($null -eq $data) { Fail-DomeniaFleetDashboard 'reponse incomplete.' $State; return }
    if ([bool]$data.Busy) { Fail-DomeniaFleetDashboard 'base occupee, reessayez dans un instant.' $State; return }
    $script:FleetLastResult = $Result
    $scope = if ($null -ne $State) { [pscustomobject]@{ Dn = [string]$State.Scope; Subtree = [bool]$State.Subtree; Name = [string]$State.Name; Path = [string]$State.ScopePath; Key = [string]$State.Key } } else { Get-DomeniaFleetScope }
    if ($null -eq $scope) { $scope = [pscustomobject]@{ Dn = ''; Subtree = $true; Name = 'Tout le domaine'; Path = ''; Key = '*' } }
    try { $board = Get-DomeniaFleetBoardData -Result $data -Scope ([string]$scope.Dn) -Subtree ([bool]$scope.Subtree) -Lifecycle (Get-DomeniaWindowsLifecycleTable) -ObservationMaxAgeDays (Get-DomeniaObservationMaxAgeDays) -IndexPartial (Get-DomeniaIndexPartialText) }
    catch [System.Management.Automation.CommandNotFoundException] {
        # Une fonction absente est un defaut de chargement (core ou module non charge), jamais un resultat
        # metier. Le catch general la rendait en « Vue d'ensemble non calculee : The term ... » et
        # Fail-DomeniaFleetDashboard effacait FleetComputedKey: la trace ne nommait plus sa propre cause.
        $absente = [string]$_.Exception.Message
        if ($absente -match "'([^']*)'") { $absente = $matches[1] } else { $absente = [string]$_.Exception.ErrorRecord.FullyQualifiedErrorId }
        Add-DomeniaUiLog -Text ('Tableau de bord flotteur : fonction absente ' + $absente + ' | ' + [string]$_.Exception.Message) -Level "ERROR" -Area "Interface"
        Fail-DomeniaFleetDashboard ('fonction absente du chargement : ' + $absente) $State; return
    }
    catch { Fail-DomeniaFleetDashboard $_.Exception.Message $State; return }
    $script:FleetPendingKey = ''; $script:FleetJobId = ''; $script:FleetComputedKey = [string]$scope.Key
    $count = @($board.Last.Targets).Count
    $lastSync = ''
    try { if ($null -ne $script:IndexInfo) { $lastSync = [string]$script:IndexInfo.Date } } catch { $lastSync = '' }
    Update-DomeniaFleetScopeText $scope -Count $count -LastSyncUtc $lastSync
    # Observations (presence, console user, light WMI, queries) feed the query widgets of both boards.
    $script:FleetObservations = Merge-DomeniaFleetObservations -Stored $board.Observations -Current $script:FleetObservations
    $script:FleetLast = $board.Last
    Add-Member -InputObject $script:FleetLast -MemberType NoteProperty -Name 'Epoch' -Value ([long]$script:SessionEpoch) -Force
    # New data never removes the undo of a layout change (FI-11): Show-DomeniaBoard keeps the undo stack.
    Show-DomeniaBoard -Board Fleet -Data $board
    # A query run on the selected workstation refreshes its widgets even without an inventory.
    if ($null -ne $script:SelectedObject -or $null -ne $script:LastComputerDashboardResult) { try { Show-DomeniaBoard -Board Computer -Quiet } catch { } }
    [void](Set-DomeniaControlText 'LblFleetDashboard' ('Calculée depuis la base autonome locale, sans requête AD ni poste, le ' + (Get-Date -Format 'dd/MM/yyyy HH:mm') + '.'))
    [void](Save-DomeniaFleetSnapshot -Scope $scope -Board $board)
    try { Update-DomeniaFirstSteps } catch { }
    # Data changed while computing (analysis or base saved meanwhile): computed again while Accueil is shown.
    if ([bool]$script:FleetStale) { try { Request-DomeniaFleetRefresh } catch { } }
}
function Get-DomeniaAttentionTargets {
    # Workstations of a point of the Fleet board, from the rows already in memory (no request).
    param($Item)
    $machines = @()
    if (($null -ne $script:FleetLast) -and ($null -ne $script:FleetLast.PSObject.Properties['Machines'])) { $machines = @($script:FleetLast.Machines) }
    return @(Get-DomeniaFleetPointTargets -Machines $machines -Point $Item -Max 200)
}
function Copy-DomeniaFleetTargets {
    # Names of the workstations of one point, one per line, to the clipboard.
    param([object[]]$Targets = @())
    $names = @($Targets | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.name } | Where-Object { $_ })
    if (-not $names.Count) { Set-Status 'Aucun poste à copier.' 'WARN'; return }
    try { [System.Windows.Clipboard]::SetText(($names -join [Environment]::NewLine)) } catch { Set-Status ('Copie impossible : ' + $_.Exception.Message) 'WARN'; return }
    Set-Status ([string]$names.Count + ' nom(s) de poste copiés.')
}
function Show-DomeniaFleetTargetsInSearch {
    # The workstations of one point as the Rechercher list, from the local base rows: no request is sent.
    param([object[]]$Targets = @(),[string]$Label = '')
    $rows = @(foreach ($target in @($Targets | Where-Object { $null -ne $_ })) {
        [pscustomobject]@{ Type = 'Machine'; Name = [string]$target.name; Login = [string]$target.name; UPN = ''; Mail = ''; Description = ''; Changed = ''; DN = [string]$target.distinguished_name; Guid = [string]$target.object_guid }
    })
    if (-not $rows.Count) { Set-Status 'Aucun poste à afficher.' 'WARN'; return }
    try { Stop-DomeniaLiveSearch } catch { }
    $text = [string]$rows.Count + ' poste(s) de lʼaccueil' + $(if ($Label) { ' : ' + $Label } else { '' }) + ' (base locale, sans requête)'
    Show-ObjectRows -Rows $rows -Label $text -SkipPresenceScan -NoAutoOpen
    Select-DomeniaWorkspace -Workspace 'WsSearch'
    Set-Status ($text + '.')
}
function Start-DomeniaFleetBitLockerPresence {
    # Explicit gesture of the BitLocker widget: presence of recovery objects for the OU shown on Accueil only, never
    # at the domain root, never a key (BitLockerPresence reads name, place and date of the recovery objects).
    $scope = Get-DomeniaFleetScope
    if ($null -eq $scope) { Set-Status 'Connectez-vous pour lire la présence des clés BitLocker.' 'WARN'; return $false }
    if (-not [string]$scope.Dn) { Set-Status 'Lecture refusée à la racine du domaine : choisissez une OU dans Rechercher.' 'WARN'; return $false }
    $targets = @()
    if (($null -ne $script:FleetLast) -and ([string]$script:FleetLast.Scope -ieq [string]$scope.Dn)) { $targets = @($script:FleetLast.Targets) }
    if (-not $targets.Count) { Set-Status 'Aucun poste actif de cette OU dans la base locale : mettez la base à jour avant de lire la présence des clés.' 'WARN'; return $false }
    # BitLockerPresence is a BitLocker read (Get-DomeniaOperationResource): the Secrets account of Comptes et accès and
    # the BitLocker refusals apply; Generation is the selection guard of the secret reads (Request-DomeniaAccessRecovery).
    $state = [pscustomobject]@{ Epoch = [long]$script:SessionEpoch; Key = [string]$scope.Key; Dn = [string]$scope.Dn; Targets = $targets; Generation = [long]$script:SelectedObjectGeneration }
    $job = Start-UiTask -Name 'Présence des clés BitLocker de lʼOU' -OperationId 'BitLockerPresence' -Code (Get-DomeniaBitLockerPresenceWorkerCode) -Payload ([pscustomobject]@{ DN = [string]$scope.Dn; Limit = 100000 }) -CallbackState $state -ReplaceKey 'fleet:bitlocker' -SuccessHandler 'Complete-DomeniaFleetBitLockerPresence' -ErrorHandler 'Fail-DomeniaFleetBitLockerPresence' -TimeoutSeconds 180 -TaskClass 'Explicit'
    if ($job) { Set-Status ('Lecture de la présence des clés BitLocker de ' + [string]$scope.Name + '...') }
    return [bool]$job
}
function Complete-DomeniaFleetBitLockerPresence {
    param($Result,$State)
    if (($null -ne $State) -and ([long]$State.Epoch -ne [long]$script:SessionEpoch)) { return }
    $r = Get-DomeniaEffectiveWorkerResult $Result @('Mode','Computers')
    if ($null -eq $r) { Fail-DomeniaFleetBitLockerPresence 'réponse incomplète.' $State; return }
    if (-not [bool]$r.Success) {
        $message = if ([string]$r.ErrorKind -in @('AccessDenied','NoReadableValue')) { 'non lisible avec ce compte.' } else { [string]$r.ErrorMessage }
        # A secret read handles its own refusals: the access badge offers another account for BitLocker, never for AD.
        if ([string]$r.ErrorKind -in @('AccessDenied','LogonFailure','CredentialsRejected')) { try { [void](Request-DomeniaAccessRecovery -Operation 'Présence des clés BitLocker de lʼOU' -ErrorValue ([string]$r.ErrorMessage) -OperationId 'BitLockerPresence' -DN ([string]$State.Dn)) } catch { } }
        Fail-DomeniaFleetBitLockerPresence $message $State
        return
    }
    $found = @{}
    foreach ($computer in @($r.Computers)) { if ($null -ne $computer) { $found[([string]$computer.DN).ToLowerInvariant()] = $computer } }
    $classPresent = [bool]$r.ClassPresent
    # Nothing visible in the whole OU (rights, or keys never saved in AD): the zero written for an unseen workstation
    # never replaces a key count already read for it (KeepKnown, applied by LocalStore).
    $nothingSeen = ($found.Count -eq 0)
    $rows = New-Object System.Collections.ArrayList
    $withKeys = 0
    foreach ($target in @($State.Targets)) {
        if ($null -eq $target) { continue }
        $hit = $found[([string]$target.distinguished_name).ToLowerInvariant()]
        # A truncated read only records the keys it saw: an unseen workstation is not written as "no key".
        if (($null -eq $hit) -and [bool]$r.Truncated) { continue }
        $keys = if ($null -ne $hit) { [int]$hit.Keys } else { 0 }
        if ($keys -gt 0) { $withKeys++ }
        $verdict = if (-not $classPresent) { 'non disponible dans ce domaine' } elseif ($keys -gt 0) { 'presence lue pour l OU' } else { 'aucune cle visible avec ce compte' }
        [void]$rows.Add([pscustomobject]@{ Computer = [string]$target.name; BitLockerKeys = $keys; BitLockerLast = $(if ($null -ne $hit) { [string]$hit.Last } else { '' }); LapsScheme = ''; LapsExpiry = ''; Verdict = $verdict; At = [string]$r.ReadAtUtc; KeepKnown = (($null -eq $hit) -and $nothingSeen -and $classPresent) })
    }
    if ($rows.Count) { [void](Queue-DomeniaMetadata -Kind SecretMeta -Key ('presence|' + [string]$State.Key) -Row ([pscustomobject]@{ Rows = @($rows) })) }
    $script:FleetStale = $true
    $text = if (-not $classPresent) { 'Présence BitLocker : non disponible dans ce domaine (classe absente du schéma).' }
        elseif (-not $withKeys) { 'Aucune clé visible avec ce compte (droits ou clés non sauvegardées dans AD) pour ' + [string]$rows.Count + ' poste(s).' }
        else { 'Présence BitLocker lue : ' + [string]$withKeys + ' poste(s) avec clé sur ' + [string]$rows.Count + '.' }
    if ([bool]$r.Truncated) { $text += ' Lecture partielle : limite atteinte.' }
    Set-Status $text $(if ($classPresent -and $withKeys) { 'INFO' } else { 'WARN' })
}
function Fail-DomeniaFleetBitLockerPresence {
    param($Message,$State)
    if (($null -ne $State) -and ([long]$State.Epoch -ne [long]$script:SessionEpoch)) { return }
    Set-Status ('Présence BitLocker non lue : ' + [string]$Message) 'WARN'
}
function Get-DomeniaFirstStepsState {
    # The four first steps (UX-20) from what the session already knows: no request, no scan.
    $ouDone = $false
    try { $scope = Get-DomeniaFleetScope; $ouDone = (($null -ne $scope) -and [bool][string]$scope.Dn) } catch { $ouDone = $false }
    $baseDone = $false
    try { $baseDone = ([int]$script:IndexDbCount -gt 0) } catch { $baseDone = $false }
    $accountDone = $false
    try { $accountDone = (($null -ne $script:RemoteAdminCredential) -or [bool][string](Get-DomeniaSetting -Name 'RemoteCredentialUser' -Default '')) } catch { $accountDone = $false }
    $backupDone = $false
    try {
        $folder = Join-Path ([IO.Path]::GetDirectoryName((Get-DomeniaDatabasePath))) 'Backups'
        if ([IO.Directory]::Exists($folder)) { $backupDone = (@([IO.Directory]::GetFiles($folder,'Domenia-*.db')).Count -gt 0) }
    } catch { $backupDone = $false }
    return [pscustomobject]@{ Ou = $ouDone; Base = $baseDone; Account = $accountDone; Backup = $backupDone; Done = ($ouDone -and $baseDone -and $accountDone -and $backupDone) }
}
function Update-DomeniaFirstSteps {
    # Card shown until the four steps are done once, then hidden for good (local preference).
    $card = Get-DomeniaControl 'CardFirstSteps'
    if ($null -eq $card) { return }
    if ([bool](Get-DomeniaSetting -Name 'Home.FirstStepsDone' -Default $false)) { $card.Visibility = [System.Windows.Visibility]::Collapsed; return }
    $steps = Get-DomeniaFirstStepsState
    if ([bool]$steps.Done) {
        Set-DomeniaSetting -Name 'Home.FirstStepsDone' -Value $true
        $card.Visibility = [System.Windows.Visibility]::Collapsed
        return
    }
    $card.Visibility = [System.Windows.Visibility]::Visible
    $number = 0
    foreach ($name in @('Ou','Base','Account','Backup')) {
        $number++
        $done = [bool]$steps.$name
        $mark = Get-DomeniaControl ('LblFirstStep' + $name + 'Mark')
        if ($null -ne $mark) { $mark.Text = $(if ($done) { [string][char]0x2713 } else { [string]$number }) }
        $label = Get-DomeniaControl ('LblFirstStep' + $name)
        if ($null -ne $label) { $label.Opacity = $(if ($done) { 0.6 } else { 1.0 }) }
    }
}
function Open-DomeniaFirstStep {
    # Each step opens the screen concerned and starts nothing (decision David 2026-10-08, UX-20).
    param([ValidateSet('Ou','Base','Account','Backup')][string]$Step)
    switch ($Step) {
        'Ou' { Show-DomeniaFleetScopeSource }
        'Base' { Select-DomeniaWorkspace -Workspace 'TabApplicationTools' -Inner 'ApplicationToolTabs' -Tab 'TabIndex'; Set-Status 'Base autonome : Mettre à jour tout lit les utilisateurs et les postes du domaine, à votre clic.' }
        'Account' { Invoke-DomeniaUxRoute -Route 'TabAccounts'; Set-Status 'Comptes et accès : enregistrez le compte utilisé pour les postes.' }
        'Backup' { Select-DomeniaWorkspace -Workspace 'TabApplicationTools' -Inner 'ApplicationToolTabs' -Tab 'TabIndex'; Set-Status 'Base autonome : Sauvegarder maintenant copie la base locale, à votre clic.' }
    }
}
function Get-DomeniaBoardRouteTarget {
    # Stable routes of the workstation board points (UX-10): the inner tab that holds the useful action. Any other
    # name is a workspace route of Invoke-DomeniaUxRoute.
    param([string]$Route)
    switch ($Route) {
        'ComputerActions' { return [pscustomobject]@{ Workspace = 'WsComputer'; Inner = 'ComputerTabs'; Tab = 'TabComputerAdmin' } }
        'ComputerSecrets' { return [pscustomobject]@{ Workspace = 'WsComputer'; Inner = 'ComputerTabs'; Tab = 'TabSecurity' } }
        default { return $null }
    }
}
function Invoke-DomeniaBoardRoute {
    # Link of a point of attention: opens the tab of the useful action (Redémarrer and Ouvrir C$ in Actions, the keys
    # and LAPS in Secrets) and runs nothing (decision David 2026-10-08, UX-10).
    param([Parameter(Mandatory=$true)][string]$Route)
    $target = Get-DomeniaBoardRouteTarget -Route $Route
    if ($null -eq $target) { Invoke-DomeniaUxRoute -Route $Route; return }
    Select-DomeniaWorkspace -Workspace $target.Workspace -Inner $target.Inner -Tab $target.Tab
    $inner = Get-DomeniaControl $target.Inner
    $opened = $false
    try { $opened = (($null -ne $inner) -and ($null -ne $inner.SelectedItem) -and ([string]$inner.SelectedItem.Name -eq [string]$target.Tab)) } catch { $opened = $false }
    if (-not $opened) { Set-Status 'Sélectionnez dʼabord le poste dans Rechercher : lʼonglet sʼouvrira sur sa fiche.' 'WARN' }
}
function Update-DomeniaComputerDashboard {
    param($Result)
    $script:LastComputerDashboardResult = $Result
    $board = Get-DomeniaComputerBoardData -Result $Result -Object $script:SelectedObject -Lifecycle (Get-DomeniaWindowsLifecycleTable)
    Show-DomeniaBoard -Board Computer -Data $board
    $text = if ($board.Summary) { [string]$board.Summary } else { 'Tableau de bord de l inventaire du ' + (Get-Date -Format 'dd/MM/yyyy HH:mm') + '.' }
    [void](Set-DomeniaControlText 'LblComputerDashboard' $text)
}
function Update-DomeniaSoftwareDashboard {
    param($Rows)
    $items = @($Rows | Where-Object { $null -ne $_ -and [string]$_.Name })
    if (-not $items.Count) {
        $panel = Get-DomeniaControl 'PnlSoftwareDashboard'; if ($null -ne $panel) { $panel.Children.Clear() }
        [void](Set-DomeniaControlText 'LblSoftwareDashboard' 'Aucun logiciel lu.')
        return
    }
    $board = Get-DomeniaSoftwareBoardData -Rows $items
    Show-DomeniaBoard -Board Software -Data $board
    [void](Set-DomeniaControlText 'LblSoftwareDashboard' $(if ($board.Summary) { [string]$board.Summary } else { [string]$items.Count + ' logiciels lus. Synthese calculee sur la liste chargee.' }))
}
