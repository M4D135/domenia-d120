#requires -Version 5.1
# Native DOMENIA adapter. The model has no network access and no WPF dependency.
$script:SupportState=$null
$script:SupportTimer=$null
$script:SupportView=$null
$script:SupportModuleRoot=$PSScriptRoot

function Get-DomeniaSupportSessionKey {
    # Epoch changes even when the same account relogs. Never reuse data across logins.
    return ([string]$script:SessionEpoch+'|'+[string]$script:Conn.BaseDn+'|'+[string]$script:Conn.BindUser)
}

function Reset-DomeniaSupportSession {
    $script:SupportState=[pscustomobject]@{
        Key=(Get-DomeniaSupportSessionKey); SourceDn=''; Source='Unknown'; ObservedAtUtc=[datetime]::UtcNow
        Snapshot=$null; A=$null; B=$null; Pins=(New-Object Collections.ArrayList); Incidents=(New-Object Collections.ArrayList)
        Revision=0L; RenderedRevision=-1L; ObjectKey=''; SelectedIncidentId=''; Report=''
    }
    if ($null -ne $script:SupportView) {
        foreach ($name in @('DgSupportFindings','DgSupportDiff','DgSupportPins','DgSupportIncidents')) { [void](Set-DomeniaItemsSource -Name $name -Rows @()) }
        foreach ($name in @('TxtSupportFindingDetail','TxtSupportDiffDetail','TxtSupportIncidentDetail','TxtSupportReport')) { [void](Set-DomeniaControlText -Name $name -Text '') }
        [void](Set-DomeniaControlText -Name 'TxtSupportIncidentFilter' -Text '')
        (Get-DomeniaControl 'ChkSupportIncludeIncident').IsChecked=$false
        [void](Set-DomeniaControlText -Name 'LblSupportA' -Text 'A : aucune capture')
        [void](Set-DomeniaControlText -Name 'LblSupportB' -Text 'B : aucune capture')
        [void](Set-DomeniaControlText -Name 'LblSupportComparison' -Text 'Capture A puis B pour comparer.')
        [void](Set-DomeniaControlText -Name 'LblSupportContext' -Text 'Atelier vide. Les donnees AD et la base locale sont conservees.')
        [void](Set-DomeniaControlText -Name 'LblSupportCoverage' -Text 'Aucune synthese calculee.')
    }
}

function Sync-DomeniaSupportSession {
    if ($null -eq $script:SupportState -or $script:SupportState.Key -cne (Get-DomeniaSupportSessionKey)) { Reset-DomeniaSupportSession }
}

function Set-DomeniaSupportObjectSource {
    param([string]$Dn,[bool]$IsLive)
    Sync-DomeniaSupportSession
    $script:SupportState.SourceDn=$Dn
    $script:SupportState.Source=if ($IsLive) {'Live'} else {'Cache'}
    $script:SupportState.ObservedAtUtc=[datetime]::UtcNow
    $script:SupportState.ObjectKey=''
    $script:SupportState.Revision++
    if ($null -ne $script:SupportView) { [void](Set-DomeniaControlText 'TxtSupportReport' 'La fiche a change. Recalculer l apercu avant utilisation.') }
}

function Add-DomeniaSupportIncidentFromLog {
    param([string]$Text,[string]$Level,[string]$Area)
    # Never recurse to logging here. Collection is inert before the view is installed.
    if ($null -eq $script:SupportView -or $Level -notin @('WARN','ERROR')) { return }
    if ($null -ne $script:Window -and -not $script:Window.Dispatcher.CheckAccess()) { return }
    Sync-DomeniaSupportSession
    $incident=New-DomeniaSupportIncident -Text $Text -Level $Level -Area $Area
    # Suppress only identical adjacent duplicates within two seconds. Do not merge failures from different messages.
    $n=$script:SupportState.Incidents.Count
    if ($n -gt 0) {
        $last=$script:SupportState.Incidents[$n-1]
        if ($last.Detail -ceq $incident.Detail -and $last.Area -ceq $incident.Area -and $last.Level -ceq $incident.Level) {
            if (([datetime]::Parse($incident.AtUtc)-[datetime]::Parse($last.AtUtc)).TotalSeconds -lt 2) { return }
        }
    }
    Add-DomeniaSupportBoundedItem -Items $script:SupportState.Incidents -Item $incident -Limit 200
    $script:SupportState.Revision++
}

