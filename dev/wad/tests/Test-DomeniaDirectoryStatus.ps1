#requires -Version 5.1
# Directory status regression: production rules and task callback through inert UI ports.
# No WPF, AD, network, SQLite or background task is started. PS7 results do not qualify Windows UI.
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
foreach($name in @('Common.Model','Cache.Model','Engine.Model','Access.Model','Guard.Model','Shell.Model','Engine.UI')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$script:Checks=New-Object 'System.Collections.Generic.List[object]';$script:Assertions=0
function Expect([bool]$Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Case([string]$Name,[scriptblock]$Body){try{& $Body | Out-Null;$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=($_.Exception.Message+' @ '+$_.ScriptStackTrace)})}}
# The callback is unchanged. Only application/UI side effects are replaced by counters or forbidden ports.
function Apply-CurrentPermissionUi {param([switch]$StartupFastPath);$script:PermissionUpdates++;Expect ([bool]$StartupFastPath) 'Permission transition did not use the startup fast path'}
function Test-DomeniaSelectionLoadCurrent {return $true}
function Update-DomeniaSelectionReadUi {$script:SelectionUpdates++}
function Write-AppLog {param($Message,$Level);$script:Logs.Add([string]$Message)}
function Start-UiTask {throw 'Unexpected background task'}
function Invoke-DomeniaDbQuery {throw 'Unexpected SQLite read'}
function Update-Dashboard {throw 'Unexpected dashboard refresh'}
function Apply-DomeniaGuiElementPolicy {throw 'Unexpected global UI walk'}
function Reset-StatusFixture {
    $script:SessionEpoch=17L;$script:DirectoryReachability=$null;$script:DomeniaSchedulerEnabled=$false
    $script:DomeniaProviderState=$null;$script:DomeniaResources=$null;$script:DomeniaTaskSequence=$null
    $script:AsyncTimer=$null;$script:DomeniaRegisteredAsyncTimer=$null;$script:Ctrl=@{}
    $script:PermissionUpdates=0;$script:SelectionUpdates=0;$script:Logs=New-Object 'System.Collections.Generic.List[string]'
    Initialize-DomeniaEngineState
}
function New-StatusJob([string]$Provider='Directory',[long]$Epoch=17L,[bool]$Demo=$false){
    return [pscustomobject]@{Provider=$Provider;SessionEpoch=$Epoch;Demo=$Demo;SchedulerManaged=$false;OperationId='GlobalSearch';ProviderTarget='dc.example.invalid';CredentialIdentity='test'}
}
function Network-Failure($Job){[void](Register-DomeniaTaskOutcome $Job -ErrorMessage '[DOMENIA:Unavailable;0;0x8007203A] Serveur indisponible')}
function Status-Badge {return (Get-DomeniaSessionBadge -Domain 'example.invalid' -Offline $script:DirectoryReachability.Offline -Slow $script:DirectoryReachability.Slow)}
Case 'Initialization has independent offline and timeout state' {
    Reset-StatusFixture
    Expect (-not $script:DirectoryReachability.Offline -and -not $script:DirectoryReachability.Slow) 'New session begins degraded'
    Expect ($null -eq $script:DirectoryReachability.LastOutageUtc -and $null -eq $script:DirectoryReachability.LastTimeoutUtc) 'New session contains fabricated dates'
    Expect ($script:DirectoryReachability.Epoch -eq 17L) 'Session epoch missing'
}
Case 'A GlobalSearch deadline warns without declaring the directory offline' {
    Reset-StatusFixture;$job=New-StatusJob
    [void](Register-DomeniaTaskOutcome $job -TimedOut)
    Expect (-not $script:DirectoryReachability.Offline -and $script:DirectoryReachability.Slow) 'Deadline treated as network outage'
    Expect ($null -eq $script:DirectoryReachability.LastOutageUtc -and $null -ne $script:DirectoryReachability.LastTimeoutUtc) 'Deadline changes outage clock or has no own clock'
    Expect ($script:PermissionUpdates -eq 1 -and $script:SelectionUpdates -eq 1) 'Transition did not update existing UI'
    Expect ((Status-Badge).State -eq 'Slow' -and (Status-Badge).Text -ceq 'Dernière requête AD : délai dépassé') 'Incorrect deadline badge'
    Expect ($script:Logs.Count -eq 0) 'Callback swallowed an integration error'
}
Case 'An explicit structured Timeout error follows the same deadline path' {
    Reset-StatusFixture;$job=New-StatusJob
    [void](Register-DomeniaTaskOutcome $job -ErrorMessage 'Lecture AD trop longue' -ErrorInfo ([pscustomobject]@{Structured=[pscustomobject]@{Kind='Timeout'};Category='Timeout'}))
    Expect (-not $script:DirectoryReachability.Offline -and $script:DirectoryReachability.Slow) 'Structured timeout misclassified'
    Expect ($null -eq $script:DirectoryReachability.LastOutageUtc) 'Structured timeout dates a network outage'
    Expect ($script:Logs.Count -eq 0) 'Structured timeout callback failed'
}
Case 'Repeated deadlines refresh their own timestamp without repeating UI transition' {
    Reset-StatusFixture;$job=New-StatusJob
    [void](Register-DomeniaTaskOutcome $job -TimedOut)
    $script:DirectoryReachability.LastTimeoutUtc='2000-01-01T00:00:00.0000000Z'
    [void](Register-DomeniaTaskOutcome $job -TimedOut)
    Expect ($script:DirectoryReachability.LastTimeoutUtc -ne '2000-01-01T00:00:00.0000000Z') 'Latest deadline timestamp not stored'
    Expect ($script:PermissionUpdates -eq 1 -and $script:SelectionUpdates -eq 1) 'Repeated warning repeats UI transition'
}
Case 'A successful AD read clears the warning and retains historical timestamps' {
    Reset-StatusFixture;$job=New-StatusJob
    [void](Register-DomeniaTaskOutcome $job -TimedOut);$at=$script:DirectoryReachability.LastTimeoutUtc
    [void](Register-DomeniaTaskOutcome $job)
    Expect (-not $script:DirectoryReachability.Offline -and -not $script:DirectoryReachability.Slow) 'Success leaves a warning active'
    Expect ($script:DirectoryReachability.LastTimeoutUtc -eq $at -and $null -ne $script:DirectoryReachability.LastSuccessUtc) 'Success erases history or lacks read date'
    Expect ((Status-Badge).State -eq 'Connected') 'Successful read did not restore connected badge'
    Expect ($script:PermissionUpdates -eq 2 -and $script:Logs.Count -eq 0) 'Recovery transition failed'
}
Case 'An unavailable server remains an outage and uses the offline badge' {
    Reset-StatusFixture;Network-Failure (New-StatusJob)
    Expect ($script:DirectoryReachability.Offline -and -not $script:DirectoryReachability.Slow) 'Network failure not protected'
    Expect ($null -ne $script:DirectoryReachability.LastOutageUtc -and $null -eq $script:DirectoryReachability.LastTimeoutUtc) 'Network outage clock incorrect'
    Expect ((Status-Badge).State -eq 'Offline' -and $script:Logs.Count -eq 0) 'Network failure display failed'
}
Case 'A later deadline cannot remove protection established by an outage' {
    Reset-StatusFixture;$job=New-StatusJob;Network-Failure $job;$outage=$script:DirectoryReachability.LastOutageUtc
    [void](Register-DomeniaTaskOutcome $job -TimedOut)
    Expect ($script:DirectoryReachability.Offline -and $script:DirectoryReachability.Slow) 'Deadline cleared offline protection'
    Expect ($script:DirectoryReachability.LastOutageUtc -eq $outage) 'Deadline moved AD invalidation boundary'
    Expect ((Status-Badge).State -eq 'Offline') 'Slow warning hides established outage'
    [void](Register-DomeniaTaskOutcome $job)
    Expect (-not $script:DirectoryReachability.Offline -and -not $script:DirectoryReachability.Slow) 'Success failed to clear both states'
    Expect ($script:DirectoryReachability.LastOutageUtc -eq $outage) 'Recovery erased reread requirement'
}
Case 'A new network failure after a deadline keeps the outage policy and clears Slow' {
    Reset-StatusFixture;$job=New-StatusJob
    [void](Register-DomeniaTaskOutcome $job -TimedOut);$at=$script:DirectoryReachability.LastTimeoutUtc
    Network-Failure $job
    Expect ($script:DirectoryReachability.Offline -and -not $script:DirectoryReachability.Slow) 'Network transition not applied'
    Expect ($script:DirectoryReachability.LastTimeoutUtc -eq $at) 'Network transition erased timeout history'
    $script:DirectoryReachability.LastOutageUtc='2000-01-01T00:00:00.0000000Z'
    Network-Failure $job
    Expect ($script:DirectoryReachability.LastOutageUtc -ne '2000-01-01T00:00:00.0000000Z') 'New network failure does not invalidate old attribute reads'
}
Case 'Other providers cannot create or clear AD warning and outage states' {
    Reset-StatusFixture
    foreach($provider in @('Cim','Wts','Network','Storage','Local')){[void](Register-DomeniaTaskOutcome (New-StatusJob $provider) -TimedOut)}
    Expect (-not $script:DirectoryReachability.Offline -and -not $script:DirectoryReachability.Slow) 'Foreign timeout contaminated AD state'
    Network-Failure (New-StatusJob);[void](Register-DomeniaTaskOutcome (New-StatusJob) -TimedOut)
    foreach($provider in @('Cim','Wts','Network','Storage','Local')){[void](Register-DomeniaTaskOutcome (New-StatusJob $provider))}
    Expect ($script:DirectoryReachability.Offline -and $script:DirectoryReachability.Slow) 'Foreign success cleared AD state'
}
Case 'Cancelled jobs cannot create or clear the warning' {
    Reset-StatusFixture;$job=New-StatusJob
    [void](Register-DomeniaTaskOutcome $job -TimedOut -Cancelled)
    Expect (-not $script:DirectoryReachability.Slow) 'Cancelled deadline creates warning'
    [void](Register-DomeniaTaskOutcome $job -TimedOut)
    [void](Register-DomeniaTaskOutcome $job -Cancelled)
    Expect ($script:DirectoryReachability.Slow) 'Cancelled job was treated as AD success'
}
Case 'Demo jobs cannot create or clear the real directory warning' {
    Reset-StatusFixture
    [void](Register-DomeniaTaskOutcome (New-StatusJob -Demo $true) -TimedOut)
    Expect (-not $script:DirectoryReachability.Slow) 'Demo timeout creates warning'
    [void](Register-DomeniaTaskOutcome (New-StatusJob) -TimedOut)
    [void](Register-DomeniaTaskOutcome (New-StatusJob -Demo $true))
    Expect ($script:DirectoryReachability.Slow) 'Demo success cleared real warning'
}
Case 'Old session outcomes cannot create or clear current directory status' {
    Reset-StatusFixture
    [void](Register-DomeniaTaskOutcome (New-StatusJob -Epoch 16L) -TimedOut)
    Expect (-not $script:DirectoryReachability.Slow) 'Old session timeout creates warning'
    [void](Register-DomeniaTaskOutcome (New-StatusJob) -TimedOut)
    [void](Register-DomeniaTaskOutcome (New-StatusJob -Epoch 16L))
    Expect ($script:DirectoryReachability.Slow) 'Old session success cleared warning'
    $script:SessionEpoch=18L;Initialize-DomeniaEngineState
    Expect (-not $script:DirectoryReachability.Offline -and -not $script:DirectoryReachability.Slow -and $null -eq $script:DirectoryReachability.LastTimeoutUtc) 'Account change retained previous status'
}
Case 'Access refusals and unknown failures neither prove a network outage nor clear a deadline' {
    Reset-StatusFixture;$job=New-StatusJob
    foreach($category in @('AccessDenied','CredentialsRejected','Unknown')){
        [void](Register-DomeniaTaskOutcome $job -ErrorMessage 'Erreur AD de test' -ErrorInfo ([pscustomobject]@{Structured=[pscustomobject]@{Kind=$category};Category=$category}))
    }
    Expect (-not $script:DirectoryReachability.Offline -and -not $script:DirectoryReachability.Slow) 'Unrelated refusal marked network unhealthy'
    [void](Register-DomeniaTaskOutcome $job -TimedOut)
    [void](Register-DomeniaTaskOutcome $job -ErrorMessage 'Acces refuse' -ErrorInfo ([pscustomobject]@{Structured=[pscustomobject]@{Kind='AccessDenied'};Category='AccessDenied'}))
    Expect ($script:DirectoryReachability.Slow -and $null -eq $script:DirectoryReachability.LastSuccessUtc) 'Refusal cleared warning or synthesized success'
}
Case 'Demo presentation wins over both network and deadline badges' {
    $badge=Get-DomeniaSessionBadge -Domain 'example.invalid' -Offline $true -Slow $true -Demo $true -DemoText 'DÉMO'
    Expect ($badge.State -eq 'Demo' -and $badge.Text -ceq 'DÉMO') 'Demo badge lost precedence'
}
$passed=@($script:Checks|Where-Object{$_.Passed}).Count;$failed=@($script:Checks|Where-Object{-not $_.Passed}).Count
$report=[ordered]@{Kind='DirectoryStatusRegression';PSVersion=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.Platform.ToString();WpfExecuted=$false;DomainAccessed=$false;NetworkAccessed=$false;ProductionTaskCallbackExecuted=$true;UI='Inert ports only';Passed=$passed;Failed=$failed;Assertions=$script:Assertions;Tests=$script:Checks.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))}
Write-Host ('Directory status: '+$passed+' passed, '+$failed+' failed; '+$script:Assertions+' assertions. WPF and real AD not run.')
foreach($case in @($script:Checks|Where-Object{-not $_.Passed})){Write-Host ($case.Name+': '+$case.Error)}
if($failed -gt 0){exit 1};exit 0
