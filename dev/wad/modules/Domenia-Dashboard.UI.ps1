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
function Start-DomeniaFleetDashboard {
    # Home dashboard (decision David 2026-10-07): aggregates of the local index, read in the background.
    param([switch]$Quiet)
    $path = [string]$script:DatabaseScopedPath
    if (-not $path) { if (-not $Quiet) { Set-Status 'Aucune base autonome active : vue d ensemble indisponible.' 'WARN' }; return }
    [void](Initialize-DomeniaWinSqliteNative)
    $job = Start-UiTask -Name 'Vue d ensemble du parc' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload ([pscustomobject]@{ Action='FleetStats'; Path=$path; BusyTimeoutMs=250 }) -CallbackState ([pscustomobject]@{ Path=$path; Epoch=[long]$script:SessionEpoch }) -SuccessHandler 'Complete-DomeniaFleetDashboard' -ErrorHandler 'Fail-DomeniaFleetDashboard' -TimeoutSeconds 60 -TaskClass 'Explicit'
    if ($job) { [void](Set-DomeniaControlText 'LblFleetDashboard' 'Calcul de la vue d ensemble depuis la base locale...') }
}
function Fail-DomeniaFleetDashboard {
    param($Message,$State)
    [void](Set-DomeniaControlText 'LblFleetDashboard' ('Vue d ensemble non calculee : ' + [string]$Message))
}
function Get-DomeniaFleetScope {
    return ([string](Get-DomeniaSetting 'FleetScopeDn' '')).Trim()
}
function Select-DomeniaFleetScope {
    # Starting OU of the home dashboard and of its analyses (decision David 2026-10-07), remembered between sessions.
    param([switch]$Reset)
    if ($Reset) { Set-DomeniaSetting 'FleetScopeDn' '' }
    else {
        $picked = Show-DomeniaInlinePicker -Kind OU -Title 'Perimetre du tableau de bord' -Prompt 'Choisissez l OU de depart : les statistiques et les analyses se limitent a ses postes.'
        if ($null -eq $picked -or -not [string]$picked.DN) { return }
        Set-DomeniaSetting 'FleetScopeDn' ([string]$picked.DN)
    }
    try { Save-DomeniaSettings -Immediate } catch { }
    Start-DomeniaFleetDashboard
}
function Start-DomeniaFleetAction {
    # Ping, detection or light WMI analysis of the indexed workstations of the chosen OU; never the whole domain.
    param([ValidateSet('Ping','Detect','Analyze')][string]$Mode)
    try {
        $scope = Get-DomeniaFleetScope
        if (-not $scope -or $scope -ieq [string]$script:Conn.BaseDn) { throw 'choisissez d abord une OU : aucune analyse sur le domaine entier.' }
        if ($null -eq $script:FleetLast -or [string]$script:FleetLast.Scope -cne $scope) { throw 'actualisez d abord la vue d ensemble de cette OU.' }
        $targets = @($script:FleetLast.Targets)
        if (-not $targets.Count) { throw 'aucun poste indexe dans cette OU. Mettez a jour la base autonome.' }
        $label = (($scope -split '(?<!\\),')[0] -replace '^OU=','')
        switch ($Mode) {
            'Ping'    { Start-DomeniaOnlinePark -ScopeTargets $targets -ScopeLabel $label -PingOnly }
            'Detect'  { Start-DomeniaOnlinePark -ScopeTargets $targets -ScopeLabel $label }
            'Analyze' { Start-DomeniaOnlinePark -ScopeTargets $targets -ScopeLabel $label -Inventory }
        }
    } catch { Set-Status ('Analyse impossible : ' + $_.Exception.Message) 'WARN' }
}
function Complete-DomeniaFleetDashboard {
    param($Result,$State)
    if ($null -ne $State -and [long]$State.Epoch -ne [long]$script:SessionEpoch) { return }
    $panel = Get-DomeniaControl 'PnlFleetDashboard'
    if ($null -eq $panel) { return }
    $data = Get-DomeniaEffectiveWorkerResult $Result @('Types','Machines')
    if ($null -eq $data) { Fail-DomeniaFleetDashboard 'reponse incomplete.' $State; return }
    if ([bool]$data.Busy) { Fail-DomeniaFleetDashboard 'base occupee, reessayez dans un instant.' $State; return }
    $script:FleetLastResult = $Result
    $scope = Get-DomeniaFleetScope
    [void](Set-DomeniaControlText 'TxtFleetScope' $(if ($scope) { $scope } else { 'Tout le domaine indexe' }))
    $board = Get-DomeniaFleetBoardData -Result $data -Scope $scope
    # Observations (presence, console user, light WMI, queries) and analysis targets feed the query widgets.
    $script:FleetObservations = $board.Observations
    $script:FleetLast = $board.Last
    # The targets belong to this session: queries refuse them after a new login (epoch) or a change of OU.
    Add-Member -InputObject $script:FleetLast -MemberType NoteProperty -Name 'Epoch' -Value ([long]$script:SessionEpoch) -Force
    Show-DomeniaBoard -Board Fleet -Data $board
    # A query run on the selected workstation refreshes its widgets even without an inventory.
    if ($null -ne $script:SelectedObject -or $null -ne $script:LastComputerDashboardResult) { try { Show-DomeniaBoard -Board Computer -Quiet } catch { } }
    $count = @($board.Last.Targets).Count
    [void](Set-DomeniaControlText 'LblFleetDashboard' $(if ($board.Summary) { [string]$board.Summary } else { 'Base autonome locale et derniers releves : ' + $count + ' postes actifs dans le perimetre, calcul du ' + (Get-Date -Format 'dd/MM/yyyy HH:mm') + '. Parc incomplet ? Outils, Base autonome, Mettre a jour tout.' }))
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