function Get-DomeniaSupportCurrentSnapshot {
    Sync-DomeniaSupportSession
    $selected=$script:SelectedObject
    if ($null -eq $selected -or $null -eq $selected.Entry -or $null -eq $selected.Entry.Properties) { return $null }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:CurrentObjectRequestDn) -and [string]$script:CurrentObjectRequestDn -ine [string]$selected.DN) {
        throw 'Une autre fiche est en cours de chargement. Attends son resultat avant de capturer.'
    }
    $source='Unknown'; $when=[datetime]::UtcNow
    if ($script:SupportState.SourceDn -ieq [string]$selected.DN) {
        $source=$script:SupportState.Source; $when=$script:SupportState.ObservedAtUtc
    }
    return New-DomeniaSupportSnapshot -Properties $selected.Entry.Properties -Scope ([string]$script:Conn.BaseDn) -Dn ([string]$selected.DN) -Name ([string]$selected.Name) -Type ([string]$selected.Type) -Source $source -ObservedAtUtc $when
}

function Update-DomeniaSupportAnalysis {
    $snapshot=Get-DomeniaSupportCurrentSnapshot
    $script:SupportState.Snapshot=$snapshot
    if ($null -eq $snapshot) {
        [void](Set-DomeniaItemsSource -Name 'DgSupportFindings' -Rows @())
        [void](Set-DomeniaControlText -Name 'LblSupportContext' -Text 'Ouvre une fiche depuis Recherche ou Arborescence, puis reviens dans Atelier.')
        [void](Set-DomeniaControlText -Name 'LblSupportCoverage' -Text 'Aucune fiche chargee. Aucun constat calcule.')
        [void](Set-DomeniaControlText -Name 'TxtSupportFindingDetail' -Text '')
        return
    }
    [void](Set-DomeniaControlText -Name 'LblSupportContext' -Text ($snapshot.Type+' | '+$snapshot.Name+' | '+$snapshot.Scope))
    $sourceLabel=switch ($snapshot.Source) {'Live' {'Lecture AD'} 'Cache' {'Cache : age AD non etabli'} default {'Origine non confirmee'}}
    $coverage=$snapshot.FieldCount.ToString()+' attribut(s) fournis sur '+@(Get-DomeniaSupportFieldNames).Count+' | '+$sourceLabel+' | observation '+([datetime]::Parse($snapshot.ObservedAtUtc)).ToLocalTime().ToString('HH:mm:ss')
    [void](Set-DomeniaControlText -Name 'LblSupportCoverage' -Text $coverage)
    [void](Set-DomeniaItemsSource -Name 'DgSupportFindings' -Rows @(Get-DomeniaSupportFindings -Snapshot $snapshot))
    $grid=Get-DomeniaControl 'DgSupportFindings'
    if ($grid.Items.Count -gt 0) { $grid.SelectedIndex=0 }
}

