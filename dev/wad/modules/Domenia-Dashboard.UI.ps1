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
    # Section title in the display face, aligned with the card edges; cards flow below it. -Grid: the cards are laid
    # out in columns instead (DS-04, Set-DomeniaBoardSectionGrid); the grid is returned in place of the flow panel.
    param($Host_,[string]$Title,[string]$Subtitle = '',[switch]$Grid)
    $section = New-Object System.Windows.Controls.StackPanel
    $section.Margin = [System.Windows.Thickness]::new(0,$(if ($Host_.Children.Count) { 18 } else { 6 }),0,0)
    $header = New-DomeniaChartText -Text $Title -Size 17 -Weight SemiBold -Key 'TextColor' -Display
    $header.Margin = [System.Windows.Thickness]::new(7,0,0,$(if ($Subtitle) { 0 } else { 4 }))
    [void]$section.Children.Add($header)
    if ($Subtitle) { $sub = New-DomeniaChartText -Text $Subtitle -Size 12 -Key 'MutedColor'; $sub.Margin = [System.Windows.Thickness]::new(7,1,0,4); [void]$section.Children.Add($sub) }
    $wrap = if ($Grid) { New-Object System.Windows.Controls.Grid } else { New-Object System.Windows.Controls.WrapPanel }
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
    try { $ticks = ConvertFrom-DomeniaLargeInteger $raw } catch { Write-DomeniaSwallowed 'Dashboard' 'Get-DomeniaEntryFileTimeUtc' $_ }
    if ($null -eq $ticks) { $parsed = 0L; if ([long]::TryParse([string]$raw,[ref]$parsed)) { $ticks = $parsed } }
    if ($null -eq $ticks -or $ticks -le 0 -or $ticks -eq [long]::MaxValue) { return $null }
    try { return [datetime]::FromFileTimeUtc($ticks) } catch { return $null }
}
function Get-DomeniaFleetScope {
    # The dashboard owns its scope. Empty means the whole current domain; a chosen OU never changes Search filters.
    $base = ([string]$script:Conn.BaseDn).Trim()
    if (-not $base) { return $null }
    $dn = ([string]$script:FleetScopeDn).Trim()
    if ($dn -and $dn -ine $base -and -not $dn.EndsWith(',' + $base,[StringComparison]::OrdinalIgnoreCase)) { $dn = '' }
    $whole = (-not $dn -or $dn -ieq $base)
    if ($whole) { $dn = '' }
    # Point 54: the depth chosen in the shared OU picker. The whole domain is always read with its sub-OU, and an
    # unset value keeps the former behaviour (sub-OU included).
    $subtree = $true
    if ((-not $whole) -and ($script:FleetScopeSubtree -is [bool]) -and (-not $script:FleetScopeSubtree)) { $subtree = $false }
    $name = if ($whole) { 'Tout le domaine' } else { ((($dn -split '(?<!\\),')[0] -replace '^(OU|CN)=','') -replace '\\(.)','$1') }
    return [pscustomobject]@{
        Dn = $dn
        Subtree = $subtree
        Name = $name
        Path = $dn
        Key = $(if ($whole) { '*' } else { $dn.ToLowerInvariant() + '|' + $(if ($subtree) { 'Subtree' } else { 'OneLevel' }) })
    }
}
function Update-DomeniaFleetMachineList {
    if($null -ne $script:DomeniaQueryState -and $script:DomeniaQueryState.Bound){Request-DomeniaQueryEvaluation;return}
    # A local view over FleetStats.Machines; it includes disabled accounts and never starts an AD or endpoint query.
    $grid = Get-DomeniaControl 'DgFleetMachines'
    if ($null -eq $grid) { return }
    $all = @()
    if ($null -ne $script:FleetLast -and $null -ne $script:FleetLast.PSObject.Properties['Machines']) { $all = @($script:FleetLast.Machines) }
    $filterBox = Get-DomeniaControl 'TxtFleetMachineFilter'
    $filter = if ($null -ne $filterBox) { ([string]$filterBox.Text).Trim().ToLowerInvariant() } else { '' }
    $selector = Get-DomeniaControl 'CmbFleetMachineState'
    $state = if ($null -ne $selector -and $null -ne $selector.SelectedItem) { [string]$selector.SelectedItem.Content } else { 'Tous les états' }
    $rows = @(foreach ($machine in $all) {
        $isDisabled = ([string]$machine.st -eq 'D')
        if ($state -in @('Actifs','Activés') -and [string]$machine.st -ne 'A') { continue }
        if ($state -eq 'État inconnu' -and [string]$machine.st -in @('A','D')) { continue }
        if ($state -eq 'Désactivés' -and -not $isDisabled) { continue }
        $name = [string]$machine.name; $dn = [string]$machine.distinguished_name
        if ($filter -and $name.ToLowerInvariant().IndexOf($filter,[StringComparison]::Ordinal) -lt 0 -and $dn.ToLowerInvariant().IndexOf($filter,[StringComparison]::Ordinal) -lt 0) { continue }
        [pscustomobject]@{ name = $name; StateLabel = $(if ($isDisabled) { 'Désactivé' } elseif([string]$machine.st -eq 'A') { 'Activé' } else { 'État inconnu' }); logon = [string]$machine.logon; distinguished_name = $dn }
    })
    $grid.ItemsSource = $rows
    [void](Set-DomeniaControlText 'LblFleetMachineCount' ('{0} affiché(s) sur {1} — base locale' -f $rows.Count,$all.Count))
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
        # Point 133: a table of a newer Domenia is named with its version, never read as an unknown file.
        $format = Resolve-DomeniaContractFormat -Format ([string](Get-DomeniaMember $table 'Format' '')) -Family 'DomeniaWindowsLifecycle'
        if (-not $format.Accepted) { Write-AppLog ([string]$format.Message + ' Dates de fin inconnues.') 'WARN'; return $null }
        if (@($table.Entries).Count -eq 0) { Write-AppLog 'Table des fins de service vide : dates de fin inconnues.' 'WARN'; return $null }
        $script:DomeniaWindowsLifecycle = $table
    } catch { try { Write-AppLog ('Table des fins de service illisible : ' + $_.Exception.Message) 'WARN' } catch { Write-DomeniaSwallowed 'Dashboard' 'Get-DomeniaWindowsLifecycleTable' $_ } }
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
    if ([string]$tabs.SelectedItem.Name -eq 'TabDashboard') { return $true }
    if ([string]$tabs.SelectedItem.Name -ne 'TabApplicationTools') { return $false }
    $tools = Get-DomeniaControl 'ApplicationToolTabs'
    return ($null -ne $tools -and $null -ne $tools.SelectedItem -and [string]$tools.SelectedItem.Name -eq 'WsQueryWorkshop')
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
    try { Update-DomeniaOuRefreshUi } catch { Write-DomeniaSwallowed 'Dashboard' 'Request-DomeniaFleetRefresh' $_ }
    if ($Force) {
        $script:FleetStale = $true
        $q=$script:DomeniaQueryState
        if($null -ne $q){$q.Records=$null;$q.At=[datetime]::MinValue;$q.Generation++;$q.Result=$null;$q.Busy=$false}
    }
    if (-not (Test-DomeniaFleetDashboardShown)) { return }
    if (Test-DomeniaFleetAwaitingScope) {
        $script:FleetAwaitingRestore = $true
        [void](Set-DomeniaControlText 'LblFleetDashboard' 'En attente de l OU memorisee dans Rechercher...')
        Set-DomeniaFleetDashboardToolTip
        return
    }
    $scope = Get-DomeniaFleetScope
    if ($null -eq $scope) { return }
    # First steps (UX-20): their state is read from the session each time Accueil is shown, without any request.
    try { Update-DomeniaFirstSteps } catch { Write-DomeniaSwallowed 'Dashboard' 'Request-DomeniaFleetRefresh' $_ }
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
    $policyBook=Get-DomeniaStoredHealthPolicyBook
    $policy=Resolve-DomeniaHealthPolicy $policyBook ([string]$scope.Dn)
    $state = [pscustomobject]@{ Path = $path; Epoch = [long]$script:SessionEpoch; Key = [string]$scope.Key; Scope = [string]$scope.Dn; Subtree = [bool]$scope.Subtree; Name = [string]$scope.Name; ScopePath = [string]$scope.Path; HealthPolicy=$policy;HealthPolicyBook=$policyBook }
    # The selected workstation keeps its observations for its own board, even outside the OU.
    $keys = @()
    try { if (($null -ne $script:SelectedObject) -and ([string]$script:SelectedObject.Type -eq 'Machine') -and [string]$script:SelectedObject.DN) { $keys = @(([string]$script:SelectedObject.DN).ToLowerInvariant()) } } catch { $keys = @() }
    $plan = Get-DomeniaFleetQueryPlan -Now ([datetime]::Now) -ObservationMaxAgeDays (Get-DomeniaObservationMaxAgeDays) -HealthPolicy $policy
    $coverage=Get-DomeniaFleetFreshness -ScopeDn ([string]$scope.Dn) -DomainDn ([string]$script:Conn.BaseDn) -SyncStates $script:IndexSyncStates
    $partialText=if([string]$scope.Dn){if($coverage.Partial){'dernière lecture du périmètre incomplète le '+$coverage.AttemptAt.ToLocalTime().ToString('dd/MM/yyyy HH:mm')}else{''}}else{Get-DomeniaIndexPartialText}
    $families=@('Presence','Console','Inventory')+@(Get-DomeniaBoardProbeIds|ForEach-Object{'Probe:'+$_})
    # Clocks of the explicit OU collections: the exact scope and its enclosing subtrees, read in the same snapshot.
    # A scope whose keys cannot be built sends none ($null): its clocks stay unknown, never "aucun relevé".
    $runKeys=$null
    try { $runKeys=@(Get-DomeniaCollectionRunKeys -ScopeDn ([string]$scope.Dn) -DomainDn ([string]$script:Conn.BaseDn) -Subtree ([bool]$scope.Subtree)) } catch { $runKeys=$null }
    # No key (scope outside the connection domain, no base DN) is not "requested and none recorded".
    if (($null -ne $runKeys) -and ($runKeys.Count -eq 0)) { $runKeys=$null }
    $job = $null
    try {
        [void](Initialize-DomeniaWinSqliteNative)
        $job = Start-UiTask -Name 'Vue d ensemble du parc' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload ([pscustomobject]@{ Action='FleetStats'; ObservationFamilies=$families; RunKeys=$runKeys; DomainDn=[string]$script:Conn.BaseDn; Path=$path; Scope=[string]$scope.Dn; Subtree=[bool]$scope.Subtree; Plan=$plan; Keys=$keys; ScopeKey=[string]$scope.Key; ComputeBoard=$true; ModuleRoot=$script:DashboardModuleRoot; Lifecycle=(Get-DomeniaWindowsLifecycleTable); ObservationMaxAgeDays=(Get-DomeniaObservationMaxAgeDays); IndexPartial=$partialText; HealthPolicy=$policy;HealthPolicyBook=$policyBook }) -CallbackState $state -ReplaceKey 'fleet:stats' -SuccessHandler 'Complete-DomeniaFleetDashboard' -ErrorHandler 'Fail-DomeniaFleetDashboard' -TimeoutSeconds 120 -TaskClass $(if ($Quiet) { 'Background' } else { 'Explicit' })
    } catch {
        $script:FleetPendingKey = ''; $script:FleetJobId = ''
        [void](Set-DomeniaControlText 'LblFleetDashboard' ('Vue dʼensemble non calculée : ' + $_.Exception.Message))
        Set-DomeniaFleetDashboardToolTip
        if (-not $Quiet) { throw }
        return
    }
    if (-not $job) {
        $script:FleetPendingKey = ''; $script:FleetJobId = ''
        [void](Set-DomeniaControlText 'LblFleetDashboard' 'Vue dʼensemble non calculée : calcul non admis pour lʼinstant, réessayez avec lʼicône dʼactualisation.')
        Set-DomeniaFleetDashboardToolTip
        return
    }
    # Computed only once drawn (Complete): a cancelled or refused calculation is tried again at the next display.
    $script:FleetPendingKey = [string]$scope.Key; $script:FleetJobId = [string]$job; $script:FleetStale = $false
    [void](Set-DomeniaControlText 'LblFleetDashboard' ('Calcul de la vue dʼensemble depuis la base locale : ' + [string]$scope.Name + '...'))
    Set-DomeniaFleetDashboardToolTip
}
function Fail-DomeniaFleetDashboard {
    param($Message,$State)
    if ($null -ne $State -and [long]$State.Epoch -ne [long]$script:SessionEpoch) { return }
    # A replaced calculation (other OU) does not overwrite the text of the current one.
    if ($null -ne $State -and [string]$State.Key -cne [string]$script:FleetPendingKey) { return }
    # The next display of Accueil tries again.
    $script:FleetPendingKey = ''; $script:FleetJobId = ''; $script:FleetComputedKey = ''
    [void](Set-DomeniaControlText 'LblFleetDashboard' ('Vue dʼensemble non calculée : ' + [string]$Message))
    Set-DomeniaFleetDashboardToolTip
}
function Set-DomeniaFleetDashboardToolTip {
    # The catalogued help of LblFleetDashboard (Domenia-UX.help.json) stays the base of its tool tip; the provenance
    # of the OU collections of the drawn view is appended, never substituted. Without provenance (calculation started,
    # refused or failed) the base help comes back, so no clock of a previous OU stays attached to the label.
    param([AllowEmptyString()][string]$Provenance='')
    $label=Get-DomeniaControl 'LblFleetDashboard'
    if($null -eq $label){return}
    $base=''
    if(($null -ne $script:UxHelpCatalogue) -and ($script:UxHelpCatalogue.ContainsKey('LblFleetDashboard'))){$base=[string]$script:UxHelpCatalogue['LblFleetDashboard'].Text}
    $detail=if($Provenance){'Provenance des relevés de lʼOU (base locale) :'+"`r`n"+$Provenance}else{''}
    $parts=@(@($base,$detail)|Where-Object{$_})
    # No catalogue entry and no provenance: no help was ever attached, so the stale provenance is cleared.
    $label.ToolTip=$(if($parts.Count){$parts -join "`r`n`r`n"}else{$null})
}
function Update-DomeniaFleetScopeText {
    # The committed AD coverage has its own clock. LastSyncUtc is retained for callers but never used as a global fallback.
    param($Scope,[int]$Count = -1,[string]$LastSyncUtc = '',$Freshness=$null,[datetime]$NowUtc=[datetime]::UtcNow)
    if ($null -eq $Scope) { return }
    $parts = New-Object System.Collections.ArrayList
    if (-not [string]$Scope.Dn) { [void]$parts.Add('Tout le domaine indexé (consultation)') }
    elseif (-not [bool]$Scope.Subtree) { [void]$parts.Add('sans les sous-OU') }
    else { [void]$parts.Add('et ses sous-OU') }
    if ($Count -ge 0) { [void]$parts.Add([string]$Count + ' poste' + $(if ($Count -gt 1) { 's' } else { '' }) + ' recensé(s) dans la base') }
    $indexFreshness=if($null -ne $Freshness){Get-DomeniaMemberValue $Freshness 'Index'}else{Get-DomeniaFleetFreshness -ScopeDn ([string]$Scope.Dn) -DomainDn ([string]$script:Conn.BaseDn) -SyncStates $script:IndexSyncStates -Subtree ([bool]$Scope.Subtree) -NowUtc $NowUtc}
    $summary=Format-DomeniaOuFreshnessSummary -IndexFreshness $indexFreshness -NowUtc $NowUtc -Runs (Get-DomeniaMemberValue $Freshness 'Runs')
    [void]$parts.Add($summary.BaseText)
    $label = Get-DomeniaControl 'LblFleetScope'
    $text = ($parts -join ' · ')
    if ([string]$Scope.Dn) { $text = ' · ' + $text }
    [void](Set-DomeniaControlText 'LblFleetScope' $text)
    if ($null -ne $label) { $label.ToolTip = ('Périmètre : '+[string]$Scope.Path+"`r`n"+'Dernière lecture complète : '+$(if($indexFreshness.SourceDn){$indexFreshness.SourceDn}else{'non disponible'})) + "`r`n" + ('Ce nombre inclut les postes actifs et désactivés de la base locale. La date correspond à la dernière synchronisation réussie couvrant ce périmètre ; une lecture partielle ne la remplace pas. Rechercher peut relire lʼannuaire en direct.') }
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
        $link.ToolTip = 'Choisir cette OU dans le tableau de bord : ' + [string]$segments[$i].Dn
        $link.Add_Click({ param($s,$e) try { Select-DomeniaFleetScopeOu -Dn ([string]$s.Tag) } catch { Write-DomeniaSwallowed 'Dashboard' 'Update-DomeniaFleetScopeText' $_ } })
        [void]$block.Inlines.Add($link)
        [void]$crumbs.Children.Add($block)
    }
}
function Show-DomeniaFleetScopeSource {
    # Point 54: the shared OU picker (same tree, search, favourites, depth and confirmation as the other pages).
    # The tableau de bord and the Atelier read the local base of this OU; Rechercher keeps its own OU.
    $current = Get-DomeniaFleetScope
    $initial = ''; $subtree = $true
    if ($null -ne $current) { $initial = [string]$current.Dn; $subtree = [bool]$current.Subtree }
    $picked = Show-DomeniaInlinePicker -Kind OU -Title 'Périmètre du tableau de bord' -Prompt 'Choisissez une OU dans le domaine courant. Le tableau de bord et lʼatelier liront sa base locale ; la recherche et ses filtres restent indépendants.' -DepthMode Choice -Subtree $subtree -Purpose 'Effet : le tableau de bord et lʼatelier recalculent depuis la base locale, sans collecte ; les actualisations AD, ping et WMI couvrent toujours les sous-OU.' -InitialDn $initial
    if ($null -eq $picked -or -not [string]$picked.DN) { return }
    $dn = ([string]$picked.DN).Trim()
    $base = [string]$script:Conn.BaseDn
    if (-not $dn.EndsWith(',' + $base,[StringComparison]::OrdinalIgnoreCase)) { Set-Status 'Cette OU nʼappartient pas au domaine courant.' 'WARN'; return }
    $script:FleetScopeDn = $dn
    $script:FleetScopeSubtree = [bool](Get-DomeniaMember $picked 'Subtree' $true)
    $script:FleetStale = $true
    Request-DomeniaFleetRefresh
    Set-Status ('Périmètre du tableau de bord : ' + $dn + $(if ($script:FleetScopeSubtree) { ' et ses sous-OU' } else { ', sans ses sous-OU' }) + '. Recherche reste inchangée.')
}
function Select-DomeniaFleetScopeOu {
    # Breadcrumb navigation stays inside the autonomous dashboard scope, with the depth already chosen.
    param([string]$Dn)
    $script:FleetScopeDn = ([string]$Dn).Trim()
    $script:FleetStale = $true
    Request-DomeniaFleetRefresh
}
function Show-DomeniaFleetAnalyzeSource {
    # "Ouvrir dans Rechercher": all workstations, including disabled accounts, of the OU shown on Accueil become the
    # Rechercher list, from the local base rows (no request); Pinger, Détecter or Analyser la liste start from it at the
    # operator's click. The whole domain is never listed this way: Rechercher opens on its OU tree.
    $scope = $null
    try { $scope = Get-DomeniaFleetScope } catch { $scope = $null }
    $last = $script:FleetLast
    # A running read or an earlier session cannot seed a new actionable list.
    if([bool]$script:FleetStale -or [string]$script:FleetJobId -or ($null -ne $last -and $null -ne $last.PSObject.Properties['Epoch'] -and [long]$last.Epoch -ne [long]$script:SessionEpoch)){
        Request-DomeniaFleetRefresh -Force
        Set-Status 'Actualisation du parc en cours. Attendez son résultat avant dʼouvrir les postes dans Rechercher.' 'WARN'
        return
    }
    $targets = @()
    if (($null -ne $scope) -and [string]$scope.Dn -and ($null -ne $last) -and ([string]$last.Scope -ieq [string]$scope.Dn) -and ([bool]$last.Subtree -eq [bool]$scope.Subtree)) { $targets = @($last.Machines | Where-Object { $null -ne $_ }) }
    if (($null -ne $scope) -and [string]$scope.Dn -and ($null -ne $last) -and ([string]$last.Scope -ieq [string]$scope.Dn) -and ([bool]$last.Subtree -eq [bool]$scope.Subtree)) {
        $savedSuppression=$script:SuppressBranchAutoLoad;$script:SuppressBranchAutoLoad=$true
        try {
            $script:SelectedBranchDn=[string]$scope.Dn;$script:SearchMode='OU';$script:ActiveSearchViewId='';$script:ListSurveyBlocked=$false
            $check=Get-DomeniaControl 'ChkSubtree';if($null -ne $check){$check.IsChecked=[bool]$scope.Subtree}
            $term=Get-DomeniaControl 'TxtBranchSearch';if($null -ne $term){$term.Text=''}
            if($null -ne (Get-Command Update-DomeniaSearchScopeUi -ErrorAction SilentlyContinue)){Update-DomeniaSearchScopeUi}
        } finally {$script:SuppressBranchAutoLoad=$savedSuppression}
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
    param($Stored,$Current,[string[]]$RetainKeys=$null)
    if ($null -eq $Stored) { $Stored = @{} }
    $allowed=$null
    if($PSBoundParameters.ContainsKey('RetainKeys')){
        $allowed=@{};foreach($key in $RetainKeys){if($key){$allowed[$key.ToLowerInvariant()]=$true}}
        foreach($key in @($Stored.Keys)){if(-not $allowed.ContainsKey($key)){[void]$Stored.Remove($key)}}
    }
    if ($null -eq $Current) { return $Stored }
    foreach ($key in @($Current.Keys)) {
        if($null -ne $allowed -and -not $allowed.ContainsKey($key)){continue}
        $mine = $Current[$key]
        if ($null -eq $mine) { continue }
        $known = $Stored[$key]
        if ($null -eq $known -or [string]::CompareOrdinal([string]$mine.CheckedUtc,[string]$known.CheckedUtc) -gt 0) { $Stored[$key] = $mine }
    }
    return $Stored
}
function Request-DomeniaSelectedObservation {
    param([switch]$Force,[long]$MinimumRevision=0)
    # FI-04, workstation side: the overview loads the observations of its OU only. A selected workstation that lies
    # elsewhere gets its own from the local base: the row of its DN, GUID-checked against the index and recent enough,
    # read once per workstation and session in the background (no network, nothing sent to the workstation).
    $selected = $script:SelectedObject
    if (($null -eq $selected) -or ([string]$selected.Type -ne 'Machine')) { return $false }
    $dn = ([string]$selected.DN).Trim()
    if (-not $dn) { return $false }
    $key = $dn.ToLowerInvariant()
    $guid=[string](Get-DomeniaMember $selected 'Guid' '')
    if(-not (Test-DomeniaGuidText $guid)){return $false}
    $path = [string]$script:DatabaseScopedPath
    if (-not $path) { return $false }
    if ($null -eq $script:FleetSelectedReads) { $script:FleetSelectedReads = @{} }
    $requestedRevision=[Math]::Max($MinimumRevision,[long]$script:StoreSnapshotRevision)
    $marker = [string]$script:SessionEpoch + '|' + $path + '|' + $guid.ToLowerInvariant() + '|' + [string]$script:SelectedObjectGeneration + '|' + [string]$requestedRevision
    if($Force){$script:FleetSelectedReads.Clear()}
    if ($script:FleetSelectedReads.ContainsKey($marker)) { return $false }
    $script:FleetSelectedReads.Clear()
    $script:FleetSelectedReads[$marker] = $true
    $state = [pscustomobject]@{ Epoch = [long]$script:SessionEpoch; Key = $key; Guid=$guid; Path=$path; Marker=$marker; Generation=[long]$script:SelectedObjectGeneration; RequestedRevision=$requestedRevision; Context=$null }
    $job = $null
    try {
        $state.Context=New-DomeniaStoreContext -RequestId ('selected-observation-'+[guid]::NewGuid().ToString('N')) -Generation $state.Generation
        $job = Request-DomeniaStoreRead -Context $state.Context -Query @{Kind='Observation';Guids=@($guid);Limit=1} -CallbackState $state -SuccessHandler 'Complete-DomeniaSelectedObservation' -ErrorHandler 'Fail-DomeniaSelectedObservation'
    } catch { $job = $null }
    # Not started (engine busy or closing): tried again at the next display of the board.
    if (-not $job) { [void]$script:FleetSelectedReads.Remove($marker) }
    return [bool]$job
}
function Complete-DomeniaSelectedObservation {
    param($Result,$State)
    if ($null -eq $State -or $null -eq $script:SelectedObject -or [long]$State.Epoch -ne [long]$script:SessionEpoch -or [string]$State.Path -cne [string]$script:DatabaseScopedPath -or [long]$State.Generation -ne [long]$script:SelectedObjectGeneration -or [string]$State.Guid -ine [string]$script:SelectedObject.Guid -or [string]$State.Key -ine [string]$script:SelectedObject.DN) { return }
    $data = Get-DomeniaEffectiveWorkerResult $Result @('ObservationRows','DataSource')
    if ($null -eq $data -or [bool]$data.Busy -or [bool]$data.Missing -or [string]$data.DataSource -cne 'SQLite' -or [string]$data.StoreId -cne [string]$State.Context.StoreId -or [string]$data.Path -cne [string]$State.Path) { Fail-DomeniaSelectedObservation 'lecture non confirmee' $State; return }
    $revision=[long](Get-DomeniaMember $data 'SnapshotRevision' 0)
    $minimum=[Math]::Max([long](Get-DomeniaMember $State 'RequestedRevision' 0),[long]$script:StoreSnapshotRevision)
    if($revision -lt $minimum){Fail-DomeniaSelectedObservation 'Instantané remplacé par une écriture plus récente.' $State;[void](Request-DomeniaSelectedObservation -Force -MinimumRevision $minimum);return}
    $found = @{};$hasCanonicalRow=$false
    foreach ($item in @($data.ObservationRows)) {
        if ($null -eq $item -or [string]$item.Guid -ine [string]$State.Guid) { continue }
        $hasCanonicalRow=$true
        $known=$null;if($null -ne $script:FleetObservations){$known=$script:FleetObservations[[string]$State.Key]}
        if($null -ne $known -and [string]$known.Guid -ieq [string]$item.Guid -and [long]$known.Revision -gt [long]$item.Revision){continue}
        $found[[string]$State.Key] = $item
    }
    if (-not $found.Count) {
        if($hasCanonicalRow){return}
        # A canonical absence is authoritative too; never keep a deleted or expired row from another snapshot.
        if($null -ne $script:FleetObservations -and $script:FleetObservations.ContainsKey([string]$State.Key)){
            $previous=$script:FleetObservations[[string]$State.Key]
            if([string]$previous.Guid -ieq [string]$State.Guid -and [long]$previous.Revision -le $revision){[void]$script:FleetObservations.Remove([string]$State.Key);try{Show-DomeniaBoard -Board Computer -Quiet -DeferIfHidden}catch{Write-DomeniaSwallowed 'Dashboard' 'Complete-DomeniaSelectedObservation' $_}}
        }
        return
    }
    if($null -eq $script:FleetObservations){$script:FleetObservations=@{}}
    # Replace the selected entries with their committed database projection. A raw in-memory timestamp
    # must never override the database value, including a newer failure retaining an older success.
    foreach($key in $found.Keys){$script:FleetObservations[$key]=$found[$key]}
    # The board of the selected workstation shows them at once while it is still that workstation.
    if (($null -ne $script:SelectedObject) -and $found.ContainsKey(([string]$script:SelectedObject.DN).ToLowerInvariant())) { try { Show-DomeniaBoard -Board Computer -Quiet -DeferIfHidden } catch { Write-DomeniaSwallowed 'Dashboard' 'Complete-DomeniaSelectedObservation' $_ } }
}
function Fail-DomeniaSelectedObservation {
    param($Message,$State)
    if (($null -eq $State) -or ([long]$State.Epoch -ne [long]$script:SessionEpoch) -or ($null -eq $script:FleetSelectedReads)) { return }
    # A locked or unreadable base is tried again at the next display of the board.
    [void]$script:FleetSelectedReads.Remove([string]$State.Marker)
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
    if ($null -ne $State -and ([long]$State.Epoch -ne [long]$script:SessionEpoch -or [string]$State.Path -cne [string]$script:DatabaseScopedPath)) { return }
    $panel = Get-DomeniaControl 'PnlFleetDashboard'
    if ($null -eq $panel) { return }
    # A calculation replaced by a newer one (other OU) is not shown.
    if ($null -ne $State -and [string]$State.Key -cne [string]$script:FleetPendingKey) { return }
    $data = Get-DomeniaEffectiveWorkerResult $Result @('Types','Machines')
    if ($null -eq $data) { Fail-DomeniaFleetDashboard 'reponse incomplete.' $State; return }
    if ([bool]$data.Busy) { Fail-DomeniaFleetDashboard 'base occupee, reessayez dans un instant.' $State; return }
    # A commit or observation changed the base while this read was running. Do not briefly repaint old dates/counts.
    if([bool]$script:FleetStale){
        $script:FleetPendingKey='';$script:FleetJobId='';$script:FleetComputedKey=''
        try { Request-DomeniaFleetRefresh } catch { Write-DomeniaSwallowed 'Dashboard' 'Complete-DomeniaFleetDashboard' $_ }
        return
    }
    $script:FleetLastResult = $Result
    $scope = if ($null -ne $State) { [pscustomobject]@{ Dn = [string]$State.Scope; Subtree = [bool]$State.Subtree; Name = [string]$State.Name; Path = [string]$State.ScopePath; Key = [string]$State.Key } } else { Get-DomeniaFleetScope }
    if ($null -eq $scope) { $scope = [pscustomobject]@{ Dn = ''; Subtree = $true; Name = 'Tout le domaine'; Path = ''; Key = '*' } }
    try {
        $board=Get-DomeniaMemberValue $data 'Board'
        if($null -eq $board){throw 'Les indicateurs du parc nʼont pas été calculés. Actualisez la vue.'}
    }
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
    $count = @($board.Last.Machines).Count
    Update-DomeniaFleetScopeText $scope -Count $count -Freshness (Get-DomeniaMemberValue $board 'Freshness')
    # Observations (presence, console user, light WMI, queries) feed the query widgets of both boards.
    # This is a complete SQLite snapshot for the scope. Never combine it with collector memory.
    $script:FleetObservations = if($null -ne $board.Observations){$board.Observations}else{@{}}
    if($null -ne $script:SelectedObject -and [string]$script:SelectedObject.Type -eq 'Machine'){
        $selectedKey=([string]$script:SelectedObject.DN).ToLowerInvariant()
        if($selectedKey -and -not $script:FleetObservations.ContainsKey($selectedKey)){
            [void](Request-DomeniaSelectedObservation -Force -MinimumRevision ([long](Get-DomeniaMember $data 'SnapshotRevision' 0)))
        }
    }
    $script:FleetLast = $board.Last
    $script:FleetQuerySnapshotKey = [guid]::NewGuid().ToString('N')
    try { Update-DomeniaFleetMachineList } catch { Write-AppLog ('Liste locale du parc indisponible : ' + $_.Exception.Message) 'WARN' }
    Add-Member -InputObject $script:FleetLast -MemberType NoteProperty -Name 'Epoch' -Value ([long]$script:SessionEpoch) -Force
    # New data never removes the undo of a layout change (FI-11): Show-DomeniaBoard keeps the undo stack.
    Show-DomeniaBoard -Board Fleet -Data $board -DeferIfHidden
    # A query run on the selected workstation refreshes its widgets even without an inventory.
    if ($null -ne $script:SelectedObject -or $null -ne $script:LastComputerDashboardResult) { try { Show-DomeniaBoard -Board Computer -Quiet -DeferIfHidden } catch { Write-DomeniaSwallowed 'Dashboard' 'Complete-DomeniaFleetDashboard' $_ } }
    $freshness=Get-DomeniaMemberValue $board 'Freshness'
    $summary=Format-DomeniaOuFreshnessSummary -IndexFreshness (Get-DomeniaMemberValue $freshness 'Index') -Observations (Get-DomeniaMemberValue $freshness 'Observations') -ComputedAtUtc (Get-DomeniaMemberValue $freshness 'ComputedAtUtc') -Runs (Get-DomeniaMemberValue $freshness 'Runs')
    # Three committed clocks: measures of the active workstations, the OU collections (last success and, when newer,
    # the failed attempt with its error), then the local calculation, which never dates the data.
    $lines=@($summary.ObservationsText,$summary.RunsText,$summary.ComputedText|Where-Object{$_})
    [void](Set-DomeniaControlText 'LblFleetDashboard' ($lines -join "`n"))
    Set-DomeniaFleetDashboardToolTip -Provenance ([string]$summary.RunsDetail)
    [void](Save-DomeniaFleetSnapshot -Scope $scope -Board $board)
    # Point 148: the dashboard is discovered once an overview with workstations was computed while Accueil itself is
    # shown. The workshop (Outils, Atelier) also reads this overview, but it is not the dashboard the step points to.
    try {
        $workspaces = Get-DomeniaControl 'WorkspaceTabs'
        $homeShown = (($null -ne $workspaces) -and ($null -ne $workspaces.SelectedItem) -and ([string]$workspaces.SelectedItem.Name -eq 'TabDashboard'))
        if (($count -gt 0) -and $homeShown -and (-not [bool][string](Get-DomeniaSetting -Name 'Home.DashboardSeen' -Default ''))) {
            Set-DomeniaSetting -Name 'Home.DashboardSeen' -Value ([datetime]::UtcNow.ToString('o'))
        }
    } catch { Write-AppLog ('Premiers pas : préférence non enregistrée. ' + $_.Exception.Message) 'WARN' }
    try { Update-DomeniaFirstSteps } catch { Write-DomeniaSwallowed 'Dashboard' 'Complete-DomeniaFleetDashboard' $_ }
    # Data changed while computing (analysis or base saved meanwhile): computed again while Accueil is shown.
    if ([bool]$script:FleetStale) { try { Request-DomeniaFleetRefresh } catch { Write-DomeniaSwallowed 'Dashboard' 'Complete-DomeniaFleetDashboard' $_ } }
}
function Get-DomeniaAttentionTargets {
    # Workstations of a point of the Fleet board, from the rows already in memory (no request).
    param($Item)
    $machines = @()
    if (($null -ne $script:FleetLast) -and ($null -ne $script:FleetLast.PSObject.Properties['Machines'])) { $machines = @($script:FleetLast.Machines) }
    return @(Get-DomeniaFleetPointTargets -Machines $machines -Point $Item -Max ([int]::MaxValue))
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
        [pscustomobject]@{ Type = 'Machine'; Name = [string]$target.name; Login = [string]$target.name; UPN = ''; Mail = ''; Description = ''; Changed = ''; State = $(if([string]$target.st -eq 'D'){'Désactivé'}else{'Actif'}); DN = [string]$target.distinguished_name; Guid = [string]$target.object_guid }
    })
    Invalidate-DomeniaSearchResults
    # A deliberate transfer must not inherit a hidden text, presence or query filter.
    $script:CurrentPresenceFilter='Tous'
    $presence=Get-DomeniaControl 'CmbPresenceFilter';if($null -ne $presence){$presence.SelectedIndex=0}
    $filter=Get-DomeniaControl 'TxtSuiteResultFilter';if($null -ne $filter){$filter.Text=''}
    if($null -ne $script:DomeniaQueryState){$script:DomeniaQueryState.SearchRecipe=$null;$script:DomeniaQueryState.SearchRefinement=$null;$script:DomeniaQueryState.SearchRecords=@{}}
    [void](Set-DomeniaControlText 'LblSearchQuery' 'Aucune requête enregistrée appliquée aux résultats.')
    # Point 2: the list is the population of the Accueil figures; the local revision that produced them is named.
    $population = Get-DomeniaMemberValue $script:FleetLast 'Population'
    $revision = [long](Get-DomeniaMember $population 'SnapshotRevision' -1)
    $text = [string]$rows.Count + ' poste(s) de lʼaccueil' + $(if ($Label) { ' : ' + $Label } else { '' }) + ' (base locale' + $(if ($revision -ge 0) { ', révision ' + [string]$revision } else { '' }) + ', sans requête)'
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
        if ([string]$r.ErrorKind -in @('AccessDenied','LogonFailure','CredentialsRejected')) { try { [void](Request-DomeniaAccessRecovery -Operation 'Présence des clés BitLocker de lʼOU' -ErrorValue ([string]$r.ErrorMessage) -OperationId 'BitLockerPresence' -DN ([string]$State.Dn)) } catch { Write-DomeniaSwallowed 'Dashboard' 'Complete-DomeniaFleetBitLockerPresence' $_ } }
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
    # Point 148: the four first steps (connection, working OU, first read, dashboard) from what the session already
    # knows, through the pure rule Get-DomeniaFirstRunPlan: no request, no scan.
    $domain = ''; $account = ''; $connected = $false
    try { $connected = [bool]$script:Conn.Connected; $domain = [string]$script:Conn.Domain; $account = [string]$script:Conn.BindUser } catch { $connected = $false }
    if (-not $connected) { $domain = '' }
    $scopeDn = ''; $scopeName = ''
    try { $scope = Get-DomeniaFleetScope; if ($null -ne $scope) { $scopeDn = [string]$scope.Dn; $scopeName = [string]$scope.Name } } catch { $scopeDn = '' }
    $indexed = 0L
    try { $indexed = [long]$script:IndexDbCount } catch { $indexed = 0L }
    $seen = $false
    try { $seen = [bool][string](Get-DomeniaSetting -Name 'Home.DashboardSeen' -Default '') } catch { $seen = $false }
    return Get-DomeniaFirstRunPlan -Domain $domain -Account $account -ScopeDn $scopeDn -ScopeName $scopeName -IndexedObjects $indexed -DashboardSeen $seen
}
function Update-DomeniaFirstSteps {
    # Card shown until the four steps are done once, then hidden for good (local preference). The account used on the
    # workstations and the backups are not steps: the card says where they are set when they are needed.
    $card = Get-DomeniaControl 'CardFirstSteps'
    if ($null -eq $card) { return }
    if ([bool](Get-DomeniaSetting -Name 'Home.FirstStepsDone' -Default $false)) { $card.Visibility = [System.Windows.Visibility]::Collapsed; return }
    $plan = Get-DomeniaFirstStepsState
    if ([bool]$plan.Done) {
        Set-DomeniaSetting -Name 'Home.FirstStepsDone' -Value $true
        $card.Visibility = [System.Windows.Visibility]::Collapsed
        return
    }
    $card.Visibility = [System.Windows.Visibility]::Visible
    foreach ($step in @($plan.Steps)) {
        $name = [string]$step.Name
        $mark = Get-DomeniaControl ('LblFirstStep' + $name + 'Mark')
        if ($null -ne $mark) { $mark.Text = $(if ([bool]$step.Done) { [string][char]0x2713 } else { [string]$step.Number }) }
        $label = Get-DomeniaControl ('LblFirstStep' + $name)
        if ($null -ne $label) {
            $label.Text = [string]$step.Text
            $label.Opacity = $(if ([bool]$step.Done) { 0.6 } else { 1.0 })
            $label.FontWeight = $(if ($name -ceq [string]$plan.Next) { [System.Windows.FontWeights]::SemiBold } else { [System.Windows.FontWeights]::Normal })
        }
        $button = Get-DomeniaControl ('BtnFirstStep' + $name)
        if ($null -ne $button) { $button.IsEnabled = [bool]$step.Enabled }
    }
    [void](Set-DomeniaControlText 'LblFirstStepsDeferred' ([string]$plan.Deferred))
}
function Open-DomeniaFirstStep {
    # Each step opens the screen concerned and starts nothing (decision David 2026-10-08, UX-20).
    param([ValidateSet('Connection','Ou','Base','Dashboard')][string]$Step)
    switch ($Step) {
        'Connection' { Invoke-DomeniaUxRoute -Route 'TabAccounts'; Set-Status 'Comptes et accès : compte utilisé pour lʼannuaire ; changer de compte reste possible à tout moment.' }
        'Ou' { Show-DomeniaFleetScopeSource }
        'Base' { Select-DomeniaWorkspace -Workspace 'TabApplicationTools' -Inner 'ApplicationToolTabs' -Tab 'TabIndex'; $tabs=Get-DomeniaControl 'IndexWorkspaceTabs'; if($null -ne $tabs){$tabs.SelectedItem=Get-DomeniaControl 'TabIndexUpdate'}; Set-Status 'Choisissez une OU, puis mettez-la à jour. La lecture couvre cette OU et ses sous-OU.' }
        'Dashboard' {
            Invoke-DomeniaUxRoute -Route 'TabDashboard'
            $summary = Get-DomeniaControl 'LblFleetDashboard'
            if ($null -ne $summary) { try { $summary.BringIntoView() } catch { Write-DomeniaSwallowed 'Premiers pas' 'Open-DomeniaFirstStep' $_ } }
            Set-Status 'Tableau de bord : vue dʼensemble de lʼOU, calculée depuis la base locale à lʼaffichage de lʼaccueil. Une tuile ouvre la liste exacte de ses postes.'
        }
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
    # Link of a point of attention: opens the view of the useful action (Redémarrer and Ouvrir le disque C in
    # Intervenir, the keys and LAPS in Secrets) and runs nothing (decision David 2026-10-08, UX-10).
    param([Parameter(Mandatory=$true)][string]$Route)
    $target = Get-DomeniaBoardRouteTarget -Route $Route
    if ($null -eq $target) { Invoke-DomeniaUxRoute -Route $Route; return }
    Select-DomeniaWorkspace -Workspace $target.Workspace -Inner $target.Inner -Tab $target.Tab
    $inner = Get-DomeniaControl $target.Inner
    $opened = $false
    try { $opened = (($null -ne $inner) -and ($null -ne $inner.SelectedItem) -and ([string]$inner.SelectedItem.Name -eq [string]$target.Tab)) } catch { $opened = $false }
    if (-not $opened) { Set-Status 'Sélectionnez dʼabord le poste dans Rechercher : la vue sʼouvrira sur sa fiche.' 'WARN' }
}
function Update-DomeniaComputerDashboard {
    param($Result)
    $script:LastComputerDashboardResult = $Result
    $board = Get-DomeniaComputerBoardData -Result $Result -Object $script:SelectedObject -Lifecycle (Get-DomeniaWindowsLifecycleTable) -HealthPolicy (Get-DomeniaStoredHealthPolicy -ScopeDn ([string]$script:SelectedObject.DN))
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
# ---------------------------------------------------------------- MO-04 domain totals from the local copy
$script:DomainTotalsState = $null
function Start-DomeniaDomainLocalTotals {
    # MO-04: the Domaine tab shows the totals of the local copy with its date, never a count of the whole directory.
    # Read-only LocalIndexRead (FleetStats) in the background, on the explicit gesture « Analyser le domaine ». Only the
    # type totals and the directory synchronisation date are used: the workstation part of the answer is limited to
    # the objects placed directly under the domain root (one level), so that nothing else is aggregated for nothing.
    $path = [string]$script:DatabaseScopedPath
    $domainDn = ''
    if ($null -ne $script:Conn) { $domainDn = [string]$script:Conn.BaseDn }
    if ((-not $path) -or (-not $domainDn)) {
        $script:DomainTotalsState = $null
        [void](Set-DomeniaControlText 'LblDomainLocalTotals' 'Totaux du domaine : aucune base autonome active ; aucun dénombrement nʼest lancé sur lʼannuaire.')
        return
    }
    $state = [pscustomobject]@{ Epoch = [long]$script:SessionEpoch; DomainDn = $domainDn; Path = $path; Job = '' }
    $script:DomainTotalsState = $state
    $job = $null
    try {
        [void](Initialize-DomeniaWinSqliteNative)
        $payload = [pscustomobject]@{ Action = 'FleetStats'; Path = $path; BusyTimeoutMs = 250; DomainDn = $domainDn; Scope = $domainDn; Subtree = $false; Plan = (Get-DomeniaFleetQueryPlan -ObservationMaxAgeDays (Get-DomeniaObservationMaxAgeDays)); Keys = @(); ScopeKey = ''; ComputeBoard = $false; ModuleRoot = $script:DashboardModuleRoot }
        $job = Start-UiTask -Name 'Totaux de la copie locale' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload $payload -CallbackState $state -ReplaceKey 'domain:totals' -SuccessHandler 'Complete-DomeniaDomainLocalTotals' -ErrorHandler 'Fail-DomeniaDomainLocalTotals' -TimeoutSeconds 60 -TaskClass Explicit
    } catch { Fail-DomeniaDomainLocalTotals -Message $_.Exception.Message -State $state; return }
    if (-not $job) { Fail-DomeniaDomainLocalTotals -Message 'lecture locale non admise pour lʼinstant, relancez lʼanalyse.' -State $state; return }
    $state.Job = [string]$job
    [void](Set-DomeniaControlText 'LblDomainLocalTotals' 'Totaux du domaine : lecture de la copie locale…')
}
function Test-DomeniaDomainLocalTotalsCurrent {
    param($State)
    return (($null -ne $State) -and [object]::ReferenceEquals($State,$script:DomainTotalsState) -and ([long]$State.Epoch -eq [long]$script:SessionEpoch))
}
function Complete-DomeniaDomainLocalTotals {
    param($Result,$State)
    if (-not (Test-DomeniaDomainLocalTotalsCurrent $State)) { return }
    $data = Get-DomeniaEffectiveWorkerResult $Result @('Busy','Missing')
    if ($null -eq $data) { Fail-DomeniaDomainLocalTotals -Message 'réponse locale incomplète.' -State $State; return }
    if ([bool]$data.Busy) { Fail-DomeniaDomainLocalTotals -Message 'base occupée, relancez lʼanalyse dans un instant.' -State $State; return }
    if ([bool]$data.Missing) { [void](Set-DomeniaControlText 'LblDomainLocalTotals' 'Totaux du domaine : aucune base autonome sur ce poste ; aucun dénombrement nʼest lancé sur lʼannuaire.'); return }
    $last = ''
    $sync = Get-DomeniaMember $data 'SyncStates' $null
    if (($sync -is [Collections.IDictionary]) -and $sync.Contains('directory')) { $last = [string](Get-DomeniaMember $sync['directory'] 'last_sync' '') }
    $summary = Get-DomeniaLocalTotalsSummary -Types @(Get-DomeniaMember $data 'Types' @()) -LastSyncUtc $last
    [void](Set-DomeniaControlText 'LblDomainLocalTotals' ([string]$summary.Text))
}
function Fail-DomeniaDomainLocalTotals {
    param([string]$Message,$State)
    if (-not (Test-DomeniaDomainLocalTotalsCurrent $State)) { return }
    [void](Set-DomeniaControlText 'LblDomainLocalTotals' ('Totaux de la copie locale non lus : ' + $Message))
}
