# DOMENIA: presentation adapters for the shared support-suite contract.
$script:ExperienceInitialized=$false
$script:ExperienceActivitySignature=''
$script:ExperienceFilterTimer=$null
$script:ExperienceRestoring=$false
# UX-32: the operations panel (Domenia-Operations.xaml) is loaded on its first opening.
$script:OperationsPanel=$null
$script:DomeniaExperienceModuleRoot=$PSScriptRoot

function Get-DomeniaExperienceVisibleRows {
    $grid=Get-DomeniaControl 'DgObjects'
    if($null -eq $grid){return}
    foreach($item in @($grid.Items)){if($null -ne $item){$item}}
}

function Get-DomeniaExperienceExportRows {
    param($VisibleRows,$SelectedRows)
    $visible=@($VisibleRows|Where-Object{$null -ne $_})
    $selected=@($SelectedRows|Where-Object{$null -ne $_})
    if($selected.Count -eq 0){return $visible}
    # The export is always a subset of the visible grid, even after a filter changed.
    $picked=@(foreach($row in $visible){
        foreach($selection in $selected){
            if([object]::ReferenceEquals($row,$selection)){$row;break}
        }
    })
    # UX-02: a single click selects one row (and pings it): the selection is exported from two rows only,
    # otherwise the whole visible list is. The caller always announces the number of rows.
    if($picked.Count -ge 2){return $picked}
    return $visible
}

function Open-DomeniaExperienceActivity {
    # UX-32: the Opérations button opens (or closes) the panel under itself; the page underneath does not move.
    Switch-DomeniaOperationsPanel
}

function Initialize-DomeniaOperationsPanel {
    # UX-32: drop-down panel of the operations, laid in DomeniaDialogLayer under the Opérations button. Its view comes
    # from Domenia-Operations.xaml (same model as Initialize-DomeniaSupportUi), loaded once, at the first opening.
    if($null -ne $script:OperationsPanel){return $true}
    if($null -eq $script:Window){return $false}
    $layer=$script:Window.FindName('DomeniaDialogLayer')
    if($null -eq $layer){return $false}
    $path=Join-Path $script:DomeniaExperienceModuleRoot 'Domenia-Operations.xaml'
    [xml]$document=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    $reader=New-Object Xml.XmlNodeReader $document
    try{$view=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    foreach($element in $document.SelectNodes('//*')){
        $name=$element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if([string]::IsNullOrWhiteSpace($name)){continue}
        $control=if($name -eq [string]$view.Name){$view}else{$view.FindName($name)}
        if($null -ne $control -and $null -ne $script:Ctrl){$script:Ctrl[$name]=$control}
    }
    $rows=[Collections.ObjectModel.ObservableCollection[object]]::new()
    $grid=$view.FindName('DgSuiteActivity');$grid.ItemsSource=$rows
    # One handler for the Arrêter buttons of every row (bubbling Click); the real job is checked again on click.
    $grid.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent,[Windows.RoutedEventHandler]{
        param($sender,$eventArgs)
        $button=$eventArgs.OriginalSource
        if(($button -is [Windows.Controls.Button]) -and -not [string]::IsNullOrWhiteSpace([string]$button.Tag)){$eventArgs.Handled=$true;Stop-DomeniaOperationRow -Id ([string]$button.Tag)}
    })
    $grid.Add_KeyDown({param($sender,$eventArgs) if($eventArgs.Key -eq [Windows.Input.Key]::Delete){$eventArgs.Handled=$true;Stop-DomeniaExperienceSelectedRead}})
    $view.FindName('BtnOperationsClose').Add_Click({Hide-DomeniaOperationsPanel})
    $view.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -eq [Windows.Input.Key]::Escape){$eventArgs.Handled=$true;Hide-DomeniaOperationsPanel}})
    # A click beside the panel (on the transparent layer itself) closes it, like a drop-down list.
    $layer.Add_MouseLeftButtonDown({param($sender,$eventArgs) if([object]::ReferenceEquals($eventArgs.OriginalSource,$sender) -and $null -ne $script:OperationsPanel -and $script:OperationsPanel.Open){$eventArgs.Handled=$true;Hide-DomeniaOperationsPanel}})
    $script:OperationsPanel=[pscustomobject]@{View=$view;Layer=$layer;Rows=$rows;Map=@{};Signature='';Open=$false;Timer=$null;Typed=($null -ne ('Domenia.Live.OperationRow' -as [type]))}
    # PF-12: durations are refreshed in place once per second while the panel is open, aligned with the other timers.
    $script:OperationsPanel.Timer=New-DomeniaTimer -Owner 'Timer:Operations' -IntervalMs 1000 -IdleIntervalMs 1000 -Tick {Update-DomeniaExperienceActivity}
    return $true
}

function Set-DomeniaOperationsPanelPosition {
    # Under the Opérations button, right edges aligned, inside the window whatever its width.
    $panel=$script:OperationsPanel
    if($null -eq $panel){return}
    $width=620.0;$left=16.0;$top=64.0
    try{
        $layerWidth=[double]$panel.Layer.ActualWidth
        if($layerWidth -gt 0){$width=[Math]::Min(620.0,[Math]::Max(320.0,$layerWidth-32))}
        $button=Get-DomeniaControl 'BtnSuiteActivity'
        if($null -ne $button -and $button.IsVisible){
            $point=$button.TranslatePoint([Windows.Point]::new(0,0),$panel.Layer)
            $top=[double]$point.Y+[double]$button.ActualHeight+6
            $left=[double]$point.X+[double]$button.ActualWidth-$width
            if($layerWidth -gt 0){$left=[Math]::Min($left,$layerWidth-$width-16)}
            $left=[Math]::Max(16.0,$left)
        }
        $layerHeight=[double]$panel.Layer.ActualHeight
        if($layerHeight -gt 0){$panel.View.MaxHeight=[Math]::Max(240.0,$layerHeight-$top-16)}
    }catch{}
    $panel.View.Width=$width
    $panel.View.Margin=[Windows.Thickness]::new($left,$top,0,0)
}

