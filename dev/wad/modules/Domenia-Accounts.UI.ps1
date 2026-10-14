# Sign-in and accounts views (lot X03): short read-only reveal of a typed secret, diagnostic panel and layout of the
# sign-in window, trial of the workstation account. No network call of its own (the trial goes through Start-UiTask
# and the pinned LiveConsole worker), no credential object kept, nothing written to the disk.
$script:DomeniaSecretPeeks=@{}
$script:RemoteAccountTrial=$null
$script:RemoteTrialHint='Ouvrez un poste dans Assistance poste pour essayer le compte.'

function Show-DomeniaSecretPeek {
    # SE-16: shows the typed secret for a few seconds in a read-only TextBlock laid over its PasswordBox, then hides
    # it. The PasswordBox stays the only source of the secret: nothing is copied into an editable field, an undo
    # history or the clipboard, and the text is cleared when the overlay closes. A second click hides it at once.
    # The reveal needs the characters as a String for the TextBlock: that copy lives only while the overlay shows.
    param(
        [Parameter(Mandatory=$true)]$PasswordBox,
        [Parameter(Mandatory=$true)]$Overlay,
        [Parameter(Mandatory=$true)]$Display,
        $Button=$null,
        [Parameter(Mandatory=$true)][string]$Owner,
        [ValidateRange(1,30)][int]$Seconds=5,
        [string]$ShownContent='Masquer',
        [switch]$Standalone
    )
    if($null -eq $script:DomeniaSecretPeeks){$script:DomeniaSecretPeeks=@{}}
    $state=$null
    if($script:DomeniaSecretPeeks.ContainsKey($Owner)){$state=$script:DomeniaSecretPeeks[$Owner]}
    if(($null -ne $state) -and [bool]$state.Shown){Hide-DomeniaSecretPeek -Owner $Owner;return $false}
    if(-not [bool]$PasswordBox.IsEnabled){return $false}
    if($null -eq $state){
        $state=[pscustomobject]@{Owner=$Owner;Overlay=$null;Display=$null;Button=$null;ButtonContent=$null;Timer=$null;Shown=$false}
        $script:DomeniaSecretPeeks[$Owner]=$state
    }
    $state.Overlay=$Overlay;$state.Display=$Display;$state.Button=$Button
    if($null -eq $state.Timer){
        # FI-05: protected one-shot timer; it hides the secret even while the window is minimised.
        $state.Timer=New-DomeniaTimer -Owner $Owner -IntervalMs ($Seconds*1000) -Standalone:$Standalone -RunWhenHidden -Tag $Owner -Tick {param($sender,$eventArgs) Hide-DomeniaSecretPeek -Owner ([string]$sender.Tag)}
    }
    $Display.Text=[string]$PasswordBox.Password
    if([string]::IsNullOrEmpty([string]$Display.Text)){$Display.Text='';return $false}
    $Overlay.Visibility=[Windows.Visibility]::Visible
    if($null -ne $Button){$state.ButtonContent=$Button.Content;$Button.Content=$ShownContent}
    $state.Shown=$true
    $state.Timer.Stop();$state.Timer.Start()
    return $true
}

function Hide-DomeniaSecretPeek {
    # SE-16: closes a reveal (end of the delay, second click, typing, busy form or closed window) and clears its text.
    param([Parameter(Mandatory=$true)][string]$Owner)
    if(($null -eq $script:DomeniaSecretPeeks) -or (-not $script:DomeniaSecretPeeks.ContainsKey($Owner))){return}
    $state=$script:DomeniaSecretPeeks[$Owner]
    try{if($null -ne $state.Timer){$state.Timer.Stop()}}catch{}
    try{if($null -ne $state.Display){$state.Display.Text=''}}catch{}
    try{if($null -ne $state.Overlay){$state.Overlay.Visibility=[Windows.Visibility]::Collapsed}}catch{}
    try{if(($null -ne $state.Button) -and [bool]$state.Shown -and ($null -ne $state.ButtonContent)){$state.Button.Content=$state.ButtonContent}}catch{}
    $state.Shown=$false
}

