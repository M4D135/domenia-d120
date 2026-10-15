# Workstation assistance (programme of 8 October 2026, lot X04): the five views of Assistance poste and the former tab
# names they absorb, the fixed header, the association line, the AD account card, the restart prepared in the page
# with the open sessions read first, the program run panel, the in-page confirmation of GPUpdate, the services of the
# workstation and the « opérations à vérifier » pill. The authorisation of an intervention is the one control of X03
# (UX-16, Guard.UI) at the top of Intervenir; the run panel only states it. Presentation and coordination only: the decisions are the rules
# of Domenia-Assist.Model.ps1; network work runs in pinned workers started on an explicit click, and every answer is
# checked against the session epoch and the selection that asked for it. Nothing here reads or sends by itself.

$script:DomeniaAssist=$null

function Initialize-DomeniaAssist {
    # Wires the controls of the lot once the main window exists. Nothing is read or sent here.
    if($null -ne $script:DomeniaAssist){return}
    $script:DomeniaAssist=[pscustomobject]@{Restart=$null;Run=$null;Tool=$null;Services=$null;ServiceRequest=$null;PresenceAt=''}
    $clicks=[ordered]@{
        BtnCompHeaderRdp={Invoke-ComputerTool 'RDP'}
        BtnCompHeaderC={Invoke-ComputerTool 'C'}
        BtnCompHeaderPing={Invoke-ComputerTool 'Ping'}
        BtnCompHeaderUser={Open-LinkedUserFromMachine}
        BtnCompOpenDiag={Select-DomeniaWorkspace -Workspace 'WsComputer' -Inner 'ComputerTabs' -Tab 'TabComputerChecks';Start-ComputerDiagnostics}
        BtnCompRestartSend={Submit-DomeniaComputerRestart}
        BtnCompRestartCancel={Close-DomeniaComputerRestartPanel;Set-Status 'Redémarrage abandonné : rien nʼa été envoyé au poste.' 'INFO'}
        BtnCompRunStart={Submit-DomeniaRunProgram}
        BtnCompRunCancel={Close-DomeniaRunProgramPanel}
        BtnCompServicesRead={Start-DomeniaComputerServicesRead}
        BtnCompServiceStart={Request-DomeniaComputerServiceControl -Action 'Start'}
        BtnCompServiceRestart={Request-DomeniaComputerServiceControl -Action 'Restart'}
        BtnPendingOperations={[void](Invoke-DomeniaCapabilityRoute -Route 'TabGuard')}
    }
    foreach($name in @($clicks.Keys)){$control=Get-DomeniaControl $name;if($null -ne $control){$control.Add_Click($clicks[$name])}}
    foreach($name in @('RbCompRestartDelayed','RbCompRestartNow')){$control=Get-DomeniaControl $name;if($null -ne $control){$control.Add_Checked({Update-DomeniaComputerRestartChoice})}}
    foreach($name in @('RbCompRunSystem','RbCompRunUser')){$control=Get-DomeniaControl $name;if($null -ne $control){$control.Add_Checked({Update-DomeniaRunProgramMode})}}
    $filter=Get-DomeniaControl 'ChkCompServicesAutoStopped'
    if($null -ne $filter){$filter.Add_Checked({Update-DomeniaComputerServicesView});$filter.Add_Unchecked({Update-DomeniaComputerServicesView})}
    $text=Get-DomeniaControl 'TxtCompServicesFilter'
    if($null -ne $text){$text.Add_TextChanged({Update-DomeniaComputerServicesView})}
    $grid=Get-DomeniaControl 'DgCompServices'
    if($null -ne $grid){$grid.Add_SelectionChanged({param($sender,$eventArgs) if($sender -eq $eventArgs.OriginalSource){Update-DomeniaComputerServiceButtons}})}
    # The header and the association line follow every writer of the fiche fields (fiche, presence, Live, Relations):
    # the former fields stay the shared place where those paths write.
    $presence=Get-DomeniaControl 'TxtCompPresence'
    if($null -ne $presence){$presence.Add_TextChanged({Update-DomeniaComputerHeaderPresence})}
    foreach($name in @('TxtCompLinkedUser','TxtCompLinkSource','TxtCompLinkWhen')){$control=Get-DomeniaControl $name;if($null -ne $control){$control.Add_TextChanged({Update-DomeniaComputerLinkLine})}}
    # UX-21: Logiciels is an inner tab of Détails; opening it shows the inventory already read, as before.
    # SP-16: the account of the workstation operations is said again whenever its line comes into sight (Intervenir
    # selected, Assistance poste shown again after an account change elsewhere).
    $account=Get-DomeniaControl 'LblCompOperationAccount'
    if($null -ne $account){$account.Add_IsVisibleChanged({param($sender,$eventArgs) if([bool]$eventArgs.NewValue){Update-DomeniaComputerOperationAccount}})}
    $details=Get-DomeniaControl 'ComputerDetailTabs'
    if($null -ne $details){$details.Add_SelectionChanged({param($sender,$eventArgs) if($sender -ne $eventArgs.OriginalSource){return};try{if(([string]$sender.SelectedItem.Name) -eq 'TabSoftware'){Show-DomeniaSoftwareFromInventory}}catch{}})}
    Update-DomeniaPendingOperationsPill
}

function Get-DomeniaAssistText {
    param([string]$Name)
    $control=Get-DomeniaControl $Name
    if($null -eq $control){return ''}
    try{return [string]$control.Text}catch{return ''}
}

function Set-DomeniaAssistVisible {
    param([string]$Name,[bool]$Visible)
    $control=Get-DomeniaControl $Name
    if($null -eq $control){return}
    if($Visible){$control.Visibility=[Windows.Visibility]::Visible}else{$control.Visibility=[Windows.Visibility]::Collapsed}
}

function Test-DomeniaAssistSelectedMachine {
    return (($null -ne $script:SelectedObject) -and ([string]$script:SelectedObject.Type -eq 'Machine'))
}

function New-DomeniaAssistRequest {
    # The identity a prepared action keeps: answered later, it applies only to the same session and selection.
    param([string]$Computer)
    return [pscustomobject]@{Computer=$Computer;Epoch=[long]$script:SessionEpoch;Generation=[long]$script:SelectedObjectGeneration;DN=[string]$script:SelectedObject.DN}
}

function Test-DomeniaAssistRequestCurrent {
    param($Request)
    if(($null -eq $Request) -or (-not (Test-DomeniaAssistSelectedMachine))){return $false}
    if([long]$Request.Epoch -ne [long]$script:SessionEpoch){return $false}
    if([long]$Request.Generation -ne [long]$script:SelectedObjectGeneration){return $false}
    return ([string]$Request.DN -ieq [string]$script:SelectedObject.DN)
}