function Show-DomeniaOperationsPanel {
    # Returns $false when the panel cannot open (no main window, or a sheet waiting for an answer holds the layer).
    $ready=$false
    try{$ready=Initialize-DomeniaOperationsPanel}catch{Write-AppLog ('Panneau des opérations indisponible : '+$_.Exception.Message) 'WARN';$ready=$false}
    if(-not $ready){return $false}
    if($null -ne $script:DomeniaSurfaceState -and -not $script:DomeniaSurfaceState.Done){return $false}
    $panel=$script:OperationsPanel;$layer=$panel.Layer
    if(-not $layer.Children.Contains($panel.View)){$layer.Children.Clear();[void]$layer.Children.Add($panel.View)}
    $layer.Background=[Windows.Media.Brushes]::Transparent
    $layer.Visibility=[Windows.Visibility]::Visible
    Set-DomeniaOperationsPanelPosition
    $panel.Open=$true;$panel.Signature=''
    Update-DomeniaExperienceActivity -Force
    $panel.Timer.Start()
    try{$grid=Get-DomeniaControl 'DgSuiteActivity';if($null -ne $grid){[void]$grid.Focus()}}catch{}
    return $true
}

function Hide-DomeniaOperationsPanel {
    $panel=$script:OperationsPanel
    if($null -eq $panel -or -not $panel.Open){return}
    $panel.Open=$false
    try{$panel.Timer.Stop()}catch{}
    $layer=$panel.Layer
    if($layer.Children.Contains($panel.View)){[void]$layer.Children.Remove($panel.View)}
    if($layer.Children.Count -eq 0){$layer.Visibility=[Windows.Visibility]::Collapsed;$layer.ClearValue([Windows.Controls.Panel]::BackgroundProperty)}
    $button=Get-DomeniaControl 'BtnSuiteActivity';if($null -ne $button){try{[void]$button.Focus()}catch{}}
}

function Switch-DomeniaOperationsPanel {
    if($null -ne $script:OperationsPanel -and $script:OperationsPanel.Open){Hide-DomeniaOperationsPanel}else{[void](Show-DomeniaOperationsPanel)}
}

function Test-DomeniaOperationsPanelOpen {
    return ($null -ne $script:OperationsPanel -and [bool]$script:OperationsPanel.Open)
}

function Stop-DomeniaOperationRow {
    # UX-32: Arrêter on one row. The real job is checked again: a write, a protected local save or a task of another
    # session is never stopped from here.
    param([string]$Id)
    if([string]::IsNullOrWhiteSpace($Id) -or $null -eq $script:AsyncJobs -or -not $script:AsyncJobs.Contains($Id)){return}
    $job=$script:AsyncJobs[$Id]
    if(-not (Test-DomeniaExperienceCanCancel $job ([long]$script:SessionEpoch))){
        if([bool]$job.IsWrite){Set-Status 'Une écriture AD envoyée ne peut pas être annulée. Attendez la relecture de vérification.' 'WARN'}
        elseif([bool]$job.NonCancellable){Set-Status 'Enregistrement local : il se termine seul.'}
        return
    }
    Request-UiTaskStop -Id $Id -Reason 'Arrêt demandé depuis le panneau des opérations'
    Update-DomeniaExperienceActivity -Force
}

function Stop-DomeniaExperienceSelectedRead {
    $grid=Get-DomeniaControl 'DgSuiteActivity'
    if($null -eq $grid -or $null -eq $grid.SelectedItem){return}
    $row=$grid.SelectedItem;$id=[string]$row.Id
    if([bool]$row.Detached -or $null -eq $script:AsyncJobs -or -not $script:AsyncJobs.Contains($id)){return}
    # Recheck against the actual job, not against the displayed CanCancel flag.
    $job=$script:AsyncJobs[$id]
    if(-not (Test-DomeniaExperienceCanCancel $job ([long]$script:SessionEpoch))){return}
    Request-UiTaskStop -Id $id -Reason 'Arrêt demandé depuis le suivi des opérations'
    Update-DomeniaExperienceActivity -Force
}

function Sync-DomeniaOperationRows {
    # PF-12: the identity of the list is the Id and the state of each row. A new, finished or changed operation
    # updates the collection; otherwise only the duration of each row changes, in place: the selection, the scroll
    # position and the focus stay where the operator left them. Without the notifying type, rows are replaced only
    # when that identity changes.
    param([object[]]$Projections=@())
    $panel=$script:OperationsPanel
    if($null -eq $panel){return}
    $signature=(@($Projections|ForEach-Object{[string]$_.Id+'='+[string]$_.State})) -join '|'
    if(-not [bool]$panel.Typed){
        if($signature -cne [string]$panel.Signature){
            $panel.Rows.Clear();$panel.Map=@{}
            foreach($projection in $Projections){[void]$panel.Rows.Add($projection);$panel.Map[[string]$projection.Id]=$projection}
        }
        $panel.Signature=$signature
        return
    }
    $seen=@{}
    foreach($projection in $Projections){
        $id=[string]$projection.Id;$seen[$id]=$true
        $row=$panel.Map[$id]
        if($null -eq $row){$row=New-Object Domenia.Live.OperationRow;$row.Id=$id;$panel.Map[$id]=$row;[void]$panel.Rows.Add($row)}
        $row.Name=[string]$projection.Name;$row.Kind=[string]$projection.Kind;$row.State=[string]$projection.State
        $row.Duration=[string]$projection.Duration;$row.Detail=[string]$projection.Detail
        $row.CanCancel=[bool]$projection.CanCancel;$row.Detached=[bool]$projection.Detached
    }
    foreach($id in @($panel.Map.Keys)){if(-not $seen.ContainsKey([string]$id)){[void]$panel.Rows.Remove($panel.Map[$id]);[void]$panel.Map.Remove($id)}}
    $panel.Signature=$signature
}