function Show-DomeniaLoginDiagnosticPanel {
    # CD-10: the Debug sign-in mode is the standard window plus this live panel (stage and technical trace). The
    # trace is the same text that Copier le diagnostic copies; no password is ever added to it.
    param([Parameter(Mandatory=$true)]$Window)
    $panel=$Window.FindName('LoginDiagnosticBuffer')
    if($null -eq $panel){return $false}
    $panel.Visibility=[Windows.Visibility]::Visible
    $panel.IsHitTestVisible=$true
    $trace=$Window.FindName('TxtLoginTechnical')
    if($null -ne $trace){$trace.Focusable=$true}
    try{$Window.Title=[string]$Window.Title+' · diagnostic'}catch{}
    return $true
}

function Set-DomeniaLoginChoicePresentation {
    # UX-28: applies Get-DomeniaLoginChoice to the sign-in window: label, help and state of the Windows button, then
    # the Windows-first layout in a domain session or the form layout. Nothing is read or validated here.
    param([Parameter(Mandatory=$true)]$Ui,[Parameter(Mandatory=$true)]$Choice)
    $button=$Ui.Windows
    $button.Content=[string]$Choice.WindowsLabel
    [Windows.Automation.AutomationProperties]::SetName($button,[string]$Choice.WindowsLabel)
    if([string]$Choice.WindowsToolTip){
        $button.ToolTip=[string]$Choice.WindowsToolTip
        [Windows.Automation.AutomationProperties]::SetHelpText($button,[string]$Choice.WindowsToolTip)
    }
    $button.Visibility=if([bool]$Choice.Offered){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}
    $button.IsEnabled=[bool]$Choice.Available
    if($null -ne $Ui.OtherAccount){$Ui.OtherAccount.Content=[string]$Choice.OtherAccountLabel}
    Set-DomeniaLoginWindowsFirst -Ui $Ui -WindowsFirst ([bool]$Choice.WindowsFirst)
}

function Set-DomeniaLoginWindowsFirst {
    # UX-28: Windows-first layout (Continuer en tant que... on top as the default button, form and Se connecter
    # folded under Utiliser un autre compte) or form layout (Se connecter is the default button, the Windows
    # session below it). Only the presentation changes: no attempt starts from here.
    param([Parameter(Mandatory=$true)]$Ui,[bool]$WindowsFirst)
    $form=$Ui.Window.FindName('LoginFormScroll')
    $windows=$Ui.Windows;$connect=$Ui.Connect;$other=$Ui.OtherAccount
    if($WindowsFirst){
        if($null -ne $form){$form.Visibility=[Windows.Visibility]::Collapsed}
        $connect.IsDefault=$false;$connect.Visibility=[Windows.Visibility]::Collapsed
        if($null -ne $other){$other.Visibility=[Windows.Visibility]::Visible}
        [Windows.Controls.Grid]::SetRow($windows,0)
        $windows.Margin=[Windows.Thickness]::new(0,0,0,8)
        $run=$windows.TryFindResource('Run')
        if($null -ne $run){$windows.Style=$run}
        $windows.IsDefault=$true
    }else{
        if($null -ne $form){$form.Visibility=[Windows.Visibility]::Visible}
        if($null -ne $other){$other.Visibility=[Windows.Visibility]::Collapsed}
        $windows.IsDefault=$false
        [Windows.Controls.Grid]::SetRow($windows,2)
        $windows.Margin=[Windows.Thickness]::new(0,8,0,0)
        $windows.ClearValue([Windows.FrameworkElement]::StyleProperty)
        $connect.Visibility=[Windows.Visibility]::Visible;$connect.IsDefault=$true
    }
}

