# Sign-in and accounts views (lot X03): short read-only reveal of a typed secret and diagnostic panel of the sign-in
# window. No network call, no credential object kept, nothing written to the disk.
$script:DomeniaSecretPeeks=@{}

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
