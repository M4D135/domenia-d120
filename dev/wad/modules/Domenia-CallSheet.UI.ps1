# Fiche dʼappel (R40, improvement 3 of David): one view of the fiche of a user account, tab TabUserCallSheet, loaded from
# Domenia-CallSheet.xaml at its first opening (same contract as Initialize-DomeniaAssistanceView). It is opened from the
# fiche (BtnUserCallSheet) or from Rechercher (context menu of a user row) and gathers what a phone call needs. Opening it
# reads nothing on the network: the facts come from the fiche already read, the stored associations and measures, the
# receipts already read and one local read of the last stored inventory of the workstation shown. Each network read
# (4740 journal, password policy, presence, sessions, quick inventory) is one existing pinned operation started by its
# own button, with its own callbacks bound to the session epoch and to this sheet. The rules are in
# Domenia-CallSheet.Model.ps1.
$script:CallSheetModuleRoot=$PSScriptRoot
$script:CallSheetView=$null
$script:CallSheetState=$null
$script:CallSheetFiche=$null
$script:CallSheetPendingDn=''
$script:CallSheetBaselines=@{}
$script:CallSheetTimer=$null
$script:CallSheetSignature=''
$script:CallSheetDrawing=$false

function Register-DomeniaCallSheetUi {
    # Called once by Wire-Events. Nothing is parsed nor read before the operator opens the sheet.
    $tabs=Get-DomeniaControl 'DetailTabs'
    if(($null -eq $tabs) -or ($null -eq (Get-DomeniaControl 'TabUserCallSheet'))){return}
    $button=Get-DomeniaControl 'BtnUserCallSheet'
    if($null -ne $button){$button.Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Fiche dʼappel' -Action {Show-DomeniaCallSheet}})}
    $tabs.Add_SelectionChanged({
        param($sender,$eventArgs)
        if(($null -ne $eventArgs) -and ($eventArgs.OriginalSource -ne $sender)){return}
        if($sender.SelectedItem -eq (Get-DomeniaControl 'TabUserCallSheet')){Invoke-DomeniaSafeUiAction -Operation 'Fiche dʼappel' -Action {Initialize-DomeniaCallSheetView;Update-DomeniaCallSheet -Force} -NoPopup}
    })
    if($null -ne $script:Window){$script:Window.Add_Closed({Stop-DomeniaCallSheetUi})}
}

function Stop-DomeniaCallSheetUi {
    if($null -ne $script:CallSheetTimer){try{$script:CallSheetTimer.Stop()}catch{Write-DomeniaSwallowed 'CallSheet' 'Stop-DomeniaCallSheetUi' $_};$script:CallSheetTimer=$null}
    $script:CallSheetState=$null;$script:CallSheetPendingDn='';$script:CallSheetBaselines=@{}
}

function Initialize-DomeniaCallSheetView {
    # Loads the view once per session; its named controls join the control map and receive the help of the catalogue.
    $tab=Get-DomeniaControl 'TabUserCallSheet'
    if(($null -eq $tab) -or ($null -ne $script:CallSheetView)){return}
    [xml]$document=[IO.File]::ReadAllText((Join-Path $script:CallSheetModuleRoot 'Domenia-CallSheet.xaml'),[Text.Encoding]::UTF8)
    $reader=New-Object Xml.XmlNodeReader $document
    try{$view=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $controls=@{}
    foreach($element in $document.SelectNodes('//*')){
        $name=$element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if(-not $name){continue}
        if($script:Ctrl.ContainsKey($name)){throw ('Nom de contrôle déjà présent : '+$name)}
        $control=if($name -eq [string]$view.Name){$view}else{$view.FindName($name)}
        if($null -eq $control){throw ('Contrôle de la fiche dʼappel introuvable : '+$name)}
        $controls[$name]=$control
    }
    foreach($name in $controls.Keys){
        $script:Ctrl[$name]=$controls[$name]
        try{Initialize-DomeniaUxControlHelp -Control $controls[$name]}catch{Write-DomeniaSwallowed 'CallSheet' 'Initialize-DomeniaCallSheetView' $_}
    }
    $tab.Content=$view
    $script:CallSheetView=$view
    (Get-DomeniaControl 'BtnCallSheetRefresh').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Fiche dʼappel' -Action {Update-DomeniaCallSheet -Force}})
    (Get-DomeniaControl 'BtnCallSheetCopy').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Copier la fiche dʼappel' -Action {Copy-DomeniaCallSheetTicket}})
    (Get-DomeniaControl 'BtnCallSheetLockouts').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Verrouillages du compte' -Action {Start-DomeniaCallSheetLockoutRead}})
    (Get-DomeniaControl 'BtnCallSheetPolicy').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Stratégie de mot de passe' -Action {Start-DomeniaCallSheetPolicyRead}})
    (Get-DomeniaControl 'BtnCallSheetPresence').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Présence du poste' -Action {Start-DomeniaCallSheetPresence}})
    (Get-DomeniaControl 'BtnCallSheetSessions').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Sessions du poste' -Action {Start-DomeniaCallSheetSessionsRead}})
    (Get-DomeniaControl 'BtnCallSheetOpenComputer').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Ouvrir le poste' -Action {Open-DomeniaCallSheetComputer}})
    (Get-DomeniaControl 'BtnCallSheetGroupsView').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Appartenances' -Action {Select-DomeniaWorkspace -Workspace 'WsObject' -Inner 'DetailTabs' -Tab 'TabMemberOf'}})
    (Get-DomeniaControl 'BtnCallSheetCompareRights').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Comparer les droits' -Action {Open-DomeniaCallSheetRightsComparison}})
    (Get-DomeniaControl 'BtnCallSheetReceipts').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Reçus' -Action {Start-DomeniaCallSheetReceiptRefresh}})
    (Get-DomeniaControl 'BtnCallSheetTriage').Add_Click({Invoke-DomeniaSafeUiAction -Operation 'Tri du poste lent' -Action {Start-DomeniaCallSheetTriage}})
    (Get-DomeniaControl 'DgCallSheetAccount').Add_SelectionChanged({Invoke-DomeniaSafeUiAction -Operation 'Fiche dʼappel' -Action {Update-DomeniaCallSheetFactDetail} -NoPopup})
    (Get-DomeniaControl 'DgCallSheetTriage').Add_SelectionChanged({Invoke-DomeniaSafeUiAction -Operation 'Fiche dʼappel' -Action {Update-DomeniaCallSheetFactDetail -Triage} -NoPopup})
    (Get-DomeniaControl 'DgCallSheetComputers').Add_SelectionChanged({Invoke-DomeniaSafeUiAction -Operation 'Fiche dʼappel' -Action {Select-DomeniaCallSheetComputer} -NoPopup})
    (Get-DomeniaControl 'DgCallSheetComputers').Add_MouseDoubleClick({Invoke-DomeniaSafeUiAction -Operation 'Ouvrir le poste' -Action {Open-DomeniaCallSheetComputer}})
    # The light refresh runs only while the sheet is visible: presence, receipts and ages follow without any read.
    $script:CallSheetTimer=New-DomeniaTimer -Owner 'Timer:CallSheet' -IntervalMs 2000 -Transient -Tick {Invoke-DomeniaCallSheetTick}
    $view.Add_IsVisibleChanged({
        param($sender,$eventArgs)
        if($null -eq $script:CallSheetTimer){return}
        if([bool]$sender.IsVisible){$script:CallSheetTimer.Start();Invoke-DomeniaSafeUiAction -Operation 'Fiche dʼappel' -Action {Update-DomeniaCallSheet} -NoPopup}
        else{$script:CallSheetTimer.Stop()}
    })
    if([bool]$view.IsVisible){$script:CallSheetTimer.Start()}
    $script:UxLayoutSignature=''
}

function Show-DomeniaCallSheet {
    # Opens the sheet of the user fiche on display. Nothing is read: the tab shows what is known, each read has its button.
    $tab=Get-DomeniaControl 'TabUserCallSheet'
    if($null -eq $tab){return}
    if(($null -eq $script:SelectedObject) -or ([string]$script:SelectedObject.Type -ne 'Utilisateur')){Set-Status 'Ouvrez dʼabord la fiche dʼun utilisateur : la fiche dʼappel porte sur un compte.' 'WARN';return}
    $tab.Visibility=[Windows.Visibility]::Visible
    Select-DomeniaWorkspace -Workspace 'WsObject' -Inner 'DetailTabs' -Tab 'TabUserCallSheet'
    Initialize-DomeniaCallSheetView
    Update-DomeniaCallSheet -Force
}

function Open-DomeniaResultRowCallSheet {
    # Rechercher, context menu of one user row: the fiche of this account opens (cache then directory read), then its
    # sheet. The menu itself reads nothing more than the opening of the fiche.
    $row=Get-DomeniaSelectedGridRow
    if(($null -eq $row) -or ([string]$row.Type -ne 'Utilisateur')){Set-Status 'Sélectionnez un seul utilisateur.' 'WARN';return}
    $dn=[string]$row.DN
    if((-not $dn)){Set-Status 'Cette ligne nʼa pas de nom distinctif : ouvrez sa fiche dʼabord.' 'WARN';return}
    if(($null -ne $script:SelectedObject) -and ([string]$script:SelectedObject.DN -ieq $dn) -and (-not [string]$script:CurrentObjectRequestDn)){Show-DomeniaCallSheet;return}
    $script:CallSheetPendingDn=$dn
    Queue-DomeniaSelectedObjectOpen -Immediate -Force
}

function Sync-DomeniaCallSheetAfterOpen {
    # Called by Show-AdObjectResult after each display of a fiche (cache, local preview or directory read). Keeps the
    # origin of the fiche for the sheet, opens a sheet asked from Rechercher once its fiche is drawn (and again after the
    # directory read, which lands on the fiche), and redraws a sheet on display.
    param([string]$Dn,[string]$Type,[bool]$IsLive,$ObservedUtc=$null,[switch]$NoNavigate)
    $script:CallSheetFiche=[pscustomobject]@{Dn=$Dn;Origin=$(if($IsLive){'Live'}else{'Cache'});ObservedUtc=(ConvertTo-DomeniaUtcDate $ObservedUtc);Epoch=[long]$script:SessionEpoch}
    $pending=[string]$script:CallSheetPendingDn
    if($pending){
        if(($Type -eq 'Utilisateur') -and ($pending -ieq $Dn)){
            if($IsLive){$script:CallSheetPendingDn=''}
            if(-not $NoNavigate){Show-DomeniaCallSheet;return}
        }else{$script:CallSheetPendingDn=''}
    }
    if(Test-DomeniaCallSheetShown){Update-DomeniaCallSheet -Force}
}

function Test-DomeniaCallSheetShown {
    $tab=Get-DomeniaControl 'TabUserCallSheet'
    return (($null -ne $script:CallSheetView) -and ($null -ne $tab) -and ([bool]$tab.IsSelected) -and ([bool]$script:CallSheetView.IsVisible))
}

function Get-DomeniaCallSheetSubject {
    # The user account of the fiche on display, or $null.
    $selected=$script:SelectedObject
    if(($null -eq $selected) -or ([string]$selected.Type -ne 'Utilisateur') -or ($null -eq $selected.Entry)){return $null}
    $properties=$selected.Entry.Properties
    $sam=[string](Get-DomeniaAttr $properties 'sAMAccountName' '')
    $display=[string](Get-DomeniaAttr $properties 'displayName' '')
    if(-not $display){$display=[string]$selected.Name}
    return [pscustomobject]@{
        Dn=[string]$selected.DN;Sam=$sam;Upn=[string](Get-DomeniaAttr $properties 'userPrincipalName' '');DisplayName=$display
        Sid=(ConvertTo-DomeniaSidText (Get-DomeniaAttr $properties 'objectSid' $null));Guid=(ConvertTo-DomeniaGuidText (Get-DomeniaAttr $properties 'objectGUID' ''))
        CreatedUtc=(Get-DomeniaAttr $properties 'whenCreated' $null);Properties=$properties;LoadedAt=$selected.LoadedAt
    }
}

function Get-DomeniaCallSheetSheetState {
    # Explicit reads and choices of the sheet of one account in one session; a new account or a new login starts empty.
    param($Subject)
    $key=[string]$script:SessionEpoch+'|'+([string]$Subject.Dn).ToLowerInvariant()
    if(($null -ne $script:CallSheetState) -and ([string]$script:CallSheetState.Key -ceq $key)){return $script:CallSheetState}
    foreach($old in @($script:CallSheetBaselines.Keys)){if(-not ([string]$old).StartsWith([string]$script:SessionEpoch+'|',[StringComparison]::Ordinal)){$script:CallSheetBaselines.Remove($old)}}
    if($script:CallSheetBaselines.Count -ge 200){$script:CallSheetBaselines.Clear()}
    $script:CallSheetState=[pscustomobject]@{
        Key=$key;Epoch=[long]$script:SessionEpoch;Dn=[string]$Subject.Dn;Lockout=$null;Policy=$null;Sessions=@{};Triage=@{};Thresholds=@{}
        StoredRequested=@{};Notes=@{};Jobs=@{};TriageComputer='';Targets=@();Ticket=$null
    }
    $script:CallSheetSignature=''
    return $script:CallSheetState
}

function Test-DomeniaCallSheetCallback {
    param($State)
    return (($null -ne $State) -and ($null -ne $script:CallSheetState) -and ([long](Get-DomeniaMember $State 'Epoch' -1) -eq [long]$script:SessionEpoch) -and ([string](Get-DomeniaMember $State 'SheetKey' '') -ceq [string]$script:CallSheetState.Key))
}

function Test-DomeniaCallSheetJobRunning {
    # A read started from the sheet is running while its engine task exists; a task withdrawn without callback frees it.
    param([string]$Name)
    if($null -eq $script:CallSheetState){return $false}
    $id=[string]$script:CallSheetState.Jobs[$Name]
    if(-not $id){return $false}
    if(($null -ne $script:AsyncJobs) -and ($script:AsyncJobs.Contains($id))){return $true}
    $script:CallSheetState.Jobs.Remove($Name)
    return $false
}

function Get-DomeniaCallSheetObservation {
    # Last committed measures of one workstation held in memory (presence, console, probes), by its DN. No read.
    param([string]$Dn)
    $key=([string]$Dn).Trim()
    if(-not $key){return $null}
    $value=$null
    foreach($candidate in @($key.ToLowerInvariant(),$key)){
        if(($null -ne $script:Live) -and ($null -ne $script:Live.Observations)){
            $found=$null
            if($script:Live.Observations.TryGetValue($candidate,[ref]$found)){$value=$found;break}
        }
    }
    if(($null -eq $value) -and ($script:FleetObservations -is [Collections.IDictionary]) -and ($script:FleetObservations.Contains($key.ToLowerInvariant()))){$value=$script:FleetObservations[$key.ToLowerInvariant()]}
    return $value
}

function Get-DomeniaCallSheetTargets {
    # One target per associated workstation (the relation shown first for that workstation), with its DN and GUID from
    # the association or the local index, and its last committed measures. Returns {Targets; Error}.
    param($Subject,$Sheet)
    $links=@()
    try{$links=@(Get-LinksForUser -UserLogin ([string]$Subject.Sam) -Guid ([string]$Subject.Guid) -CreatedUtc $Subject.CreatedUtc)}
    catch{return [pscustomobject]@{Targets=@();Error=('Associations illisibles : '+$_.Exception.Message)}}
    $byKey=[ordered]@{}
    foreach($link in $links){
        if($null -eq $link){continue}
        $key=Normalize-LinkComputer ([string](Get-DomeniaMember $link 'Computer' ''))
        if(-not $key){continue}
        if(-not $byKey.Contains($key)){$byKey[$key]=New-Object 'System.Collections.Generic.List[object]'}
        $byKey[$key].Add($link)
    }
    $targets=New-Object 'System.Collections.Generic.List[object]'
    foreach($key in @($byKey.Keys)){
        $link=Select-DomeniaPrimaryRelation @($byKey[$key].ToArray())
        $computer=[string](Get-DomeniaMember $link 'Computer' '')
        $dn=[string](Get-DomeniaMember $link 'ComputerDn' '');$guid=[string](Get-DomeniaMember $link 'ComputerGuid' '')
        if((-not $dn) -or (-not $guid)){
            $row=Find-DomeniaCachedComputerRow -Computer $computer -Guid $guid
            if($null -ne $row){if(-not $dn){$dn=[string](Get-DomeniaMember $row 'DN' '')};if(-not $guid){$guid=[string](Get-DomeniaMember $row 'Guid' '')}}
        }
        $sessions=$null
        $read=$Sheet.Sessions[[string]$key]
        if($null -ne $read){$sessions=Get-DomeniaCallSheetSessionSummary -View $read.View -UserLogin ([string]$Subject.Sam) -ObservedUtc $read.ObservedUtc -Failure ([string]$read.Failure)}
        $targets.Add([pscustomobject]@{Key=[string]$key;Computer=$computer;Dn=$dn;Guid=$guid;Link=$link;Observation=(Get-DomeniaCallSheetObservation $dn);Sessions=$sessions})
    }
    return [pscustomobject]@{Targets=$targets.ToArray();Error=''}
}

function Get-DomeniaCallSheetTriageInput {
    # The newest inventory known for the workstation of the triage: read from this sheet, read back from the local base,
    # or kept by Assistance poste for this session. Starts the one local read of the stored inventory when none is known.
    param($Sheet,$Target)
    if($null -eq $Target){return $null}
    $entry=$Sheet.Triage[[string]$Target.Key]
    $inventory=$null;$failure='';$failureUtc=$null
    if($null -ne $entry){$inventory=$entry.Inventory;$failure=[string]$entry.Failure;$failureUtc=$entry.FailureUtc}
    $cache=$null
    if($script:InventoryCacheByComputer -is [Collections.IDictionary]){$cache=$script:InventoryCacheByComputer[[string]$Target.Key]}
    if(($null -ne $cache) -and ([long](Get-DomeniaMember $cache 'Epoch' -1) -eq [long]$script:SessionEpoch) -and ($null -ne (Get-DomeniaMemberValue $cache 'Effective'))){
        $cached=Get-DomeniaMemberValue $cache 'Effective'
        $cachedAt=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $cached 'SourceCompletedUtc' $null)
        $ownAt=$null
        if($null -ne $inventory){$ownAt=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $inventory 'SourceCompletedUtc' $null)}
        if(($null -ne $cachedAt) -and (($null -eq $ownAt) -or ($cachedAt -gt $ownAt))){$inventory=$cached}
    }
    if(($null -eq $inventory) -and (-not $failure)){Request-DomeniaCallSheetStoredInventory -Sheet $Sheet -Target $Target}
    return [pscustomobject]@{Inventory=$inventory;Failure=$failure;FailureUtc=$failureUtc}
}

