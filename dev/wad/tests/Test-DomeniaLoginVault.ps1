#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='',[switch]$Wpf)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Core parse failed'}
function Import-Core {param([string]$Name)
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true));if($nodes.Count -ne 1){throw ('Function '+$Name)}
 . ([scriptblock]::Create(($nodes[0].Extent.Text -replace ('^function '+[regex]::Escape($Name)),('function script:'+$Name))))
}
foreach($name in @('New-DomeniaFastLoginSession','Complete-DomeniaLoginAuthRunspaceCleanup','Get-CfgValue','Convert-DomainToDn','Get-DomeniaFastLoginVaultIdentity','Update-DomeniaFastLoginVaultUi','Remove-DomeniaFastLoginVault','Save-DomeniaFastLoginVaultPreference','Start-DomeniaFastLoginAttempt','Complete-DomeniaFastLoginSuccess','Update-DomeniaFastLoginAttempt','Test-DomeniaComputerAccountIdentity','Save-AppConfig')){Import-Core $name}
. (Join-Path $wad 'modules/Domenia-CredentialVault.Model.ps1')
# UI-20 (lot X03): wording of a refusal, read by Update-DomeniaFastLoginAttempt.
. (Join-Path $wad 'modules/Domenia-Accounts.Model.ps1')
$cases=[Collections.Generic.List[object]]::new();$script:Assertions=0
function Assert {param([bool]$Value,[string]$Message);$script:Assertions++;if(-not $Value){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body);try{& $Body|Out-Null;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message+' '+$_.ScriptStackTrace+' Logs='+($script:Logs -join ' | ')})}}
function Secret {$s=[Security.SecureString]::new();1..24|ForEach-Object{$s.AppendChar([char](65+($_%20)))};$s.MakeReadOnly();return $s}
function Control {return [pscustomobject]@{Text='';IsEnabled=$true;IsChecked=$false;ToolTip='';Foreground='';Password='';SecurePassword=$null}}
function Fixture {
 $script:Config=[ordered]@{Auth=[ordered]@{RememberLogin=$false;LastLogin='';VaultDomainDn='DC=example,DC=invalid';VaultUserName='EXAMPLE\operator'};Conf=[ordered]@{AutoDiscover=$true;SearchBase=''}}
 $script:FastLoginUi=@{};foreach($key in @('Login','Password','PasswordPeek','PasswordPeekText','Remember','VaultRemember','VaultUse','VaultForget','Error','Stage','Technical','Window')){$script:FastLoginUi[$key]=Control}
 $script:FastLoginUi.Technical|Add-Member -MemberType ScriptMethod -Name Clear -Value {$this.Text=''}
 $script:FastLoginUi.Login.Text='EXAMPLE\operator'
 $script:FastLoginUi.Password.SecurePassword=Secret
 $script:FastLoginState=[pscustomobject]@{Session=$null;Reveal=$false;Login='';Password='';LoginOk=$false;UseCurrentCredentials=$false;VaultRemember=$false;VaultUsed=$false}
 $script:Conn=[ordered]@{Connected=$false;Credential=$null};$script:FastLoginVaultRejected=@{};$script:DemoMode=$false;$script:SearchBase='';$script:Server='';$script:Reads=0;$script:Writes=0;$script:Deletes=0;$script:Starts=0;$script:Reg=@{};$script:RegFail=$false;$script:Missing=$false;$script:VaultThrow=$false;$script:Busy=$false;$script:Logs=@();$script:ReturnSuccess=$true;$script:FastLoginTimer=$null
 $script:FakeResult=[pscustomobject]@{Success=$true;BindUser='EXAMPLE\operator';Domain='example.invalid';Netbios='EXAMPLE';BaseDn='DC=example,DC=invalid';Server='dc.example.invalid';RootPath='LDAP://dc.example.invalid';DurationMs=1;AuthMode='Explicit';AuthMethod='Fixture';Error='';ErrorCategory=''}
}
# Only native vault, authentication and UI services are substituted. No actual credential or domain exists.
function Get-DomeniaCredentialVaultCredential {param($DomainDn,$Scope,$UserName,[switch]$Enabled);Assert $Enabled 'manual opt-in absent';$script:Reads++;if($script:VaultThrow){throw 'fixture unavailable'};if($script:Missing){return $null};$script:ReadSecret=Secret;return [Management.Automation.PSCredential]::new($UserName,$script:ReadSecret)}
function Save-DomeniaCredentialVaultCredential {param($DomainDn,$Scope,$Credential,[switch]$Enabled,[switch]$AuthenticationConfirmed);Assert ($Enabled -and $AuthenticationConfirmed) 'write lacks consent/auth';$script:Writes++;$script:SavedDomain=$DomainDn;$script:SavedUser=$Credential.UserName;if($script:VaultThrow){throw 'fixture unavailable'};return [pscustomobject]@{Saved=$true}}
function Remove-DomeniaCredentialVaultCredential {param($DomainDn,$Scope,$UserName,[switch]$Enabled);Assert $Enabled 'delete lacks consent';$script:Deletes++;$script:Deleted=@($DomainDn,$Scope,$UserName);return [pscustomobject]@{Removed=$true}}
function Start-DomeniaFastLoginWorker {param($Session);$script:Starts++;$Session.AsyncResult=[pscustomobject]@{IsCompleted=$true};$Session.EndInvoked=$true;return $Session}
function Read-DomeniaAuthRunspaceResult {param($Session);return $script:FakeResult}
function Set-DomeniaFastLoginBusy {param([bool]$Busy);$script:Busy=$Busy;Update-DomeniaFastLoginVaultUi -Busy $Busy}
function Get-DomeniaBootStatusColor {param($Kind);return $Kind}
function Write-DomeniaFastLoginLog {param($Stage,$Status,$Detail,$DurationMs);$script:Logs+=([string]$Stage+':'+[string]$Detail)}
function Add-DomeniaFastLoginDetail {param($Text)}
function Write-AppLog {param($Text,$Level)}
function Get-DomeniaProcessWindowsIdentity {return 'EXAMPLE\windows'}
function New-DomeniaTimer {param($Owner,$IntervalMs,[switch]$Standalone,[switch]$RunWhenHidden,[switch]$Start,$Tick);$c=[pscustomobject]@{IsEnabled=$true};$c|Add-Member -MemberType ScriptMethod -Name Stop -Value {$this.IsEnabled=$false};return $c}
function Set-DomeniaSurfaceResult {param($Window,$Result);$script:Accepted=[bool]$Result}
function Test-Path {param($LiteralPath);return $true}
function Set-ItemProperty {param($LiteralPath,$Name,$Value,[switch]$Force);if($script:RegFail){throw 'fixture HKCU denied'};$script:Reg[$Name]=$Value}
function Reset-DomeniaFastLoginAttempt {param([switch]$Kill,[switch]$KeepDiagnostics);if($null -ne $script:FastLoginState.Session){Complete-DomeniaLoginAuthRunspaceCleanup $script:FastLoginState.Session};$script:FastLoginState.Session=$null;Set-DomeniaFastLoginBusy $false}
Case 'Metadata and UI changes make no vault read or authentication' {
 Fixture;1..3|ForEach-Object{Update-DomeniaFastLoginVaultUi};Assert ($script:Reads -eq 0 -and $script:Starts -eq 0) 'automatic read';Assert $script:FastLoginUi.VaultUse.IsEnabled 'remembered exact identity inaccessible'
 $script:FastLoginUi.Login.Text='EXAMPLE\other';Update-DomeniaFastLoginVaultUi;Assert (-not $script:FastLoginUi.VaultUse.IsEnabled -and -not $script:FastLoginUi.VaultForget.IsEnabled) 'another identity used'
}
Case 'Different configured domain cannot select the previous domain vault' {
 Fixture;$script:SearchBase='OU=Parc,DC=other,DC=invalid';Update-DomeniaFastLoginVaultUi;Assert (-not $script:FastLoginUi.VaultUse.IsEnabled) 'cross-domain metadata used';Assert ($script:Reads -eq 0) 'vault read during check'
}
Case 'Secure session owns a private copy; completed cleanup cannot dispose caller secret' {
 Fixture;$s=Secret;$session=New-DomeniaFastLoginSession -Login 'EXAMPLE\operator' -SecurePassword $s
 Assert (-not [object]::ReferenceEquals($s,$session.OwnedSecret) -and $session.Request.PasswordLength -eq 24) 'not independently owned'
 Complete-DomeniaLoginAuthRunspaceCleanup $session;Assert ($s.Length -eq 24 -and $null -eq $session.OwnedSecret -and $session.Cleaned) 'ownership cleanup';$s.Dispose()
}
Case 'An unfinished worker retains its owned secret until actual completion' {
 Fixture;$s=Secret;$session=New-DomeniaFastLoginSession -Login 'EXAMPLE\operator' -SecurePassword $s;$session.AsyncResult=[pscustomobject]@{IsCompleted=$false}
 Complete-DomeniaLoginAuthRunspaceCleanup $session;Assert ($session.OwnedSecret.Length -eq 24 -and -not $session.Cleaned) 'active secret disposed'
 $session.AsyncResult.IsCompleted=$true;$session.EndInvoked=$true;Complete-DomeniaLoginAuthRunspaceCleanup $session;Assert ($null -eq $session.OwnedSecret -and $session.Cleaned) 'completed secret retained';$s.Dispose()
}
Case 'Manual vault click reads once and passes a SecureString to exactly one auth request' {
 Fixture;Start-DomeniaFastLoginAttempt -UseVault;$session=$script:FastLoginState.Session
 Assert ($script:Reads -eq 1 -and $script:Starts -eq 1 -and $session.Request.PasswordLength -eq 24) 'read/auth count'
 Assert ($session.Request.Credential.Password.Length -eq 24 -and $session.Request.ConfiguredBase -eq 'DC=example,DC=invalid') 'request missing secure copy/domain'
 $disposed=$false;try{$null=$script:ReadSecret.get_Length()}catch{$disposed=$true};Assert $disposed 'vault-read secret not cleared'
 Assert (-not $script:FastLoginUi.VaultUse.IsEnabled -and -not $script:FastLoginUi.VaultRemember.IsEnabled) 'controls enabled while busy'
}
Case 'Failed stored authentication blocks its exact identity without rereading or retrying' {
 Fixture;Start-DomeniaFastLoginAttempt -UseVault;$script:FakeResult.Success=$false;$script:FakeResult.Error='data 52e';$script:FakeResult.ErrorCategory='Credentials';Update-DomeniaFastLoginAttempt
 Assert (-not $script:FastLoginUi.VaultUse.IsEnabled -and $script:Writes -eq 0 -and -not $script:Conn.Connected) 'refused vault remains usable'
 Start-DomeniaFastLoginAttempt -UseVault;Assert ($script:Reads -eq 1 -and $script:Starts -eq 1) 'refused value retried'
}
Case 'Successful login keeps its own credential after session cleanup' {
 Fixture;Start-DomeniaFastLoginAttempt -UseVault;$session=$script:FastLoginState.Session;Update-DomeniaFastLoginAttempt
 Assert ($session.Cleaned -and $null -eq $session.OwnedSecret -and $script:Conn.Credential.Password.Length -eq 24) 'cleanup destroyed connected credential'
 Assert ($script:FastLoginState.LoginOk -and $script:Reads -eq 1 -and $script:Writes -eq 0) 'unrequested rewrite';$script:Conn.Credential.Password.Dispose()
}
Case 'Saving uses the clicked opt-in and the identity that actually authenticated' {
 Fixture;$script:FastLoginUi.VaultRemember.IsChecked=$true;Start-DomeniaFastLoginAttempt;$script:FastLoginUi.VaultRemember.IsChecked=$false;$script:FakeResult.BindUser='operator@example.invalid';Update-DomeniaFastLoginAttempt
 Assert ($script:Writes -eq 1 -and $script:SavedUser -eq 'operator@example.invalid' -and $script:SavedDomain -eq 'DC=example,DC=invalid') 'wrong consent or canonical identity'
 Assert ($script:Reg.VaultUserName -eq 'operator@example.invalid' -and $script:Reg.VaultDomainDn -eq 'DC=example,DC=invalid') 'missing pre-database identity metadata'
 Assert (($script:Reg.Keys|Sort-Object)-join ',' -eq 'LastLogin,RememberLogin,VaultDomainDn,VaultUserName') 'unexpected registry data';$script:Conn.Credential.Password.Dispose()
}
Case 'Unchecked manual login never reads or writes a vault secret' {
 Fixture;Start-DomeniaFastLoginAttempt;Update-DomeniaFastLoginAttempt;Assert ($script:Reads -eq 0 -and $script:Writes -eq 0 -and $script:Starts -eq 1) 'unrequested persistence';$script:Conn.Credential.Password.Dispose()
}
Case 'A missing or unavailable vault does not start authentication' {
 foreach($failure in @('Missing','VaultThrow')){Fixture;Set-Variable -Name $failure -Value $true -Scope Script;Start-DomeniaFastLoginAttempt -UseVault;Assert ($script:Reads -eq 1 -and $script:Starts -eq 0 -and $null -eq $script:FastLoginState.Session) $failure}
}
Case 'Failed manual authentication never stores the checked secret' {
 Fixture;$script:FastLoginUi.VaultRemember.IsChecked=$true;Start-DomeniaFastLoginAttempt;$script:FakeResult.Success=$false;Update-DomeniaFastLoginAttempt;Assert ($script:Writes -eq 0 -and $script:Reg.Count -eq 0) 'failed credential stored'
}
Case 'Windows session and demonstration cannot access the optional vault' {
 Fixture;$script:FastLoginUi.VaultRemember.IsChecked=$true;Start-DomeniaFastLoginAttempt -UseCurrentCredentials;$script:FakeResult.AuthMode='Windows';Update-DomeniaFastLoginAttempt;Assert ($script:Reads -eq 0 -and $script:Writes -eq 0 -and $script:FastLoginState.LoginOk -and $script:Conn.AuthMode -eq 'Windows') 'windows session persisted or failed'
 Fixture;$script:DemoMode=$true;Start-DomeniaFastLoginAttempt -UseVault;Update-DomeniaFastLoginVaultUi;Assert ($script:Reads -eq 0 -and $script:Starts -eq 0 -and -not $script:FastLoginUi.VaultRemember.IsEnabled) 'demo accessed vault'
}
Case 'Forget deletes only the selected exact identity and clears metadata without auth' {
 Fixture;Remove-DomeniaFastLoginVault;Assert ($script:Deletes -eq 1 -and ($script:Deleted -join '|') -eq 'DC=example,DC=invalid|Directory|EXAMPLE\operator') 'wrong deleted target';Assert ($script:Reg.VaultUserName -eq '' -and $script:Reg.VaultDomainDn -eq '' -and $script:Starts -eq 0) 'metadata or authentication changed'
}
Case 'Optional save failure preserves the valid login without fallback storage' {
 Fixture;$script:FastLoginUi.VaultRemember.IsChecked=$true;$script:VaultThrow=$true;Start-DomeniaFastLoginAttempt;Update-DomeniaFastLoginAttempt;Assert ($script:FastLoginState.LoginOk -and $script:Conn.Connected -and $script:Writes -eq 1) 'optional save invalidated auth';Assert ($script:Reg.VaultUserName -eq 'EXAMPLE\operator' -and @($script:Logs|Where-Object{$_ -like 'VAULT_SAVE:*'}).Count -eq 1) 'failed save pretended success';$script:Conn.Credential.Password.Dispose()
}
Case 'A successful manual correction re-enables only its exact vault identity and leaves shared guard untouched' {
 Fixture;$id=Get-DomeniaFastLoginVaultIdentity;$script:FastLoginVaultRejected[$id.Target]=$true;$script:FastLoginVaultRejected['other-target']=$true
 $script:DomeniaCredentialGuard=[hashtable]::Synchronized(@{Faults=@{'operator@example.invalid'='refused'}})
 Start-DomeniaFastLoginAttempt;Update-DomeniaFastLoginAttempt
 Assert (-not $script:FastLoginVaultRejected.ContainsKey($id.Target) -and $script:FastLoginVaultRejected.ContainsKey('other-target')) 'wrong target unblocked'
 Assert ($script:DomeniaCredentialGuard.Faults.Count -eq 1 -and $script:Reads -eq 0 -and $script:Writes -eq 0) 'shared guard silently reset';$script:Conn.Credential.Password.Dispose()
}
Case 'Preference storage failure reports partial persistence without denying a successful login' {
 Fixture;$script:RegFail=$true;$script:FastLoginUi.VaultRemember.IsChecked=$true;Start-DomeniaFastLoginAttempt;Update-DomeniaFastLoginAttempt
 Assert ($script:Conn.Connected -and $script:Writes -eq 1 -and $script:Reg.Count -eq 0) 'login or registry receipt incorrect'
 Assert (@($script:Logs|Where-Object {$_ -like 'VAULT_SAVE:*HKCU*'}).Count -eq 1) 'partial persistence not reported';$script:Conn.Credential.Password.Dispose()
}
Case 'SE-16 : the account comes from SecurePassword; the plain Password text is never read' {
 Fixture;$script:PasswordCleared=$false
 $script:FastLoginUi.Password|Add-Member -MemberType ScriptProperty -Name Password -Value {throw 'SE-16: plain Password read'} -SecondValue {param($value) $script:PasswordCleared=([string]$value -eq '')} -Force
 Start-DomeniaFastLoginAttempt;$session=$script:FastLoginState.Session
 Assert ($script:Starts -eq 1 -and $null -ne $session) ('validation not started : '+[string]$script:FastLoginUi.Error.Text)
 Assert ($session.Request.Credential.Password.Length -eq 24 -and $session.Request.Credential.Password.IsReadOnly()) 'credential not sealed from SecurePassword'
 Assert $script:PasswordCleared 'password box not emptied once the request left'
 Update-DomeniaFastLoginAttempt;if($null -ne $script:Conn.Credential){$script:Conn.Credential.Password.Dispose()}
}
Case 'SE-16 : an empty SecurePassword is refused before any session' {
 Fixture;$script:FastLoginUi.Password.SecurePassword=[Security.SecureString]::new()
 Start-DomeniaFastLoginAttempt
 Assert ($script:Starts -eq 0 -and $null -eq $script:FastLoginState.Session -and [string]$script:FastLoginUi.Error.Text -eq 'Mot de passe manquant.') ('empty secret accepted : '+[string]$script:FastLoginUi.Error.Text)
}
Case 'Conflicting login modes refuse before native vault access' {
 Fixture;$refused=$false;try{Start-DomeniaFastLoginAttempt -UseVault -UseCurrentCredentials}catch{$refused=$true}
 Assert ($refused -and $script:Reads -eq 0 -and $script:Starts -eq 0) 'mixed login mode accepted'
}
Case 'Real XAML contains explicit unchecked consent and manual buttons (single template since CD-10)' {
 foreach($name in @('Get-DomeniaStandardLoginXaml')){
  Import-Core $name;function Convert-DomeniaXamlToBootTheme {param($Xaml);return $Xaml};$xml=[xml](& $name)
  $ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('w','http://schemas.microsoft.com/winfx/2006/xaml/presentation');$ns.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
  $box=$xml.SelectSingleNode('//w:CheckBox[@x:Name="ChkLoginVaultRemember"]',$ns);Assert ($null -ne $box -and $box.IsChecked -eq 'False') 'default vault consent'
  foreach($button in @('BtnLoginVaultUse','BtnLoginVaultForget')){Assert ($null -ne $xml.SelectSingleNode(('//w:Button[@x:Name="'+$button+'"]'),$ns)) ('Missing '+$button)}
 }
}
$wpfExecuted=$false
if($Wpf){Case 'Windows renders the sign-in form with native vault controls' {
 Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
 foreach($name in @('Get-DomeniaBootThemePalette','Get-DomeniaBootThemeResources','Convert-DomeniaXamlToBootTheme')){Import-Core $name}
 function Get-DomeniaStoredTheme {return 'Light'}
 foreach($mode in @('Standard')){$xaml=& ('Get-Domenia'+$mode+'LoginXaml');$window=[Windows.Markup.XamlReader]::Parse($xaml);try{Assert ($null -ne $window.FindName('BtnLoginVaultUse') -and -not $window.FindName('ChkLoginVaultRemember').IsChecked) 'WPF vault control';$window.Measure([Windows.Size]::new(590,800));$window.Arrange([Windows.Rect]::new(0,0,590,800));$window.UpdateLayout()}finally{$window.Close()}}
 $script:wpfExecuted=$true
}}
$failed=@($cases|Where-Object{-not $_.Passed}).Count
$r=[pscustomobject]@{Suite='LoginVault';Passed=($failed -eq 0);Total=$cases.Count;Failed=$failed;Assertions=$script:Assertions;NetworkCalls=0;NativeVaultUsed=$false;WpfExecuted=$wpfExecuted;Cases=$cases.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($r|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))}
$r|ConvertTo-Json -Depth 7
if($failed){exit 1};exit 0
