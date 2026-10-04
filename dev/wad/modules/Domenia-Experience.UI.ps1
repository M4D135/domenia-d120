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
    foreach($row in $visible){
        foreach($selection in $selected){
            if([object]::ReferenceEquals($row,$selection)){$row;break}
        }
    }
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
    if(-not $script:ExperienceRestoring){
        Set-DomeniaSetting 'UxLogWrap' $wrapped
        Set-DomeniaSetting 'UxLogFontSize' $number
    }
}

function Find-DomeniaExperienceLog {
    $box=Get-DomeniaControl 'TxtUiLog';$search=Get-DomeniaControl 'TxtSuiteLogFind'
    if($null -eq $box -or $null -eq $search){return}
    $query=[string]$search.Text
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
    $height=ConvertTo-SuiteNumber $script:UxLogHeight -Default 180 -Minimum 100 -Maximum 600
    $row.Height=[Windows.GridLength]::new($(if($Collapsed){42.0}else{$height}))
    foreach($name in @('UxSuiteLogTools','TxtUiLog')){
        $control=Get-DomeniaControl $name
        if($null -ne $control){$control.Visibility=if($Collapsed){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible}}
    }
    if($null -ne $split){$split.Visibility=if($Collapsed){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible}}
    if($null -ne $button){$button.Content=if($Collapsed){'Agrandir'}else{'Réduire'}}
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