function Get-DomeniaCallSheetThresholds {
    # Health thresholds of the workstation (Outils > Règles de santé), once per sheet and workstation; defaults when unreadable.
    param($Sheet,$Target)
    if($null -eq $Target){return $null}
    $key=[string]$Target.Key
    if($Sheet.Thresholds.ContainsKey($key)){return $Sheet.Thresholds[$key]}
    $thresholds=$null
    try{$thresholds=Get-DomeniaBoardThresholds -Policy (Get-DomeniaStoredHealthPolicy -ScopeDn ([string]$Target.Dn))}catch{Write-DomeniaSwallowed 'CallSheet' 'Get-DomeniaCallSheetThresholds' $_}
    $Sheet.Thresholds[$key]=$thresholds
    return $thresholds
}

function Update-DomeniaCallSheet {
    # Builds and draws the sheet from what is in memory. -Force redraws even when nothing seems to have changed.
    param([switch]$Force)
    if(($null -eq $script:CallSheetView) -or ($script:CallSheetDrawing)){return}
    $script:CallSheetDrawing=$true
    try{Update-DomeniaCallSheetView -Force:$Force}finally{$script:CallSheetDrawing=$false}
}

function Update-DomeniaCallSheetView {
    # Body of Update-DomeniaCallSheet, which guards it against a redraw started by its own grid selections.
    param([switch]$Force)
    $subject=Get-DomeniaCallSheetSubject
    if($null -eq $subject){
        $script:CallSheetState=$null;$script:CallSheetSignature=''
        foreach($grid in @('DgCallSheetAccount','DgCallSheetComputers','DgCallSheetGroups','DgCallSheetReceipts','DgCallSheetTriage')){[void](Set-DomeniaItemsSource -Name $grid -Rows @())}
        [void](Set-DomeniaControlText 'LblCallSheetSubject' 'Fiche dʼappel')
        [void](Set-DomeniaControlText 'LblCallSheetOrigin' 'Ouvrez la fiche dʼun utilisateur depuis Rechercher : la fiche dʼappel porte sur un compte.')
        [void](Set-DomeniaControlText 'TxtCallSheetTicket' '')
        Update-DomeniaCallSheetActions -Subject $null -Sheet $null -Target $null
        return
    }
    if(([string]$script:CurrentObjectRequestDn) -and ([string]$script:CurrentObjectRequestDn -ine [string]$subject.Dn)){
        [void](Set-DomeniaControlText 'LblCallSheetOrigin' 'Une autre fiche est en cours de chargement : les valeurs ci-dessous restent celles du compte précédent.')
        return
    }
    $sheet=Get-DomeniaCallSheetSheetState -Subject $subject
    if((-not $Force) -and ((Get-DomeniaCallSheetSignature -Sheet $sheet) -ceq $script:CallSheetSignature)){return}
    $now=[datetime]::UtcNow
    $offset=[int][Math]::Round([TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes)
    $origin='Unknown';$observed=ConvertTo-DomeniaUtcDate $subject.LoadedAt
    $fiche=$script:CallSheetFiche
    if(($null -ne $fiche) -and ([long]$fiche.Epoch -eq [long]$script:SessionEpoch) -and ([string]$fiche.Dn -ieq [string]$subject.Dn)){$origin=[string]$fiche.Origin;if($null -ne $fiche.ObservedUtc){$observed=$fiche.ObservedUtc}}
    $server=[string]$script:Conn.Server
    $targetRead=Get-DomeniaCallSheetTargets -Subject $subject -Sheet $sheet
    $targets=@($targetRead.Targets)
    $sheet.Targets=$targets
    $rows=@(ConvertTo-DomeniaCallSheetComputerRows -Targets $targets -UserLogin ([string]$subject.Sam) -NowUtc $now)
    $policy=$sheet.Policy;$policyView=$null;$policyAt=$null;$policyServer=''
    if(($null -ne $policy) -and ($null -ne $policy.View)){$policyView=$policy.View;$policyAt=$policy.ObservedUtc;$policyServer=[string]$policy.Server}
    $facts=New-Object 'System.Collections.Generic.List[object]'
    foreach($fact in @(Get-DomeniaCallSheetAccountFacts -Properties $subject.Properties -Origin $origin -ObservedUtc $observed -NowUtc $now -UtcOffsetMinutes $offset -Server $server -PolicyView $policyView -PolicyObservedUtc $policyAt -PolicyServer $policyServer -LinkedComputers @($targets|ForEach-Object{[string]$_.Computer}))){
        $facts.Add($fact)
        if([string]$fact.Label -ceq 'Verrouillage'){
            $lockout=$sheet.Lockout
            if($null -eq $lockout){$facts.Add((Get-DomeniaCallSheetLockoutFact))}
            else{$facts.Add((Get-DomeniaCallSheetLockoutFact -Read $lockout.Read -Diagnosis $lockout.Diagnosis -Failure ([string]$lockout.Failure) -FailureUtc $lockout.FailureUtc))}
        }
    }
    # Groups: the first sheet of this account in the session is the reference of the changes shown later.
    $baseline=$null;$baselineAt=$null
    if($script:CallSheetBaselines.ContainsKey([string]$sheet.Key)){$baseline=@($script:CallSheetBaselines[[string]$sheet.Key].Groups);$baselineAt=$script:CallSheetBaselines[[string]$sheet.Key].AtUtc}
    $groups=Get-DomeniaCallSheetGroupSummary -Properties $subject.Properties -Origin $origin -ObservedUtc $observed -Baseline $baseline -BaselineUtc $baselineAt -NowUtc $now
    if(($null -eq $baseline) -and ([string]$groups.State -ne 'NotRead') -and ([string]$groups.State -ne 'Incomplete')){$script:CallSheetBaselines[[string]$sheet.Key]=[pscustomobject]@{Groups=@($groups.Current);AtUtc=$observed}}
    $views=$null
    if(($null -ne $script:ReceiptViews) -and ([long]$script:ReceiptViewsEpoch -eq [long]$script:SessionEpoch)){$views=@($script:ReceiptViews)}
    $receipts=ConvertTo-DomeniaCallSheetReceiptSummary -Views $views -Dn ([string]$subject.Dn) -ReadUtc $script:ReceiptViewsReadUtc
    # Triage: the workstation chosen in the grid, else the one shown first (declared, else the most recent).
    $target=$null
    foreach($candidate in $targets){if([string]$candidate.Key -ceq [string]$sheet.TriageComputer){$target=$candidate;break}}
    if(($null -eq $target) -and ($rows.Count -gt 0)){foreach($candidate in $targets){if((Normalize-LinkComputer ([string]$candidate.Computer)) -ceq (Normalize-LinkComputer ([string]$rows[0].Computer))){$target=$candidate;break}}}
    $triageFacts=@();$triageComputer=''
    if($null -ne $target){
        $triageComputer=[string]$target.Computer
        $triageInput=Get-DomeniaCallSheetTriageInput -Sheet $sheet -Target $target
        $triageFacts=@(Get-DomeniaCallSheetTriageFacts -Inventory $triageInput.Inventory -Computer $triageComputer -Failure ([string]$triageInput.Failure) -FailureUtc $triageInput.FailureUtc -NowUtc $now -Thresholds (Get-DomeniaCallSheetThresholds -Sheet $sheet -Target $target))
    }
    $model=[pscustomobject]@{
        Subject=[pscustomobject]@{DisplayName=[string]$subject.DisplayName;Login=[string]$subject.Sam;Upn=[string]$subject.Upn}
        AccountFacts=$facts.ToArray();ComputerRows=$rows;GroupSummary=$groups;ReceiptSummary=$receipts;TriageComputer=$triageComputer;TriageFacts=$triageFacts
    }
    $template=Resolve-DomeniaCallSheetTemplate (Get-CfgValue 'CallSheet' 'TicketTemplate' $null)
    $sheet.Ticket=ConvertTo-DomeniaCallSheetTicket -Template ([string]$template.Text) -Values (Get-DomeniaCallSheetTicketValues -Sheet $model -NowUtc $now)
    # Drawing.
    $subjectText=[string]$subject.DisplayName
    if([string]$subject.Sam){$subjectText+=' · '+[string]$subject.Sam}
    if([string]$subject.Upn){$subjectText+=' · '+[string]$subject.Upn}
    [void](Set-DomeniaControlText 'LblCallSheetSubject' $subjectText)
    [void](Set-DomeniaControlText 'LblCallSheetOrigin' ([string](Get-DomeniaCallSheetOrigin -Origin $origin -ObservedUtc $observed -NowUtc $now -Server $server).Text))
    $attention=@(Get-DomeniaCallSheetAttention -Facts @($facts.ToArray()+@($groups.Facts)+@($receipts.Fact)+$triageFacts))
    [void](Set-DomeniaControlText 'LblCallSheetAttention' $(if($attention.Count){'À noter : '+($attention -join ' · ')}else{'Aucun point dʼattention parmi les faits relevés.'}))
    Set-DomeniaCallSheetGridRows -Name 'DgCallSheetAccount' -Rows $facts.ToArray() -KeyProperty 'Label'
    Set-DomeniaCallSheetGridRows -Name 'DgCallSheetComputers' -Rows $rows -KeyProperty 'Computer'
    Set-DomeniaCallSheetGridRows -Name 'DgCallSheetGroups' -Rows @($groups.Rows) -KeyProperty 'Dn'
    Set-DomeniaCallSheetGridRows -Name 'DgCallSheetReceipts' -Rows @($receipts.Rows) -KeyProperty 'Date'
    Set-DomeniaCallSheetGridRows -Name 'DgCallSheetTriage' -Rows $triageFacts -KeyProperty 'Label'
    $reads=New-Object 'System.Collections.Generic.List[string]'
    if(Test-DomeniaCallSheetJobRunning 'Lockout'){$reads.Add('Lecture du journal Sécurité de lʼémulateur PDC (7 derniers jours) en cours…')}
    elseif(($null -ne $sheet.Lockout) -and ([string]$sheet.Lockout.Text)){$reads.Add([string]$sheet.Lockout.Text)}
    if(Test-DomeniaCallSheetJobRunning 'Policy'){$reads.Add('Lecture de la stratégie de mot de passe applicable en cours…')}
    elseif($null -ne $policy){
        if([string]$policy.Failure){$reads.Add('Stratégie de mot de passe non lue : '+[string]$policy.Failure)}
        else{$reads.Add([string](Get-DomeniaMember $policy.View 'Summary' '')+' Lu sur '+$policyServer+' le '+(Format-DomeniaCallSheetDate $policyAt)+'. Aucun mot de passe nʼest lu.')}
    }
    [void](Set-DomeniaControlText 'TxtCallSheetAccountReads' ($reads.ToArray() -join [Environment]::NewLine))
    $computersText='Aucun poste associé à ce compte dans Domenia : la présence et le tri ne sont pas disponibles.'
    if([string]$targetRead.Error){$computersText=[string]$targetRead.Error+' La présence et le tri restent inconnus.'}
    elseif($rows.Count){
        $computersText=[string]$rows.Count+' poste(s) associé(s). Le premier est la relation déclarée, sinon la plus récente.'
        if(Test-DomeniaCallSheetJobRunning 'Sessions'){$computersText+=' Lecture des sessions en cours…'}
        $note=[string]$sheet.Notes['Sessions']
        if($note){$computersText+=' '+$note}
    }
    [void](Set-DomeniaControlText 'LblCallSheetComputers' $computersText)
    [void](Set-DomeniaControlText 'LblCallSheetGroups' ((@($groups.Facts|ForEach-Object{ConvertTo-DomeniaCallSheetFactLine $_})) -join [Environment]::NewLine))
    [void](Set-DomeniaControlText 'LblCallSheetReceipts' (ConvertTo-DomeniaCallSheetFactLine $receipts.Fact))
    $targetText='Aucun poste associé : tri non disponible.'
    if($null -ne $target){
        $targetText='Poste : '+[string]$target.Computer+'. Le tri lit lʼinventaire rapide du poste (CIM/WMI, 10 à 60 secondes, droits dʼadministration du poste) ; choisissez un autre poste dans la liste pour le changer.'
        if((-not [string]$target.Guid) -or (-not [string]$target.Dn)){$targetText+=' Identité AD du poste inconnue : ouvrez sa fiche une fois pour lʼenregistrer.'}
    }
    [void](Set-DomeniaControlText 'LblCallSheetTriageTarget' $targetText)
    $triageText=''
    if(Test-DomeniaCallSheetJobRunning 'Triage'){$triageText='Inventaire rapide en cours ; les valeurs ci-dessus gardent leur date jusquʼà son enregistrement.'}
    elseif(($null -ne $target) -and ([string]$sheet.Notes[[string]$target.Key])){$triageText=[string]$sheet.Notes[[string]$target.Key]}
    [void](Set-DomeniaControlText 'LblCallSheetTriage' $triageText)
    $ticketText='Texte brut construit depuis le modèle par défaut.'
    if([string]$template.Source -ceq 'Configuration'){$ticketText='Texte brut construit depuis le modèle CallSheet.TicketTemplate de Domenia.config.json.'}
    if([string]$template.Warning){$ticketText+=' '+[string]$template.Warning}
    if(@($sheet.Ticket.Unknown).Count){$ticketText+=' Champ(s) inconnu(s) laissé(s) tel(s) quel(s) : '+(@($sheet.Ticket.Unknown) -join ', ')+'.'}
    if([bool]$sheet.Ticket.Masked){$ticketText+=' Une valeur ressemblant à un secret a été masquée.'}
    [void](Set-DomeniaControlText 'LblCallSheetTicket' $ticketText)
    [void](Set-DomeniaControlText 'TxtCallSheetTicket' ([string]$sheet.Ticket.Text))
    Update-DomeniaCallSheetActions -Subject $subject -Sheet $sheet -Target $target
    Update-DomeniaCallSheetFactDetail
    # What the light refresh compares with: the state drawn, targets included.
    $script:CallSheetSignature=Get-DomeniaCallSheetSignature -Sheet $sheet
}

function Set-DomeniaCallSheetGridRows {
    # Redraws one grid of the sheet and keeps the selected line when it is still there.
    param([string]$Name,[object[]]$Rows=@(),[string]$KeyProperty)
    $grid=Get-DomeniaControl $Name
    $kept=''
    if(($null -ne $grid) -and ($null -ne $grid.SelectedItem)){$kept=[string](Get-DomeniaMember $grid.SelectedItem $KeyProperty '')}
    [void](Set-DomeniaItemsSource -Name $Name -Rows @($Rows))
    if(($null -eq $grid) -or (-not $kept)){return}
    foreach($row in @($grid.Items)){if([string](Get-DomeniaMember $row $KeyProperty '') -ceq $kept){$grid.SelectedItem=$row;break}}
}

function Get-DomeniaCallSheetSelectedTarget {
    # The workstation chosen in the grid of the sheet, else the one shown first.
    $sheet=$script:CallSheetState
    if($null -eq $sheet){return $null}
    $grid=Get-DomeniaControl 'DgCallSheetComputers'
    $row=$null
    if($null -ne $grid){$row=$grid.SelectedItem;if(($null -eq $row) -and ($grid.Items.Count -gt 0)){$row=$grid.Items[0]}}
    if($null -eq $row){return $null}
    $key=Normalize-LinkComputer ([string](Get-DomeniaMember $row 'Computer' ''))
    foreach($target in @($sheet.Targets)){if([string]$target.Key -ceq $key){return $target}}
    return $null
}

function Select-DomeniaCallSheetComputer {
    # The workstation chosen in the grid becomes the one of the triage; its stored inventory is read back once.
    $sheet=$script:CallSheetState
    if(($null -eq $sheet) -or ($script:CallSheetDrawing)){return}
    $grid=Get-DomeniaControl 'DgCallSheetComputers'
    if(($null -eq $grid) -or ($null -eq $grid.SelectedItem)){return}
    $key=Normalize-LinkComputer ([string](Get-DomeniaMember $grid.SelectedItem 'Computer' ''))
    if((-not $key) -or ($key -ceq [string]$sheet.TriageComputer)){return}
    $sheet.TriageComputer=$key
    Update-DomeniaCallSheet -Force
}

function Update-DomeniaCallSheetActions {
    # Buttons follow the sheet: a read needs its target (SID, DN and GUID of the workstation) and none running.
    param($Subject,$Sheet,$Target)
    $has=($null -ne $Subject)
    $selected=$null
    if($has){$selected=Get-DomeniaCallSheetSelectedTarget}
    $workstation=(($null -ne $selected) -and ([bool][string]$selected.Guid) -and ([bool][string]$selected.Dn))
    [void](Set-DomeniaControlEnabled 'BtnCallSheetCopy' $has)
    [void](Set-DomeniaControlEnabled 'BtnCallSheetRefresh' $has)
    [void](Set-DomeniaControlEnabled 'BtnCallSheetLockouts' (($has) -and ([bool][string]$Subject.Sid) -and (-not (Test-DomeniaCallSheetJobRunning 'Lockout'))))
    [void](Set-DomeniaControlEnabled 'BtnCallSheetPolicy' (($has) -and (-not (Test-DomeniaCallSheetJobRunning 'Policy'))))
    [void](Set-DomeniaControlEnabled 'BtnCallSheetPresence' $workstation)
    [void](Set-DomeniaControlEnabled 'BtnCallSheetSessions' (($workstation) -and (-not (Test-DomeniaCallSheetJobRunning 'Sessions'))))
    [void](Set-DomeniaControlEnabled 'BtnCallSheetOpenComputer' ($null -ne $selected))
    [void](Set-DomeniaControlEnabled 'BtnCallSheetGroupsView' $has)
    [void](Set-DomeniaControlEnabled 'BtnCallSheetReceipts' $has)
    $triage=(($null -ne $Target) -and ([bool][string]$Target.Guid) -and ([bool][string]$Target.Dn) -and (-not (Test-DomeniaCallSheetJobRunning 'Triage')))
    [void](Set-DomeniaControlEnabled 'BtnCallSheetTriage' $triage)
    # « Comparer les droits avec… » exists only where its view (tab TabUserAccessDiff of the fiche) is delivered.
    $compare=Get-DomeniaControl 'BtnCallSheetCompareRights'
    if($null -ne $compare){
        $available=($null -ne (Get-DomeniaControl 'TabUserAccessDiff'))
        $compare.Visibility=if($available){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}
        $compare.IsEnabled=(($available) -and ($has))
    }
}

function Update-DomeniaCallSheetFactDetail {
    # What the selected line proves and what it does not, under the account grid.
    param([switch]$Triage)
    $name='DgCallSheetAccount'
    if($Triage){$name='DgCallSheetTriage'}
    $grid=Get-DomeniaControl $name
    if(($null -eq $grid) -or ($null -eq $grid.SelectedItem)){
        if(-not $Triage){[void](Set-DomeniaControlText 'TxtCallSheetFactDetail' 'Sélectionnez une ligne pour lire ce quʼelle prouve et ce quʼelle ne prouve pas.')}
        return
    }
    $row=$grid.SelectedItem
    $text=[string](Get-DomeniaMember $row 'Label' '')+' : '+[string](Get-DomeniaMember $row 'StateLabel' '')+'. '+[string](Get-DomeniaMember $row 'Detail' '')
    if($Triage){[void](Set-DomeniaControlText 'LblCallSheetTriage' $text.Trim())}else{[void](Set-DomeniaControlText 'TxtCallSheetFactDetail' $text.Trim())}
}

function Get-DomeniaCallSheetSignature {
    # What the light refresh watches, all in memory: the fiche, the receipts read, the measures of the associated
    # workstations, the inventory kept for the triage, the explicit reads of the sheet and the minute (ages).
    param($Sheet)
    $parts=New-Object 'System.Collections.Generic.List[string]'
    $parts.Add([string]$script:SessionEpoch);$parts.Add([string]$script:SelectedObjectGeneration);$parts.Add([string]$script:CurrentObjectRequestDn)
    $parts.Add([string]$script:ReceiptViewsReadUtc);$parts.Add([datetime]::UtcNow.ToString('yyyyMMddHHmm'))
    if($null -ne $Sheet){
        foreach($target in @($Sheet.Targets)){
            $observation=Get-DomeniaCallSheetObservation ([string]$target.Dn)
            foreach($field in @('PresenceCheckedUtc','PresenceAttemptUtc','Presence','UserCheckedUtc','ConsoleAttemptUtc','CurrentUser','Outcome')){$parts.Add([string](Get-DomeniaMember $observation $field ''))}
            if($script:InventoryCacheByComputer -is [Collections.IDictionary]){$parts.Add([string](Get-DomeniaMember $script:InventoryCacheByComputer[[string]$target.Key] 'CompletedAt' ''))}
        }
        foreach($name in @('Lockout','Policy','Sessions','Triage')){$parts.Add([string](Test-DomeniaCallSheetJobRunning $name))}
    }
    return ($parts.ToArray() -join '|')
}

function Invoke-DomeniaCallSheetTick {
    # Light refresh of the visible sheet: redraws only when something it shows has changed. Reads nothing.
    if(-not (Test-DomeniaCallSheetShown)){return}
    $subject=Get-DomeniaCallSheetSubject
    $sheet=$null
    if(($null -ne $subject) -and ($null -ne $script:CallSheetState) -and ([string]$script:CallSheetState.Dn -ieq [string]$subject.Dn)){$sheet=$script:CallSheetState}
    if((Get-DomeniaCallSheetSignature -Sheet $sheet) -ceq $script:CallSheetSignature){return}
    Update-DomeniaCallSheet
}

# ---------------------------------------------------------------- explicit reads of the account
function New-DomeniaCallSheetReadState {
    param($Subject,[string]$Kind)
    return [pscustomobject]@{Epoch=[long]$script:SessionEpoch;SheetKey=[string]$script:CallSheetState.Key;Dn=[string]$Subject.Dn;Sid=[string]$Subject.Sid;Kind=$Kind}
}

function Start-DomeniaCallSheetLockoutRead {
    # Point 47 read of the sheet: the 4740 events of this account only, 7 days, 200 at most, on the PDC emulator.
    $subject=Get-DomeniaCallSheetSubject
    if(($null -eq $subject) -or ($null -eq $script:CallSheetState) -or ([string]$script:CallSheetState.Dn -ine [string]$subject.Dn)){[void](Set-DomeniaControlText 'TxtCallSheetAccountReads' 'Rechargez la fiche du compte avant de lire ses verrouillages.');return}
    if(-not [string]$subject.Sid){[void](Set-DomeniaControlText 'TxtCallSheetAccountReads' 'SID du compte non lu : le journal ne peut pas être filtré sur ce compte.');return}
    if(Test-DomeniaCallSheetJobRunning 'Lockout'){return}
    $payload=[pscustomobject]@{UserSid=[string]$subject.Sid;Hours=168;MaxEvents=200}
    $job=Start-UiTask -Name ('Fiche dʼappel : verrouillages de '+[string]$subject.Sam) -OperationId 'LockoutDiagnosis' -Code (Get-DomeniaLockoutEventWorkerCode) -Payload $payload -CallbackState (New-DomeniaCallSheetReadState $subject 'Lockout') -ReplaceKey 'callsheet-lockouts' -TimeoutSeconds 60 -TaskClass 'Explicit' -SuccessHandler 'Complete-DomeniaCallSheetLockoutRead' -ErrorHandler 'Fail-DomeniaCallSheetLockoutRead'
    if($job){$script:CallSheetState.Jobs['Lockout']=[string]$job}
    Update-DomeniaCallSheet -Force
}

function Complete-DomeniaCallSheetLockoutRead {
    param($Result,$State)
    if(-not (Test-DomeniaCallSheetCallback $State)){return}
    $script:CallSheetState.Jobs.Remove('Lockout')
    try{
        $read=Get-DomeniaEffectiveWorkerResult $Result @('State','Server','Events')
        if(($null -eq $read) -or ([string]$read.UserSid -cne [string]$State.Sid)){throw 'Résultat du journal absent ou provenant dʼun autre compte.'}
        $subject=Get-DomeniaCallSheetSubject
        if(($null -eq $subject) -or ([string]$subject.Dn -ine [string]$State.Dn)){return}
        $diagnosis=Get-DomeniaLockoutDiagnosis -User $subject.Properties -Dc ([string]$read.Server) -Events @($read.Events) -EventReadState ([string]$read.State) -Reader ([string]$script:Conn.User) -DomeniaFailures @(Get-DomeniaCredentialFailureHistory) -AccountKeys @(Get-DomeniaLockoutAccountKeys -Sam ([string]$subject.Sam) -Upn ([string]$subject.Upn))
        $script:CallSheetState.Lockout=[pscustomobject]@{Read=$read;Diagnosis=$diagnosis;Text=(Format-DomeniaLockoutReport $read $diagnosis);Failure='';FailureUtc=$null}
    }catch{
        $script:CallSheetState.Lockout=[pscustomobject]@{Read=$null;Diagnosis=$null;Text=('Lecture des verrouillages non exploitable : '+$_.Exception.Message);Failure=[string]$_.Exception.Message;FailureUtc=[datetime]::UtcNow}
    }
    Update-DomeniaCallSheet -Force
}

function Fail-DomeniaCallSheetLockoutRead {
    param($Message,$State)
    if(-not (Test-DomeniaCallSheetCallback $State)){return}
    $script:CallSheetState.Jobs.Remove('Lockout')
    $script:CallSheetState.Lockout=[pscustomobject]@{Read=$null;Diagnosis=$null;Text=('Lecture des verrouillages impossible : '+[string]$Message);Failure=[string]$Message;FailureUtc=[datetime]::UtcNow}
    Update-DomeniaCallSheet -Force
}

function Start-DomeniaCallSheetPolicyRead {
    # Point 102 read of the sheet: the policy that applies to this account and the expiry computed by the controller.
    $subject=Get-DomeniaCallSheetSubject
    if(($null -eq $subject) -or ($null -eq $script:CallSheetState) -or ([string]$script:CallSheetState.Dn -ine [string]$subject.Dn)){return}
    if(Test-DomeniaCallSheetJobRunning 'Policy'){return}
    $job=Start-UiTask -Name ('Fiche dʼappel : stratégie de mot de passe de '+[string]$subject.Sam) -OperationId 'PasswordPolicyRead' -Code (Get-DomeniaPasswordPolicyReadWorkerCode) -Payload ([pscustomobject]@{Dn=[string]$subject.Dn}) -CallbackState (New-DomeniaCallSheetReadState $subject 'Policy') -ReplaceKey 'callsheet-policy' -TimeoutSeconds 45 -TaskClass 'Explicit' -SuccessHandler 'Complete-DomeniaCallSheetPolicyRead' -ErrorHandler 'Fail-DomeniaCallSheetPolicyRead'
    if($job){$script:CallSheetState.Jobs['Policy']=[string]$job}
    Update-DomeniaCallSheet -Force
}

function Complete-DomeniaCallSheetPolicyRead {
    param($Result,$State)
    if(-not (Test-DomeniaCallSheetCallback $State)){return}
    $script:CallSheetState.Jobs.Remove('Policy')
    $read=Get-DomeniaEffectiveWorkerResult $Result @('Dn','User','PsoVisibleCount')
    if(($null -eq $read) -or ([string]$read.Dn -ine [string]$State.Dn)){
        $script:CallSheetState.Policy=[pscustomobject]@{View=$null;Server='';ObservedUtc=$null;Failure='résultat absent ou provenant dʼun autre objet.'}
    }else{
        $view=ConvertTo-DomeniaPasswordPolicyView -Read $read -Reader ([string]$script:Conn.User) -NowUtc ([datetime]::UtcNow)
        $script:CallSheetState.Policy=[pscustomobject]@{View=$view;Server=[string]$read.Server;ObservedUtc=(ConvertTo-DomeniaUtcDate $read.ObservedUtc);Failure=''}
    }
    Update-DomeniaCallSheet -Force
}

function Fail-DomeniaCallSheetPolicyRead {
    param($Message,$State)
    if(-not (Test-DomeniaCallSheetCallback $State)){return}
    $script:CallSheetState.Jobs.Remove('Policy')
    $script:CallSheetState.Policy=[pscustomobject]@{View=$null;Server='';ObservedUtc=$null;Failure=[string]$Message}
    Update-DomeniaCallSheet -Force
}

# ---------------------------------------------------------------- workstations: presence, sessions, triage
function New-DomeniaCallSheetCollectionState {
    # Collection state of one associated workstation (not the object on display): its committed result is written in the
    # local base under its own GUID and DN, then read back before it is shown, as for Assistance poste.
    param($Target,[string]$ResultKind,[string]$RequestKey,[string]$PublishHandler='',[string]$PublishErrorHandler='')
    $state=[pscustomobject]@{
        Computer=[string]$Target.Computer;DN=[string]$Target.Dn;ResultKind=$ResultKind;RequestKey=$RequestKey;PublishHandler=$PublishHandler;PublishErrorHandler=$PublishErrorHandler
        RemoteStartedUtc=[datetime]::UtcNow.ToString('o');SheetKey=[string]$script:CallSheetState.Key;ComputerKey=[string]$Target.Key;Epoch=[long]$script:SessionEpoch
    }
    [void](Initialize-DomeniaRemoteStoreState $state ([string]$Target.Guid) ([string]$Target.Dn) ([long]$script:GlobalSearchGeneration))
    return $state
}

function Start-DomeniaCallSheetPresence {
    # One ping of the chosen workstation (LiveSelectedPing, credential free), committed like the fiche presence. For the
    # workstation shown first the presence line of the fiche follows; for another one only its measure is updated.
    $target=Get-DomeniaCallSheetSelectedTarget
    if($null -eq $target){Set-Status 'Aucun poste associé à vérifier.' 'WARN';return}
    $subject=Get-DomeniaCallSheetSubject
    $rows=@((Get-DomeniaControl 'DgCallSheetComputers').Items)
    $first=(($rows.Count -gt 0) -and ((Normalize-LinkComputer ([string]$rows[0].Computer)) -ceq [string]$target.Key))
    if(($first) -and ($null -ne $subject)){
        $suffix=''
        try{$suffix=[string](Get-DomeniaLinkQualification $target.Link).Suffix}catch{Write-DomeniaSwallowed 'CallSheet' 'Start-DomeniaCallSheetPresence' $_}
        Start-DomeniaCommittedPresence -Computer ([string]$target.Computer) -Guid ([string]$target.Guid) -DN ([string]$target.Dn) -DisplayDN ([string]$subject.Dn) -DisplayKind 'Utilisateur' -Suffix $suffix -Explicit
    }else{
        Start-DomeniaCommittedPresence -Computer ([string]$target.Computer) -Guid ([string]$target.Guid) -DN ([string]$target.Dn) -DisplayDN ([string]$target.Dn) -DisplayKind 'Machine' -Explicit
    }
}

function Start-DomeniaCallSheetSessionsRead {
    # SessionsList of the chosen workstation (WTS, consultation only), committed then read back.
    $target=Get-DomeniaCallSheetSelectedTarget
    if(($null -eq $target) -or ($null -eq $script:CallSheetState)){Set-Status 'Aucun poste associé dont lire les sessions.' 'WARN';return}
    if(Test-DomeniaCallSheetJobRunning 'Sessions'){return}
    try{$state=New-DomeniaCallSheetCollectionState -Target $target -ResultKind 'Sessions' -RequestKey 'WTS' -PublishHandler 'Complete-DomeniaCallSheetSessions' -PublishErrorHandler 'Fail-DomeniaCallSheetSessions'}
    catch{$script:CallSheetState.Notes['Sessions']=('Sessions non lues : '+$_.Exception.Message);Update-DomeniaCallSheet -Force;return}
    $script:CallSheetState.Notes['Sessions']=''
    $job=Start-UiTask -Name ('Fiche dʼappel : sessions de '+[string]$target.Computer) -OperationId 'SessionsList' -Code (Get-DomeniaSessionsWorkerCode) -Payload ([pscustomobject]@{Computer=[string]$target.Computer}) -CallbackState $state -ReplaceKey 'callsheet-sessions' -TimeoutSeconds 30 -TaskClass 'Explicit' -SuccessHandler 'Complete-DomeniaSessionsCollected' -ErrorHandler 'Fail-DomeniaSessionsCollected'
    if($job){$script:CallSheetState.Jobs['Sessions']=[string]$job}
    Update-DomeniaCallSheet -Force
}

function Complete-DomeniaCallSheetSessions {
    # Publish handler of the committed sessions (Complete-DomeniaRemoteDetailStored).
    param($Result,$State)
    if((-not (Test-DomeniaCallSheetCallback $State)) -or (-not (Test-DomeniaRemoteStoreContext $State $null))){return}
    $script:CallSheetState.Jobs.Remove('Sessions')
    $read=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Computer')
    if($null -eq $read){Fail-DomeniaCallSheetSessions -Message 'Résultat WTS absent.' -State $State;return}
    $script:CallSheetState.Sessions[[string]$State.ComputerKey]=[pscustomobject]@{View=(ConvertTo-DomeniaSessionView $read);ObservedUtc=(ConvertTo-DomeniaUtcDate (Get-DomeniaMember $read 'ObservedUtc' $null));Failure=''}
    Update-DomeniaCallSheet -Force
}

function Fail-DomeniaCallSheetSessions {
    param([string]$Message,$State)
    if(-not (Test-DomeniaCallSheetCallback $State)){return}
    $script:CallSheetState.Jobs.Remove('Sessions')
    $script:CallSheetState.Sessions[[string]$State.ComputerKey]=[pscustomobject]@{View=$null;ObservedUtc=(ConvertTo-DomeniaUtcDate ([string]$State.RemoteStartedUtc));Failure=[string]$Message}
    Update-DomeniaCallSheet -Force
}

function Start-DomeniaCallSheetTriage {
    # One click: the quick inventory of the workstation of the triage (ComputerInventory, the pinned body of Assistance
    # poste), committed under its GUID then read back. Processor, memory, disks, processes, start and pending restart
    # come from it with its date.
    $sheet=$script:CallSheetState
    if($null -eq $sheet){return}
    $target=$null
    foreach($candidate in @($sheet.Targets)){if([string]$candidate.Key -ceq [string]$sheet.TriageComputer){$target=$candidate;break}}
    if($null -eq $target){$target=Get-DomeniaCallSheetSelectedTarget}
    if($null -eq $target){Set-Status 'Aucun poste associé à trier.' 'WARN';return}
    if(Test-DomeniaCallSheetJobRunning 'Triage'){return}
    $computer=Assert-DomeniaComputerTarget -Computer ([string]$target.Computer)
    try{$state=New-DomeniaCallSheetCollectionState -Target $target -ResultKind 'ClassicInventory' -RequestKey 'inventory-rapide' -PublishHandler 'Complete-DomeniaCallSheetTriage' -PublishErrorHandler 'Fail-DomeniaCallSheetTriage'}
    catch{$sheet.Notes[[string]$target.Key]=('Tri impossible : '+$_.Exception.Message);Update-DomeniaCallSheet -Force;return}
    $sheet.TriageComputer=[string]$target.Key
    $sheet.Notes[[string]$target.Key]=''
    # Same budget as the quick inventory of Assistance poste: the worker stops by itself before the task delay.
    $payload=[pscustomobject]@{Computer=$computer;Deep=$false;BudgetMs=55000;MaxSoftwareKeys=250;PreferWinrm=[bool](Get-CfgValue 'Inventory' 'PreferWinrm' $false)}
    $job=Start-UiTask -Name ('Fiche dʼappel : tri du poste '+$computer) -OperationId 'ComputerInventory' -Code (Get-DomeniaInventoryWorkerCode) -Payload $payload -CallbackState $state -ReplaceKey 'callsheet-triage' -TimeoutSeconds 110 -TaskClass 'Explicit' -StatusText ('Inventaire rapide de '+$computer+' en arrière-plan…') -SuccessHandler 'Complete-DomeniaClassicCollected' -ErrorHandler 'Fail-DomeniaClassicCollected'
    if($job){$sheet.Jobs['Triage']=[string]$job}
    Update-DomeniaCallSheet -Force
}

function Complete-DomeniaCallSheetTriage {
    # Publish handler of the committed inventory (Complete-DomeniaRemoteDetailStored): a SQLite read-back only.
    param($Result,$State)
    if((-not (Test-DomeniaCallSheetCallback $State)) -or (-not (Test-DomeniaRemoteStoreContext $State $null))){return}
    $script:CallSheetState.Jobs.Remove('Triage')
    if([string](Get-DomeniaMemberValue $Result 'DataSource') -cne 'SQLite'){return}
    $script:CallSheetState.Triage[[string]$State.ComputerKey]=[pscustomobject]@{Inventory=$Result;Failure='';FailureUtc=$null}
    $script:CallSheetState.Notes[[string]$State.ComputerKey]=('Inventaire rapide de '+[string]$State.Computer+' enregistré le '+(Format-DomeniaCallSheetDate (Get-DomeniaMember $Result 'SourceCompletedUtc' $null))+'.')
    Update-DomeniaCallSheet -Force
}

function Fail-DomeniaCallSheetTriage {
    param([string]$Message,$State)
    if(-not (Test-DomeniaCallSheetCallback $State)){return}
    $script:CallSheetState.Jobs.Remove('Triage')
    $key=[string]$State.ComputerKey
    $previous=$script:CallSheetState.Triage[$key]
    $inventory=$null
    if($null -ne $previous){$inventory=$previous.Inventory}
    $script:CallSheetState.Triage[$key]=[pscustomobject]@{Inventory=$inventory;Failure=[string]$Message;FailureUtc=[datetime]::UtcNow}
    $script:CallSheetState.Notes[$key]=('Inventaire rapide de '+[string]$State.Computer+' non confirmé : '+(ConvertTo-DomeniaFlatText ([string]$Message) 240))
    Update-DomeniaCallSheet -Force
}

function Request-DomeniaCallSheetStoredInventory {
    # One local read (LocalIndexRead, no network) of the last inventory stored for the workstation of the triage.
    param($Sheet,$Target)
    if(($null -eq $Sheet) -or ($null -eq $Target) -or (-not [string]$Target.Key)){return}
    if($Sheet.StoredRequested.ContainsKey([string]$Target.Key)){return}
    $Sheet.StoredRequested[[string]$Target.Key]=$true
    if((-not [string]$Target.Guid) -or (-not [string]$Target.Dn)){return}
    try{
        $state=New-DomeniaCallSheetCollectionState -Target $Target -ResultKind 'ClassicInventory' -RequestKey 'inventory-cache'
        [void](Request-DomeniaStoreRead -Context $state.StoreContext -Query ([pscustomobject]@{Kind='Detail';Guids=@([string]$Target.Guid);ResultKind='ClassicInventory';Offset=0;Limit=20}) -SuccessHandler 'Complete-DomeniaCallSheetStoredInventory' -ErrorHandler 'Fail-DomeniaCallSheetStoredInventory' -CallbackState $state)
    }catch{$Sheet.Notes[[string]$Target.Key]=('Inventaire enregistré non relu : '+$_.Exception.Message)}
}

function Complete-DomeniaCallSheetStoredInventory {
    param($Result,$State)
    if((-not (Test-DomeniaCallSheetCallback $State)) -or (-not (Test-DomeniaRemoteStoreContext $State $null))){return}
    if(([bool]$Result.Busy) -or ([bool]$Result.Missing) -or ([string]$Result.DataSource -cne 'SQLite') -or ([string]$Result.StoreId -cne [string]$State.StoreContext.StoreId)){return}
    $details=@(@($Result.Details)|Where-Object{($null -ne $_) -and ([string]$_.Guid -ieq [string]$State.StoreGuid) -and ([string]$_.ResultKind -ceq 'ClassicInventory')})
    $saved=@($details|Where-Object{($null -ne $_.Data) -and ([string]$_.LastSuccessAtUtc)}|Sort-Object {[string]$_.LastSuccessAtUtc} -Descending|Select-Object -First 1)
    $last=@($details|Sort-Object {[string]$_.LastAttemptAtUtc} -Descending|Select-Object -First 1)
    $inventory=$null;$failure='';$failureUtc=$null
    if($saved.Count){
        $inventory=$saved[0].Data
        $inventory|Add-Member -NotePropertyName DataSource -NotePropertyValue 'SQLite' -Force
        $inventory|Add-Member -NotePropertyName SourceCompletedUtc -NotePropertyValue ([string]$saved[0].LastSuccessAtUtc) -Force
    }
    if(($last.Count) -and ([string]$last[0].Status -eq 'Error')){
        $attempt=ConvertTo-DomeniaUtcDate ([string]$last[0].LastAttemptAtUtc)
        $success=$null
        if($saved.Count){$success=ConvertTo-DomeniaUtcDate ([string]$saved[0].LastSuccessAtUtc)}
        if(($null -ne $attempt) -and (($null -eq $success) -or ($attempt -gt $success))){$failure=[string]$last[0].Error;if(-not $failure){$failure='Lecture non confirmée.'};$failureUtc=$attempt}
    }
    $key=[string]$State.ComputerKey
    $current=$script:CallSheetState.Triage[$key]
    # A late local read never replaces a newer inventory read from this sheet.
    if(($null -ne $current) -and ($null -ne $current.Inventory)){
        $own=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $current.Inventory 'SourceCompletedUtc' $null)
        $stored=$null
        if($null -ne $inventory){$stored=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $inventory 'SourceCompletedUtc' $null)}
        if(($null -ne $own) -and (($null -eq $stored) -or ($own -ge $stored))){return}
    }
    if(($null -eq $inventory) -and (-not $failure)){$script:CallSheetState.Notes[$key]='Aucun inventaire enregistré pour ce poste dans la base locale.';Update-DomeniaCallSheet -Force;return}
    $script:CallSheetState.Triage[$key]=[pscustomobject]@{Inventory=$inventory;Failure=$failure;FailureUtc=$failureUtc}
    Update-DomeniaCallSheet -Force
}

