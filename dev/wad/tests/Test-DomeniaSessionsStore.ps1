#requires -Version 5.1
# Synthetic collection/store/publication lifecycle; no WTS, Windows vault or real credentials.
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop';$wad=Split-Path -Parent $PSScriptRoot
foreach($name in @('Common.Model','Store.Model','Workstation.Model','Sessions.UI')){. (Join-Path $wad ('modules/Domenia-'+$name+'.ps1'))}
$cases=[Collections.Generic.List[object]]::new()
function Assert {param($Value,[string]$Why='Assertion failed')if(-not $Value){throw $Why}}
function Case {param($Name,[scriptblock]$Body)Reset-Fixture;try{& $Body|Out-Null;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true})}catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
function Reset-Fixture {
 $script:SessionEpoch=1L;$script:SelectedObjectGeneration=2L;$script:SelectedObject=[pscustomobject]@{DN='CN=PC,DC=example,DC=invalid'}
 $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid'};$script:Displayed=0;$script:StoreFailures=0;$script:Recoveries=0;$script:ValidContext=$true
 $script:Submissions=[Collections.Generic.List[object]]::new();$script:Logs=[Collections.Generic.List[string]]::new();$script:Owned=$null;$script:WorkerMode='Throw'
 $script:State=[pscustomobject]@{Computer='PC';DN=$script:SelectedObject.DN;Epoch=1L;Generation=2L;RemoteStartedUtc='2026-10-13T10:00:00Z';ResultKind='Sessions';RequestKey='WTS'}
 $script:Packet=[pscustomobject]@{Computer='PC';Rows=@([pscustomobject]@{Id=1;Station='Console';User='operator';Domain='EXAMPLE';State='Actif';Protocol='Console';Detail='Lecture WTS';LogonTicks=0L;IdleTicks=0L});ObservedUtc='2026-10-13T10:01:00Z';Identity='EXAMPLE\reader'}
}
function Get-DomeniaEffectiveWorkerResult {param($Result,$Fields)return $Result}
function Submit-DomeniaRemoteDetail {param($Data,$State,$Succeeded,$SourceCompletedUtc,$ErrorText)$script:Submissions.Add([pscustomobject]@{Data=$Data;State=$State;Succeeded=$Succeeded;At=$SourceCompletedUtc;Error=$ErrorText});return $true}
function Fail-DomeniaRemoteDetailStored {param($Message,$State)$script:StoreFailures++;$script:Logs.Add($Message)}
function Test-DomeniaClassicResultCurrent {param($Result,$State,[switch]$ContextOnly)return ($script:ValidContext -and ($ContextOnly -or [string](Get-DomeniaMember $Result 'DataSource') -ceq 'SQLite'))}
function Set-DomeniaItemsSource {param($Name,$Items)$script:Displayed++;return $true}
function Set-DomeniaControlText {param($Name,$Text)return $true}
function Request-DomeniaAccessRecovery {param($Operation,$OperationId,$ErrorValue,$DN,[switch]$Interactive)$script:Recoveries++;return $true}
function Write-AppLog {param($Text,$Level)$script:Logs.Add($Text)}
function New-DomeniaWorkerRunspace {
 param($OperationId,$Code)
 $script:Owned=Get-Variable -Name ownedSecret -Scope 1 -ValueOnly
 if($script:WorkerMode -eq 'Throw'){throw 'fixture worker creation failed'}
 $rs=[runspacefactory]::CreateRunspace();$rs.Open();$rs.Dispose()
 return [pscustomobject]@{Runspace=$rs;CommandName='Get-Date'}
}
Case 'Successful WTS collection enters store before any GUI publication' {
 Complete-DomeniaSessionsCollected $script:Packet $script:State
 Assert ($script:Submissions.Count -eq 1);Assert ($script:Displayed -eq 0);Assert $script:Submissions[0].Succeeded
 Assert ($script:Submissions[0].Data.Rows[0].User -ceq 'operator');Assert ($script:Submissions[0].At -like '2026-10-13T10:01:00*')
}
Case 'Only committed SQLite result can populate sessions grid' {
 Complete-DomeniaSessionsRead $script:Packet $script:State;Assert ($script:Displayed -eq 0)
 $script:Packet|Add-Member DataSource SQLite;Complete-DomeniaSessionsRead $script:Packet $script:State;Assert ($script:Displayed -eq 1)
}
Case 'Remote extra properties are not copied to persistent session data' {
 $script:Packet|Add-Member Password 'fixture-value';$script:Packet.Rows[0]|Add-Member Token 'fixture-value'
 Complete-DomeniaSessionsCollected $script:Packet $script:State
 $json=$script:Submissions[0].Data|ConvertTo-Json -Depth 5 -Compress;Assert ($json -notmatch 'Password|Token|fixture-value')
}
Case 'Complete empty session list is a valid result, absent list is not' {
 $script:Packet.Rows=@();Complete-DomeniaSessionsCollected $script:Packet $script:State
 Assert ($script:Submissions.Count -eq 1);Assert ($script:Submissions[0].Data.Rows.Count -eq 0)
 $script:Packet.Rows=$null;Complete-DomeniaSessionsCollected $script:Packet $script:State;Assert ($script:StoreFailures -eq 1);Assert ($script:Submissions.Count -eq 1)
}
Case 'Wrong target and missing timestamp never reach the base as a fresh result' {
 $script:Packet.Computer='OTHER';Complete-DomeniaSessionsCollected $script:Packet $script:State
 $script:Packet.Computer='PC';$script:Packet.ObservedUtc='';Complete-DomeniaSessionsCollected $script:Packet $script:State
 Assert ($script:Submissions.Count -eq 0);Assert ($script:StoreFailures -eq 2)
}
Case 'Failure records attempt without marking empty sessions or displaying network result' {
 Fail-DomeniaSessionsCollected 'access denied fixture' $script:State
 Assert ($script:Submissions.Count -eq 1);Assert (-not $script:Submissions[0].Succeeded)
 Assert ($script:Submissions[0].At -ceq $script:State.RemoteStartedUtc);Assert ($script:Displayed -eq 0);Assert ($script:Recoveries -eq 0)
}
foreach($condition in @('Epoch','Generation','DN','Context')){
 Case ('Committed session data ignored after '+$condition+' changes') {
  $script:Packet|Add-Member DataSource SQLite
  switch($condition){Epoch{$script:SessionEpoch++}Generation{$script:SelectedObjectGeneration++}DN{$script:SelectedObject.DN='CN=OTHER,DC=example,DC=invalid'}Context{$script:ValidContext=$false}}
  Complete-DomeniaSessionsRead $script:Packet $script:State;Assert ($script:Displayed -eq 0)
 }
}
foreach($failure in @('Throw','DisposedRunspace')){
 Case ('Owned secure string disposed when '+$failure+' fails before BeginInvoke') {
  $script:WorkerMode=$failure;$password=ConvertTo-SecureString 'synthetic-not-a-login' -AsPlainText -Force
  try{
   $caught=$false;try{Start-DomeniaRemoteCredentialSession -User 'EXAMPLE\fixture' -Password $password -Computer PC}catch{$caught=$true}
   Assert $caught;Assert ($null -ne $script:Owned);Assert ($password.Length -gt 0) 'Caller password was disposed'
   $disposed=$false;try{[void]$script:Owned.Copy()}catch{$disposed=$true};Assert $disposed 'Owned copy leaked after failed startup'
  }finally{$password.Dispose()}
 }
}
$failed=@($cases|Where-Object{-not $_.Passed});$report=[pscustomobject]@{Suite='SessionsStore';Passed=$cases.Count-$failed.Count;Failed=$failed.Count;NetworkCalls=0;NativeWtsValidated=$false;Cases=$cases.ToArray()}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 8
if($failed.Count){exit 1}