function Get-DomeniaMachineAccountInUse {
    # UX-15 / UI-27 / FO-19: the account the next workstation operation takes, in the order of the worker context:
    # local account accepted for this workstation (Set-DomeniaTargetCredentialContext), temporary workstation account
    # (Set-DomeniaRetryWorkerContext), account typed for the workstations, Postes account of the Comptes page, account
    # of the connection, Windows session (Get-WorkerContext). Read only: no lease is used or removed here.
    param([string]$Target='')
    $access=$script:AccessState
    $live=(($null -ne $access) -and ([long]$access.Epoch -eq [long]$script:SessionEpoch) -and ([string]$access.BaseDn -ieq [string]$script:Conn.BaseDn))
    if($live -and $Target){
        $key='RemoteLocal|'+(ConvertTo-DomeniaMachineKey $Target).ToUpperInvariant()
        if($access.Credentials.ContainsKey($key) -and (Test-DomeniaAccessLeaseUsable -Key $key)){return (Get-DomeniaMachineAccountLabel -Source 'TemporaryLocal' -Account ([string]$access.Credentials[$key].UserName))}
    }
    if($live -and $access.Credentials.ContainsKey('Remote') -and (Test-DomeniaAccessLeaseUsable -Key 'Remote')){return (Get-DomeniaMachineAccountLabel -Source 'Temporary' -Account ([string]$access.Credentials['Remote'].UserName))}
    if($null -ne $script:MachineCredential){return (Get-DomeniaMachineAccountLabel -Source 'Typed' -Account ([string]$script:MachineCredential.UserName))}
    if($null -ne $script:RemoteAdminCredential){return (Get-DomeniaMachineAccountLabel -Source 'Remote' -Account ([string]$script:RemoteAdminCredential.UserName))}
    if([bool]$script:Conn.UseCredential -and ($null -ne $script:Conn.Credential)){return (Get-DomeniaMachineAccountLabel -Source 'Connection' -Account ([string]$script:Conn.Credential.UserName))}
    return (Get-DomeniaMachineAccountLabel -Source 'Windows' -Account ([string]$script:ProcessIdentity))
}

function Get-DomeniaOpenWorkstationTarget {
    # FO-19 / UX-15: the workstation open in Assistance poste, never a list or a search result.
    $object=$script:SelectedObject
    if(($null -eq $object) -or ([string]$object.Type -ne 'Machine')){return $null}
    $computer=''
    try{$computer=[string](Get-DomeniaEntryFirstString $object.Entry 'dNSHostName')}catch{}
    if(-not $computer){try{$computer=[string](Get-DomeniaEntryFirstString $object.Entry 'name')}catch{}}
    if(-not $computer){$computer=[string]$object.Name}
    if(-not $computer){return $null}
    $guid='';try{$guid=[string]$object.Safety.Guid}catch{}
    return [pscustomobject]@{Computer=$computer;Dn=[string]$object.DN;Guid=$guid}
}

function Set-DomeniaRemoteTrialText {
    param([string]$Text)
    [void](Set-DomeniaControlText 'LblAccountRemoteTry' $Text)
}

function Update-DomeniaRemoteTrialUi {
    # FO-19: Essayer sur le poste sélectionné is greyed while no workstation is open or while a trial runs.
    $button=Get-DomeniaControl 'BtnAccountRemoteTry'
    if($null -eq $button){return}
    $target=Get-DomeniaOpenWorkstationTarget
    $running=(($null -ne $script:RemoteAccountTrial) -and (-not [bool]$script:RemoteAccountTrial.Done))
    $enabled=(($null -ne $target) -and (-not $running) -and (-not (Test-DomeniaControlIsBusy -Name 'BtnAccountRemoteTry')))
    if([bool]$button.IsEnabled -ne $enabled){$button.IsEnabled=$enabled}
    # The hint only fills an empty result line and leaves as soon as a workstation is open; a verdict stays.
    $label=Get-DomeniaControl 'LblAccountRemoteTry'
    if(($null -ne $label) -and (-not $running)){
        $text=[string]$label.Text
        if(($null -eq $target) -and (-not $text)){$label.Text=$script:RemoteTrialHint}
        elseif(($null -ne $target) -and ($text -ceq $script:RemoteTrialHint)){$label.Text=''}
    }
}