function Fail-DomeniaCallSheetStoredInventory {
    param([string]$Message,$State)
    if(-not (Test-DomeniaCallSheetCallback $State)){return}
    $script:CallSheetState.Notes[[string]$State.ComputerKey]=('Inventaire enregistré non relu : '+[string]$Message)
    Update-DomeniaCallSheet -Force
}

function Open-DomeniaCallSheetComputer {
    # The fiche of the chosen workstation (explicit gesture): by its DN when known, else looked up by its name.
    $target=Get-DomeniaCallSheetSelectedTarget
    if($null -eq $target){Set-Status 'Aucun poste associé à ouvrir.' 'WARN';return}
    if([string]$target.Dn){Open-AdObject -Dn ([string]$target.Dn) -Type 'Machine';return}
    Start-OpenLinkedObject -Type 'Machine' -Identity ([string]$target.Computer)
}

function Open-DomeniaCallSheetRightsComparison {
    # « Comparer les droits avec… » opens the comparison view of the fiche when this version delivers it.
    if($null -eq (Get-DomeniaControl 'TabUserAccessDiff')){Set-Status 'Comparaison des droits indisponible dans cette version.' 'WARN';return}
    Select-DomeniaWorkspace -Workspace 'WsObject' -Inner 'DetailTabs' -Tab 'TabUserAccessDiff'
}