function Show-DomeniaAssistSection {
    # Brings a part of a view into sight once WPF has laid it out (a section of a view just selected has no size yet).
    param([string]$Name)
    $control=Get-DomeniaControl $Name
    if($null -eq $control){return}
    try{[void]$control.Dispatcher.BeginInvoke([Action]({$control.BringIntoView()}.GetNewClosure()),[Windows.Threading.DispatcherPriority]::Loaded)}catch{}
}

# ---------------------------------------------------------------- UX-21 five views
function Select-DomeniaComputerView {
    # A destination inside Assistance poste, a former tab name included (menus, widget links, shortcuts). The
    # workspace itself is chosen by Select-DomeniaWorkspace. Returns $false for a name that is not a view.
    param([AllowEmptyString()][string]$Tab)
    $route=Resolve-DomeniaComputerViewRoute -Tab $Tab
    if(-not [bool]$route.Known){return $false}
    $tabs=Get-DomeniaControl 'ComputerTabs';$view=Get-DomeniaControl ([string]$route.View)
    if(($null -eq $tabs) -or ($null -eq $view)){return $false}
    $tabs.SelectedItem=$view
    if(([string]$route.Inner) -and ([string]$route.Sub)){
        $inner=Get-DomeniaControl ([string]$route.Inner);$sub=Get-DomeniaControl ([string]$route.Sub)
        if(($null -ne $inner) -and ($null -ne $sub) -and ($sub.Visibility -eq [Windows.Visibility]::Visible)){$inner.SelectedItem=$sub}
    }
    if([string]$route.Section){Show-DomeniaAssistSection -Name ([string]$route.Section)}
    if([string]$route.View -eq 'TabComputerAdmin'){Update-DomeniaComputerOperationAccount}
    return $true
}

# ---------------------------------------------------------------- DS-08 fixed header
function Update-DomeniaComputerHeaderPresence {
    # TextChanged of TxtCompPresence: the pill follows the state and its colour. A new state written without its
    # observation (result list, memory, fiche without probe) has no known time, so the former time is dropped; the
    # writers that publish an observation give its time right after (Set-DomeniaComputerHeaderPresenceTime).
    if($null -eq $script:DomeniaAssist){return}
    $script:DomeniaAssist.PresenceAt=''
    Update-DomeniaComputerHeader
}

function Set-DomeniaComputerHeaderPresenceTime {
    # The time of the pill is the time of the presence observation just published for the selected workstation
    # (Publish-DomeniaCommittedPresence, Live), not the time a text changed: a second « Tester la réponse » with the
    # same answer writes the same text, raises no TextChanged, and must still show the time of this last test.
    param($Observation)
    if($null -eq $script:DomeniaAssist){return}
    $script:DomeniaAssist.PresenceAt=[string](Get-DomeniaPresenceObservationTime -Observation $Observation)
    Update-DomeniaComputerHeader
}

function Set-DomeniaAssistTone {
    # Theme colours of a pill or a badge: background, border and the text or dot brush follow the theme in use.
    param($Border,$Glyph,[string]$Tone)
    if($null -eq $Border){return}
    $edge='BorderColor';$ink='MutedColor';$fill='TileBg'
    switch($Tone){
        'Online' {$edge='StatusSuccess';$ink='StatusSuccess'}
        'Offline' {$edge='StatusError';$ink='StatusError'}
        'Error' {$edge='StatusWarning';$ink='StatusWarning'}
        'Pending' {$edge='AccentColor';$ink='AccentColor'}
        'Declare' {$edge='AccentColor';$ink='AccentText';$fill='AccentSoft'}
        'Observe' {$edge='StatusSuccess';$ink='TextColor'}
        'Contradictoire' {$edge='StatusWarning';$ink='TextColor'}
    }
    $Border.SetResourceReference([Windows.Controls.Border]::BackgroundProperty,$fill)
    $Border.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty,$edge)
    if($null -eq $Glyph){return}
    if($Glyph -is [Windows.Shapes.Shape]){$Glyph.SetResourceReference([Windows.Shapes.Shape]::FillProperty,$ink)}
    elseif($Glyph -is [Windows.Controls.TextBlock]){$Glyph.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,$ink)}
}

function Update-DomeniaComputerHeader {
    # DS-08: the fixed header, from the fiche fields and the session memory only (no read, no probe).
    if(($null -eq $script:Ctrl) -or ($null -eq $script:DomeniaAssist)){return}
    $machine=Test-DomeniaAssistSelectedMachine
    $computer='';$link=$null;$inventory=''
    if($machine){
        $computer=Get-CurrentSelectedComputerName
        try{$link=Get-ExistingLinkForComputer -Computer $computer}catch{$link=$null}
        if(($script:InventoryCompletedAt -is [datetime]) -and ((Normalize-LinkComputer ([string]$script:InventoryComputer)) -ieq $computer)){$inventory=Get-DomeniaInventoryAgeLabel -CompletedAt $script:InventoryCompletedAt}
    }
    $summary=Get-DomeniaLinkSummaryText -Link $link
    $name=Get-DomeniaAssistText 'TxtCompName';if(-not $name){$name=$computer}
    $presence=Get-DomeniaAssistText 'TxtCompPresence'
    # FI-16 / DS-15: a state taken from the result list no longer ends with « (cache) »; its row says it is remembered
    # (PresenceCached), and the pill keeps saying « (mémoire) » for it, never a time.
    if(($presence) -and (-not $presence.EndsWith('(cache)')) -and (-not [string]$script:DomeniaAssist.PresenceAt) -and ($machine)){
        $row=$null;try{$row=Get-DomeniaSelectedGridRow}catch{$row=$null}
        if(($null -ne $row) -and ([string]$row.DN -ieq [string]$script:SelectedObject.DN) -and ([string]$row.PresenceCached -eq '1')){$presence+=' (cache)'}
    }
    $view=Get-DomeniaComputerHeaderView -Name $name -OperatingSystem (Get-DomeniaAssistText 'TxtCompOs') -Version (Get-DomeniaAssistText 'TxtCompOsVersion') -Presence $presence -PresenceCheckedAt ([string]$script:DomeniaAssist.PresenceAt) -UserDisplay ([string]$summary.User) -UserLogin ([string]$summary.Login) -InventoryLabel $inventory
    [void](Set-DomeniaControlText 'LblCompHeaderName' ([string]$view.Name))
    [void](Set-DomeniaControlText 'LblCompHeaderSystem' ([string]$view.SystemText))
    [void](Set-DomeniaControlText 'LblCompHeaderPresence' ([string]$view.Presence.Label))
    [void](Set-DomeniaControlText 'LblCompHeaderInventory' ([string]$view.InventoryText))
    $pill=Get-DomeniaControl 'UxCompPresencePill'
    if($null -ne $pill){
        $dot=$null;try{$dot=$pill.Child.Children[0]}catch{$dot=$null}
        Set-DomeniaAssistTone -Border $pill -Glyph $dot -Tone ([string]$view.Presence.Tone)
        $pill.ToolTip=[string]$view.Presence.Help
        [Windows.Automation.AutomationProperties]::SetHelpText($pill,[string]$view.Presence.Help)
    }
    [void](Set-DomeniaControlText 'LblCompHeaderUser' ([string]$view.UserText))
    $user=Get-DomeniaControl 'BtnCompHeaderUser'
    if($null -ne $user){$user.ToolTip=[string]$view.UserHelp}
    Set-DomeniaAssistVisible 'BtnCompHeaderUser' ([bool]$view.HasUser)
    Set-DomeniaAssistVisible 'LblCompHeaderNoUser' (-not [bool]$view.HasUser)
}