function Get-DomeniaOperationsHealthText {
    # UX-32: the health of the engine in plain words. Local measures of this session only, no network probe.
    $lines=New-Object 'System.Collections.Generic.List[string]'
    try{$process=[Diagnostics.Process]::GetCurrentProcess();try{$lines.Add('Mémoire utilisée par Domenia : '+[Math]::Round($process.PrivateMemorySize64/1MB)+' Mo.')}finally{$process.Dispose()}}catch{}
    $delay=$null;try{$delay=Get-DomeniaRuntimeMetricSummary -Provenance 'Dispatcher' -Prefix 'Pulse'}catch{$delay=$null}
    if($null -ne $delay -and [int]$delay.Count -gt 0){$lines.Add('Réactivité de lʼinterface : retard habituel '+[Math]::Round([double]$delay.P50)+' ms ; 95 % des mesures sous '+[Math]::Round([double]$delay.P95)+' ms.')}
    else{$lines.Add('Réactivité de lʼinterface : pas encore mesurée.')}
    # Point 122: one line per category (local search, interface, local base, directory, workstations); an unmeasured
    # category says so and a 95th percentile needs at least 20 measures.
    $responses=@();try{$responses=@(Get-DomeniaResponseTimeSummaries)}catch{$responses=@()}
    if($responses.Count){
        $lines.Add('Temps de réponse mesurés sur ce poste pendant cette session (512 dernières mesures par opération ; pas un test du réseau) :')
        foreach($response in $responses){$lines.Add([string]$response.Text)}
    }
    $saved=$null;try{if($null -ne $script:Persistence){$saved=$script:Persistence.LastSavedAt}}catch{$saved=$null}
    $save=if($null -ne $saved){'Dernière sauvegarde locale à '+([datetime]$saved).ToString('HH:mm:ss')+'.'}else{'Aucune sauvegarde locale dans cette session.'}
    try{$state=Get-DomeniaPersistenceState;if([string]$state.Label){$save+=' '+[string]$state.Label}}catch{}
    $lines.Add($save)
    # FI-12: SQLite lock waits that ran out in this session, with the configured wait.
    try{$lines.Add([string](Get-DomeniaSqliteBusyStatusText))}catch{}
    return ($lines.ToArray() -join "`r`n")
}

function Update-DomeniaExperienceActivity {
    param([switch]$Force)
    if(-not $script:ExperienceInitialized){return}
    $active=0;$detached=0;$queued=0
    # D017: an entry waiting in the engine queue is counted apart; it holds no call yet.
    if($null -ne $script:AsyncJobs){foreach($job in @($script:AsyncJobs.Values)){if($null -eq $job){continue};if([string]$job.State -eq 'Queued'){$queued++}else{$active++}}}
    if($null -ne $script:DetachedReadJobs){$detached=@($script:DetachedReadJobs).Count}
    $button=Get-DomeniaControl 'BtnSuiteActivity'
    $total=[long]$active+[long]$detached+[long]$queued
    $counter=Get-DomeniaControl 'LblSuiteActivityCount';$badge=Get-DomeniaControl 'BadgeSuiteActivity'
    $label=Get-DomeniaCounterText -Count ([int]$total) -ZeroText '0'
    $visibility=if($total -gt 0){'Visible'}else{'Hidden'}
    if($null -ne $counter -and $counter.Text -cne $label){$counter.Text=$label}
    if($null -ne $badge -and [string]$badge.Visibility -ne $visibility){$badge.Visibility=$visibility}
    if($null -ne $button){
        $help=if($total -eq 0){'Aucune opération active. Afficher le panneau des opérations et la santé du moteur.'}elseif($queued -gt 0){"$total opération(s) suivie(s) : $active active(s), $queued en attente, $detached en nettoyage. Afficher le panneau."}else{"$total opération(s) suivie(s) : $active active(s), $detached en nettoyage. Afficher le panneau."}
        if([string]$button.ToolTip -cne $help){$button.ToolTip=$help}
        [Windows.Automation.AutomationProperties]::SetHelpText($button,$help)
    }
    # UX-32 / D020: the rows are built only while the panel is open.
    $panel=$script:OperationsPanel
    if($null -eq $panel -or -not [bool]$panel.Open){return}
    # A sheet that took the layer removed the panel: it is closed, not left half open.
    if($null -eq $panel.View.Parent){$panel.Open=$false;try{$panel.Timer.Stop()}catch{};return}
    $now=Get-Date;$rows=New-Object 'System.Collections.Generic.List[object]'
    if($null -ne $script:AsyncJobs){
        foreach($job in @($script:AsyncJobs.Values)){
            if($rows.Count -ge 64){break}
            $row=Get-DomeniaExperienceTaskRow $job -Now $now -SessionEpoch ([long]$script:SessionEpoch)
            if($null -ne $row -and [string]$job.State -eq 'Queued'){
                # D017: never shown as running before its worker starts; its waiting time is the one shown.
                $row.State='En attente';$row.Detail='Demande non envoyée ; aucun appel en cours.'
            }
            if($null -ne $row){$rows.Add($row)}
        }
    }
    foreach($job in @($script:DetachedReadJobs)){
        if($rows.Count -ge 64){break}
        $row=Get-DomeniaExperienceTaskRow $job -Now $now -Detached -SessionEpoch ([long]$script:SessionEpoch)
        if($null -ne $row){$rows.Add($row)}
    }
    Sync-DomeniaOperationRows -Projections $rows.ToArray()
    $state=[string]$script:WriteState
    $message=if($active+$detached+$queued -eq 0){'Aucune opération active. Les résultats précédents restent dans le journal.'}else{"$active opération(s) active(s) · $queued en attente · $detached lecture(s) en nettoyage."}
    if($state -in @('Unknown','UnknownPending')){$message+=' Écriture à vérifier : ne relancez pas lʼaction avant relecture de lʼobjet.'}
    [void](Set-DomeniaControlText 'LblSuiteActivityState' $message)
    [void](Set-DomeniaControlText 'LblOperationsHealth' (Get-DomeniaOperationsHealthText))
}

function Update-DomeniaExperienceIdentity {
    if(-not $script:ExperienceInitialized){return}
    $ad=[string]$script:Conn.BindUser
    if([string]::IsNullOrWhiteSpace($ad)){$ad=[string]$script:Conn.User}
    if([string]::IsNullOrWhiteSpace($ad)){$ad='Aucune identité AD active'}
    $remote=Get-DomeniaCredentialUserName $script:RemoteAdminCredential
    $secret=Get-DomeniaCredentialUserName $script:SecretsCredential
    if([string]::IsNullOrWhiteSpace($remote)){$remote='Compte AD courant'}
    if([string]::IsNullOrWhiteSpace($secret)){$secret='Compte AD courant'}
    [void](Set-DomeniaControlText 'LblSuiteIdentityAd' $ad)
    [void](Set-DomeniaControlText 'LblSuiteIdentityRemote' $remote)
    [void](Set-DomeniaControlText 'LblSuiteIdentitySecrets' $secret)
}