function Update-DomeniaSupportComparison {
    [void](Set-DomeniaControlText 'TxtSupportReport' 'Les captures ont change. Recalculer l apercu avant utilisation.')
    foreach ($slot in @('A','B')) {
        $snapshot=$script:SupportState.$slot
        $label=$slot+' : aucune capture'
        if ($null -ne $snapshot) { $label=$slot+' : '+$snapshot.Name+' | '+$snapshot.Source+"`r`n"+([datetime]::Parse($snapshot.CapturedAtUtc)).ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss') }
        [void](Set-DomeniaControlText -Name ('LblSupport'+$slot) -Text $label)
    }
    if ($null -eq $script:SupportState.A -or $null -eq $script:SupportState.B) {
        [void](Set-DomeniaItemsSource -Name 'DgSupportDiff' -Rows @())
        [void](Set-DomeniaControlText -Name 'LblSupportComparison' -Text 'Capture A, actualise ou ouvre une autre fiche du meme type, puis capture B.')
        return
    }
    try {
        $a=$script:SupportState.A; $b=$script:SupportState.B
        $all=@(Compare-DomeniaSupportSnapshots -Before $a -After $b)
        $rows=$all
        if ([bool](Get-DomeniaControl 'ChkSupportDiffOnly').IsChecked) { $rows=@($all | Where-Object {$_.Status -ne 'Identique'}) }
        [void](Set-DomeniaItemsSource -Name 'DgSupportDiff' -Rows $rows)
        $mode=if ($a.Identity -ieq $b.Identity) {'Meme objet : avant / apres capture.'} else {'Objets differents : comparaison de reference, pas un historique.'}
        $summary=$mode+' '+@($all | Where-Object {$_.Status -eq 'Different'}).Count+' difference(s), '+@($all | Where-Object {$_.Status -eq 'Indetermine'}).Count+' indetermine(s).'
        [void](Set-DomeniaControlText -Name 'LblSupportComparison' -Text $summary)
    } catch {
        [void](Set-DomeniaItemsSource -Name 'DgSupportDiff' -Rows @())
        [void](Set-DomeniaControlText -Name 'LblSupportComparison' -Text $_.Exception.Message)
    }
    [void](Set-DomeniaControlText -Name 'TxtSupportDiffDetail' -Text 'Selectionne memberOf pour voir les groupes presents seulement en A ou en B. Aucune modification n est executee.')
}

function Set-DomeniaSupportCapture {
    param([ValidateSet('A','B')][string]$Slot)
    $snapshot=Get-DomeniaSupportCurrentSnapshot
    if ($null -eq $snapshot) { throw 'Ouvre une fiche avant de capturer.' }
    $script:SupportState.$Slot=$snapshot
    $script:SupportState.Revision++
    Update-DomeniaSupportComparison
    Select-DomeniaWorkspace -Workspace 'TabSupport' -Inner 'SupportTabs' -Tab 'SupportCompareTab'
}

function Add-DomeniaSupportPin {
    $snapshot=Get-DomeniaSupportCurrentSnapshot
    if ($null -eq $snapshot) { throw 'Ouvre une fiche avant de l epingler.' }
    foreach ($pin in @($script:SupportState.Pins.ToArray())) {
        if ($pin.Identity -ieq $snapshot.Identity) { [void]$script:SupportState.Pins.Remove($pin); break }
    }
    if ($script:SupportState.Pins.Count -ge 24) { throw '24 reperes sont deja presents. Retire un repere avant d en ajouter un autre.' }
    [void]$script:SupportState.Pins.Add([pscustomobject]@{Identity=$snapshot.Identity;Scope=$snapshot.Scope;Name=$snapshot.Name;Type=$snapshot.Type;Dn=([string]$script:SelectedObject.DN)})
    [void](Set-DomeniaItemsSource -Name 'DgSupportPins' -Rows $script:SupportState.Pins.ToArray())
    $script:SupportState.Revision++
    Select-DomeniaWorkspace -Workspace 'TabSupport' -Inner 'SupportTabs' -Tab 'SupportPinsTab'
}

function Open-DomeniaSupportPin {
    Sync-DomeniaSupportSession
    $pin=(Get-DomeniaControl 'DgSupportPins').SelectedItem
    if ($null -eq $pin) { return }
    if ([string]$pin.Scope -ine ([string]$script:Conn.BaseDn).Trim()) { throw 'Repere d un autre perimetre refuse.' }
    Open-AdObject -Dn ([string]$pin.Dn) -Type ([string]$pin.Type)
}

function Update-DomeniaSupportIncidents {
    $grid=Get-DomeniaControl 'DgSupportIncidents'
    $selectedId=''; if ($null -ne $grid.SelectedItem) { $selectedId=[string]$grid.SelectedItem.Id }
    $query=[string](Get-DomeniaControl 'TxtSupportIncidentFilter').Text
    $list=New-Object Collections.ArrayList
    for ($i=$script:SupportState.Incidents.Count-1; $i -ge 0; $i--) {
        $row=$script:SupportState.Incidents[$i]
        if (Test-DomeniaSupportLiteralMatch -Text ($row.Title+' '+$row.Codes+' '+$row.Area) -Query $query) { [void]$list.Add($row) }
    }
    [void](Set-DomeniaItemsSource -Name 'DgSupportIncidents' -Rows $list.ToArray())
    foreach ($row in $list) { if ($row.Id -eq $selectedId) { $grid.SelectedItem=$row; break } }
    [void](Set-DomeniaControlText -Name 'LblSupportIncidents' -Text ($list.Count.ToString()+' incident(s) visible(s) / '+$script:SupportState.Incidents.Count+' en memoire, plafond 200. Session complete, toutes cibles confondues.'))
}

function Update-DomeniaSupportView {
    param([switch]$Force)
    if ($null -eq $script:SupportView) { return }
    if ($Force -and $null -ne $script:SupportTimer) { $script:SupportTimer.Start() }
    Sync-DomeniaSupportSession
    $tab=Get-DomeniaControl 'TabSupport'
    if (-not $Force -and -not $tab.IsSelected) { return }
    $objectKey=[string]$script:SelectedObjectGeneration+'|'+[string]$script:CurrentObjectRequestDn
    if ($null -eq $script:SelectedObject) { $objectKey+='|none' }
    $objectKey+='|'+[datetime]::UtcNow.ToString('yyyyMMddHHmm')
    if ($null -ne $script:SelectedObject -and -not [string]::IsNullOrWhiteSpace([string]$script:CurrentObjectRequestDn) -and [string]$script:CurrentObjectRequestDn -ine [string]$script:SelectedObject.DN) {
        [void](Set-DomeniaControlText 'LblSupportContext' 'Une autre fiche est en cours de chargement. Les donnees ci-dessous restent celles de la fiche precedente.')
        return
    }
    if ($Force -or $script:SupportState.ObjectKey -cne $objectKey) {
        Update-DomeniaSupportAnalysis
        $script:SupportState.ObjectKey=$objectKey
    }
    if ($Force -or $script:SupportState.Revision -ne $script:SupportState.RenderedRevision) {
        Update-DomeniaSupportIncidents
        $script:SupportState.RenderedRevision=$script:SupportState.Revision
    }
}

function New-DomeniaSupportUiReport {
    Update-DomeniaSupportAnalysis
    $incident=$null
    if ([bool](Get-DomeniaControl 'ChkSupportIncludeIncident').IsChecked) {
        $incident=(Get-DomeniaControl 'DgSupportIncidents').SelectedItem
        if ($null -eq $incident) { throw 'Choisis un incident ou decoche son inclusion.' }
    }
    $script:SupportState.Report=New-DomeniaSupportReport -Snapshot $script:SupportState.Snapshot -Before $script:SupportState.A -After $script:SupportState.B -Incident $incident -Build ([string]$script:MasterBuild)
    $ticket=ConvertTo-DomeniaSupportText ([string](Get-DomeniaControl 'TxtSupportTicket').Text) 80
    if($ticket){$script:SupportState.Report='Reference : '+$ticket+"`r`n"+$script:SupportState.Report}
    [void](Set-DomeniaControlText -Name 'TxtSupportReport' -Text $script:SupportState.Report)
    return $script:SupportState.Report
}

function Export-DomeniaSupportHtml {
    $report=New-DomeniaSupportUiReport
    if (-not (Confirm-Action 'Le dossier contient des identifiants et metadonnees internes du parc. Il ne contient pas les champs secrets dedies. Enregistrer ce dossier localement ?')) { return }
    $dialog=New-DomeniaFileRequest -Mode Save
    $dialog.Title='DOMENIA : enregistrer le dossier support'
    $dialog.Filter='Dossier HTML (*.html)|*.html'; $dialog.DefaultExt='.html';$dialog.AddExtension=$true;$dialog.OverwritePrompt=$true
    $dialog.FileName='Domenia-Support-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.html'
    if ($dialog.ShowDialog($script:Window) -ne $true) { return }
    $html=ConvertTo-DomeniaSupportHtml -Report $report
    Start-DomeniaDocumentTask -Action Write -Path $dialog.FileName -Text $html
}

function Stop-DomeniaSupportUi {
    if ($null -ne $script:SupportTimer) { $script:SupportTimer.Stop(); $script:SupportTimer=$null }
    if ($null -ne $script:Ctrl -and $script:Ctrl.ContainsKey('TabSupport')) {
        $tab=$script:Ctrl['TabSupport']; $tab.IsEnabled=$false
        $tabs=Get-DomeniaControl 'WorkspaceTabs'
        if ($null -ne $tabs) { [void]$tabs.Items.Remove($tab) }
        foreach ($key in @($script:Ctrl.Keys)) { if ($key -eq 'TabSupport' -or $key -match '^(DomeniaSupport|Support|BtnSupport|DgSupport|TxtSupport|LblSupport|ChkSupport|CmbSupport)') { $script:Ctrl.Remove($key) } }
    }
    $script:SupportState=$null; $script:SupportView=$null
}

function Initialize-DomeniaSupportUi {
    if ($null -ne $script:SupportView) { return }
    $path=Join-Path $script:SupportModuleRoot 'Domenia-Support.xaml'
    $text=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    [xml]$document=$text
    $reader=New-Object Xml.XmlNodeReader $document
    try { $view=[Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    # Resolve names inside this UserControl's own namescope, not Window.FindName.
    foreach ($element in $document.SelectNodes('//*')) {
        $name=$element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            if ($script:Ctrl.ContainsKey($name)) { throw ('Nom de controle deja present : '+$name) }
            $control=if ($name -eq [string]$view.Name) { $view } else { $view.FindName($name) }
            if ($null -eq $control) { throw ('Controle atelier introuvable : '+$name) }
            $script:Ctrl[$name]=$control
        }
    }
    $tab=New-Object Windows.Controls.TabItem
    $tab.Name='TabSupport';$tab.Header='Atelier';$tab.Content=$view
    $tab.ToolTip='Analyse locale, comparaison de captures et dossier support. Sans scan automatique.'
    $script:Ctrl['TabSupport']=$tab
    $workspaces=Get-DomeniaControl 'WorkspaceTabs'
    [void]$workspaces.Items.Add($tab)
    $script:SupportView=$view
    Reset-DomeniaSupportSession
    # All event scriptblocks use named functions or global state: no expired local closures.
    (Get-DomeniaControl 'BtnSupportAnalyse').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Synthese atelier' -Action {Update-DomeniaSupportView -Force}})
    (Get-DomeniaControl 'BtnSupportAccounts').Add_Click({Select-DomeniaWorkspace -Workspace 'TabAccounts';Update-DomeniaAccountUi})
    (Get-DomeniaControl 'BtnSupportEngine').Add_Click({Show-InfoBox -Message (Get-DomeniaRuntimeHealthText)})
    (Get-DomeniaControl 'BtnSupportSaveCapture').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Enregistrer capture' -Action {Use-DomeniaCaptureFile Write}})
    (Get-DomeniaControl 'BtnSupportLoadCapture').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Charger capture' -Action {Use-DomeniaCaptureFile Read}})
    (Get-DomeniaControl 'BtnSupportCaptureA').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Capture A' -Action {Set-DomeniaSupportCapture 'A'}})
    (Get-DomeniaControl 'BtnSupportCaptureB').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Capture B' -Action {Set-DomeniaSupportCapture 'B'}})
    (Get-DomeniaControl 'BtnSupportSwap').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Inverser captures' -Action {$temp=$script:SupportState.A;$script:SupportState.A=$script:SupportState.B;$script:SupportState.B=$temp;Update-DomeniaSupportComparison}})
    (Get-DomeniaControl 'BtnSupportClearCompare').Add_Click({$script:SupportState.A=$null;$script:SupportState.B=$null;Update-DomeniaSupportComparison;[void](Set-DomeniaControlText 'TxtSupportDiffDetail' '')})
    (Get-DomeniaControl 'ChkSupportDiffOnly').Add_Checked({Update-DomeniaSupportComparison})
    (Get-DomeniaControl 'ChkSupportDiffOnly').Add_Unchecked({Update-DomeniaSupportComparison})
    (Get-DomeniaControl 'BtnSupportPin').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Epingler fiche' -Action {Add-DomeniaSupportPin}})
    (Get-DomeniaControl 'BtnSupportPinCurrent').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Epingler fiche' -Action {Add-DomeniaSupportPin}})
    (Get-DomeniaControl 'BtnSupportOpenPin').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Ouvrir repere' -Action {Open-DomeniaSupportPin}})
    (Get-DomeniaControl 'DgSupportPins').Add_MouseDoubleClick({Invoke-DomeniaSafeUiAction -Operation 'Ouvrir repere' -Action {Open-DomeniaSupportPin}})
    (Get-DomeniaControl 'BtnSupportRemovePin').Add_Click({$row=(Get-DomeniaControl 'DgSupportPins').SelectedItem;if ($null -ne $row){[void]$script:SupportState.Pins.Remove($row);[void](Set-DomeniaItemsSource 'DgSupportPins' $script:SupportState.Pins.ToArray())}})
    (Get-DomeniaControl 'TxtSupportIncidentFilter').Add_TextChanged({Update-DomeniaSupportIncidents})
    (Get-DomeniaControl 'BtnSupportClearIncidents').Add_Click({$script:SupportState.Incidents.Clear();$script:SupportState.Revision++;Update-DomeniaSupportIncidents;[void](Set-DomeniaControlText 'TxtSupportIncidentDetail' '')})
    (Get-DomeniaControl 'BtnSupportClearSession').Add_Click({if (Confirm-Action 'Vider les captures, reperes et incidents de l atelier ? Aucune donnee de la base DOMENIA ni d AD ne sera supprimee.') {Reset-DomeniaSupportSession;Update-DomeniaSupportView -Force}})
    (Get-DomeniaControl 'DgSupportFindings').Add_SelectionChanged({
        $row=(Get-DomeniaControl 'DgSupportFindings').SelectedItem
        $text='Selectionne un constat.'
        if ($null -ne $row) {$text=$row.Title+' ['+$row.Code+"]`r`n"+$row.Evidence+"`r`n`r`nVerification proposee : "+$row.Next+"`r`nNature : "+$row.Basis}
        [void](Set-DomeniaControlText 'TxtSupportFindingDetail' $text)
    })
    (Get-DomeniaControl 'DgSupportDiff').Add_SelectionChanged({
        $row=(Get-DomeniaControl 'DgSupportDiff').SelectedItem
        $text='Selectionne un attribut.'
        if ($null -ne $row) {$text=$row.Attribute+' ['+$row.Status+"]`r`nA : "+$row.Before+"`r`nB : "+$row.After;if ($row.Attribute -eq 'memberOf'){$text+="`r`nSeulement en B : "+$row.Added+"`r`nSeulement en A : "+$row.Removed+"`r`nGroupes directs fournis uniquement, pas les droits effectifs."}}
        [void](Set-DomeniaControlText 'TxtSupportDiffDetail' $text)
    })
    (Get-DomeniaControl 'DgSupportIncidents').Add_SelectionChanged({
        $row=(Get-DomeniaControl 'DgSupportIncidents').SelectedItem;$text='Selectionne un incident.'
        if ($null -ne $row) {
            $text='SESSION COMPLETE : cet incident n est pas automatiquement lie a la fiche.'+"`r`n"
            foreach ($hint in @($row.Hints)) {$text+="`r`n"+$hint.Title+' ['+$hint.Code+"]`r`n"+$hint.Evidence+"`r`nA verifier : "+$hint.Next+"`r`n"}
            $text+="`r`nMessage local (exclu du dossier exporte) :`r`n"+$row.Detail
        }
        [void](Set-DomeniaControlText 'TxtSupportIncidentDetail' $text)
    })
    (Get-DomeniaControl 'BtnSupportPreview').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Dossier support' -Action {[void](New-DomeniaSupportUiReport)}})
    (Get-DomeniaControl 'BtnSupportCopyReport').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Copier dossier support' -Action {$report=New-DomeniaSupportUiReport;Set-ClipboardSafe $report}})
    (Get-DomeniaControl 'BtnSupportExportHtml').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Exporter dossier support' -Action {Export-DomeniaSupportHtml}})
    # Point 139: offline diagnostic folder, written by the local automation interface (Domenia-Automation.UI.ps1).
    (Get-DomeniaControl 'BtnSupportOfflineDossier').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Dossier hors ligne' -Action {Start-DomeniaOfflineDossier}})
    $script:SupportTimer=New-Object Windows.Threading.DispatcherTimer
    $script:SupportTimer.Interval=[timespan]::FromSeconds(1)
    $script:SupportTimer.Add_Tick({
        try {Update-DomeniaSupportView} catch {
            # Inert degradation: stop this timer, not the main app. A manual recalculation remains available.
            $script:SupportTimer.Stop()
            [void](Set-DomeniaControlText 'LblSupportCoverage' ('Actualisation atelier suspendue : '+$_.Exception.Message))
        }
    })
    $script:SupportTimer.Start()
    $script:Window.Add_Closed({Stop-DomeniaSupportUi})
}
