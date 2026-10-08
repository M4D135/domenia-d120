# DOMENIA: presentation adapters for the shared support-suite contract.
$script:ExperienceInitialized=$false
$script:ExperienceActivitySignature=''
$script:ExperienceFilterTimer=$null
$script:ExperienceRestoring=$false

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
    Select-DomeniaWorkspace -Workspace 'TabApplicationTools' -Inner 'ApplicationToolTabs' -Tab 'TabExperience'
    Update-DomeniaExperienceActivity -Force
}

function Update-DomeniaExperienceCancelState {
    $button=Get-DomeniaControl 'BtnSuiteCancelRead';$grid=Get-DomeniaControl 'DgSuiteActivity'
    if($null -eq $button -or $null -eq $grid){return}
    $button.IsEnabled=$false
    $row=$grid.SelectedItem
    if($null -ne $row -and -not [bool]$row.Detached -and $null -ne $script:AsyncJobs -and $script:AsyncJobs.Contains([string]$row.Id)){
        $button.IsEnabled=Test-DomeniaExperienceCanCancel $script:AsyncJobs[[string]$row.Id] ([long]$script:SessionEpoch)
    }
    $button.ToolTip=if($button.IsEnabled){'Demande l''arrêt de cette lecture. Un appel natif peut encore terminer son nettoyage.'}else{'Sélectionnez une lecture annulable de cette session. Une écriture envoyée ne peut pas être annulée ici.'}
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
        $help=if($total -eq 0){'Aucune opération active. Ouvrir le suivi des opérations.'}elseif($queued -gt 0){"$total opération(s) suivie(s) : $active active(s), $queued en attente, $detached en nettoyage. Ouvrir le suivi."}else{"$total opération(s) suivie(s) : $active active(s), $detached en nettoyage. Ouvrir le suivi."}
        if([string]$button.ToolTip -cne $help){$button.ToolTip=$help}
        [Windows.Automation.AutomationProperties]::SetHelpText($button,$help)
    }
    $tab=Get-DomeniaControl 'TabExperience'
    if($null -eq $tab -or (-not $Force -and (-not $tab.IsVisible -or -not $tab.IsSelected))){return}
    $now=Get-Date;$rows=New-Object 'System.Collections.Generic.List[object]'
    if($null -ne $script:AsyncJobs){
        foreach($job in @($script:AsyncJobs.Values)){
            if($rows.Count -ge 64){break}
            $row=Get-DomeniaExperienceTaskRow $job -Now $now -SessionEpoch ([long]$script:SessionEpoch)
            if($null -ne $row -and [string]$job.State -eq 'Queued'){
                # D017: never shown as running before its worker starts.
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
    $materialized=@($rows.ToArray()|Sort-Object Detached,Name,Id)
    $signature=($materialized|ConvertTo-Json -Depth 3 -Compress)
    if($Force -or $signature -cne $script:ExperienceActivitySignature){
        [void](Set-DomeniaGridRows 'DgSuiteActivity' -Rows $materialized -KeyProperty 'Id')
        $script:ExperienceActivitySignature=$signature
    }
    $state=[string]$script:WriteState
    $message=if($active+$detached+$queued -eq 0){'Aucune opération active. Les résultats précédents restent dans le journal.'}else{"$active opération(s) active(s) · $queued en attente · $detached lecture(s) en nettoyage."}
    if($state -in @('Unknown','UnknownPending')){$message+=' Écriture à vérifier : ne relancez pas l''action avant relecture de l''objet.'}
    [void](Set-DomeniaControlText 'LblSuiteActivityState' $message)
    Update-DomeniaExperienceCancelState
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
    # UI-22 / UX-01: called by Add-DomeniaUiLog. Technical lines (Write-AppLog, area Journal) stay in the raw
    # view of the Expert profile and in Domenia.log; the readable view keeps the session statuses.
    param([datetime]$Time,[string]$Level='INFO',[string]$Area='',[AllowEmptyString()][string]$Text='')
    if([string]$Area -eq 'Journal'){return}
    if(($null -ne $script:Window) -and (-not $script:Window.Dispatcher.CheckAccess())){return}
    $entry=ConvertTo-DomeniaExperienceLogEntry -Time $Time -Level $Level -Area $Area -Text $Text
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
    $value=[regex]::Replace($value,'\b[\w-]{1,15}\\[\w.$-]+','[compte]')
    $value=[regex]::Replace($value,'\b(?:\d{1,3}\.){3}\d{1,3}\b','[adresse IP]')
    $value=[regex]::Replace($value,'(?i)\b(?=[\w-]*[a-z])[\w-]+(?:\.[\w-]+){2,}\b','[nom]')
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
    $bindings=@{
        BtnSuiteActivity={Open-DomeniaExperienceActivity};BtnSuiteRefreshActivity={Update-DomeniaExperienceActivity -Force}
        BtnSuiteCancelRead={Stop-DomeniaExperienceSelectedRead};BtnSuiteLogNext={Find-DomeniaExperienceLog}
        BtnSuiteResultClear={(Get-DomeniaControl 'TxtSuiteResultFilter').Clear()}
    }
    foreach($name in $bindings.Keys){$control=Get-DomeniaControl $name;if($null -ne $control){$control.Add_Click($bindings[$name])}}
    $control=Get-DomeniaControl 'DgSuiteActivity';if($null -ne $control){$control.Add_SelectionChanged({Update-DomeniaExperienceCancelState})}
    $control=Get-DomeniaControl 'ApplicationToolTabs';if($null -ne $control){$control.Add_SelectionChanged({param($s,$e) if($s -eq $e.OriginalSource){Update-DomeniaExperienceActivity -Force}})}
    $control=Get-DomeniaControl 'CmbSuiteDensity';if($null -ne $control){$control.Add_SelectionChanged({Apply-DomeniaExperienceDensity})}
    $control=Get-DomeniaControl 'CmbSuiteLogSize';if($null -ne $control){$control.Add_SelectionChanged({Apply-DomeniaExperienceLogReading})}
    if($null -ne $wrap){$wrap.Add_Checked({Apply-DomeniaExperienceLogReading});$wrap.Add_Unchecked({Apply-DomeniaExperienceLogReading})}
    $control=Get-DomeniaControl 'ChkUiLogErrorsOnly';if($null -ne $control){$control.Add_Checked({Set-DomeniaExperienceLogFilter});$control.Add_Unchecked({Set-DomeniaExperienceLogFilter})}
    # UX-01: a click on the folded bar (title, last line, pill) unfolds the journal; buttons keep their own click.
    $control=Get-DomeniaControl 'UxLogHeader'
    if($null -ne $control){$control.Add_MouseLeftButtonUp({param($s,$e) if([bool]$script:UiLogVisuallyCollapsed){Switch-DomeniaUxLog;$e.Handled=$true}})}
    $control=Get-DomeniaControl 'TxtSuiteLogFind';if($null -ne $control){$control.Add_KeyDown({param($s,$e) if($e.Key -eq [Windows.Input.Key]::Enter){Find-DomeniaExperienceLog;$e.Handled=$true}})}
    $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(180)
    $timer.Add_Tick({
        $script:ExperienceFilterTimer.Stop()
        $grid=Get-DomeniaControl 'DgObjects'
        # A pending local filter must not change the selection during a write lock.
        if($null -ne $grid -and $grid.IsEnabled){Apply-DomeniaPresenceFilter}
    })
    $script:ExperienceFilterTimer=$timer
    $control=Get-DomeniaControl 'TxtSuiteResultFilter'
    if($null -ne $control){$control.Add_TextChanged({
        if($script:ExperienceRestoring){return}
        $script:ExperienceFilterTimer.Stop();$script:ExperienceFilterTimer.Start()
    })}
    $script:Window.Add_Closed({
        try{Save-DomeniaExperiencePreferences}finally{
            if($null -ne $script:ExperienceFilterTimer){$script:ExperienceFilterTimer.Stop();$script:ExperienceFilterTimer=$null}
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
    $button=$Window.FindName('BtnSuiteLoginTheme')
    if($null -ne $button){$button.Content=if($theme -eq 'Dark'){'☀'}else{'☾'}}
}

function Initialize-DomeniaExperienceLogin {
    param($Window)
    if($null -eq $Window -or $Window.Resources.Contains('Suite.Login.Attached')){return}
    $Window.Resources['Suite.Login.Attached']=$true
    $button=$Window.FindName('BtnSuiteLoginTheme')
    if($null -ne $button){
        $button.Content=if((Get-DomeniaStoredTheme) -eq 'Dark'){'☀'}else{'☾'}
        $button.Add_Click({param($s,$e) Switch-DomeniaExperienceLoginTheme -Window (Get-DomeniaOwningDialog $s)})
    }
    $Window.Add_Activated({param($s,$e) Update-DomeniaExperienceCapsLock $s})
    $Window.Add_PreviewKeyUp({param($s,$e) Update-DomeniaExperienceCapsLock $s})
    Update-DomeniaExperienceCapsLock $Window
}