function Apply-DomeniaExperienceDensity {
    $combo=Get-DomeniaControl 'CmbSuiteDensity'
    if($null -eq $combo -or $null -eq $combo.SelectedItem){return}
    $mode=[string]$combo.SelectedItem.Content
    $grid=Get-DomeniaControl 'DgObjects'
    if($null -ne $grid){$grid.RowHeight=if($mode -eq 'Compact'){28.0}else{36.0}}
    if(-not $script:ExperienceRestoring){Set-DomeniaSetting 'UxDensity' $mode}
}

function Apply-DomeniaExperienceLogReading {
    $box=Get-DomeniaControl 'TxtUiLog';$wrap=Get-DomeniaControl 'ChkSuiteLogWrap';$size=Get-DomeniaControl 'CmbSuiteLogSize'
    if($null -eq $box){return}
    $wrapped=($null -ne $wrap -and [bool]$wrap.IsChecked)
    $box.TextWrapping=if($wrapped){[Windows.TextWrapping]::Wrap}else{[Windows.TextWrapping]::NoWrap}
    $box.HorizontalScrollBarVisibility=if($wrapped){[Windows.Controls.ScrollBarVisibility]::Disabled}else{[Windows.Controls.ScrollBarVisibility]::Auto}
    $number=11.0
    if($null -ne $size -and $null -ne $size.SelectedItem){$number=ConvertTo-SuiteNumber $size.SelectedItem.Content -Default 11 -Minimum 10 -Maximum 18}
    $box.FontSize=$number
    $list=Get-DomeniaControl 'LstUiLogReadable';if($null -ne $list){$list.FontSize=[Math]::Max(11.0,$number+1)}
    if(-not $script:ExperienceRestoring){
        Set-DomeniaSetting 'UxLogWrap' $wrapped
        Set-DomeniaSetting 'UxLogFontSize' $number
    }
}

function Find-DomeniaExperienceLog {
    $box=Get-DomeniaControl 'TxtUiLog';$search=Get-DomeniaControl 'TxtSuiteLogFind'
    if($null -eq $box -or $null -eq $search){return}
    $query=[string]$search.Text
    $list=Get-DomeniaControl 'LstUiLogReadable'
    if(($null -ne $list) -and ($list.Visibility -eq [Windows.Visibility]::Visible)){
        # UI-22: the readable journal is searched entry by entry, from the entry after the selected one.
        $items=@($list.Items)
        if([string]::IsNullOrEmpty($query) -or $items.Count -eq 0){[void](Set-DomeniaControlText 'LblSuiteLogFind' $(if([string]::IsNullOrEmpty($query)){'Saisissez un texte.'}else{'Aucune occurrence.'}));return}
        $start=[int]$list.SelectedIndex+1
        for($n=0;$n -lt $items.Count;$n++){
            $i=($start+$n)%$items.Count
            if((Find-SuiteLiteralText ([string]$items[$i].Text) $query 0) -ge 0){
                $follow=Get-DomeniaControl 'ChkUiLogFollow';if($null -ne $follow){$follow.IsChecked=$false}
                $list.SelectedIndex=$i;$list.ScrollIntoView($items[$i])
                [void](Set-DomeniaControlText 'LblSuiteLogFind' ('Ligne '+($i+1)+' · suivi en pause'))
                return
            }
        }
        [void](Set-DomeniaControlText 'LblSuiteLogFind' 'Aucune occurrence.')
        return
    }
    $start=[int]$box.SelectionStart+[Math]::Max(1,[int]$box.SelectionLength)
    $index=Find-SuiteLiteralText ([string]$box.Text) $query $start
    if($index -lt 0){
        [void](Set-DomeniaControlText 'LblSuiteLogFind' $(if([string]::IsNullOrEmpty($query)){'Saisissez un texte.'}else{'Aucune occurrence.'}))
        return
    }
    # Pause the view, not the logging, to prevent the next line from hiding the match.
    $follow=Get-DomeniaControl 'ChkUiLogFollow';if($null -ne $follow){$follow.IsChecked=$false}
    $box.Select($index,$query.Length)
    $line=$box.GetLineIndexFromCharacterIndex($index)
    if($line -ge 0){$box.ScrollToLine($line)}
    [void]$box.Focus()
    [void](Set-DomeniaControlText 'LblSuiteLogFind' ('Ligne '+($line+1)+' · suivi en pause'))
}

function Set-DomeniaExperienceJournalLayout {
    # -Transient: display only (short screen, D006), the operator's saved journal state is kept.
    param([bool]$Collapsed,[switch]$Transient)
    $row=Get-DomeniaControl 'UxLogRow';$split=Get-DomeniaControl 'LogGridSplitter';$button=Get-DomeniaControl 'BtnUxLogToggle'
    if($null -eq $row){return}
    if(-not $Transient){$script:UxLogCollapsed=$Collapsed}
    $script:UiLogVisuallyCollapsed=[bool]$Collapsed
    $height=ConvertTo-SuiteNumber $script:UxLogHeight -Default 180 -Minimum 100 -Maximum 600
    $row.Height=[Windows.GridLength]::new($(if($Collapsed){42.0}else{$height}))
    # UX-01: folded, the bar shows the last line and its red pill; the commands appear once the journal is open.
    foreach($name in @('UxSuiteLogTools','UxLogCommands')){
        $control=Get-DomeniaControl $name
        if($null -ne $control){$control.Visibility=if($Collapsed){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible}}
    }
    $last=Get-DomeniaControl 'LblUiLogLast'
    if($null -ne $last){$last.Visibility=if($Collapsed){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}}
    $header=Get-DomeniaControl 'UxLogHeader'
    if($null -ne $header){$header.Cursor=if($Collapsed){[Windows.Input.Cursors]::Hand}else{$null}}
    if(-not $Collapsed){$script:UiLogUnreadErrors=0}
    Update-DomeniaExperienceLogView
    Update-DomeniaExperienceLogBadge
    if($null -ne $split){$split.Visibility=if($Collapsed){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible}}
    if($null -ne $button){
        $button.Content=if($Collapsed){[string][char]0x02C4}else{[string][char]0x02C5}
        $help=if($Collapsed){'Déplier le journal de session. Lʼenregistrement continue dans les deux cas.'}else{'Replier le journal de session. Lʼenregistrement continue dans les deux cas.'}
        $button.ToolTip=$help;[Windows.Automation.AutomationProperties]::SetName($button,$(if($Collapsed){'Déplier le journal'}else{'Replier le journal'}))
        [Windows.Automation.AutomationProperties]::SetHelpText($button,$help)
    }
}