function Update-DomeniaComputerAssistView {
    # Called when a workstation fiche is filled: header, association line, account card and operations account.
    param($Uac=$null)
    if($null -eq $script:DomeniaAssist){return}
    Update-DomeniaComputerAccountCard -Uac $Uac
    Update-DomeniaComputerOperationAccount
    Update-DomeniaComputerLinkLine
}

# ---------------------------------------------------------------- UI-17 association line
function Update-DomeniaComputerLinkLine {
    # UI-17: the association on one line, from the local memory only (no read, no probe), then the header.
    if(($null -eq $script:Ctrl) -or ($null -eq $script:DomeniaAssist)){return}
    $computer='';$link=$null;$probing=$false
    if(Test-DomeniaAssistSelectedMachine){$computer=Get-CurrentSelectedComputerName}
    if($computer){
        try{$link=Get-ExistingLinkForComputer -Computer $computer}catch{$link=$null}
        if($null -eq $link){try{$probing=($null -ne (Get-DomeniaRunningComputerUserProbe -Computer $computer))}catch{$probing=$false}}
    }
    $summary=Get-DomeniaLinkSummaryText -Link $link -Probing:$probing
    [void](Set-DomeniaControlText 'LblCompLinkSummary' ([string]$summary.Text))
    $line=Get-DomeniaControl 'LblCompLinkSummary';if($null -ne $line){$line.ToolTip=[string]$summary.Detail}
    [void](Set-DomeniaControlText 'LblCompLinkBadge' ([string]$summary.BadgeLabel))
    $badge=Get-DomeniaControl 'UxCompLinkBadge'
    if($null -ne $badge){
        Set-DomeniaAssistTone -Border $badge -Glyph (Get-DomeniaControl 'LblCompLinkBadge') -Tone ([string]$summary.Badge)
        $badge.ToolTip=[string]$summary.BadgeRule
        $badge.BorderThickness=[Windows.Thickness]::new(1)
    }
    Set-DomeniaAssistVisible 'UxCompLinkBadge' ([bool]$summary.HasLink)
    $open=Get-DomeniaControl 'BtnOpenLinkedUser';if($null -ne $open){$open.IsEnabled=[bool]$summary.HasLink}
    Update-DomeniaComputerHeader
}

# ---------------------------------------------------------------- UI-07 account card and operations account
function Update-DomeniaComputerAccountCard {
    # UI-07: one account button, chosen from userAccountControl as read with the fiche.
    param($Uac=$null)
    $action=Get-DomeniaComputerAccountAction -Uac $Uac
    Set-DomeniaAssistVisible 'BtnCompEnable' ([bool]$action.ShowEnable)
    Set-DomeniaAssistVisible 'BtnCompDisable' ([bool]$action.ShowDisable)
    [void](Set-DomeniaControlText 'LblCompAccountState' ([string]$action.Text))
}

function Update-DomeniaComputerOperationAccount {
    # SP-16: the account used by Ouvrir le disque C and the consoles is said before the click, in the same words as the
    # « Compte poste » pill of the header (UX-15, Get-DomeniaMachineAccountInUse for the open workstation).
    $computer='';try{$open=Get-DomeniaOpenWorkstationTarget;if($null -ne $open){$computer=[string]$open.Computer}}catch{$computer=''}
    try{[void](Set-DomeniaControlText 'LblCompOperationAccount' (Get-DomeniaMachineOperationAccountText -Target $computer))}catch{}
}

function Update-DomeniaComputerAssistPermissions {
    # The remote writes of the panels follow the same switch as GPUpdate and Redémarrer (Apply-CurrentPermissionUi).
    if($null -eq $script:DomeniaAssist){return}
    Update-DomeniaComputerRestartChoice
    Update-DomeniaComputerServiceButtons
    $start=Get-DomeniaControl 'BtnCompRunStart'
    if($null -ne $start){$start.IsEnabled=((-not (Test-DomeniaAssistWriteBlocked)) -and (-not (Test-DomeniaControlIsBusy -Name 'BtnCompRunStart')))}
    # GPUpdate travels by WinRM only: with WinRM forbidden by the configuration the button says why it is unavailable.
    if(-not (Test-DomeniaAssistWinRmAllowed)){
        $gpupdate=Get-DomeniaControl 'BtnCompGpUpdate'
        if($null -ne $gpupdate){$gpupdate.IsEnabled=$false;$gpupdate.ToolTip='Indisponible : lʼactualisation des stratégies passe par WinRM, désactivé par la configuration (Remote.UseWinRM).'}
    }
}

function Test-DomeniaAssistWinRmAllowed {
    # Remote.UseWinRM, the switch every WinRM use honours (CIM fallback, diagnostics, GPUpdate, delayed restart).
    try{return [bool](Get-CfgValue 'Remote' 'UseWinRM' $true)}catch{return $true}
}

function Test-DomeniaAssistWriteBlocked {
    # Read-only mode, an AD write being verified, or the selection only known from the local base.
    if(([bool]$script:ReadOnlyMode) -or ([bool]$script:DemoMode)){return $true}
    if((-not [string]::IsNullOrWhiteSpace([string]$script:ActiveWriteTaskId)) -or ([string]$script:WriteState -in @('Unknown','UnknownPending'))){return $true}
    try{if((Get-DomeniaSelectionCachePolicy).Offline){return $true}}catch{}
    return $false
}

