# Demonstration mode presentation (D002, D003). Dot-sourced in the core scope by the closed loader.
# The mode is decided once after Load-AppConfig (contract C2: $script:DemoMode) and never changes in a session.

function Initialize-DomeniaDemoMode {
    # C2: called once by the main block right after Load-AppConfig. A second call keeps the first decision.
    if ([bool]$script:DemoModeFixed) { return [bool]$script:DemoMode }
    $enabled = Test-DomeniaDemoProviderEnabled -Value (Get-CfgValue 'Auth' 'DemoProvider' $false)
    $script:DemoMode = [bool]$enabled
    $script:DemoDirectory = $null
    if ($script:DemoMode) {
        $latency = 0
        try { $latency = [int](Get-CfgValue 'Demo' 'LatencyMs' 0) } catch { $latency = 0 }
        $script:DemoDirectory = New-DomeniaDemoDirectory -LatencyMs $latency
    }
    $script:DemoModeFixed = $true
    return [bool]$script:DemoMode
}

function Get-DomeniaDemoConfiguredIdentity {
    $identity = 'DEMO\demo.operateur'
    try { $identity = ([string](Get-CfgValue 'Demo' 'Identity' $identity)).Trim() } catch { }
    if (-not (Test-DomeniaDemoIdentity $identity)) { $identity = 'DEMO\demo.operateur' }
    return $identity
}

function Initialize-DomeniaDemoLoginPresentation {
    # Login in demonstration: fixed banner, demo identity, no password field, no Windows session, nothing
    # remembered in HKCU. The production handlers stay attached; Start-DomeniaFastLoginAttempt branches on DemoMode.
    param([Parameter(Mandatory=$true)]$Ui)
    $banner = Get-DomeniaDemoBannerText
    try { $Ui.Window.Title = 'Domenia · ' + $banner } catch { }
    try { $Ui.Error.Foreground = (Get-DomeniaBootStatusColor -Kind 'Warning') } catch { }
    $Ui.Error.Text = $banner + '. Identité de démonstration attendue (DEMO\nom), sans mot de passe.'
    try { [Windows.Automation.AutomationProperties]::SetName($Ui.Error,$banner) } catch { }
    $Ui.Login.Text = Get-DomeniaDemoConfiguredIdentity
    foreach ($name in @('Password','PasswordVisible','Reveal')) { try { $Ui[$name].IsEnabled = $false } catch { } }
    try { $Ui.Password.ToolTip = 'Aucun mot de passe en démonstration.' } catch { }
    try { $Ui.Remember.IsChecked = $false; $Ui.Remember.IsEnabled = $false } catch { }
    try { $Ui.Windows.Visibility = [Windows.Visibility]::Collapsed; $Ui.Windows.IsEnabled = $false } catch { }
    try { $Ui.Connect.Content = 'Entrer en démonstration' } catch { }
}

function Set-DomeniaDemoShellPresentation {
    # Permanent banner in the title and the session badge, writes locked (read-only box checked and disabled).
    $banner = Get-DomeniaDemoBannerText
    if ($null -ne $script:Window) {
        $script:BaseWindowTitle = 'Domenia 1.0 · ' + $banner
        try { $script:Window.Title = $script:BaseWindowTitle } catch { }
    }
    $label = Get-DomeniaControl -Name 'LblUxDomain'
    if ($null -ne $label) {
        $label.Text = $banner
        try { [Windows.Automation.AutomationProperties]::SetName($label,$banner) } catch { }
        try { $label.Foreground = (Get-DomeniaBootStatusColor -Kind 'Warning') } catch { }
    }
    $script:ReadOnlyMode = $true
    $readOnly = Get-DomeniaControl -Name 'ChkReadOnlyMode'
    if ($null -ne $readOnly) {
        $readOnly.IsChecked = $true
        $readOnly.IsEnabled = $false
        $readOnly.ToolTip = 'Écritures désactivées en démonstration.'
    }
    foreach($name in @('BtnParkVerify','BtnParkVerifyMenu','BtnSelectionPing','BtnSelectionConsole')){$button=Get-DomeniaControl $name;if($button){$button.IsEnabled=$false;$button.ToolTip='Relevé des postes indisponible en démonstration.'}}
    foreach($name in @('BtnStorageUsage','BtnStoragePurgePreview','BtnStoragePurge')){$button=Get-DomeniaControl $name;if($button){$button.IsEnabled=$false;$button.ToolTip='Entretien du stockage indisponible en demonstration.'}}
    Set-Status ($banner + ' : données fictives dans une base locale de démonstration séparée ; actions AD et outils poste désactivés.') 'WARN'
}