function ConvertTo-DomeniaExperienceLogEntry {
    # UI-22, pure: one readable line for a technician: HH:mm, one icon per level, the phrase (first line, bounded).
    param([datetime]$Time,[string]$Level='INFO',[string]$Area='',[AllowEmptyString()][string]$Text='')
    $level=([string]$Level).Trim().ToUpperInvariant()
    if($level -in @('WARNING','AVERTISSEMENT')){$level='WARN'}
    if($level -in @('FATAL','ERREUR')){$level='ERROR'}
    if($level -notin @('WARN','ERROR')){$level='INFO'}
    $first=@(([string]$Text) -split '\r\n|\n|\r')[0]
    $phrase=([string]$first).Trim()
    if($phrase.Length -gt 280){$phrase=$phrase.Substring(0,279)+[string][char]0x2026}
    $icon=switch($level){'ERROR'{[string][char]0x2715}'WARN'{[string][char]0x26A0}default{[string][char]0x2713}}
    return [pscustomobject]@{Time=$Time.ToString('HH:mm');Icon=$icon;Text=$phrase;Level=$level;Area=[string]$Area}
}

function Add-DomeniaExperienceLogEntry {
    # UI-22 / UX-01: called by Add-DomeniaUiLog. The readable view keeps the session statuses and every warning or
    # error, including those written only by Write-AppLog (area Journal): they keep the red pill until read.
    # Informational Write-AppLog lines and technical twins (area Technique: incident code and .NET text of a
    # sentence already shown) stay in the raw view of the Expert profile and in Domenia.log.
    param([datetime]$Time,[string]$Level='INFO',[string]$Area='',[AllowEmptyString()][string]$Text='')
    if([string]$Area -eq 'Technique'){return}
    if(($null -ne $script:Window) -and (-not $script:Window.Dispatcher.CheckAccess())){return}
    $entry=ConvertTo-DomeniaExperienceLogEntry -Time $Time -Level $Level -Area $Area -Text $Text
    if(([string]$Area -eq 'Journal') -and ($entry.Level -notin @('WARN','ERROR'))){return}
    if($null -eq $script:UiLogReadableItems){$script:UiLogReadableItems=[System.Collections.ObjectModel.ObservableCollection[object]]::new()}
    $items=$script:UiLogReadableItems
    $items.Add($entry)
    $max=[Math]::Max(100,[int]$script:UiLogMaxLines)
    while($items.Count -gt $max){$items.RemoveAt(0)}
    $list=Get-DomeniaControl 'LstUiLogReadable'
    if($null -ne $list){
        if($null -eq $list.ItemsSource){$list.ItemsSource=$items;Set-DomeniaExperienceLogFilter}
        $follow=Get-DomeniaControl 'ChkUiLogFollow'
        if($list.IsVisible -and (($null -eq $follow) -or [bool]$follow.IsChecked)){$list.ScrollIntoView($entry)}
    }
    $last=Get-DomeniaControl 'LblUiLogLast'
    if($null -ne $last){
        $last.Text=$entry.Time+'  '+$entry.Icon+'  '+$entry.Text
        [Windows.Automation.AutomationProperties]::SetHelpText($last,$entry.Text)
        $key=switch($entry.Level){'ERROR'{'StatusError'}'WARN'{'StatusWarning'}default{'MutedColor'}}
        $last.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,$key)
        # UI-13 (L08): the last line is a polite live region; warnings and errors are announced, routine lines are not.
        if(($entry.Level -in @('WARN','ERROR')) -and ($null -ne (Get-Command -Name Send-DomeniaUxLiveChange -CommandType Function -ErrorAction SilentlyContinue))){Send-DomeniaUxLiveChange -Control $last}
    }
    if(($entry.Level -eq 'ERROR') -and [bool]$script:UiLogVisuallyCollapsed){
        $script:UiLogUnreadErrors=[int]$script:UiLogUnreadErrors+1
        Update-DomeniaExperienceLogBadge
    }
}

function Clear-DomeniaExperienceLogEntries {
    if($null -ne $script:UiLogReadableItems){$script:UiLogReadableItems.Clear()}
    $script:UiLogUnreadErrors=0
    $last=Get-DomeniaControl 'LblUiLogLast';if($null -ne $last){$last.Text=''}
    Update-DomeniaExperienceLogBadge
}

function Set-DomeniaExperienceLogFilter {
    # UI-22: « Erreurs seulement » filters the readable view only; every level is still recorded.
    if($null -eq $script:UiLogReadableItems){return}
    $check=Get-DomeniaControl 'ChkUiLogErrorsOnly'
    $view=[Windows.Data.CollectionViewSource]::GetDefaultView($script:UiLogReadableItems)
    if($null -eq $view){return}
    if(($null -ne $check) -and [bool]$check.IsChecked){$view.Filter=[Predicate[object]]{param($item) [string]$item.Level -eq 'ERROR'}}
    else{$view.Filter=$null}
}