# ---------------------------------------------------------------- SE-08 restart prepared in the page
function Request-DomeniaComputerRestart {
    # Called by Invoke-ComputerTool after its write guards. Opens the restart panel of Intervenir and reads the open
    # sessions of this workstation (SessionsList, read only, the same read as « Lire les sessions »). Nothing is sent
    # to the workstation before the confirmation of the page.
    param([Parameter(Mandatory=$true)][string]$Computer)
    Initialize-DomeniaAssist
    $delay=Get-DomeniaRestartDelaySeconds (Get-CfgValue 'Restart' 'DefaultDelaySeconds' 300)
    $request=New-DomeniaAssistRequest -Computer $Computer
    $request|Add-Member -NotePropertyName Delay -NotePropertyValue $delay
    $request|Add-Member -NotePropertyName Sessions -NotePropertyValue $null
    $request|Add-Member -NotePropertyName Plan -NotePropertyValue $null
    $script:DomeniaAssist.Restart=$request
    # Asked from another page (context menu of Rechercher), the panel opens where the operator can see it.
    Select-DomeniaWorkspace -Workspace 'WsComputer' -Inner 'ComputerTabs' -Tab 'TabComputerAdmin'
    $minutes=[int][Math]::Ceiling($delay/60.0)
    [void](Set-DomeniaControlText 'LblCompRestartTitle' ('Redémarrer ' + $Computer))
    [void](Set-DomeniaControlText 'LblCompRestartSessions' 'Lecture des sessions ouvertes…')
    [void](Set-DomeniaControlText 'LblCompRestartSessionLines' '')
    Set-DomeniaAssistVisible 'LblCompRestartSessionLines' $false
    # The delayed restart (default) travels by WinRM. With WinRM forbidden by the configuration it is shown unavailable
    # with its reason, and « Maintenant » is never chosen for the operator: the send button waits for an explicit choice.
    $winRm=Test-DomeniaAssistWinRmAllowed
    $immediate=Get-DomeniaControl 'RbCompRestartNow';if($null -ne $immediate){$immediate.IsChecked=$false}
    $delayed=Get-DomeniaControl 'RbCompRestartDelayed'
    if($null -ne $delayed){
        $label='Dans ' + $minutes + ' min avec message à lʼutilisateur'
        if($winRm){$delayed.ToolTip=[Windows.Automation.AutomationProperties]::GetHelpText($delayed)}
        else{$label+=' (indisponible : WinRM désactivé)';$delayed.ToolTip='Indisponible : le redémarrage différé passe par WinRM, désactivé par la configuration (Remote.UseWinRM). Seul « Maintenant » reste possible.'}
        $delayed.Content=$label;$delayed.IsEnabled=$winRm;$delayed.IsChecked=$winRm
    }
    [void](Set-DomeniaControlText 'TxtCompRestartMessage' (Get-DomeniaRestartDefaultMessage -DelaySeconds $delay))
    Set-DomeniaAssistVisible 'UxCompRestartPanel' $true
    Update-DomeniaComputerRestartChoice
    Show-DomeniaAssistSection -Name 'UxCompRestartPanel'
    # The sessions read needs the name of the fiche; without it the panel says so instead of waiting for a read.
    $sessionTarget='';try{$sessionTarget=[string](Get-DomeniaSelectedMachineName)}catch{$sessionTarget=''}
    if(-not $sessionTarget){Update-DomeniaRestartSessions -Failure 'nom du poste absent de la fiche lue.';return}
    try{Start-DomeniaSessionsRead}
    catch{Update-DomeniaRestartSessions -Failure $_.Exception.Message}
}

function Update-DomeniaRestartSessions {
    # Called by the sessions read (Complete-/Fail-DomeniaSessionsRead) with what the page shows of it. Only the read
    # of the workstation whose restart is being prepared, in the same session and selection, fills the panel.
    param($View=$null,[AllowEmptyString()][string]$Failure='',$State=$null)
    if(($null -eq $script:DomeniaAssist) -or ($null -eq $script:DomeniaAssist.Restart)){return}
    $request=$script:DomeniaAssist.Restart
    if($null -ne $State){
        if([long](Get-DomeniaMember $State 'Epoch' -1) -ne [long]$request.Epoch){return}
        if([long](Get-DomeniaMember $State 'Generation' -1) -ne [long]$request.Generation){return}
        if([string](Get-DomeniaMember $State 'DN' '') -ine [string]$request.DN){return}
    }
    if((-not $Failure) -and ($null -eq $View)){$Failure='aucun résultat de lecture.'}
    $summary=Get-DomeniaRestartSessionSummary -View $View -Failure $Failure
    $request.Sessions=$summary
    [void](Set-DomeniaControlText 'LblCompRestartSessions' ([string]$summary.Text))
    $lines=@($summary.Lines)
    [void](Set-DomeniaControlText 'LblCompRestartSessionLines' ((@($lines|ForEach-Object{[string][char]0x2022+' '+[string]$_})) -join "`n"))
    Set-DomeniaAssistVisible 'LblCompRestartSessionLines' ($lines.Count -gt 0)
    Update-DomeniaComputerRestartChoice
}

function Update-DomeniaComputerRestartChoice {
    # Label of the send button and message field follow the choice; sending waits for the sessions read.
    $request=$null;if($null -ne $script:DomeniaAssist){$request=$script:DomeniaAssist.Restart}
    $send=Get-DomeniaControl 'BtnCompRestartSend'
    if(($null -eq $send) -or ($null -eq $request)){return}
    $now=$false;$choice=Get-DomeniaControl 'RbCompRestartNow';if($null -ne $choice){$now=[bool]$choice.IsChecked}
    $later=$false;$option=Get-DomeniaControl 'RbCompRestartDelayed';if($null -ne $option){$later=(([bool]$option.IsChecked) -and ([bool]$option.IsEnabled))}
    $message=Get-DomeniaControl 'TxtCompRestartMessage';if($null -ne $message){$message.IsEnabled=$later}
    if($now){$send.Content='Redémarrer maintenant…'}
    elseif($later){$send.Content=('Redémarrer dans ' + [int][Math]::Ceiling([int]$request.Delay/60.0) + ' min…')}
    else{$send.Content='Choisissez quand redémarrer'}
    $send.IsEnabled=((($now) -or ($later)) -and ($null -ne $request.Sessions) -and (-not (Test-DomeniaAssistWriteBlocked)) -and (-not (Test-DomeniaControlIsBusy -Name 'BtnCompRestartSend')))
}

