function Get-DomeniaSessionsWorkerCode {
return @'
if($null -eq ('Domenia.Sessions.Reader' -as [type])){Add-Type -Path (Join-Path $Context.RootDir 'modules\Domenia-Sessions.Native.cs') -ErrorAction Stop}
$cred=Get-WMachineCredential $Context;$user=$null;$domain=$null;$password=$null
if($null -ne $cred){
    $qualified=[string]$cred.UserName
    if($qualified.Contains('\')){$parts=$qualified.Split('\',2);$domain=$parts[0];$user=$parts[1]}
    else{$user=$qualified;$domain=$null}
    $password=$cred.Password
}
$rows=[Domenia.Sessions.Reader]::Read([string]$Payload.Computer,$user,$domain,$password)
[pscustomobject]@{Rows=$rows;Computer=[string]$Payload.Computer;ObservedUtc=[datetime]::UtcNow.ToString('o');Source='WTS, lecture a la demande';Identity=$(if($cred){$cred.UserName}else{$Context.ProcessIdentity})}
'@
}
function Get-DomeniaSelectedMachineName {
    if($null -eq $script:SelectedObject -or $script:SelectedObject.Type -ne 'Machine'){return ''}
    $name=[string](Get-DomeniaEntryFirstString $script:SelectedObject.Entry 'dNSHostName')
    if(-not $name){$name=[string](Get-DomeniaEntryFirstString $script:SelectedObject.Entry 'name')}
    return $name
}
function Start-DomeniaSessionsRead {
    $name=Get-DomeniaSelectedMachineName
    if(-not $name){Show-InfoBox 'Selectionnez une machine.';return}
    Start-UiTask -Name ('Sessions '+$name) -OperationId 'SessionsList' -Code (Get-DomeniaSessionsWorkerCode) -Payload ([pscustomobject]@{Computer=$name}) -CallbackState ([pscustomobject]@{Epoch=[long]$script:SessionEpoch;DN=[string]$script:SelectedObject.DN;Generation=[long]$script:SelectedObjectGeneration}) -SuccessHandler 'Complete-DomeniaSessionsRead' -ErrorHandler 'Fail-DomeniaSessionsRead' -TimeoutSeconds 20 -ReplaceKey 'sessions-selected' -DisableControls @('BtnSessionsRead') | Out-Null
}
function Complete-DomeniaSessionsRead {
    param($Result,$State)
    if($State.Epoch -ne $script:SessionEpoch -or $State.Generation -ne $script:SelectedObjectGeneration -or $State.DN -ine [string]$script:SelectedObject.DN){return}
    $r=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Computer')
    if($null -eq $r){throw 'Resultat WTS absent.'}
    [void](Set-DomeniaItemsSource 'DgSessions' @($r.Rows))
    [void](Set-DomeniaControlText 'LblSessionsState' ($r.Source+' ; '+$r.Computer+' ; '+$r.ObservedUtc+' ; compte : '+$r.Identity+'. Aucune deconnexion possible depuis cet ecran.'))
}
function Fail-DomeniaSessionsRead {
    param($Message,$State)
    if($State.Epoch -ne $script:SessionEpoch -or $State.Generation -ne $script:SelectedObjectGeneration){return}
    [void](Set-DomeniaControlText 'LblSessionsState' 'Lecture non confirmee : absence de resultat ne signifie pas absence de sessions.')
    [void](Request-DomeniaAccessRecovery -Operation 'Lecture des sessions' -OperationId 'SessionsList' -ErrorValue $Message -DN $State.DN -Interactive)
    Write-AppLog ('WTS : '+[string]$Message) 'WARN'
}
function Get-DomeniaRemoteCredentialCheckCode {
return @'
$session=$null
try{
    $session=New-CimSession -ComputerName ([string]$Payload.Computer) -Credential $Payload.Credential -SessionOption (New-CimSessionOption -Protocol Dcom) -OperationTimeoutSec 5 -ErrorAction Stop
    $result=Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystem -Property Name -OperationTimeoutSec 5 -ErrorAction Stop
    if($null -eq $result){throw 'Aucune reponse du poste.'}
    [pscustomobject]@{Success=$true;AuthMode='Remote';BindUser=[string]$Payload.Credential.UserName;BaseDn=[string]$Context.BaseDn;Computer=[string]$Payload.Computer;Error=''}
}catch{[pscustomobject]@{Success=$false;AuthMode='Remote';BindUser='';BaseDn=[string]$Context.BaseDn;Error=$_.Exception.Message;Code=$_.Exception.HResult}}
finally{if($null -ne $session){Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue}}
'@
}
function Start-DomeniaRemoteCredentialSession {
    param([string]$User,[Security.SecureString]$Password,[string]$Computer)
    if(-not $Computer -or $Computer -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}$'){throw 'Selectionnez la machine cible avant de valider un compte poste.'}
    if($User.StartsWith('.\')){$User=$Computer.Split('.')[0]+$User.Substring(1)}
    $credential=[Management.Automation.PSCredential]::new($User,$Password)
    $w=New-DomeniaWorkerRunspace -OperationId 'RemoteCredentialCheck' -Code (Get-DomeniaRemoteCredentialCheckCode)
    $ps=[Management.Automation.PowerShell]::Create();$ps.Runspace=$w.Runspace
    [void]$ps.AddCommand($w.CommandName);[void]$ps.AddParameter('Context',([pscustomobject]@{BaseDn=[string]$script:Conn.BaseDn}));[void]$ps.AddParameter('Payload',([pscustomobject]@{Computer=$Computer;Credential=$credential}))
    try{$handle=$ps.BeginInvoke()}catch{$ps.Dispose();$w.Runspace.Dispose();throw}
    return [pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Request=$null;Progress=$null;PowerShell=$ps;Runspace=$w.Runspace;AsyncResult=$handle;StartedAt=Get-Date;EndInvoked=$false;Cleaned=$false;CancelRequested=$false;CleanupRetryAt=[datetime]::MinValue;CleanupGiveUpAt=[datetime]::MinValue}
}
function Set-DomeniaTargetCredentialContext {
    # Last step before a worker leaves (Start-UiTask). D051: the account is chosen per resource AND target
    # (Get-DomeniaCredentialScope). A local account bound to one workstation is only handed to an operation
    # whose resource is that workstation, never to LDAP, LAPS or BitLocker, and never to another workstation.
    param($Context,$Payload)
    if($null -eq $Context){return $Context}
    $operationId=[string](Get-DomeniaMember $Context 'OperationId' '')
    $resource='';if($operationId){$resource=Get-DomeniaOperationResource $operationId}
    if($resource -in @('Laps','BitLocker') -and $null -ne $script:SecretsCredential -and $null -eq (Get-DomeniaRetryCredential $operationId)){
        # Every LAPS or BitLocker read (ReadBitLockerList and ReadBitLockerKey included) uses the Secrets account
        # of the Accounts tab when one is active; a temporary account accepted for that resource still wins.
        $Context.Credential=$script:SecretsCredential;$Context.BindUser=[string]$script:SecretsCredential.UserName;$Context.UseCredential=$true
    }
    if($null -eq $script:AccessState -or $null -eq $Payload){return $Context}
    $target=[string](Get-DomeniaMember $Payload 'Computer' '')
    if(-not $target -or -not $operationId){return $Context}
    $scope=Get-DomeniaCredentialScope -OperationId $operationId -Target $target
    if(-not $scope.StartsWith('Remote:',[StringComparison]::Ordinal)){return $Context}
    $key='RemoteLocal|'+(ConvertTo-DomeniaMachineKey $target).ToUpperInvariant()
    if(-not $script:AccessState.Credentials.ContainsKey($key)){return $Context}
    $cred=$script:AccessState.Credentials[$key]
    if($null -eq $cred){return $Context}
    # D054: a new use needs a live lease; D051: the local account must belong to this very workstation.
    if(-not (Test-DomeniaAccessLeaseUsable -Key $key)){Remove-DomeniaAccessCredential -Key $key;return $Context}
    $check=Test-DomeniaCredentialContext -Scope $scope -UserName ([string]$cred.UserName) -Target $target
    if(-not [bool]$check.Valid){return $Context}
    $Context.MachineCredential=$cred;$Context.RemoteAdminCredential=$cred;$Context.RemoteAdminUser=$cred.UserName
    Use-DomeniaAccessLease -Key $key
    return $Context
}
