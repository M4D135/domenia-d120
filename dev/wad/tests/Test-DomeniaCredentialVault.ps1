#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='',[switch]$NativeWindows)
$ErrorActionPreference='Stop'
$module=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Domenia-CredentialVault.Model.ps1'
. $module
$checks=[Collections.Generic.List[object]]::new()
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
function Check($Name,[scriptblock]$Body){try{& $Body;$checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message})}}
function Refuses([scriptblock]$Body){$refused=$false;try{& $Body|Out-Null}catch{$refused=$true};Assert $refused 'Invalid input was accepted'}
function New-TestSecret([int]$Length=24){$s=[Security.SecureString]::new();for($i=0;$i -lt $Length;$i++){$s.AppendChar([char](33+($i%87)))};$s.MakeReadOnly();return $s}
function Key([string]$Domain='DC=example,DC=invalid',[string]$Scope='Directory',[string]$User='EXAMPLE\operator'){Get-DomeniaCredentialVaultTarget -DomainDn $Domain -Scope $Scope -UserName $User}
Check 'Target is bounded, deterministic and contains no identity' {
 $key=Key;Assert ($key -cmatch '^Domenia:v1:[0-9a-f]{64}$') 'Unexpected target format';Assert ($key -ceq (Key)) 'Nondeterministic target'
 Assert (-not $key.Contains('example') -and -not $key.Contains('operator')) 'Identity leaked into target'
}
Check 'Trim and Windows account case preserve one target' {Assert ((Key) -ceq (Key ' dc=EXAMPLE,dc=INVALID ' 'directory' ' example\OPERATOR ')) 'Case or surrounding spaces changed target'}
Check 'Domain and scope are isolated' {
 $keys=@((Key),(Key 'DC=other,DC=invalid'),(Key -Scope 'Remote'),(Key -Scope 'Laps'),(Key -Scope 'BitLocker'),(Key -Scope 'AD:DisableUser'))
 Assert (@($keys|Select-Object -Unique).Count -eq 6) 'Resources share a credential target'
}
Check 'Foreign authorities, UPN and bare names never alias' {
 $keys=@((Key -User 'FIRST\operator'),(Key -User 'SECOND\operator'),(Key -User 'operator@first.invalid'),(Key -User 'operator@second.invalid'),(Key -User 'operator'))
 Assert (@($keys|Select-Object -Unique).Count -eq 5) 'Unknown authority equivalence was inferred'
}
Check 'Local accounts are bound to an exact workstation' {
 $a=Key -Scope 'RemoteLocal:pc-1' -User '.\admin';$b=Key -Scope 'RemoteLocal:pc-2' -User '.\admin';Assert ($a -cne $b) 'Two local machines share a credential'
 Refuses {Key -Scope 'Remote' -User '.\admin'}
 Refuses {Key -Scope 'RemoteLocal:pc-1' -User 'pc-2\admin'}
 Refuses {Key -Scope 'RemoteLocal:pc-1' -User 'admin@elsewhere.invalid'}
 Assert ((Key -Scope 'RemoteLocal:pc-1' -User 'PC-1\admin') -ne '') 'Exact machine account refused'
}
Check 'Unknown scopes and oversized identifiers are rejected before native access' {
 Refuses {Key -Scope 'Remote:pc-1'};Refuses {Key -Scope 'RemoteAdmin'};Refuses {Key -Scope ('AD:'+('a'*65))};Refuses {Key -Scope 'RemoteLocal:PC-1'}
 Refuses {Key -User ('a'*257)};Refuses {Key -Domain ('a'*2049)};Refuses {Key -User "operator`nother"};Refuses {Key -Domain "dc=bad`0,dc=invalid"}
 Assert ((Key -User ('a'*256)) -ne '') 'Valid maximum user name rejected'
}
Check 'Explicitly disabled wrappers make no native call' {
 $savedInitializer=${function:Initialize-DomeniaCredentialVault};$secret=New-TestSecret
 try{
  function Initialize-DomeniaCredentialVault {throw 'Unexpected native initialization'}
  $credential=[Management.Automation.PSCredential]::new('EXAMPLE\operator',$secret)
  Assert ($null -eq (Get-DomeniaCredentialVaultCredential -DomainDn 'dc=example,dc=invalid' -Scope Directory -UserName $credential.UserName)) 'Disabled read returned data'
  $r=Save-DomeniaCredentialVaultCredential -DomainDn 'dc=example,dc=invalid' -Scope Directory -Credential $credential;Assert ($r.Disabled -and -not $r.Saved) 'Disabled write attempted storage'
  $r=Remove-DomeniaCredentialVaultCredential -DomainDn 'dc=example,dc=invalid' -Scope Directory -UserName $credential.UserName;Assert ($r.Disabled -and -not $r.Removed) 'Disabled delete attempted storage'
 }finally{Set-Item Function:Initialize-DomeniaCredentialVault $savedInitializer;$secret.Dispose()}
}
Check 'Saving requires an explicit successful manual authentication' {
 $s=New-TestSecret;try{$c=[Management.Automation.PSCredential]::new('EXAMPLE\operator',$s);Refuses {Save-DomeniaCredentialVaultCredential -DomainDn 'dc=example,dc=invalid' -Scope Directory -Credential $c -Enabled}}finally{$s.Dispose()}
}
Check 'Empty and oversized secrets are refused without initializing Windows' {
 $savedInitializer=${function:Initialize-DomeniaCredentialVault};$script:NativeAttempted=$false
 try{function Initialize-DomeniaCredentialVault {$script:NativeAttempted=$true;throw 'Must not reach Windows'}
  foreach($size in @(0,1281)){$s=New-TestSecret $size;try{$c=[Management.Automation.PSCredential]::new('EXAMPLE\operator',$s);Refuses {Save-DomeniaCredentialVaultCredential -DomainDn 'dc=example,dc=invalid' -Scope Directory -Credential $c -Enabled -AuthenticationConfirmed}}finally{$s.Dispose()}}
  Assert (-not $script:NativeAttempted) 'Invalid secret reached native initialization'
 }finally{Set-Item Function:Initialize-DomeniaCredentialVault $savedInitializer}
}
Check 'Native source compiles without external dependencies' {if($null -eq ('Domenia.Security.CredentialVault' -as [type])){Add-Type -Path (Join-Path (Split-Path $module) 'Domenia-CredentialVault.Native.cs')};Assert ($null -ne ('Domenia.Security.CredentialVault' -as [type])) 'Type absent'}
Check 'Native credential layout matches Windows pointer alignment' {
 $t=[Domenia.Security.CredentialVault].GetNestedType('Credential',[Reflection.BindingFlags]::NonPublic)
 $actual=[Runtime.InteropServices.Marshal]::SizeOf([type]$t);$expected=if([IntPtr]::Size -eq 8){80}else{52};Assert ($actual -eq $expected) 'Unexpected CREDENTIALW layout'
}
Check 'Native API refuses alien targets and invalid secret lengths' {
 $s=New-TestSecret;try{Refuses {[Domenia.Security.CredentialVault]::Write('other-app','EXAMPLE\operator',$s)};Refuses {[Domenia.Security.CredentialVault]::Read('other-app','EXAMPLE\operator')};Refuses {[Domenia.Security.CredentialVault]::Delete('other-app')}}finally{$s.Dispose()}
 foreach($size in @(0,1281)){$s=New-TestSecret $size;try{Refuses {[Domenia.Security.CredentialVault]::Write((Key),'EXAMPLE\operator',$s)}}finally{$s.Dispose()}}
}
Check 'No managed password extraction and no automatic authentication in module' {
 $native=[IO.File]::ReadAllText((Join-Path (Split-Path $module) 'Domenia-CredentialVault.Native.cs'));$source=[IO.File]::ReadAllText($module)
 Assert ($native -notmatch 'PtrToString|Encoding\.\w+\.GetString|NetworkCredential|StringBuilder|Marshal\.Copy') 'Managed password conversion found'
 Assert ($source -notmatch 'GetNetworkCredential|ConvertFrom-SecureString|ConvertTo-SecureString|Start-UiTask|Reset-WCredential|New-CimSession|Invoke-Command') 'Vault performs an authentication or serialization'
 Assert ($native.Contains('ClearBlob(blob, byteCount)') -and $native.Contains('ClearBlob(credential.CredentialBlob, credential.CredentialBlobSize)') -and $native.Contains('CredFree(native)')) 'Unmanaged cleanup missing'
}
$nativeExecuted=$false
if($NativeWindows){
 Check 'Native Windows vault writes, reads and deletes only isolated fictional credentials' {
  Assert ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) 'NativeWindows requested outside Windows'
  $domain='DC=vault-fixture-'+[guid]::NewGuid().ToString('N')+',DC=invalid';$user='FIXTURE\vault-test';$secret=New-TestSecret 1280;$read=$null
  try{
   Assert ($null -eq (Get-DomeniaCredentialVaultCredential -DomainDn $domain -Scope Directory -UserName $user -Enabled)) 'Random fixture unexpectedly exists'
   $credential=[Management.Automation.PSCredential]::new($user,$secret)
   $save=Save-DomeniaCredentialVaultCredential -DomainDn $domain -Scope Directory -Credential $credential -Enabled -AuthenticationConfirmed;Assert $save.Saved 'Write not confirmed'
   $read=Get-DomeniaCredentialVaultCredential -DomainDn $domain -Scope Directory -UserName $user -Enabled
   Assert ($read.UserName -ceq $user -and $read.Password.Length -eq 1280 -and $read.Password.IsReadOnly()) 'Wrong identity/size'
   $left=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret);$right=[IntPtr]::Zero
   try{$right=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($read.Password);for($i=0;$i -lt 2560;$i+=2){Assert ([Runtime.InteropServices.Marshal]::ReadInt16($left,$i) -eq [Runtime.InteropServices.Marshal]::ReadInt16($right,$i)) 'Roundtrip changed fictional secret'}}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($left);if($right -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($right)}}
   Refuses {[Domenia.Security.CredentialVault]::Read((Get-DomeniaCredentialVaultTarget -DomainDn $domain -Scope Directory -UserName $user),'OTHER\vault-test')}
   Assert ((Remove-DomeniaCredentialVaultCredential -DomainDn $domain -Scope Directory -UserName $user -Enabled).Removed) 'Delete not confirmed'
   Assert (-not (Remove-DomeniaCredentialVaultCredential -DomainDn $domain -Scope Directory -UserName $user -Enabled).Removed) 'Absent key delete did not report missing'
   Assert ($null -eq (Get-DomeniaCredentialVaultCredential -DomainDn $domain -Scope Directory -UserName $user -Enabled)) 'Deleted secret remains'
   $script:nativeExecuted=$true
  }finally{try{[void](Remove-DomeniaCredentialVaultCredential -DomainDn $domain -Scope Directory -UserName $user -Enabled)}finally{if($null -ne $read){$read.Password.Dispose()};$secret.Dispose()}}
 }
}
$failed=@($checks|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='CredentialVault';Passed=($failed -eq 0);Total=$checks.Count;Failed=$failed;NativeWindowsRequested=[bool]$NativeWindows;NativeWindowsExecuted=$nativeExecuted;NetworkUsed=$false;Checks=$checks.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
$report.Checks|Format-Table -Property Name,Passed,Error -Wrap|Out-String|Write-Output
if($failed){exit 1}
