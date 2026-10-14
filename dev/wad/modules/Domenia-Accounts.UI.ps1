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
