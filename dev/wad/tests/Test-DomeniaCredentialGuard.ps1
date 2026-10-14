#requires -Version 5.1
# Synthetic only: no real credential, AD, WMI, SMB, VM or network operation.
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
foreach($name in @('Common.Model','Guard.Model','Access.Model','Engine.Model','Engine.UI')){. (Join-Path $wad ('modules/Domenia-'+$name+'.ps1'))}
$checks=[Collections.Generic.List[object]]::new()
function Assert {param($Value,[string]$Why='Assertion failed')if(-not $Value){throw $Why}}
function Case {param($Name,[scriptblock]$Body)try{& $Body|Out-Null;$checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
function New-Fixture {
    param([string]$Account='admin@example.invalid')
    return [pscustomobject]@{CredentialGuard=[hashtable]::Synchronized(@{Epoch=1L;Faults=@{};Revision=0L;NotifiedRevision=0L});DirectoryAuthKey=$Account;RemoteAuthKey=$Account;RemoteAdminAuthKey=$Account}
}
Case 'Known domain aliases share one key, foreign domains stay distinct' {
    $a=Get-DomeniaCredentialAccountKey 'EXAMPLE\Admin' 'example.invalid' 'EXAMPLE'
    Assert ($a -eq (Get-DomeniaCredentialAccountKey 'Admin@example.invalid' 'example.invalid' 'EXAMPLE'))
    Assert ($a -eq (Get-DomeniaCredentialAccountKey 'Admin' 'example.invalid' 'EXAMPLE'))
    Assert ($a -ne (Get-DomeniaCredentialAccountKey 'OTHER\Admin' 'example.invalid' 'EXAMPLE'))
}
Case 'LDAP precise account state wins over generic failure' {
    Assert ((Get-DomeniaStructuredError 'LDAP error 49 data 775').Kind -eq 'AccountLocked')
    Assert ((Get-DomeniaStructuredError 'LDAP error 49 data 532').Kind -eq 'AccountUnavailable')
    Assert ((Get-DomeniaStructuredError 'LDAP error 49 data 52e').Kind -eq 'LogonFailure')
    Assert ((Get-DomeniaErrorDecision (Get-DomeniaStructuredError 'data 532')).Category -eq 'AccountState')
}
Case 'First remote refusal blocks directory and every other workstation for same account' {
    $c=New-Fixture
    Assert (Register-WCredentialFailure $c ([ComponentModel.Win32Exception]::new(1326)) Remote)
    $blocked=0
    foreach($i in 1..5000){try{Assert-WCredentialAllowed $c Directory}catch{$blocked++}}
    Assert ($blocked -eq 5000);Assert ($c.CredentialGuard.Revision -eq 1)
    Assert ($c.CredentialGuard.Faults.Count -eq 1)
}
Case 'Local pause marker does not falsely report an AD lockout' {
    $c=New-Fixture;[void](Register-WCredentialFailure $c 'data 52e')
    try{Assert-WCredentialAllowed $c;throw 'Missing pause'}catch{
        Assert ((Get-DomeniaStructuredError $_).Kind -eq 'CredentialPaused')
        Assert ($_.Exception.Message -notmatch 'compte.*verrouille')
    }
}
Case 'Access denied and network timeout do not reject credentials' {
    $c=New-Fixture
    Assert (-not (Register-WCredentialFailure $c ([ComponentModel.Win32Exception]::new(5))))
    Assert (-not (Register-WCredentialFailure $c ([TimeoutException]::new('timeout'))))
    Assert-WCredentialAllowed $c;Assert ($c.CredentialGuard.Faults.Count -eq 0)
}
Case 'Another account stays usable; successful unrelated activity never clears fault' {
    $c=New-Fixture;[void](Register-WCredentialFailure $c 'data 52e')
    $other=[pscustomobject]@{CredentialGuard=$c.CredentialGuard;DirectoryAuthKey='reader@example.invalid';RemoteAuthKey='';RemoteAdminAuthKey=''}
    Assert-WCredentialAllowed $other
    Assert ($c.CredentialGuard.Faults.Count -eq 1)
}
Case 'Ping and database context contain no authentication keys' {
    $script:SessionEpoch=10L;$script:DomeniaCredentialGuard=$null
    foreach($op in @('LiveSelectedPing','ComputerPing','LocalStore','LocalIndexRead','LocalQuery')){
        $ctx=[pscustomobject]@{Domain='example.invalid';Netbios='EXAMPLE';ProcessIdentity='EXAMPLE\reader';Credential=$null;MachineCredential=$null;RemoteAdminCredential=$null}
        $ctx=Set-DomeniaCredentialGuardContext $ctx $op
        Assert (@(Get-WCredentialGuardKeys $ctx).Count -eq 0)
    }
}
Case 'Guard state carries only account keys and whitelisted error metadata' {
    $c=New-Fixture;[void](Register-WCredentialFailure $c 'data 52e')
    $fields=@($c.CredentialGuard.Faults['admin@example.invalid'].PSObject.Properties.Name)
    # Point 44: the account generation of the refused job is whitelisted metadata too (a number, never a secret).
    Assert (($fields -join ',') -eq 'Kind,Code,AtUtc,Generation')
}
Case 'Logon harvest records a credential refusal before returning its status' {
    $core = Get-Content -LiteralPath (Join-Path $wad 'Domenia-Core.ps1') -Raw
    $start = $core.IndexOf("function Get-DomeniaLogonHarvestWorkerCode")
    Assert ($start -ge 0) 'Fonction de moisson absente'
    $next = $core.IndexOf("`nfunction ", $start + 10)
    Assert ($next -gt $start) 'Fin de fonction de moisson introuvable'
    $fn = $core.Substring($start, $next - $start)
    $catchAt = $fn.IndexOf('try { $events = @(Get-WinEvent @params) }')
    Assert ($catchAt -ge 0) 'Lecture Get-WinEvent absente'
    $registerAt = $fn.IndexOf('Register-WCredentialFailure -Context $Context -ErrorValue $_', $catchAt)
    $returnAt = $fn.IndexOf('return [pscustomobject]@{ Pairs=@(); Status=$status', $catchAt)
    Assert ($registerAt -ge 0 -and $returnAt -gt $registerAt) 'Le return du journal doit enregistrer le refus avant de sortir'
}
Case 'Worker shares refusal immediately across runspaces before any UI callback' {
    $c=New-Fixture
    $ps=[Management.Automation.PowerShell]::Create()
    try{
        [void]$ps.AddScript('param($Path,$Context) . $Path; Register-WCredentialFailure $Context "data 52e" Remote').AddArgument((Join-Path $wad 'modules/Domenia-Guard.Model.ps1')).AddArgument($c)
        $answer=$ps.Invoke();Assert ($answer.Count -eq 1 -and [bool]$answer[0])
        $blocked=$false;try{Assert-WCredentialAllowed $c Directory}catch{$blocked=$true}
        Assert $blocked
    }finally{$ps.Dispose()}
}
Case 'Simultaneous authentication attempts serialize and stop after the first rejection' {
    $c=New-Fixture;$counter=[hashtable]::Synchronized(@{Attempts=0})
    $jobs=[Collections.Generic.List[object]]::new()
    try{
        foreach($i in 1..4){
            $ps=[Management.Automation.PowerShell]::Create()
            [void]$ps.AddScript('param($Path,$Context,$Counter) . $Path; $lease=$null; try {$lease=Enter-WCredentialAttempt $Context Remote; $Counter.Attempts++; Start-Sleep -Milliseconds 75; [void](Register-WCredentialFailure $Context "data 52e" Remote)} catch {} finally {Exit-WCredentialAttempt $lease}').AddArgument((Join-Path $wad 'modules/Domenia-Guard.Model.ps1')).AddArgument($c).AddArgument($counter)
            $jobs.Add([pscustomobject]@{PowerShell=$ps;Handle=$ps.BeginInvoke()})
        }
        foreach($job in $jobs){[void]$job.PowerShell.EndInvoke($job.Handle)}
        Assert ($counter.Attempts -eq 1) ('Simulated authentications: '+$counter.Attempts)
    }finally{foreach($job in $jobs){$job.PowerShell.Dispose()}}
}
Case 'An exception while entering a rejected account releases acquired locks' {
    $c=New-Fixture;[void](Register-WCredentialFailure $c 'data 52e')
    try{[void](Enter-WCredentialAttempt $c Remote)}catch{}
    $lock=$c.CredentialGuard.AttemptLocks[$c.RemoteAuthKey]
    Assert (-not [Threading.Monitor]::IsEntered($lock))
}
# Extract the real CIM session factory, substitute its native transport only.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$errors)
$factory=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-WDomeniaCimSession'},$true)
# WorkerCommon is a here-string, so extract this reviewed function boundary from that literal.
$core=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'))
$match=[regex]::Match($core,'(?ms)^function New-WDomeniaCimSession \{.*?(?=^function Remove-WDomeniaCimSession)')
Invoke-Expression $match.Value
function New-CimSessionOption {param($Protocol) return $Protocol}
function New-CimSession {param($ComputerName,$SessionOption,$Credential,$OperationTimeoutSec)$script:Attempts++;throw [ComponentModel.Win32Exception]::new($script:FailureCode)}
Case 'Real CIM factory never retries WSMan after rejected DCOM credentials' {
    $script:Attempts=0;$script:FailureCode=1326;$c=New-Fixture;$c|Add-Member UseWinRM $true
    try{New-WDomeniaCimSession $c 'fixture.invalid' $null}catch{}
    Assert ($script:Attempts -eq 1);Assert ($c.CredentialGuard.Faults.Count -eq 1)
}
Case 'Real CIM factory retains protocol fallback for a transport failure' {
    $script:Attempts=0;$script:FailureCode=1722;$c=New-Fixture;$c|Add-Member UseWinRM $true
    try{New-WDomeniaCimSession $c 'fixture.invalid' $null}catch{}
    Assert ($script:Attempts -eq 2);Assert ($c.CredentialGuard.Faults.Count -eq 0)
}
function Invoke-LazyGuardProbe {
    param([string]$Factory,[string]$Call,[int]$ExpectedConcurrentReads=1)
    $ctx=New-Fixture;$ctx|Add-Member -NotePropertyName UseWinRM -NotePropertyValue $true
    $ctx|Add-Member -NotePropertyName UseCredential -NotePropertyValue $false
    $ctx|Add-Member -NotePropertyName Server -NotePropertyValue 'fixture.invalid'
    $counter=[hashtable]::Synchronized(@{Sessions=0;Reads=0;Disposed=0;Ready=0;ExpectedReads=$ExpectedConcurrentReads})
    $gate=[Threading.ManualResetEventSlim]::new($false);$jobs=[Collections.Generic.List[object]]::new()
    $code=@'
param($GuardPath,$Context,$Counter,$Gate,$Factory,$Call)
$ErrorActionPreference='Stop'
# The caller creates a context per job; only its synchronized guard is shared.
. $GuardPath
function New-CimSessionOption {param($Protocol)return $Protocol}
function New-CimSession {param($ComputerName,$SessionOption,$Credential,$OperationTimeoutSec);[Threading.Monitor]::Enter($Counter.SyncRoot);try{$Counter.Sessions++}finally{[Threading.Monitor]::Exit($Counter.SyncRoot)};return [pscustomobject]@{Fixture=$true}}
function Get-CimInstance {param($CimSession,$ClassName,$Property,$OperationTimeoutSec)
 [Threading.Monitor]::Enter($Counter.SyncRoot);try{$Counter.Reads++}finally{[Threading.Monitor]::Exit($Counter.SyncRoot)}
 $wait=[Diagnostics.Stopwatch]::StartNew();while($Counter.Reads -lt $Counter.ExpectedReads -and $wait.Elapsed.TotalSeconds -lt 5){Start-Sleep -Milliseconds 10}
 Start-Sleep -Milliseconds 75
 throw [ComponentModel.Win32Exception]::new(1326)
}
function Remove-CimSession {param($CimSession);[Threading.Monitor]::Enter($Counter.SyncRoot);try{$Counter.Disposed++}finally{[Threading.Monitor]::Exit($Counter.SyncRoot)}}
function New-Object {param($TypeName,$ArgumentList);if($TypeName -eq 'System.DirectoryServices.DirectoryEntry'){return [DomeniaGuardLazyEntry]::new()};Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList}
function Get-WLdapPath {param($Context,$Dn);return ('LDAP://fixture.invalid/'+$Dn)}
. ([scriptblock]::Create($Factory))
[Threading.Monitor]::Enter($Counter.SyncRoot);try{$Counter.Ready++}finally{[Threading.Monitor]::Exit($Counter.SyncRoot)}
[void]$Gate.Wait(10000)
try{& ([scriptblock]::Create($Call))}catch{}
'@
    try{
        foreach($i in 1..4){
            $ps=[Management.Automation.PowerShell]::Create()
            $jobContext=[pscustomobject]@{CredentialGuard=$ctx.CredentialGuard;DirectoryAuthKey=$ctx.DirectoryAuthKey;RemoteAuthKey=$ctx.RemoteAuthKey;RemoteAdminAuthKey=$ctx.RemoteAdminAuthKey;UseWinRM=$true;UseCredential=$false;Server='fixture.invalid'}
            [void]$ps.AddScript($code).AddArgument((Join-Path $wad 'modules/Domenia-Guard.Model.ps1')).AddArgument($jobContext).AddArgument($counter).AddArgument($gate).AddArgument($Factory).AddArgument($Call)
            $jobs.Add([pscustomobject]@{PowerShell=$ps;Handle=$ps.BeginInvoke()})
        }
        $watch=[Diagnostics.Stopwatch]::StartNew();while($counter.Ready -lt 4 -and $watch.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 10}
        if($counter.Ready -ne 4){$diagnostic=@($jobs|ForEach-Object{[pscustomobject]@{State=[string]$_.PowerShell.InvocationStateInfo.State;Reason=[string]$_.PowerShell.InvocationStateInfo.Reason;Error=@($_.PowerShell.Streams.Error|ForEach-Object{[string]$_});Completed=$_.Handle.IsCompleted}})|ConvertTo-Json -Compress -Depth 4;throw ('Synthetic readiness '+$counter.Ready+'/4: '+$diagnostic)};$gate.Set()
        foreach($job in $jobs){[void]$job.PowerShell.EndInvoke($job.Handle);Assert ($job.PowerShell.Streams.Error.Count -eq 0) 'No fixture import errors'}
        return [pscustomobject]@{Sessions=$counter.Sessions;Reads=$counter.Reads;Disposed=$counter.Disposed;Faults=$ctx.CredentialGuard.Faults.Count}
    }finally{$gate.Set();foreach($job in $jobs){$job.PowerShell.Dispose()};$gate.Dispose()}
}
Case 'Lazy CIM first query is serialized and its rejected session is disposed' {
    $factory=[regex]::Match($core,'(?ms)^function New-WDomeniaCimSession \{.*?(?=^function Remove-WDomeniaCimSession)').Value
    $r=Invoke-LazyGuardProbe $factory '$s=New-WDomeniaCimSession $Context "fixture.invalid" $null; Get-CimInstance -CimSession $s -ClassName Win32_OperatingSystem'
    Assert ($r.Sessions -eq 1 -and $r.Reads -eq 1 -and $r.Disposed -eq 1 -and $r.Faults -eq 1) ($r|ConvertTo-Json -Compress)
}
Case 'Negative witness: releasing CIM lease before the first query allows simultaneous attempts' {
    $factory=[regex]::Match($core,'(?ms)^function New-WDomeniaCimSession \{.*?(?=^function Remove-WDomeniaCimSession)').Value
    $factory=[regex]::Replace($factory,'(?m)^\s*\[void\]\(Get-CimInstance -CimSession \$opened.*$','')
    $r=Invoke-LazyGuardProbe $factory '$s=New-WDomeniaCimSession $Context "fixture.invalid" $null; try{Get-CimInstance -CimSession $s -ClassName Win32_OperatingSystem}catch{[void](Register-WCredentialFailure $Context $_ Remote)}' -ExpectedConcurrentReads 4
    Assert ($r.Sessions -eq 4 -and $r.Reads -eq 4) ($r|ConvertTo-Json -Compress)
}
# A native-style property getter faithfully models ADSI's deferred bind, without any LDAP call.
Add-Type -TypeDefinition @'
public sealed class DomeniaGuardLazyEntry : System.IDisposable {
 public static int Created, Reads, Disposed;
 public DomeniaGuardLazyEntry(){System.Threading.Interlocked.Increment(ref Created);}
 public object NativeObject {get{System.Threading.Interlocked.Increment(ref Reads);System.Threading.Thread.Sleep(75);throw new System.ComponentModel.Win32Exception(1326);}}
 public void Dispose(){System.Threading.Interlocked.Increment(ref Disposed);}
 public static void Reset(){Created=0;Reads=0;Disposed=0;}
}
'@
foreach($factoryName in @('New-WEntry','New-WRootDse')){
    Case ($factoryName+' serializes lazy bind and disposes only the failed entry') {
        [DomeniaGuardLazyEntry]::Reset()
        $next=if($factoryName -eq 'New-WEntry'){'Get-WDirectoryVersionSource'}else{'New-WSearcher'}
        $factory=[regex]::Match($core,('(?ms)^function '+$factoryName+' \{.*?(?=^function '+$next+')')).Value
        $r=Invoke-LazyGuardProbe $factory ($factoryName+' $Context "DC=fixture"')
        Assert ([DomeniaGuardLazyEntry]::Created -eq 1 -and [DomeniaGuardLazyEntry]::Reads -eq 1 -and [DomeniaGuardLazyEntry]::Disposed -eq 1 -and $r.Faults -eq 1) ('entries='+[DomeniaGuardLazyEntry]::Created+', binds='+[DomeniaGuardLazyEntry]::Reads+', disposed='+[DomeniaGuardLazyEntry]::Disposed+', faults='+$r.Faults)
    }
}

Case 'Three accounts: refusal of machine B survives wrapping without rejecting directory A or admin C' {
    $c=New-Fixture 'directory@example.invalid'
    $c.RemoteAuthKey='machine@example.invalid';$c.RemoteAdminAuthKey='admin@example.invalid'
    $c|Add-Member -NotePropertyName Domain -NotePropertyValue 'example.invalid'
    $c|Add-Member -NotePropertyName Netbios -NotePropertyValue 'EXAMPLE'
    $c|Add-Member -NotePropertyName OperationId -NotePropertyValue 'ComputerInventory'
    Set-WCredentialAttemptIdentity $c ([pscustomobject]@{UserName='EXAMPLE\machine'}) Remote
    $error=[ComponentModel.Win32Exception]::new(1326)
    Assert (Register-WCredentialFailure $c $error Remote)
    # A later caller can change its active channel; the exception still owns the exact refusal provenance.
    Set-WCredentialAttemptIdentity $c ([pscustomobject]@{UserName='EXAMPLE\admin'}) Remote
    [void](Register-WCredentialFailure $c ([InvalidOperationException]::new('outer wrapper',$error)))
    Assert ($c.CredentialGuard.Faults.Count -eq 1 -and $c.CredentialGuard.Faults.ContainsKey('machine@example.invalid'))
    Assert-WCredentialAllowed $c Directory;Assert-WCredentialAllowed $c Remote
}
Case 'An unlocated authentication failure pauses its operation without declaring three accounts invalid' {
    $c=New-Fixture 'directory@example.invalid';$c.RemoteAuthKey='machine@example.invalid';$c.RemoteAdminAuthKey='admin@example.invalid'
    $c|Add-Member -NotePropertyName OperationId -NotePropertyValue 'MixedFixture'
    [void](Register-WCredentialFailure $c ([ComponentModel.Win32Exception]::new(1326)))
    Assert ($c.CredentialGuard.Faults.Count -eq 0 -and $c.CredentialGuard.AmbiguousOperations.ContainsKey('MixedFixture'))
    $blocked=$false;try{Assert-WCredentialAllowed $c}catch{$blocked=$_.Exception.Message -match 'indeterminee'};Assert $blocked
    $c.OperationId='AnotherFixture';Assert-WCredentialAllowed $c
}
Case 'Local machine account aliases stay separate between workstations' {
    Assert ((Get-DomeniaCredentialAccountKey '.\reader' 'example.invalid' 'EXAMPLE' 'PC-A') -eq 'pc-a\reader')
    Assert ((Get-DomeniaCredentialAccountKey '.\reader' 'example.invalid' 'EXAMPLE' 'PC-B') -ne (Get-DomeniaCredentialAccountKey '.\reader' 'example.invalid' 'EXAMPLE' 'PC-A'))
}
Case 'A replacement object for the same refused account does not silently release its pause' {
    $c=New-Fixture;[void](Register-WCredentialFailure $c 'data 52e' Remote)
    Set-WCredentialAttemptIdentity $c ([pscustomobject]@{UserName='admin@example.invalid'}) Remote
    $blocked=$false;try{Assert-WCredentialAllowed $c Remote}catch{$blocked=$true};Assert $blocked
    Set-WCredentialAttemptIdentity $c ([pscustomobject]@{UserName='another@example.invalid'}) Remote
    Assert-WCredentialAllowed $c Remote
}

Case 'Real credential selectors record only the identity selected for that transport' {
    foreach($pair in @(@('Get-WDirectoryBindUser','New-WEntry'),@('Get-WAdCredential','Get-WRemoteAdminCredential'),@('Get-WRemoteAdminCredential','Get-WMachineCredential'),@('Get-WMachineCredential','New-WDomeniaCimSession'))){
        $body=[regex]::Match($core,('(?ms)^function '+$pair[0]+' \{.*?(?=^function '+$pair[1]+')')).Value
        . ([scriptblock]::Create($body))
    }
    $script:RemoteAdminCredential=$null
    $c=New-Fixture 'directory@example.invalid';$c.RemoteAuthKey='machine@example.invalid';$c.RemoteAdminAuthKey='admin@example.invalid'
    foreach($p in @{Domain='example.invalid';Netbios='EXAMPLE';BindUser='directory@example.invalid';UseCredential=$true;Credential=[pscustomobject]@{UserName='directory@example.invalid'};MachineCredential=[pscustomobject]@{UserName='machine@example.invalid'};RemoteAdminCredential=[pscustomobject]@{UserName='admin@example.invalid'};RemoteAdminUser='admin@example.invalid';CredentialTarget='pc-a'}.GetEnumerator()){$c|Add-Member -NotePropertyName $p.Key -NotePropertyValue $p.Value}
    Assert ((Get-WMachineCredential $c).UserName -eq 'machine@example.invalid')
    Assert ((@(Get-WCredentialGuardKeys $c Remote) -join ',') -eq 'machine@example.invalid')
    Assert ((Get-WRemoteAdminCredential $c).UserName -eq 'admin@example.invalid')
    Assert ((@(Get-WCredentialGuardKeys $c Remote) -join ',') -eq 'admin@example.invalid')
    Assert ((Get-WAdCredential $c).UserName -eq 'directory@example.invalid')
    Assert ($c.LastAuthChannel -eq 'Directory')
}

# ---------------------------------------------------------------- Point 41 qualification of the refusal protection
Case 'Point 41 audit: every explicit-account logon of worker code holds the account lease' {
    # Static audit of every here-string body (worker operations and their common helpers). A logon that can carry an
    # explicit account must follow Enter-WCredentialAttempt in the same function, at most 15 lines above.
    $pattern='New-CimSession\s+[@-]|Invoke-Command\s+@|Get-WinEvent\s+@|Get-WinEvent\b.*-Credential|New-PSDrive\s+@|\$service\.Connect\(|\$conn(ection)?\.Bind\(\)|\[Domenia\.NetUse\]::Connect\(|DirectoryEntry -ArgumentList @\(\$path,\$bindUser|Restart-Computer\s+@|Test-WSMan\s+@'
    # Directory cmdlets carrying the account (AD module, Windows LAPS) run right after a leased LDAP bind of the SAME account
    # in the same body (fresh read before a write, entry read before LAPS): that bind proves the account first.
    $directoryCmdlet='Get-LapsADPassword\s+@|\b(?:Set|Add|Remove|New|Clear|Move|Rename|Unlock|Enable|Disable)-AD[A-Za-z]+\s+@'
    $directoryBind='New-WEntry|New-WSearcher|New-WRootDse|Assert-WObjectFresh|Get-WObjectSnapshot'
    # Validation of a candidate account: one attempt per operator gesture, serialized by the validation panel itself.
    $allowed=@('Domenia-Sessions.UI.ps1|Get-DomeniaRemoteCredentialCheckCode')
    $files=@((Join-Path $wad 'Domenia-Core.ps1'))+@(Get-ChildItem -LiteralPath (Join-Path $wad 'modules') -Filter '*.ps1' -File|ForEach-Object{$_.FullName})
    $missing=[Collections.Generic.List[string]]::new();$seen=0
    foreach($file in $files){
        $text=[IO.File]::ReadAllText($file);$name=[IO.Path]::GetFileName($file)
        $functions=@([regex]::Matches($text,'(?m)^function\s+([A-Za-z0-9-]+)'))
        foreach($m in [regex]::Matches($text,"(?ms)@'\r?\n(.*?)\r?\n'@")){
            $owner='';foreach($f in $functions){if($f.Index -lt $m.Index){$owner=$f.Groups[1].Value}else{break}}
            $lines=@($m.Groups[1].Value -split "\r?\n")
            for($i=0;$i -lt $lines.Count;$i++){
                if($lines[$i] -match $directoryCmdlet){
                    $seen++
                    $before=($lines[0..$i] -join "`n")
                    if(($before -notmatch $directoryBind) -and ($allowed -notcontains ($name+'|'+$owner))){$missing.Add($name+' / '+$owner+' (sans bind prealable) : '+$lines[$i].Trim())}
                    continue
                }
                if($lines[$i] -notmatch $pattern){continue}
                if(($lines[$i] -match 'Get-Command\s+New-CimSession') -and ($lines[$i] -notmatch 'New-CimSession\s+@')){continue}
                $seen++
                $leased=$false
                for($j=$i;$j -ge [Math]::Max(0,$i-15);$j--){
                    if($lines[$j] -match 'Enter-WCredentialAttempt'){$leased=$true;break}
                    if(($j -lt $i) -and ($lines[$j] -match '^\s*function\s')){break}
                }
                if((-not $leased) -and ($allowed -notcontains ($name+'|'+$owner))){$missing.Add($name+' / '+$owner+' : '+$lines[$i].Trim())}
            }
        }
    }
    Assert ($seen -ge 20) ('Audit incomplet : '+$seen+' appels trouves')
    Assert ($missing.Count -eq 0) ('Appels hors bail : '+($missing -join ' | '))
}
Case 'Point 41: index pass, park sweep and query schema reads get the lease through the shared helpers' {
    $text=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'))
    foreach($helper in @('New-WEntry','New-WRootDse','New-WDomeniaCimSession')){
        $body=[regex]::Match($text,'(?ms)^function '+[regex]::Escape($helper)+' \{.*?^\}').Value
        Assert ($body -match 'Enter-WCredentialAttempt') ($helper+' sans bail')
        Assert ($body -match 'Register-WCredentialFailure') ($helper+' sans enregistrement du refus')
    }
    $index=[regex]::Match($text,'(?ms)^function Get-DomeniaIndexWorkerCode \{.*?^''@').Value
    Assert ($index -match 'New-WSearcher') 'Passe d index sans le searcher commun'
    Assert ($index -notmatch 'New-Object\s+System\.DirectoryServices\.DirectoryEntry') 'Passe d index avec un bind hors bail'
    $park=[regex]::Match($text,'(?ms)^function Get-DomeniaParkSweepWorkerCode \{.*?^''@').Value
    Assert ($park -match 'New-WDomeniaCimSession') 'Releve du parc sans la fabrique CIM commune'
    $schema=[IO.File]::ReadAllText((Join-Path $wad 'modules\Domenia-QuerySchema.Worker.ps1'))
    Assert ($schema -match 'New-WDomeniaCimSession') 'Schema de requete sans la fabrique CIM commune'
    Assert ($schema -notmatch 'New-CimSession\s+@') 'Schema de requete avec une session hors bail'
}
Case 'Point 41: local consultation never carries an account key, whatever the guard state' {
    $script:SessionEpoch=11L;$script:DomeniaCredentialGuard=$null
    foreach($op in @('LocalStore','LocalIndexRead','LocalQuery','QueryLibrary','QueryExport','StorageUsage','DocumentStore','LiveCache','LiveSelectedPing','ComputerPing','SelectedPresence','PresenceScan')){
        $ctx=[pscustomobject]@{Domain='example.invalid';Netbios='EXAMPLE';ProcessIdentity='EXAMPLE\admin';Credential=$null;MachineCredential=$null;RemoteAdminCredential=$null}
        $ctx=Set-DomeniaCredentialGuardContext $ctx $op
        Assert (@(Get-WCredentialGuardKeys $ctx).Count -eq 0) ($op+' porte une cle de compte')
        $script:DomeniaCredentialGuard.Faults['admin@example.invalid']=[pscustomobject]@{Kind='LogonFailure';Code='0x8007052E';AtUtc=[datetime]::UtcNow}
        Assert-WCredentialAllowed $ctx
    }
}
Case 'Point 41: a refusal withdraws the queued reads of that account only, never a write' {
    $script:SessionEpoch=12L;$script:DomeniaCredentialGuard=[hashtable]::Synchronized(@{Epoch=12L;Faults=@{};Revision=0L;NotifiedRevision=0L})
    $script:Stopped=[Collections.Generic.List[string]]::new()
    function Request-UiTaskStop {param([string]$Id,[switch]$Silent,[string]$Reason) $script:Stopped.Add($Id)}
    function Set-Status {param($Text,$Level)}
    function Write-AppLog {param($Text,$Level)}
    $guardOf={param($key)[pscustomobject]@{CredentialGuard=$script:DomeniaCredentialGuard;DirectoryAuthKey=$key;RemoteAuthKey='';RemoteAdminAuthKey='';ActiveRemoteAuthKey=''}}
    $script:AsyncJobs=[ordered]@{
        'read-a'=[pscustomobject]@{Id='read-a';OperationId='GlobalSearch';IsWrite=$false;NonCancellable=$false;State='Queued';CancelRequested=$false;CredentialGuardContext=(& $guardOf 'admin@example.invalid')}
        'read-b'=[pscustomobject]@{Id='read-b';OperationId='GlobalSearch';IsWrite=$false;NonCancellable=$false;State='Queued';CancelRequested=$false;CredentialGuardContext=(& $guardOf 'reader@example.invalid')}
        'write-a'=[pscustomobject]@{Id='write-a';OperationId='WriteAttributes';IsWrite=$true;NonCancellable=$false;State='Queued';CancelRequested=$false;CredentialGuardContext=(& $guardOf 'admin@example.invalid')}
        'running-a'=[pscustomobject]@{Id='running-a';OperationId='GlobalSearch';IsWrite=$false;NonCancellable=$false;State='Running';CancelRequested=$false;CredentialGuardContext=(& $guardOf 'admin@example.invalid')}
    }
    $worker=[pscustomobject]@{CredentialGuard=$script:DomeniaCredentialGuard;DirectoryAuthKey='admin@example.invalid';RemoteAuthKey='';RemoteAdminAuthKey=''}
    Assert (Register-WCredentialFailure $worker ([ComponentModel.Win32Exception]::new(1326)) Directory)
    Sync-DomeniaCredentialGuardUi
    Assert (($script:Stopped -join ',') -eq 'read-a') ('Retraits : '+($script:Stopped -join ','))
    $blocked=$false;try{Assert-WCredentialAllowed $script:AsyncJobs['running-a'].CredentialGuardContext}catch{$blocked=$true}
    Assert $blocked 'Une lecture deja partie peut encore envoyer le compte refuse'
}

$report=[pscustomobject]@{Suite='CredentialGuard';Synthetic=$true;NetworkCalls=0;Passed=(@($checks|Where-Object{-not $_.Passed}).Count -eq 0);Cases=$checks.ToArray();PowerShell=[string]$PSVersionTable.PSVersion}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 7
if(-not $report.Passed){exit 1}
