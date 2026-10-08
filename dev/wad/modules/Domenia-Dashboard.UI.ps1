# Workstation, fleet and software dashboards (decision David 2026-10-07). Each board is a set of widgets drawn by
# Domenia-Widgets.UI.ps1 from the data of its provider (Domenia-Board*.ps1); this module feeds them and keeps the
# fleet scope and analyses. Only data already read: no extra request to the workstation.
function Clear-DomeniaDashboards {
    # Another object is selected: the workstation and software boards forget the previous data.
    $script:LastComputerDashboardResult = $null
    foreach ($board in @('Computer','Software')) { $state = Get-DomeniaBoardState $board; $state.Data = $null; $state.UndoLayout = $null; $state.UndoText = '' }
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
    # The same OU is still being computed: its end decides (data changed meanwhile is computed again then).
    $job = [string]$script:FleetJobId
    if ($job -and [string]$script:FleetPendingKey -ceq [string]$scope.Key -and $null -ne $script:AsyncJobs -and $script:AsyncJobs.Contains($job)) { return }
    if (-not [bool]$script:FleetStale -and [string]$script:FleetComputedKey -ceq [string]$scope.Key) { return }
    Start-DomeniaFleetDashboard -Quiet
}
function Start-DomeniaFleetDashboard {
    # Home dashboard (decision David 2026-10-07): aggregates of the local index, read in the background. The worker
    # filters the OU and parses the cached observations; a new request replaces the one still running. An automatic
    # request (-Quiet) is a background task: it never takes over the global Annuler button.
    param([switch]$Quiet)
    $path = [string]$script:DatabaseScopedPath
    if (-not $path) { if (-not $Quiet) { Set-Status 'Aucune base autonome active : vue d ensemble indisponible.' 'WARN' }; return }
    $scope = Get-DomeniaFleetScope
    if ($null -eq $scope) { if (-not $Quiet) { Set-Status 'Connectez-vous pour calculer la vue d ensemble.' 'WARN' }; return }
    $state = [pscustomobject]@{ Path = $path; Epoch = [long]$script:SessionEpoch; Key = [string]$scope.Key; Scope = [string]$scope.Dn; Subtree = [bool]$scope.Subtree; Name = [string]$scope.Name; ScopePath = [string]$scope.Path }
    $job = $null
    try {
        [void](Initialize-DomeniaWinSqliteNative)
        $job = Start-UiTask -Name 'Vue d ensemble du parc' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload ([pscustomobject]@{ Action='FleetStats'; Path=$path; BusyTimeoutMs=250; Scope=[string]$scope.Dn; Subtree=[bool]$scope.Subtree }) -CallbackState $state -ReplaceKey 'fleet:stats' -SuccessHandler 'Complete-DomeniaFleetDashboard' -ErrorHandler 'Fail-DomeniaFleetDashboard' -TimeoutSeconds 60 -TaskClass $(if ($Quiet) { 'Background' } else { 'Explicit' })
    } catch {
        $script:FleetPendingKey = ''; $script:FleetJobId = ''
        [void](Set-DomeniaControlText 'LblFleetDashboard' ('Vue d ensemble non calculee : ' + $_.Exception.Message))
        if (-not $Quiet) { throw }
        return
    }
    if (-not $job) {
        $script:FleetPendingKey = ''; $script:FleetJobId = ''
        [void](Set-DomeniaControlText 'LblFleetDashboard' 'Vue d ensemble non calculee : calcul non admis pour l instant, reessayez avec Actualiser.')
        return
    }
    # Computed only once drawn (Complete): a cancelled or refused calculation is tried again at the next display.
    $script:FleetPendingKey = [string]$scope.Key; $script:FleetJobId = [string]$job; $script:FleetStale = $false
    [void](Set-DomeniaControlText 'LblFleetDashboard' ('Calcul de la vue d ensemble depuis la base locale : ' + [string]$scope.Name + '...'))
}
function Fail-DomeniaFleetDashboard {
    param($Message,$State)
    if ($null -ne $State -and [long]$State.Epoch -ne [long]$script:SessionEpoch) { return }
    # A replaced calculation (other OU) does not overwrite the text of the current one.
    if ($null -ne $State -and [string]$State.Key -cne [string]$script:FleetPendingKey) { return }
    # The next display of Accueil tries again.
    $script:FleetPendingKey = ''; $script:FleetJobId = ''; $script:FleetComputedKey = ''
    [void](Set-DomeniaControlText 'LblFleetDashboard' ('Vue d ensemble non calculee : ' + [string]$Message))
}
function Update-DomeniaFleetScopeText {
    param($Scope)
    if ($null -eq $Scope) { return }
    $text = if (-not [string]$Scope.Dn) { 'Tout le domaine indexe (consultation)' } elseif ($Scope.Subtree) { [string]$Scope.Name + ' et ses sous-OU' } else { [string]$Scope.Name + ' (sans les sous-OU)' }
    [void](Set-DomeniaControlText 'LblFleetScope' $text)
    $label = Get-DomeniaControl 'LblFleetScope'
    if ($null -ne $label) { $label.ToolTip = [string]$Scope.Path }
}
function Show-DomeniaFleetScopeSource {
    # The OU is chosen in the Rechercher tree, the only OU filter of the application.
    Select-DomeniaWorkspace -Workspace 'WsSearch'
    $tree = Get-DomeniaControl 'TvDirectory'
    if ($null -ne $tree -and $tree.IsEnabled) { [void]$tree.Focus() }
    Set-Status 'Choisissez l OU dans l arbre de Rechercher : la vue d ensemble de l accueil la suit.'
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
    $board = Get-DomeniaFleetBoardData -Result $data -Scope ([string]$scope.Dn) -Subtree ([bool]$scope.Subtree)
    $script:FleetPendingKey = ''; $script:FleetJobId = ''; $script:FleetComputedKey = [string]$scope.Key
    Update-DomeniaFleetScopeText $scope
    # Observations (presence, console user, light WMI, queries) feed the query widgets of both boards.
    $script:FleetObservations = Merge-DomeniaFleetObservations -Stored $board.Observations -Current $script:FleetObservations
    $script:FleetLast = $board.Last
    Add-Member -InputObject $script:FleetLast -MemberType NoteProperty -Name 'Epoch' -Value ([long]$script:SessionEpoch) -Force
    Show-DomeniaBoard -Board Fleet -Data $board
    # A query run on the selected workstation refreshes its widgets even without an inventory.
    if ($null -ne $script:SelectedObject -or $null -ne $script:LastComputerDashboardResult) { try { Show-DomeniaBoard -Board Computer -Quiet } catch { } }
    $count = @($board.Last.Targets).Count
    [void](Set-DomeniaControlText 'LblFleetDashboard' $(if ($board.Summary) { [string]$board.Summary } else { 'Base autonome locale et derniers releves : ' + $count + ' postes actifs dans le perimetre, calcul du ' + (Get-Date -Format 'dd/MM/yyyy HH:mm') + '. Parc incomplet ? Outils, Base autonome, Mettre a jour tout.' }))
    # Data changed while computing (analysis or base saved meanwhile): computed again while Accueil is shown.
    if ([bool]$script:FleetStale) { try { Request-DomeniaFleetRefresh } catch { } }
}
function Update-DomeniaComputerDashboard {
    param($Result)
    $script:LastComputerDashboardResult = $Result
    $board = Get-DomeniaComputerBoardData -Result $Result -Object $script:SelectedObject
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