function Update-DomeniaExperienceLogView {
    # UI-22: Essentiel reads the journal (HH:mm, icon, colour, filter); Expert keeps the raw format and the
    # engine state. Display only: the recording and Domenia.log are the same in both profiles.
    $expert=([string]$script:CurrentUiProfile -eq 'Admin')
    $collapsed=[bool]$script:UiLogVisuallyCollapsed
    $raw=Get-DomeniaControl 'TxtUiLog';$list=Get-DomeniaControl 'LstUiLogReadable'
    $readable=((-not $expert) -and ($null -ne $list))
    if(($null -ne $list) -and ($null -eq $list.ItemsSource)){
        if($null -eq $script:UiLogReadableItems){$script:UiLogReadableItems=[System.Collections.ObjectModel.ObservableCollection[object]]::new()}
        $list.ItemsSource=$script:UiLogReadableItems;Set-DomeniaExperienceLogFilter
    }
    if($null -ne $raw){$raw.Visibility=if((-not $collapsed) -and (-not $readable)){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}}
    if($null -ne $list){
        $list.Visibility=if((-not $collapsed) -and $readable){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}
        if(($list.Visibility -eq [Windows.Visibility]::Visible) -and ($list.Items.Count -gt 0)){$list.ScrollIntoView($list.Items[$list.Items.Count-1])}
    }
    $health=Get-DomeniaControl 'BtnRuntimeHealth';if($null -ne $health){$health.Visibility=if($expert){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}}
    $filter=Get-DomeniaControl 'ChkUiLogErrorsOnly';if($null -ne $filter){$filter.Visibility=if($readable){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}}
    $wrap=Get-DomeniaControl 'ChkSuiteLogWrap';if($null -ne $wrap){$wrap.Visibility=if($readable){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible}}
}

function Update-DomeniaExperienceLogBadge {
    # UX-01: an error read while the journal is folded keeps a red pill until the journal is opened.
    # FI-10: « Journal indisponible » while Domenia.log cannot be written.
    $badge=Get-DomeniaControl 'UiLogErrorBadge';$label=Get-DomeniaControl 'LblUiLogErrorBadge'
    $count=[int]$script:UiLogUnreadErrors
    if($null -ne $badge){$badge.Visibility=if(($count -gt 0) -and [bool]$script:UiLogVisuallyCollapsed){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}}
    if($null -ne $label){$label.Text=if($count -le 1){'1 erreur'}else{[string]$count+' erreurs'}}
    $unavailable=Get-DomeniaControl 'UiLogUnavailableBadge'
    if($null -ne $unavailable){
        $off=[bool]$script:AppLogUnavailable
        $unavailable.Visibility=if($off){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}
        if($off){
            $fallback=[string]$script:AppLogFallbackPath
            $tip=if($fallback){'Domenia.log nʼest pas inscriptible. Journal de secours : '+$fallback}else{'Domenia.log nʼest pas inscriptible et aucun journal de secours nʼa pu être écrit.'}
            if([string]$script:AppLogUnavailableReason){$tip+=' Cause : '+[string]$script:AppLogUnavailableReason}
            $unavailable.ToolTip=$tip;[Windows.Automation.AutomationProperties]::SetHelpText($unavailable,$tip)
        }
    }
}

function Open-DomeniaExperienceJournal {
    # « Ouvrir le journal » of an error banner: unfolds the session journal and shows its last line.
    if([bool]$script:UiLogVisuallyCollapsed){Switch-DomeniaUxLog}
    if([bool]$script:UiLogVisuallyCollapsed){Set-DomeniaExperienceJournalLayout -Collapsed $false -Transient}
    $raw=Get-DomeniaControl 'TxtUiLog';if(($null -ne $raw) -and $raw.IsVisible){$raw.ScrollToEnd()}
}

