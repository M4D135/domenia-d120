#requires -Version 5.1
# Synthetic callbacks and a genuine canonical batch validator. No credentials, WPF or network.
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop';$wad=Split-Path -Parent $PSScriptRoot
foreach($name in @('Common.Model','Store.Model','Accounts.Store.UI')){. (Join-Path $wad ('modules/Domenia-'+$name+'.ps1'))}
$cases=[Collections.Generic.List[object]]::new()
function Assert {param($Value,[string]$Why='Assertion failed')if(-not $Value){throw $Why}}
function Case {param($Name,[scriptblock]$Body)Reset-Fixture;try{& $Body|Out-Null;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true})}catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
function Reset-Fixture {
 $script:AccountPreferences=$null;$script:SessionEpoch=1L;$script:DatabaseScopedPath=Join-Path ([IO.Path]::GetTempPath()) 'domenia-account-fixture.db'
 $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid'};$script:AsyncEngineClosing=$false
 $script:Control=@{TxtAccountRemoteUser=[pscustomobject]@{Text='';IsKeyboardFocusWithin=$false};TxtAccountSecretsUser=[pscustomobject]@{Text='';IsKeyboardFocusWithin=$false}}
 $script:Submissions=[Collections.Generic.List[object]]::new();$script:Reads=[Collections.Generic.List[object]]::new();$script:Logs=[Collections.Generic.List[string]]::new();$script:Admission=$true
}
function Get-DomeniaControl {param($Name)return $script:Control[$Name]}
function Set-Status {param($Text,$Level)$script:Logs.Add($Text)}
function Write-AppLog {param($Text,$Level)$script:Logs.Add($Text)}
function ConvertTo-DomeniaMachineKey {param($Name)return $Name.Trim().ToLowerInvariant()}
function Test-DomeniaLocalAccountName {param($UserName,$Target)return ($UserName.StartsWith('.\') -or $UserName.StartsWith($Target+'\',[StringComparison]::OrdinalIgnoreCase))}
function New-DomeniaStoreContext {
 param($RequestId)
 if(-not $script:DatabaseScopedPath){throw 'No database'}
 return [pscustomobject]@{Version=1;Path=$script:DatabaseScopedPath;DomainDn=$script:Conn.BaseDn.ToLowerInvariant();StoreId=(Get-DomeniaStoreId $script:DatabaseScopedPath $script:Conn.BaseDn);SessionEpoch=$script:SessionEpoch;RequestId=$RequestId;Generation=0;ScopeDn='';Subtree=$true}
}
function Submit-DomeniaStoreBatch {
 param($Context,$BatchId,$Sequence,$Changes,$SuccessHandler,$ErrorHandler,$CallbackState)
 $batch=ConvertTo-DomeniaStoreBatch -Context $Context -BatchId $BatchId -Sequence $Sequence -Changes $Changes
 $script:Submissions.Add([pscustomobject]@{Batch=$batch;State=$CallbackState;Success=$SuccessHandler;Error=$ErrorHandler})
 return [pscustomobject]@{Accepted=$script:Admission;Backpressure=(-not $script:Admission)}
}
function Request-DomeniaStoreRead {param($Context,$Query,$SuccessHandler,$ErrorHandler,$CallbackState)$script:Reads.Add($CallbackState);return 'read-job'}
function New-Receipt {
 param($State,[string]$Scope='Remote',[string]$User='EXAMPLE\reader',[long]$Revision=1)
 return [pscustomobject]@{Saved=$true;DataSource='SQLite';StoreId=$State.Context.StoreId;Path=$State.Context.Path;DomainDn=$State.Context.DomainDn;BatchId=$State.BatchId;SnapshotRevision=$Revision;AccountPreferences=@([pscustomobject]@{Scope=$Scope;UserName=$User;DomainDn=$State.Context.DomainDn})}
}
Case 'Admission does not publish an uncommitted username' {
 Assert (Save-DomeniaAccountPreference Remote 'EXAMPLE\reader');Assert ((Get-DomeniaRememberedAccount Remote) -eq '')
 Assert ($script:Submissions.Count -eq 1);Assert ($script:AccountPreferences.Pending.Count -eq 1)
}
Case 'Committed SELECT fills username and no password field' {
 [void](Save-DomeniaAccountPreference Remote 'EXAMPLE\reader');$s=$script:Submissions[0].State
 Complete-DomeniaAccountPreferenceSave (New-Receipt $s) $s
 Assert ((Get-DomeniaRememberedAccount Remote) -ceq 'EXAMPLE\reader');Assert ($script:Control.TxtAccountRemoteUser.Text -ceq 'EXAMPLE\reader')
 Assert ($script:AccountPreferences.Pending.Count -eq 0)
 Assert (($script:Submissions[0].Batch.Json -notmatch 'Password|PSCredential|SecureString'))
}
Case 'Backpressure retains exact ID and payload for next admission' {
 $script:Admission=$false;[void](Save-DomeniaAccountPreference Remote 'EXAMPLE\reader');$first=$script:Submissions[0].Batch
 $script:Admission=$true;Sync-DomeniaAccountPreferences;$second=$script:Submissions[1].Batch
 Assert ($first.BatchId -ceq $second.BatchId);Assert ($first.Hash -ceq $second.Hash)
 Sync-DomeniaAccountPreferences;Assert ($script:Submissions.Count -eq 2)
}
Case 'Failure keeps preference pending and warns only once' {
 [void](Save-DomeniaAccountPreference Remote 'EXAMPLE\reader');$s=$script:Submissions[0].State
 Fail-DomeniaAccountPreferenceSave 'busy' $s;Fail-DomeniaAccountPreferenceSave 'busy' $s
 Assert ($script:Logs.Count -eq 1);Assert ($script:AccountPreferences.Pending.Count -eq 1);Assert ((Get-DomeniaRememberedAccount Remote) -eq '')
}
Case 'False receipt never publishes or forgets pending data' {
 [void](Save-DomeniaAccountPreference Remote 'EXAMPLE\reader');$s=$script:Submissions[0].State;$r=New-Receipt $s;$r.Saved=$false
 Complete-DomeniaAccountPreferenceSave $r $s;Assert ($script:AccountPreferences.Pending.Count -eq 1);Assert ((Get-DomeniaRememberedAccount Remote) -eq '')
}
Case 'Old epoch may commit but never populates a new session' {
 [void](Save-DomeniaAccountPreference Remote 'EXAMPLE\reader');$s=$script:Submissions[0].State;$script:SessionEpoch++
 Complete-DomeniaAccountPreferenceSave (New-Receipt $s) $s
 Assert ($script:AccountPreferences.Pending.Count -eq 0);Assert ((Get-DomeniaRememberedAccount Remote) -eq '')
}
Case 'Different database never leaks a remembered account' {
 [void](Save-DomeniaAccountPreference Remote 'EXAMPLE\reader');$s=$script:Submissions[0].State;$script:DatabaseScopedPath+='-other'
 Complete-DomeniaAccountPreferenceSave (New-Receipt $s) $s;Assert ((Get-DomeniaRememberedAccount Remote) -eq '')
}
Case 'Read callback cannot overwrite edits typed while waiting' {
 Sync-DomeniaAccountPreferences;$s=$script:Reads[0];$script:Control.TxtAccountRemoteUser.Text='EXAMPLE\typed'
 Complete-DomeniaAccountPreferenceRead (New-Receipt $s) $s
 Assert ($script:Control.TxtAccountRemoteUser.Text -ceq 'EXAMPLE\typed');Assert ((Get-DomeniaRememberedAccount Remote) -ceq 'EXAMPLE\reader')
}
Case 'Old snapshot cannot replace newer committed account preference' {
 Sync-DomeniaAccountPreferences;$read=$script:Reads[0]
 [void](Save-DomeniaAccountPreference Remote 'EXAMPLE\new');$save=$script:Submissions[0].State
 Complete-DomeniaAccountPreferenceSave (New-Receipt $save -User 'EXAMPLE\new' -Revision 2) $save
 Complete-DomeniaAccountPreferenceRead (New-Receipt $read -User 'EXAMPLE\old' -Revision 1) $read
 Assert ((Get-DomeniaRememberedAccount Remote) -ceq 'EXAMPLE\new')
}
Case 'Local account is bound to one target, not the remote default' {
 [void](Save-DomeniaAccountPreference Remote 'PC01\operator' 'PC01');$s=$script:Submissions[0].State
 Assert ($s.Changes[0].Scope -ceq 'RemoteLocal:pc01')
 Complete-DomeniaAccountPreferenceSave (New-Receipt $s -Scope 'RemoteLocal:pc01' -User 'PC01\operator') $s
 Assert ((Get-DomeniaRememberedAccount Remote PC01) -ceq 'PC01\operator');Assert ((Get-DomeniaRememberedAccount Remote PC02) -eq '');Assert ((Get-DomeniaRememberedAccount Remote) -eq '')
}
Case 'Secrets account maps to two separate usages in one transaction' {
 [void](Save-DomeniaAccountPreference Secrets 'EXAMPLE\secrets');$s=$script:Submissions[0].State
 Assert ($s.Changes.Count -eq 2);Assert (($s.Changes.Scope -join ',') -ceq 'Laps,BitLocker')
}
Case 'Forgetting account writes a tombstone, not the login account' {
 [void](Save-DomeniaAccountPreference Remote '');$s=$script:Submissions[0].State
 Assert ($s.Changes[0].UserName -ceq '');Complete-DomeniaAccountPreferenceSave (New-Receipt $s -User '') $s
 Assert ((Get-DomeniaRememberedAccount Remote) -eq '')
}
Case 'Local read runs once when loaded; busy read waits before retry' {
 Sync-DomeniaAccountPreferences;$s=$script:Reads[0];$r=New-Receipt $s;$r|Add-Member Busy $true
 Complete-DomeniaAccountPreferenceRead $r $s;Sync-DomeniaAccountPreferences;Assert ($script:Reads.Count -eq 1)
 $script:AccountPreferences.ReadAfter=[datetime]::MinValue;Sync-DomeniaAccountPreferences;$s=$script:Reads[1]
 Complete-DomeniaAccountPreferenceRead (New-Receipt $s) $s;Sync-DomeniaAccountPreferences;Assert ($script:Reads.Count -eq 2)
}
Case 'Absent base cannot falsely claim a remembered username' {
 $script:DatabaseScopedPath='';Assert (-not (Save-DomeniaAccountPreference Remote 'EXAMPLE\reader'));Assert ($script:AccountPreferences.Pending.Count -eq 0)
}
Case 'Domain mismatch and wrong store receipt are rejected' {
 Sync-DomeniaAccountPreferences;$s=$script:Reads[0];$r=New-Receipt $s;$r.DomainDn='DC=other,DC=invalid'
 Assert (-not (Set-DomeniaCommittedAccountPreferences $r $s.Context));Assert ((Get-DomeniaRememberedAccount Remote) -eq '')
}
$failed=@($cases|Where-Object{-not $_.Passed});$report=[pscustomobject]@{Suite='AccountPreferences';Passed=$cases.Count-$failed.Count;Failed=$failed.Count;NetworkCalls=0;Cases=$cases.ToArray()}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 8
if($failed.Count){exit 1}