function Start-DomeniaRemoteAccountTrial {
    # FO-19: on an explicit click only, one light CIM/DCOM read (Win32_OperatingSystem.Caption) of the workstation
    # open in Assistance poste, with the account the workstation operations use. One target, no sweep, no ping, no
    # console or LDAP read, no intrusive fallback (the pinned LiveConsole operation never stages anything remotely).
    $target=Get-DomeniaOpenWorkstationTarget
    if($null -eq $target){Set-DomeniaRemoteTrialText 'Ouvrez dʼabord un poste dans Assistance poste.';Update-DomeniaRemoteTrialUi;return}
    if(($null -ne $script:RemoteAccountTrial) -and (-not [bool]$script:RemoteAccountTrial.Done)){return}
    $account=Get-DomeniaMachineAccountInUse -Target $target.Computer
    $state=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Epoch=[long]$script:SessionEpoch;Computer=[string]$target.Computer;Dn=[string]$target.Dn;Account=[string]$account.Long;Done=$false}
    $payload=[pscustomobject]@{Computer=[string]$target.Computer;Key=[string]$target.Dn;Guid=[string]$target.Guid;CollectPing=$false;ProbeUser=$false;Inventory=$false;ValidateConsoleIdentity=$false;AllowIdentityCache=$false;MethodSeconds=6;Probes=@(ConvertTo-DomeniaProbePayload -Ids @('os.caption'));AllowedClasses=@('Win32_OperatingSystem')}
    $script:RemoteAccountTrial=$state
    Set-DomeniaRemoteTrialText ('Essai en cours sur '+$state.Computer+' avec '+$state.Account+'…')
    try{
        [void](Start-UiTask -Name ('Essai du compte poste sur '+$state.Computer) -OperationId 'LiveConsole' -Code (Get-DomeniaLiveProbeCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaRemoteAccountTrial' -ErrorHandler 'Fail-DomeniaRemoteAccountTrial' -DisableControls @('BtnAccountRemoteTry') -TimeoutSeconds 30 -TaskClass 'Explicit')
    }catch{
        $state.Done=$true
        Set-DomeniaRemoteTrialText ('Essai non lancé : '+$_.Exception.Message)
    }
    Update-DomeniaRemoteTrialUi
}

function Test-DomeniaRemoteTrialStateCurrent {
    param($State)
    return (($null -ne $State) -and ([object]::ReferenceEquals($State,$script:RemoteAccountTrial)) -and ([long]$State.Epoch -eq [long]$script:SessionEpoch))
}

function Complete-DomeniaRemoteAccountTrial {
    param($Result,$State)
    if($null -ne $State){$State.Done=$true}
    if(-not (Test-DomeniaRemoteTrialStateCurrent $State)){return}
    try{
        $r=Get-DomeniaEffectiveWorkerResult $Result @('Outcome','Computer')
        if(($null -eq $r) -or ([string]$r.Computer -ine [string]$State.Computer)){throw 'Résultat absent ou provenant dʼun autre poste.'}
        $probe=$null;$probes=Get-DomeniaMember $r 'Probes' $null
        if($null -ne $probes){$probe=Get-DomeniaMember $probes 'os.caption' $null}
        $probeError='';$caption=''
        if($null -ne $probe){
            $probeError=[string](Get-DomeniaMember $probe 'Error' '')
            $first=@(Get-DomeniaMember $probe 'Instances' @())|Select-Object -First 1
            if($null -ne $first){$caption=[string](Get-DomeniaMember (Get-DomeniaMember $first 'Values' $null) 'Caption' '')}
        }elseif([string]$r.Outcome -eq 'NotRequested'){$probeError='Lecture du système non renvoyée par le poste.'}
        $errorText=if($probeError){$probeError}else{[string](Get-DomeniaMember $r 'Detail' '')}
        if((([string]$r.Outcome) -in @('NotRequested','Observed','NoConsole')) -and (-not $probeError)){$errorText=''}
        $category=''
        if($errorText){$category=[string](Get-DomeniaErrorDecision -Structured (Get-DomeniaStructuredError $errorText) -Text $errorText).Category}
        $verdict=Get-DomeniaRemoteAccessTrialVerdict -Outcome ([string]$r.Outcome) -ErrorText $errorText -Category $category -Computer $State.Computer -Account $State.Account -Caption $caption
        Set-DomeniaRemoteTrialText $verdict.Text
        Add-DomeniaUiLog -Area 'Comptes' -Text $verdict.Text
    }catch{Set-DomeniaRemoteTrialText ('Essai non exploitable : '+$_.Exception.Message)}
    Update-DomeniaRemoteTrialUi
}

function Fail-DomeniaRemoteAccountTrial {
    param($Message,$State)
    if($null -ne $State){$State.Done=$true}
    if(-not (Test-DomeniaRemoteTrialStateCurrent $State)){return}
    $text=[string]$Message
    $category=[string](Get-DomeniaErrorDecision -Structured (Get-DomeniaStructuredError $text) -Text $text).Category
    $verdict=Get-DomeniaRemoteAccessTrialVerdict -Outcome 'Unavailable' -ErrorText $text -Category $category -Computer $State.Computer -Account $State.Account
    Set-DomeniaRemoteTrialText $verdict.Text
    Add-DomeniaUiLog -Area 'Comptes' -Text $verdict.Text
    Update-DomeniaRemoteTrialUi
}