function Submit-DomeniaComputerRestart {
    # The choice of the panel becomes a plan, shown in the in-page confirmation with the sessions read just before.
    $request=$null;if($null -ne $script:DomeniaAssist){$request=$script:DomeniaAssist.Restart}
    if($null -eq $request){return}
    try{
        Assert-DomeniaRemoteWriteAllowed -Operation 'Redémarrage du poste'
        Assert-WriteAllowed
        if(-not (Test-DomeniaAssistRequestCurrent $request)){Close-DomeniaComputerRestartPanel;throw 'Le poste sélectionné a changé : redémarrage non préparé.'}
        $mode='';$choice=Get-DomeniaControl 'RbCompRestartNow';$option=Get-DomeniaControl 'RbCompRestartDelayed'
        if(($null -ne $choice) -and ([bool]$choice.IsChecked)){$mode='Now'}
        elseif(($null -ne $option) -and ([bool]$option.IsChecked)){$mode='Delayed'}
        $plan=Get-DomeniaRestartPlan -Computer ([string]$request.Computer) -Mode $mode -DelaySeconds ([int]$request.Delay) -Message (Get-DomeniaAssistText 'TxtCompRestartMessage') -WinRmAllowed (Test-DomeniaAssistWinRmAllowed)
        if(-not [bool]$plan.Valid){Set-Status ([string]$plan.Reason) 'WARN';return}
        $request.Plan=$plan
        $sessions=$request.Sessions
        $message=[string]$sessions.Text
        $lines=@($sessions.Lines)
        if($lines.Count){$message+="`n"+((@($lines|ForEach-Object{[string][char]0x2022+' '+[string]$_})) -join "`n")}
        [void](Request-DomeniaInlineConfirmation -Title ([string]$plan.Title) -Message $message -Target ('poste:' + ([string]$request.Computer).ToLowerInvariant()) -ConfirmText ([string]$plan.ConfirmText) -CancelText 'Annuler' -OnConfirm {Confirm-DomeniaComputerRestart} -OnCancel {Set-Status 'Redémarrage annulé : rien nʼa été envoyé au poste.' 'INFO'} -Risk 'Danger' -Changes @([string]$plan.Summary))
    }catch{[void](Show-DomeniaOperationError -Operation 'Redémarrage du poste' -ErrorRecordOrException $_)}
}

function Confirm-DomeniaComputerRestart {
    # Continuation of the in-page confirmation: the confirmed plan leaves once, for the same workstation only.
    $request=$null;if($null -ne $script:DomeniaAssist){$request=$script:DomeniaAssist.Restart}
    if(($null -eq $request) -or ($null -eq $request.Plan)){Set-Status 'Aucun redémarrage préparé : rien nʼa été envoyé.' 'WARN';return}
    if(-not (Test-DomeniaAssistRequestCurrent $request)){Close-DomeniaComputerRestartPanel;Set-Status 'Le poste sélectionné a changé : redémarrage non envoyé.' 'WARN';return}
    $plan=$request.Plan;$request.Plan=$null
    Invoke-ComputerTool -Tool 'Restart' -Restart $plan
}

function Close-DomeniaComputerRestartPanel {
    # Closes the panel; with -Computer, only when it is the panel of that workstation.
    param([AllowEmptyString()][string]$Computer='')
    if($null -eq $script:DomeniaAssist){return}
    $request=$script:DomeniaAssist.Restart
    if(($Computer) -and ($null -ne $request) -and ([string]$request.Computer -ine $Computer)){return}
    $script:DomeniaAssist.Restart=$null
    Set-DomeniaAssistVisible 'UxCompRestartPanel' $false
}

# ---------------------------------------------------------------- GPUpdate confirmed in the page
function Request-DomeniaComputerToolConfirmation {
    # Called by Invoke-ComputerTool after its write guards: the confirmation of the page replaces the former window.
    param([ValidateSet('GpUpdate')][string]$Tool,[Parameter(Mandatory=$true)][string]$Computer)
    Initialize-DomeniaAssist
    $request=New-DomeniaAssistRequest -Computer $Computer
    $request|Add-Member -NotePropertyName Tool -NotePropertyValue $Tool
    $script:DomeniaAssist.Tool=$request
    [void](Request-DomeniaInlineConfirmation -Title ('Actualiser les stratégies de ' + $Computer + ' ?') -Message 'Le poste applique de nouveau les stratégies de groupe (gpupdate /force), sans redémarrer ni fermer de session. La demande part une seule fois, par WinRM ; un poste qui la refuse ne reçoit rien.' -Target ('poste:' + $Computer.ToLowerInvariant()) -ConfirmText 'Actualiser les stratégies' -CancelText 'Annuler' -OnConfirm {Confirm-DomeniaComputerToolRequest} -OnCancel {Set-Status 'Actualisation des stratégies annulée : rien nʼa été envoyé.' 'INFO'})
}

function Confirm-DomeniaComputerToolRequest {
    $request=$null;if($null -ne $script:DomeniaAssist){$request=$script:DomeniaAssist.Tool;$script:DomeniaAssist.Tool=$null}
    if($null -eq $request){return}
    if(-not (Test-DomeniaAssistRequestCurrent $request)){Set-Status 'Le poste sélectionné a changé : rien nʼa été envoyé.' 'WARN';return}
    Invoke-ComputerTool -Tool ([string]$request.Tool) -Confirmed
}

