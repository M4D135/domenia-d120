# Startup foreground policy (D089). Dot-sourced in the core scope by the closed loader.
# Activation is requested only at the explicit launch (login window, then the startup monitor that prolongs it)
# and at the switch from login to the main window. One attempt per moment, never Topmost, never after a task.

function Get-DomeniaActivationState {
    if ($null -eq $script:DomeniaActivationState) {
        $script:DomeniaActivationState = [pscustomobject]@{Attempts=@{};Refused=@{};UserSwitchedAway=$false;Log=(New-Object System.Collections.ArrayList)}
    }
    return $script:DomeniaActivationState
}

function ConvertTo-DomeniaActivationTrigger {
    # Startup moments mapped to the triggers of Get-DomeniaActivationDecision (Domenia-Shell.Model.ps1).
    param([string]$Trigger)
    switch ([string]$Trigger) {
        'Launch' { return 'ExplicitLaunch' }
        'StartupMonitor' { return 'ExplicitLaunch' }
        'LoginToMain' { return 'LoginToMain' }
        'TaskCompleted' { return 'TaskCompleted' }
        default { return 'Background' }
    }
}

function Register-DomeniaUserSwitchWatch {
    # A deactivation that the operator caused (Alt-Tab to another application) is remembered, so the next
    # startup moment respects it instead of taking the foreground back.
    param($Window)
    if ($null -eq $Window) { return }
    [void](Get-DomeniaActivationState)
    $Window.Add_Closing({ try { $script:DomeniaActivationClosing = $true } catch { } })
    $Window.Add_Deactivated({
        param($sender,$eventArgs)
        try {
            if ([bool]$script:DomeniaActivationClosing -or -not [bool]$sender.IsVisible) { return }
            # Checked once activation has settled: another window of this process is not a user switch.
            [void]$sender.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background,[Action]{
                try {
                    if ([bool]$script:DomeniaActivationClosing) { return }
                    if (-not (Test-DomeniaOwnWindowActive)) { (Get-DomeniaActivationState).UserSwitchedAway = $true }
                } catch { }
            })
        } catch { }
    })
    $script:DomeniaActivationClosing = $false
}

function Test-DomeniaOwnWindowActive {
    $candidates = New-Object System.Collections.ArrayList
    foreach ($w in @($script:StartupWindow,$script:Window)) { if ($null -ne $w) { [void]$candidates.Add($w) } }
    try { if ($null -ne $script:FastLoginUi -and $null -ne $script:FastLoginUi.Window) { [void]$candidates.Add($script:FastLoginUi.Window) } } catch { }
    try { if ($null -ne [System.Windows.Application]::Current) { foreach ($w in @([System.Windows.Application]::Current.Windows)) { [void]$candidates.Add($w) } } } catch { }
    foreach ($w in $candidates) { try { if ($w -is [System.Windows.Window] -and $w.IsActive) { return $true } } catch { } }
    return $false
}

function Write-DomeniaActivationLog {
    param([string]$Trigger,[string]$Result,[string]$Reason)
    $line = 'ACTIVATION Trigger=' + $Trigger + ' Resultat=' + $Result + ' Motif=' + $Reason
    $state = Get-DomeniaActivationState
    [void]$state.Log.Add($line)
    if ($Trigger -eq 'Launch') {
        try { Write-DomeniaFastLoginLog -Stage 'ACTIVATION' -Status 'OK' -Detail ('Trigger=' + $Trigger + ' Resultat=' + $Result) } catch { }
    }
    else {
        try { Write-AppLog $line 'INFO' } catch { }
    }
}

function Request-DomeniaWindowActivation {
    # One request, logged, never repeated: a refusal by Windows (foreground lock) is final and leaves the
    # taskbar signal to the system. Topmost is never set. Without the Shell rule, nothing is activated.
    param($Window,[Parameter(Mandatory=$true)][ValidateSet('Launch','StartupMonitor','LoginToMain','Relogin','TaskCompleted')][string]$Trigger)
    $state = Get-DomeniaActivationState
    $previous = 0
    if ($state.Attempts.ContainsKey($Trigger)) { $previous = [int]$state.Attempts[$Trigger] }
    $refused = $false
    if ($state.Refused.ContainsKey($Trigger)) { $refused = [bool]$state.Refused[$Trigger] }
    $rule = Get-Command -Name Get-DomeniaActivationDecision -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $rule) {
        Write-DomeniaActivationLog -Trigger $Trigger -Result 'NonDemande' -Reason 'Regle d activation absente.'
        return [pscustomobject]@{Trigger=$Trigger;Requested=$false;Activated=$false;Reason='Regle d activation absente.'}
    }
    $decision = Get-DomeniaActivationDecision -Trigger (ConvertTo-DomeniaActivationTrigger $Trigger) -PreviousAttempts $previous -UserSwitchedAway ([bool]$state.UserSwitchedAway) -PreviousRefused $refused
    if ($null -eq $Window -or -not [bool]$decision.Activate) {
        Write-DomeniaActivationLog -Trigger $Trigger -Result 'NonDemande' -Reason ([string]$decision.Reason)
        return [pscustomobject]@{Trigger=$Trigger;Requested=$false;Activated=$false;Reason=[string]$decision.Reason}
    }
    $state.Attempts[$Trigger] = $previous + 1
    $activated = $false
    try {
        # Window.Activate returns false when Windows refuses the foreground: that answer is kept as is.
        try { if ([bool]$Window.Topmost) { $Window.Topmost = $false } } catch { }
        $activated = [bool]$Window.Activate()
    } catch { $activated = $false }
    $state.Refused[$Trigger] = (-not $activated)
    $result = 'Refusee'
    if ($activated) { $result = 'Accordee' }
    Write-DomeniaActivationLog -Trigger $Trigger -Result $result -Reason ([string]$decision.Reason)
    return [pscustomobject]@{Trigger=$Trigger;Requested=$true;Activated=$activated;Reason=[string]$decision.Reason}
}

function Test-DomeniaUserSwitchedAway {
    return [bool](Get-DomeniaActivationState).UserSwitchedAway
}