function ConvertTo-DomeniaMaskedLogText {
    # UI-22, pure: optional masking for a copy sent outside Domenia: directory paths, accounts, DNS names and
    # addresses, plus the names given by the caller. Best effort, announced as such to the operator.
    param([AllowEmptyString()][string]$Text='',[string[]]$KnownNames=@())
    $value=[string]$Text
    foreach($name in @($KnownNames|Where-Object{([string]$_).Trim().Length -ge 3}|Sort-Object {([string]$_).Length} -Descending)){
        $value=[regex]::Replace($value,[regex]::Escape(([string]$name).Trim()),'[nom]',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    $value=[regex]::Replace($value,'(?i)\b(?:CN|OU|DC)=(?:\\.|[^,;\r\n])+(?:\s*,\s*(?:CN|OU|DC)=(?:\\.|[^,;\r\n])+)*','[chemin AD]')
    $value=[regex]::Replace($value,'\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b','[compte]')
    # DOMAINE\compte, never a segment of a local or UNC path (C:\Domenia\Logs, \\serveur\partage).
    $value=[regex]::Replace($value,'(?<![\w:\\.$-])[\w-]{1,15}\\[\w.$-]+','[compte]')
    $value=[regex]::Replace($value,'\b(?:\d{1,3}\.){3}\d{1,3}\b','[adresse IP]')
    # DNS names: three labels or more ending with a letter label (a version such as RC1.13.0 is kept), never a file
    # name of a path (a UNC host is masked), a script or log file name, nor a dotted .NET name.
    $value=[regex]::Replace($value,'(?i)(?<![\w./-])(?<![^\\]\\)(?<!^\\)[\w-]+(?:\.[\w-]+)+\.[a-z][\w-]*(?![\w-]|\.[\w-])',[Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $found=[string]$match.Value
        if($found -match '(?i)\.(?:ps1|psm1|psd1|dll|exe|json|log|xaml|xml|cs|txt|csv|db|zip)$'){return $found}
        if($found -cmatch '^(?:[A-Z][a-z0-9]*[a-z][A-Za-z0-9]*\.)+[A-Z][A-Za-z0-9]*$'){return $found}
        return '[nom]'
    })
    return $value
}

function Get-DomeniaExperienceLogCopyText {
    # UI-22: « Copier » takes the journal as displayed (readable entries, filter included, or the raw text).
    $list=Get-DomeniaControl 'LstUiLogReadable';$raw=Get-DomeniaControl 'TxtUiLog'
    $text=''
    if(($null -ne $list) -and ($list.Visibility -eq [Windows.Visibility]::Visible)){
        $text=[string]::Join([Environment]::NewLine,@(@($list.Items)|ForEach-Object{[string]$_.Time+'  '+[string]$_.Icon+'  '+[string]$_.Text}))
    }elseif($null -ne $raw){$text=[string]$raw.Text}
    $text=Protect-DomeniaLogText $text
    $mask=Get-DomeniaControl 'ChkUiLogCopyMask'
    $masked=(($null -ne $mask) -and [bool]$mask.IsChecked)
    if($masked){
        $known=@([string]$script:Conn.Domain,[string]$script:Conn.Netbios,[string]$script:Conn.Server,[string]$script:Conn.BindUser,[string]$env:COMPUTERNAME,[string]$env:USERNAME)
        try{$known+=[string]$script:SelectedObject.Name}catch{}
        $text=ConvertTo-DomeniaMaskedLogText -Text $text -KnownNames $known
    }
    return [pscustomobject]@{Text=$text;Masked=$masked}
}

function Save-DomeniaExperiencePreferences {
    if(-not $script:ExperienceInitialized -or $script:ExperienceRestoring){return}
    $row=Get-DomeniaControl 'UxLogRow'
    # A journal folded only for a short screen keeps the operator's expanded height.
    if($null -ne $row -and -not $script:UxLogCollapsed -and -not [bool]$script:UxShortLogHeld){$script:UxLogHeight=ConvertTo-SuiteNumber $row.ActualHeight -Default 180 -Minimum 100 -Maximum 600}
    Set-DomeniaSetting 'UxLogCollapsed' ([bool]$script:UxLogCollapsed)
    Set-DomeniaSetting 'UxLogExpandedHeight' ([double]$script:UxLogHeight)
    Save-DomeniaSettings -Immediate
}

function Update-DomeniaFilteredEmptyState {
    # UX-03: when the filter of the list hides every loaded row, the empty list says so and offers « Effacer le filtre ».
    # Called after each repaint of the result grid (progressive list and repainted copies). Display only.
    param([int]$Loaded=0,[int]$Visible=0)
    $panel = Get-DomeniaControl 'UxSearchFilteredEmpty'
    if ($null -eq $panel) { return }
    $box = Get-DomeniaControl 'TxtSuiteResultFilter'
    $text = ''
    if ($null -ne $box) { $text = [string]$box.Text }
    # The presence filter belongs to the OU lists; the global search never applies it.
    $presence = [string]$script:CurrentPresenceFilter
    if ((Get-DomeniaSearchMode) -eq 'Global') { $presence = 'Tous' }
    $state = Get-DomeniaFilteredEmptyState -Loaded $Loaded -Visible $Visible -LocalText $text -Presence $presence
    if ([bool]$state.Show) {
        [void](Set-DomeniaControlText 'LblSearchFilteredEmpty' ([string]$state.Text))
        [void](Set-DomeniaControlText 'LblSearchFilteredDetail' ([string]$state.Detail))
    }
    $wanted = if ([bool]$state.Show) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    if ($panel.Visibility -ne $wanted) { $panel.Visibility = $wanted }
}

function Clear-DomeniaResultFilters {
    # UX-03: « Effacer le filtre » of the empty list. The text of the list and the presence go back to everything;
    # the rows already loaded are shown again, no request is sent and the search itself is kept.
    $box = Get-DomeniaControl 'TxtSuiteResultFilter'
    if ($null -ne $box) { $box.Text = '' }
    $combo = Get-DomeniaControl 'CmbPresenceFilter'
    if (($null -ne $combo) -and ($combo.SelectedIndex -ne 0)) { $combo.SelectedIndex = 0 }
    $script:CurrentPresenceFilter = 'Tous'
    Apply-DomeniaPresenceFilter
}

function Initialize-DomeniaExperience {
    if($script:ExperienceInitialized -or $null -eq $script:Window){return}
    $script:ExperienceInitialized=$true;$script:ExperienceRestoring=$true
    try{
        $script:UxLogHeight=ConvertTo-SuiteNumber (Get-DomeniaSetting 'UxLogExpandedHeight' 180) -Default 180 -Minimum 100 -Maximum 600
        Set-DomeniaExperienceJournalLayout -Collapsed (ConvertTo-SuiteFlag (Get-DomeniaSetting 'UxLogCollapsed' $false))
        $wrap=Get-DomeniaControl 'ChkSuiteLogWrap'
        if($null -ne $wrap){$wrap.IsChecked=ConvertTo-SuiteFlag (Get-DomeniaSetting 'UxLogWrap' $false)}
        $mode=[string](Get-DomeniaSetting 'UxDensity' 'Confort')
        if($mode -notin @('Confort','Compact')){$mode='Confort'}
        [void](Set-DomeniaComboByContent 'CmbSuiteDensity' $mode)
        $size=[string](Get-DomeniaSetting 'UxLogFontSize' 11)
        if($size -notin @('10','11','12','14','16','18')){$size='11'}
        [void](Set-DomeniaComboByContent 'CmbSuiteLogSize' $size)
        Apply-DomeniaExperienceDensity
        Apply-DomeniaExperienceLogReading
    }finally{$script:ExperienceRestoring=$false}
    # UX-32: Opérations opens its drop-down panel; the panel (rows, Arrêter, Santé) is wired when it is first loaded.
    $bindings=@{
        BtnSuiteActivity={Open-DomeniaExperienceActivity};BtnSuiteLogNext={Find-DomeniaExperienceLog}
        BtnSuiteResultClear={(Get-DomeniaControl 'TxtSuiteResultFilter').Clear()}
        BtnSearchFilteredClear={Clear-DomeniaResultFilters}
    }
    foreach($name in $bindings.Keys){$control=Get-DomeniaControl $name;if($null -ne $control){$control.Add_Click($bindings[$name])}}
    $control=Get-DomeniaControl 'CmbSuiteDensity';if($null -ne $control){$control.Add_SelectionChanged({Apply-DomeniaExperienceDensity})}
    $control=Get-DomeniaControl 'CmbSuiteLogSize';if($null -ne $control){$control.Add_SelectionChanged({Apply-DomeniaExperienceLogReading})}
    if($null -ne $wrap){$wrap.Add_Checked({Apply-DomeniaExperienceLogReading});$wrap.Add_Unchecked({Apply-DomeniaExperienceLogReading})}
    $control=Get-DomeniaControl 'ChkUiLogErrorsOnly';if($null -ne $control){$control.Add_Checked({Set-DomeniaExperienceLogFilter});$control.Add_Unchecked({Set-DomeniaExperienceLogFilter})}
    # UX-01: a click on the folded bar (title, last line, pill) unfolds the journal; buttons keep their own click.
    $control=Get-DomeniaControl 'UxLogHeader'
    if($null -ne $control){$control.Add_MouseLeftButtonUp({param($s,$e) if([bool]$script:UiLogVisuallyCollapsed){Switch-DomeniaUxLog;$e.Handled=$true}})}
    $control=Get-DomeniaControl 'TxtSuiteLogFind';if($null -ne $control){$control.Add_KeyDown({param($s,$e) if($e.Key -eq [Windows.Input.Key]::Enter){Find-DomeniaExperienceLog;$e.Handled=$true}})}
    # FI-05: protected, session-bound heartbeat timer (debounce of the local filter), owned and registered by the factory.
    $script:ExperienceFilterTimer=New-DomeniaTimer -Owner 'Timer:ResultFilter' -IntervalMs 180 -SessionBound -Tick {
        param($sender,$eventArgs)
        $sender.Stop()
        $grid=Get-DomeniaControl 'DgObjects'
        # A pending local filter must not change the selection during a write lock.
        if($null -ne $grid -and $grid.IsEnabled){Apply-DomeniaPresenceFilter}
    }
    $control=Get-DomeniaControl 'TxtSuiteResultFilter'
    if($null -ne $control){$control.Add_TextChanged({
        if($script:ExperienceRestoring){return}
        $script:ExperienceFilterTimer.Stop();$script:ExperienceFilterTimer.Start()
    })}
    $script:Window.Add_Closed({
        try{Save-DomeniaExperiencePreferences}finally{
            if($null -ne $script:ExperienceFilterTimer){$script:ExperienceFilterTimer.Stop();$script:ExperienceFilterTimer=$null}
            if($null -ne $script:OperationsPanel){try{$script:OperationsPanel.Timer.Stop()}catch{};$script:OperationsPanel=$null}
            $script:ExperienceInitialized=$false;$script:ExperienceActivitySignature=''
        }
    })
    Update-DomeniaExperienceActivity -Force
    Update-DomeniaExperienceIdentity
    Update-DomeniaExperienceLogView
    Update-DomeniaExperienceLogBadge
}

function Update-DomeniaExperienceCapsLock {
    param($Window)
    if($null -eq $Window){return}
    $hint=$Window.FindName('LblSuiteCapsLock')
    if($null -ne $hint){$hint.Visibility=if([Windows.Input.Keyboard]::IsKeyToggled([Windows.Input.Key]::CapsLock)){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}}
}

function Switch-DomeniaExperienceLoginTheme {
    param($Window)
    if($null -eq $Window){return}
    $theme=if((Get-DomeniaStoredTheme) -eq 'Dark'){'Light'}else{'Dark'}
    $old=Get-DomeniaBootThemePalette -Theme (Get-DomeniaStoredTheme)
    $new=Get-DomeniaBootThemePalette -Theme $theme
    # Only brushes and appearance preferences are changed, never authentication state.
    foreach($key in $new.Keys){$Window.Resources['DomeniaBoot'+$key]=[Windows.Media.BrushConverter]::new().ConvertFromInvariantString([string]$new[$key])}
    foreach($name in @('LblLoginError','LblLoginStage')){
        $control=$Window.FindName($name)
        if($null -eq $control){continue}
        foreach($kind in @('Error','Warning','Success','Text','Muted','AccentText')){
            $brush=[Windows.Media.BrushConverter]::new().ConvertFromInvariantString([string]$old[$kind])
            if($control.Foreground.ToString() -eq $brush.ToString()){$control.Foreground=$Window.Resources['DomeniaBoot'+$kind];break}
        }
    }
    $notice=$Window.FindName('LblSuiteThemeSave')
    try {
        Save-DomeniaTheme -Theme $theme
        if($null -ne $notice){$notice.Text='';$notice.Visibility=[Windows.Visibility]::Collapsed}
    } catch {
        if($null -ne $notice){
            $notice.Text='Thème appliqué mais non enregistré. Vérifiez les droits du dossier de préférences.'
            $notice.Visibility=[Windows.Visibility]::Visible
        }
    }
    Update-DomeniaExperienceLoginThemeIcon -Window $Window -Theme $theme
}

function Update-DomeniaExperienceLoginThemeIcon {
    # DS-10 (L08): the login shows, like the main window, the Path icon of the theme the button switches TO (sun while
    # dark, moon while light) and names it « Passer au thème clair / sombre ».
    param($Window,[string]$Theme='Light')
    if($null -eq $Window){return}
    $toDark=($Theme -ne 'Dark')
    $sun=$Window.FindName('LoginThemeSun');$moon=$Window.FindName('LoginThemeMoon')
    if($null -ne $sun){$sun.Visibility=if($toDark){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible}}
    if($null -ne $moon){$moon.Visibility=if($toDark){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}}
    $button=$Window.FindName('BtnSuiteLoginTheme')
    if($null -ne $button){
        $name=if($toDark){'Passer au thème sombre'}else{'Passer au thème clair'}
        [Windows.Automation.AutomationProperties]::SetName($button,$name)
        $button.ToolTip=$name+'. Le choix est mémorisé pour Domenia ; la connexion nʼest ni lancée ni modifiée.'
    }
}

function Initialize-DomeniaExperienceLogin {
    param($Window)
    if($null -eq $Window -or $Window.Resources.Contains('Suite.Login.Attached')){return}
    $Window.Resources['Suite.Login.Attached']=$true
    $button=$Window.FindName('BtnSuiteLoginTheme')
    if($null -ne $button){
        Update-DomeniaExperienceLoginThemeIcon -Window $Window -Theme ([string](Get-DomeniaStoredTheme))
        $button.Add_Click({param($s,$e) Switch-DomeniaExperienceLoginTheme -Window (Get-DomeniaOwningDialog $s)})
    }
    $Window.Add_Activated({param($s,$e) Update-DomeniaExperienceCapsLock $s})
    $Window.Add_PreviewKeyUp({param($s,$e) Update-DomeniaExperienceCapsLock $s})
    Update-DomeniaExperienceCapsLock $Window
}
