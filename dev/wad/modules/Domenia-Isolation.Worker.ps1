# D016: bounded helper process for reads whose native provider ignores cancellation. Disabled by default
# (Features.IsolatedReads=false). One single-quoted here-string, ASCII body, pinned by SHA-256.
# The helper is an out-of-process PowerShell runspace: the request travels on its private pipe, never on the
# command line, and it never carries a credential object (Get-DomeniaIsolationDecision refuses them).
# Stopping or timing out kills the helper only: the GUI and every write (never isolated) are untouched.

function Get-DomeniaIsolatedReadWorkerCode {
    return @'
if ([string]::IsNullOrWhiteSpace([string]$Payload.Script)) { throw 'Lecture isolee sans corps verifie.' }
foreach ($name in @('Credential','MachineCredential','RemoteAdminCredential')) {
    if ($null -ne $Context.PSObject.Properties[$name] -and $null -ne $Context.$name) { throw 'Lecture isolee refusee : un compte explicite ne traverse pas la frontiere du processus.' }
}
$timeout = [Math]::Max(5,[Math]::Min(300,[int]$Payload.TimeoutSeconds))
$instance = $null; $remote = $null; $shell = $null
try {
    $instance = New-Object System.Management.Automation.Runspaces.PowerShellProcessInstance
    $remote = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateOutOfProcessRunspace($null,$instance)
    $remote.Open()
    $shell = [System.Management.Automation.PowerShell]::Create()
    $shell.Runspace = $remote
    [void]$shell.AddScript([string]$Payload.Script)
    [void]$shell.AddArgument([string]$Payload.ContextJson)
    [void]$shell.AddArgument([string]$Payload.RequestJson)
    $handle = $shell.BeginInvoke()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    # Short polling: a stop request of the engine interrupts this loop and the finally block kills the helper.
    while (-not $handle.IsCompleted) {
        if ($watch.Elapsed.TotalSeconds -gt $timeout) { throw ('Lecture isolee arretee apres ' + $timeout + ' s : processus auxiliaire termine, interface et ecritures non concernees.') }
        Start-Sleep -Milliseconds 100
    }
    $output = @($shell.EndInvoke($handle))
    if ($shell.Streams.Error.Count -gt 0) { throw ([string]$shell.Streams.Error[0]) }
    $text = [string]($output | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'Lecture isolee sans resultat.' }
    $parsed = ConvertFrom-Json $text
    foreach ($item in @($parsed)) { $item }
}
finally {
    try { if ($null -ne $instance -and $null -ne $instance.Process -and -not $instance.Process.HasExited) { $instance.Process.Kill() } } catch { }
    try { if ($null -ne $shell) { $shell.Dispose() } } catch { }
    try { if ($null -ne $remote) { $remote.Dispose() } } catch { }
    try { if ($null -ne $instance) { $instance.Dispose() } } catch { }
}
'@
}