function Start-DomeniaCallSheetReceiptRefresh {
    # The receipts are re-read from the local disk by the receipt store (ReceiptStore), as from Outils > Fiabilité.
    if((Test-DomeniaReceiptStoreBusy)){Set-Status 'Lecture des reçus ou écriture déjà en cours : la fiche dʼappel suivra son résultat.';return}
    $script:ReceiptRefreshNeeded=$true
    Start-DomeniaReceiptRefresh
}

function Copy-DomeniaCallSheetTicket {
    # Plain text for a ticket, built from the template and the sheet on display, masked by the secret rule of the journal.
    Update-DomeniaCallSheet -Force
    $sheet=$script:CallSheetState
    if(($null -eq $sheet) -or ($null -eq $sheet.Ticket) -or (-not [string]$sheet.Ticket.Text)){Set-Status 'Ouvrez dʼabord la fiche dʼun utilisateur : rien à copier.' 'WARN';return}
    Set-ClipboardSafe ([string]$sheet.Ticket.Text)
    $text='Fiche dʼappel copiée pour le ticket ('+[string]([string]$sheet.Ticket.Text).Length+' caractères, aucun secret).'
    if([bool]$sheet.Ticket.Masked){$text+=' Une valeur ressemblant à un secret a été masquée.'}
    if([bool]$sheet.Ticket.Truncated){$text+=' Texte tronqué à sa longueur maximale.'}
    Set-Status $text
}