# ---------------------------------------------------------------- UI-26 run a program, in the page
function Show-DomeniaRunProgramPanel {
    # Opens the run panel of Intervenir for the selected workstation. Nothing is created before « Lancer » and the
    # confirmation of the page.
    try{
        Initialize-DomeniaAssist
        Assert-DomeniaRemoteWriteAllowed -Operation 'Exécution dʼun programme sur le poste'
        $computer=Assert-DomeniaComputerTarget -Computer (Get-CurrentSelectedComputerName)
        $previous=$script:DomeniaAssist.Run
        $request=New-DomeniaAssistRequest -Computer $computer
        $request|Add-Member -NotePropertyName Plan -NotePropertyValue $null
        $script:DomeniaAssist.Run=$request
        Select-DomeniaWorkspace -Workspace 'WsComputer' -Inner 'ComputerTabs' -Tab 'TabComputerAdmin'
        [void](Set-DomeniaControlText 'LblCompRunTitle' ('Exécuter un programme sur ' + $computer))
        if(($null -eq $previous) -or ([string]$previous.Computer -ine $computer) -or (-not (Get-DomeniaAssistText 'TxtCompRunUser'))){
            # The session account is prefilled with the associated user, in the DOMAINE\identifiant form.
            $user=''
            try{$link=Get-ExistingLinkForComputer -Computer $computer;if($null -ne $link){$user=Normalize-LinkUser ([string]$link.UserLogin)}}catch{$user=''}
            if(($user) -and ($user -notmatch '[\\@]') -and ([string]$script:Conn.Netbios)){$user=[string]$script:Conn.Netbios + '\' + $user}
            [void](Set-DomeniaControlText 'TxtCompRunUser' $user)
        }
        [void](Set-DomeniaControlText 'LblCompRunState' '')
        Set-DomeniaAssistVisible 'LblCompRunState' $false
        Update-DomeniaRunProgramMode
        Update-DomeniaRunProgramConsent
        Set-DomeniaAssistVisible 'UxCompRunPanel' $true
        Update-DomeniaComputerAssistPermissions
        Show-DomeniaAssistSection -Name 'UxCompRunPanel'
        $field=Get-DomeniaControl 'TxtCompRunCommand';if($null -ne $field){try{[void]$field.Focus()}catch{}}
    }catch{[void](Show-DomeniaOperationError -Operation 'Exécuter un programme' -ErrorRecordOrException $_)}
}

function Update-DomeniaRunProgramMode {
    $user=$false;$choice=Get-DomeniaControl 'RbCompRunUser';if($null -ne $choice){$user=[bool]$choice.IsChecked}
    $account=Get-DomeniaControl 'TxtCompRunUser';if($null -ne $account){$account.IsEnabled=$user}
}

function Test-DomeniaRunProgramConsent {
    # The creation of a task needs the 5-minute intervention consent for this very workstation (Guard.UI).
    param([string]$Computer)
    $consent=$script:ArtifactConsent
    if(($null -eq $consent) -or ([long]$consent.Epoch -ne [long]$script:SessionEpoch) -or ([datetime]$consent.Expires -le [datetime]::UtcNow)){return $false}
    foreach($alias in @(@([string]$consent.Target)+@($consent.Aliases))){if((Normalize-LinkComputer ([string]$alias)) -ieq (Normalize-LinkComputer $Computer)){return $true}}
    return $false
}

function Update-DomeniaRunProgramConsent {
    # The state of the one authorisation control (UX-16, top of Intervenir), said in the panel: the panel never grants
    # it itself. Called when the panel opens and by Update-DomeniaInterventionPill (grant, Retirer, countdown).
    $request=$null;if($null -ne $script:DomeniaAssist){$request=$script:DomeniaAssist.Run}
    if($null -eq $request){return}
    $granted=Test-DomeniaRunProgramConsent -Computer ([string]$request.Computer)
    $text='Ce lancement crée une tâche sur le poste : il exige lʼautorisation dʼintervention de 5 minutes pour ce poste, donnée en haut de la vue Intervenir par « Autoriser une intervention (5 min) ».'
    if($granted){$text='Autorisation dʼintervention active pour ce poste jusquʼà ' + ([datetime]$script:ArtifactConsent.Expires).ToLocalTime().ToString('HH:mm',[Globalization.CultureInfo]::InvariantCulture) + '. « Retirer », en haut de la vue Intervenir, la reprend.'}
    [void](Set-DomeniaControlText 'LblCompRunConsent' $text)
}

function Submit-DomeniaRunProgram {
    # The fields become a plan, refused with its reason in the panel, or shown in the in-page confirmation.
    $request=$null;if($null -ne $script:DomeniaAssist){$request=$script:DomeniaAssist.Run}
    if($null -eq $request){return}
    try{
        Assert-DomeniaRemoteWriteAllowed -Operation 'Exécution dʼun programme sur le poste'
        Assert-WriteAllowed
        if(-not (Test-DomeniaAssistRequestCurrent $request)){Close-DomeniaRunProgramPanel;throw 'Le poste sélectionné a changé : rien nʼa été lancé.'}
        $mode='System';$choice=Get-DomeniaControl 'RbCompRunUser';if(($null -ne $choice) -and ([bool]$choice.IsChecked)){$mode='Interactive'}
        $elevated=$true;$box=Get-DomeniaControl 'ChkCompRunElevated';if($null -ne $box){$elevated=[bool]$box.IsChecked}
        $plan=Get-DomeniaRunProgramPlan -Computer ([string]$request.Computer) -Mode $mode -Command (Get-DomeniaAssistText 'TxtCompRunCommand') -Arguments (Get-DomeniaAssistText 'TxtCompRunArguments') -RunUser (Get-DomeniaAssistText 'TxtCompRunUser') -Elevated $elevated
        if(-not [bool]$plan.Valid){[void](Set-DomeniaControlText 'LblCompRunState' ([string]$plan.Reason));Set-DomeniaAssistVisible 'LblCompRunState' $true;return}
        Update-DomeniaRunProgramConsent
        if(-not (Test-DomeniaRunProgramConsent -Computer ([string]$request.Computer))){
            # The one authorisation control is brought into sight; nothing is granted from here.
            [void](Set-DomeniaControlText 'LblCompRunState' 'Accordez dʼabord lʼautorisation dʼintervention de 5 minutes pour ce poste, en haut de la vue Intervenir (« Autoriser une intervention (5 min) ») : sans elle, aucune tâche nʼest créée.');Set-DomeniaAssistVisible 'LblCompRunState' $true
            Show-DomeniaAssistSection -Name 'BtnCompInterventionGrant'
            return
        }
        Set-DomeniaAssistVisible 'LblCompRunState' $false
        $request.Plan=$plan
        [void](Request-DomeniaInlineConfirmation -Title ([string]$plan.Title) -Message ([string]$plan.Summary) -Target ('poste:' + ([string]$request.Computer).ToLowerInvariant()) -ConfirmText 'Lancer' -CancelText 'Annuler' -OnConfirm {Confirm-DomeniaRunProgram} -OnCancel {Set-Status 'Lancement annulé : aucune tâche créée sur le poste.' 'INFO'} -Risk 'Danger')
    }catch{[void](Show-DomeniaOperationError -Operation 'Exécuter un programme' -ErrorRecordOrException $_)}
}

function Confirm-DomeniaRunProgram {
    $request=$null;if($null -ne $script:DomeniaAssist){$request=$script:DomeniaAssist.Run}
    if(($null -eq $request) -or ($null -eq $request.Plan)){Set-Status 'Aucun lancement préparé : rien nʼa été créé.' 'WARN';return}
    if(-not (Test-DomeniaAssistRequestCurrent $request)){Close-DomeniaRunProgramPanel;Set-Status 'Le poste sélectionné a changé : rien nʼa été lancé.' 'WARN';return}
    $plan=$request.Plan;$request.Plan=$null
    try{
        Assert-DomeniaRemoteWriteAllowed -Operation 'Exécution dʼun programme sur le poste'
        Start-DomeniaRimotteRun -Settings ([pscustomobject]@{Computer=[string]$plan.Computer;Command=[string]$plan.Command;Arguments=[string]$plan.Arguments;Mode=[string]$plan.Mode;RunUser=[string]$plan.RunUser;Elevated=[bool]$plan.Elevated})
    }catch{[void](Show-DomeniaOperationError -Operation 'Exécuter un programme' -ErrorRecordOrException $_)}
}

function Close-DomeniaRunProgramPanel {
    # Closes the panel; with -Computer, only when it is the panel of that workstation. The command and its arguments
    # are not kept for another workstation.
    param([AllowEmptyString()][string]$Computer='')
    if($null -eq $script:DomeniaAssist){return}
    $request=$script:DomeniaAssist.Run
    if(($Computer) -and ($null -ne $request) -and ([string]$request.Computer -ine $Computer)){return}
    $script:DomeniaAssist.Run=$null
    foreach($name in @('TxtCompRunCommand','TxtCompRunArguments')){[void](Set-DomeniaControlText $name '')}
    Set-DomeniaAssistVisible 'UxCompRunPanel' $false
}

# ---------------------------------------------------------------- UX-38 services of the workstation
function Start-DomeniaComputerServicesRead {
    # Read on the click only: Win32_Service through the WmiQuery operation (one workstation, read only).
    try{
        Initialize-DomeniaAssist
        $computer=Get-DomeniaWmiComputer
        if(-not $computer){return}
        Assert-DomeniaWmiReadQuery -ClassName 'Win32_Service' -Namespace 'root\cimv2' -Where '' -Limit 500
        [void](Set-DomeniaControlText 'LblCompServicesState' ('Lecture des services de ' + $computer + '…'))
        $state=New-DomeniaClassicCollectionState -Computer $computer -ResultKind 'WmiServices' -RequestKey 'win32_service' -PublishHandler 'Complete-DomeniaComputerServicesUi' -PublishErrorHandler 'Fail-DomeniaComputerServicesUi'
        Start-UiTask -Name ('Services de ' + $computer) -OperationId 'WmiQuery' -Code (Get-DomeniaWmiQueryWorkerCode) -Payload ([pscustomobject]@{Computer=$computer;Namespace='root\cimv2';ClassName='Win32_Service';Where='';Limit=500;MsiClassNames=@(Get-DomeniaMsiProviderClassNames)}) -CallbackState $state -ReplaceKey 'services' -DisableControls @('BtnCompServicesRead') -TimeoutSeconds 90 -TaskClass 'Explicit' -StatusText ('Lecture des services de ' + $computer + ' en arrière-plan...') -SuccessHandler 'Complete-DomeniaClassicCollected' -ErrorHandler 'Fail-DomeniaClassicCollected' | Out-Null
    }catch{[void](Show-DomeniaOperationError -Operation 'Lecture des services' -ErrorRecordOrException $_)}
}

function Complete-DomeniaComputerServicesUi {
    param($Result,$State)
    if(-not (Test-DomeniaClassicResultCurrent $Result $State)){return}
    $effective=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Instances')
    if($null -eq $effective){Fail-DomeniaComputerServicesUi -Message 'résultat vide.' -State $State;return}
    $rows=@(ConvertTo-DomeniaServiceRows -Instances @($effective.Instances))
    $readAt=''
    try{$at=ConvertTo-DomeniaUtcDate ([string](Get-DomeniaMember $effective 'SourceCompletedUtc' ''));if($null -ne $at){$readAt=$at.ToLocalTime().ToString('HH:mm',[Globalization.CultureInfo]::InvariantCulture)}}catch{$readAt=''}
    $script:DomeniaAssist.Services=[pscustomobject]@{Computer=[string]$State.Computer;DN=[string]$State.StoreDn;Epoch=[long]$script:SessionEpoch;Generation=[long]$script:SelectedObjectGeneration;Rows=$rows;ReadAt=$readAt;Capped=([int](Get-DomeniaMember $effective 'InstanceCount' 0) -ge 500);Redacted=[int](Get-DomeniaMember $effective 'RedactedSecretRows' 0)}
    Update-DomeniaComputerServicesView
}

function Fail-DomeniaComputerServicesUi {
    param($Message,$State)
    if(-not (Test-DomeniaClassicResultCurrent -Result $null -State $State -ContextOnly)){return}
    $detail=([string]$Message).Trim();if(-not $detail){$detail='erreur inconnue.'}
    [void](Set-DomeniaControlText 'LblCompServicesState' ('Services non lus : ' + $detail + ' La liste affichée nʼest pas mise à jour.'))
    Set-Status ('Lecture des services : ' + $detail) 'WARN'
}

function Test-DomeniaComputerServicesCurrent {
    $list=$null;if($null -ne $script:DomeniaAssist){$list=$script:DomeniaAssist.Services}
    if(($null -eq $list) -or (-not (Test-DomeniaAssistSelectedMachine))){return $false}
    return (([long]$list.Epoch -eq [long]$script:SessionEpoch) -and ([long]$list.Generation -eq [long]$script:SelectedObjectGeneration) -and ([string]$list.DN -ieq [string]$script:SelectedObject.DN))
}

function Update-DomeniaComputerServicesView {
    # Local filter of the list read on the click; nothing is read again.
    if($null -eq $script:DomeniaAssist){return}
    if(-not (Test-DomeniaComputerServicesCurrent)){[void](Set-DomeniaItemsSource -Name 'DgCompServices' -Rows @());Update-DomeniaComputerServiceButtons;return}
    $list=$script:DomeniaAssist.Services
    $only=$false;$box=Get-DomeniaControl 'ChkCompServicesAutoStopped';if($null -ne $box){$only=[bool]$box.IsChecked}
    $text=Get-DomeniaAssistText 'TxtCompServicesFilter'
    $shown=@(@($list.Rows)|Where-Object{Test-DomeniaServiceRowMatch -Row $_ -AutoStoppedOnly $only -Text $text})
    [void](Set-DomeniaItemsSource -Name 'DgCompServices' -Rows $shown)
    $summary=Get-DomeniaServiceListSummary -Rows @($list.Rows) -Shown $shown.Count -ReadAt ([string]$list.ReadAt) -Computer ([string]$list.Computer)
    if([bool]$list.Capped){$summary+=' Liste limitée aux 500 premiers services.'}
    if([int]$list.Redacted -gt 0){$summary+=' '+[int]$list.Redacted+' valeur(s) assimilée(s) à un secret écartée(s).'}
    [void](Set-DomeniaControlText 'LblCompServicesState' $summary)
    Update-DomeniaComputerServiceButtons
}

function Update-DomeniaComputerServiceButtons {
    $row=$null;$grid=Get-DomeniaControl 'DgCompServices';if($null -ne $grid){$row=$grid.SelectedItem}
    $usable=((Test-DomeniaComputerServicesCurrent) -and ($null -ne $row) -and (-not (Test-DomeniaAssistWriteBlocked)))
    $start=Get-DomeniaControl 'BtnCompServiceStart'
    if($null -ne $start){$start.IsEnabled=(($usable) -and ([bool](Get-DomeniaMember $row 'CanStart' $false)) -and (-not (Test-DomeniaControlIsBusy -Name 'BtnCompServiceStart')))}
    $restart=Get-DomeniaControl 'BtnCompServiceRestart'
    if($null -ne $restart){$restart.IsEnabled=(($usable) -and ([bool](Get-DomeniaMember $row 'CanRestart' $false)) -and (-not (Test-DomeniaControlIsBusy -Name 'BtnCompServiceRestart')))}
}

function Request-DomeniaComputerServiceControl {
    # Start or restart the selected service: a plan from the list just read, confirmed in the page, sent once.
    param([ValidateSet('Start','Restart')][string]$Action)
    try{
        Assert-DomeniaRemoteWriteAllowed -Operation 'Commande de service'
        Assert-WriteAllowed
        if(-not (Test-DomeniaComputerServicesCurrent)){throw 'Relisez les services de ce poste avant dʼagir sur lʼun dʼeux.'}
        $list=$script:DomeniaAssist.Services
        $row=$null;$grid=Get-DomeniaControl 'DgCompServices';if($null -ne $grid){$row=$grid.SelectedItem}
        $plan=Get-DomeniaServiceControlPlan -Computer ([string]$list.Computer) -Action $Action -Row $row
        if(-not [bool]$plan.Valid){Set-Status ([string]$plan.Reason) 'WARN';return}
        $request=New-DomeniaAssistRequest -Computer ([string]$list.Computer)
        $request|Add-Member -NotePropertyName Plan -NotePropertyValue $plan
        $script:DomeniaAssist.ServiceRequest=$request
        [void](Request-DomeniaInlineConfirmation -Title ([string]$plan.Title) -Message ([string]$plan.Summary) -Target ('poste:' + ([string]$plan.Computer).ToLowerInvariant()) -ConfirmText ([string]$plan.ConfirmText) -CancelText 'Annuler' -OnConfirm {Confirm-DomeniaComputerServiceControl} -OnCancel {Set-Status 'Commande de service annulée : rien nʼa été envoyé au poste.' 'INFO'} -Risk ([string]$plan.Risk))
    }catch{[void](Show-DomeniaOperationError -Operation 'Commande de service' -ErrorRecordOrException $_)}
}

function Confirm-DomeniaComputerServiceControl {
    $request=$null;if($null -ne $script:DomeniaAssist){$request=$script:DomeniaAssist.ServiceRequest;$script:DomeniaAssist.ServiceRequest=$null}
    if($null -eq $request){return}
    if(-not (Test-DomeniaAssistRequestCurrent $request)){Set-Status 'Le poste sélectionné a changé : rien nʼa été envoyé.' 'WARN';return}
    try{
        Assert-DomeniaRemoteWriteAllowed -Operation 'Commande de service'
        Assert-WriteAllowed
        $plan=$request.Plan
        $computer=Assert-DomeniaComputerTarget -Computer ([string]$plan.Computer)
        $correlation=[guid]::NewGuid().ToString('N')
        $payload=[pscustomobject]@{Computer=$computer;Target=$computer;DN=$computer;Service=[string]$plan.Name;Action=[string]$plan.Action;CorrelationId=$correlation;SingleRequest=$true}
        $state=[pscustomobject]@{Computer=$computer;Service=[string]$plan.Name;DisplayName=[string]$plan.DisplayName;Action=[string]$plan.Action;Epoch=[long]$request.Epoch;Generation=[long]$request.Generation;DN=[string]$request.DN}
        $verb='Démarrage';if([string]$plan.Action -eq 'Restart'){$verb='Redémarrage'}
        Start-UiTask -Name ($verb + ' du service ' + [string]$plan.Name + ' sur ' + $computer) -OperationId 'ComputerServiceControl' -Code (Get-DomeniaServiceControlWorkerCode) -Payload $payload -CallbackState $state -ReplaceKey ('service:' + $computer + ':' + [string]$plan.Name) -DisableControls @('BtnCompServiceStart','BtnCompServiceRestart') -TimeoutSeconds 90 -NonCancellable -StatusText ($verb + ' de « ' + [string]$plan.DisplayName + ' » sur ' + $computer + '...') -SuccessHandler 'Complete-DomeniaComputerServiceControlUi' -ErrorHandler 'Fail-DomeniaComputerServiceControlUi' -IsWrite -CorrelationId $correlation | Out-Null
    }catch{[void](Show-DomeniaOperationError -Operation 'Commande de service' -ErrorRecordOrException $_)}
}

function Complete-DomeniaComputerServiceControlUi {
    param($Result,$State)
    $effective=$Result;if(($Result -is [System.Array]) -and ($Result.Count -gt 0)){$effective=$Result[-1]}
    $message=[string](Get-DomeniaMember $effective 'Message' '')
    if(-not $message){$message='Commande de service envoyée à ' + [string]$State.Computer + '.'}
    $message+=(Get-DomeniaRemotePostconditionText -OperationId 'ComputerServiceControl' -Result $effective)
    Set-Status $message
    try{Add-DomeniaUiLog -Area 'Poste' -Text $message}catch{}
    # The row takes the state the worker has just read again, while the list still belongs to that selection.
    if((Test-DomeniaComputerServicesCurrent) -and ([long]$State.Generation -eq [long]$script:SelectedObjectGeneration) -and ([long]$State.Epoch -eq [long]$script:SessionEpoch)){
        $list=$script:DomeniaAssist.Services;$after=[string](Get-DomeniaMember $effective 'StateAfter' '')
        $updated=New-Object 'System.Collections.Generic.List[object]'
        foreach($row in @($list.Rows)){if([string]$row.Name -ieq [string]$State.Service){$updated.Add((Get-DomeniaServiceRowWithState -Row $row -State $after))}else{$updated.Add($row)}}
        $list.Rows=$updated.ToArray()
        Update-DomeniaComputerServicesView
    }
}

function Fail-DomeniaComputerServiceControlUi {
    param([string]$Message,$State)
    [void](Show-DomeniaOperationError -Operation ('Service « ' + [string]$State.DisplayName + ' » de ' + [string]$State.Computer) -ErrorRecordOrException ([string]$Message))
    Update-DomeniaComputerServiceButtons
}

# ---------------------------------------------------------------- UX-19 operations to check
function Update-DomeniaPendingOperationsPill {
    # Shown only while a durable receipt waits for a check; a click opens the receipts, nothing is replayed.
    $button=Get-DomeniaControl 'BtnPendingOperations'
    if($null -eq $button){return}
    $view=Get-DomeniaPendingOperationsView -Pending ([int]$script:ReceiptPending)
    if([bool]$view.Visible){$button.Content=[string]$view.Text;$button.Visibility=[Windows.Visibility]::Visible}
    else{$button.Visibility=[Windows.Visibility]::Collapsed}
}

# ---------------------------------------------------------------- selection change
function Reset-DomeniaComputerAssistViews {
    # Another selection: the prepared actions of the former workstation are withdrawn and its services list emptied.
    if($null -eq $script:DomeniaAssist){return}
    Close-DomeniaComputerRestartPanel
    Close-DomeniaRunProgramPanel
    $script:DomeniaAssist.Tool=$null;$script:DomeniaAssist.ServiceRequest=$null;$script:DomeniaAssist.Services=$null;$script:DomeniaAssist.PresenceAt=''
    [void](Set-DomeniaItemsSource -Name 'DgCompServices' -Rows @())
    [void](Set-DomeniaControlText 'LblCompServicesState' 'Services non lus. « Lire les services » interroge ce poste en lecture seule.')
    Update-DomeniaComputerServiceButtons
}
