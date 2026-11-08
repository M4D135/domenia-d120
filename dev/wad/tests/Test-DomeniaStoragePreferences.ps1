#requires -Version 5.1
param([string]$ReportPath='', [string]$WadPath=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $WadPath 'modules\Domenia-Experience.Model.ps1')
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $WadPath 'Domenia-Core.ps1'),[ref]$t,[ref]$e);if($e.Count){throw 'Core parse failure'}
foreach($name in @('Get-DomeniaDefaultSettings','Load-DomeniaSettings','Save-DomeniaSettings','Get-DomeniaSetting','Set-DomeniaSetting')){
 $node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));if($node.Count -ne 1){throw $name};. ([scriptblock]::Create($node[0].Extent.Text))
}
$storageAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $WadPath 'modules\Domenia-Storage.UI.ps1'),[ref]$t,[ref]$e);if($e.Count){throw 'Storage UI parse failure'}
foreach($name in @('Get-DomeniaBackupPreferencesJson','Restore-DomeniaBackupPreferences')){
 $node=@($storageAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));if($node.Count -ne 1){throw $name};. ([scriptblock]::Create($node[0].Extent.Text))
}
$script:RejectNextPreferenceWrite=$false
$script:File=Join-Path ([IO.Path]::GetTempPath()) ('domenia-prefs-'+[guid]::NewGuid().ToString('N')+'.json')
function Read-DomeniaPreference($FileName){if($FileName -eq 'Domenia.settings.json' -and (Test-Path $script:File)){return [IO.File]::ReadAllText($script:File)};return ''}
function Write-DomeniaPreference($FileName,$Value){if($script:RejectNextPreferenceWrite){$script:RejectNextPreferenceWrite=$false;return $false};if($FileName -ne 'Domenia.settings.json'){throw 'Unexpected preference'};[IO.File]::WriteAllText($script:File,$Value,[Text.UTF8Encoding]::new($false));return $true}
function Get-DomeniaStoredTheme{return 'Light'}
function Write-AppLog($Text,$Level){}
function Write-DomeniaSwallowed($Category,$Operation,$ErrorRecord){}
$script:SettingsTimer=$null;$rows=[Collections.Generic.List[object]]::new()
function Expect($condition,$text){if(-not $condition){throw $text}}
function Case($name,$code){try{& $code;$rows.Add([pscustomobject]@{Name=$name;Passed=$true})}catch{$rows.Add([pscustomobject]@{Name=$name;Passed=$false;Error=$_.Exception.Message})}}
function Reload-Settings{Save-DomeniaSettings -Immediate -ThrowOnFailure;$script:Settings=$null;[void](Load-DomeniaSettings)}
try{
 Case 'Enabled automatic policy and retention settings survive two disk reloads' {
  [void](Load-DomeniaSettings);$policy='{"Version":1,"AutomaticBackup":true,"BackupHours":48,"BackupKeep":5,"InventoryDays":120}'
  $script:Settings['Storage.PolicyJson']=$policy;Reload-Settings;Reload-Settings
  Expect ((Get-DomeniaSetting 'Storage.PolicyJson' '') -ceq $policy) 'Storage policy lost on reload'
 }
 Case 'Restored database choice is available before startup opens any local store' {
  $key='Storage.Database.'+('ab'*32);$path='C:\DomeniaLab\restored.db'
  $script:Settings[$key]=$path;Reload-Settings
  Expect ((Get-DomeniaSetting $key '') -ceq $path) 'Restored database preference lost'
  $startup=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-Window'},$true)
  $calls=@($startup.Body.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))
  $load=@($calls|Where-Object {$_.GetCommandName() -eq 'Load-DomeniaSettings'})
  Expect ($load.Count -eq 1) 'Startup must load persisted preferences once'
  foreach($name in @('Load-XamlWindow','Wire-Events','Initialize-DomeniaWorkerContextCache','Initialize-DomeniaDatabase')){
   $call=@($calls|Where-Object {$_.GetCommandName() -eq $name})
   Expect ($call.Count -eq 1 -and $load[0].Extent.StartOffset -lt $call[0].Extent.StartOffset) ('Preferences loaded too late: '+$name)
  }
 }
 Case 'Disabled policy remains explicit after reload' {
  $policy='{"Version":1,"AutomaticBackup":false,"BackupHours":48,"BackupKeep":5}'
  $script:Settings['Storage.PolicyJson']=$policy;Reload-Settings
  Expect ((Get-DomeniaSetting 'Storage.PolicyJson' '') -ceq $policy) 'Disabled policy lost on reload'
 }
 Case 'Last success and verified receipt survive reload independently for each store' {
  $a='a'*64;$b='b'*64;$date='2026-10-18T08:53:42.0000000Z';$detail='{"Automatic":true,"Origin":"Scheduled","File":"test.db","Bytes":4096}'
  $script:Settings['Storage.Backup.Last.'+$a]=$date;$script:Settings['Storage.Backup.LastDetail.'+$a]=$detail
  $script:Settings['Storage.Backup.Last.'+$b]='2026-10-17T08:00:00.0000000Z';Reload-Settings;Reload-Settings
  Expect ((Get-DomeniaSetting ('Storage.Backup.Last.'+$a) '') -ceq $date) 'Last success lost'
  Expect ((Get-DomeniaSetting ('Storage.Backup.LastDetail.'+$a) '') -ceq $detail) 'Verified receipt lost'
  Expect ((Get-DomeniaSetting ('Storage.Backup.Last.'+$b) '') -eq '2026-10-17T08:00:00.0000000Z') 'Other store lost'
 }
 Case 'A chosen dashboard OU is a scoped setting and survives reload' {
  $key='Fleet.Scope.'+('ab'*32)
  $script:Settings[$key]='{"Dn":"OU=Postes,DC=example,DC=invalid","Subtree":true}'
  Reload-Settings
  Expect ((Get-DomeniaSetting $key '') -like '*OU=Postes*') 'OU du tableau de bord perdue'
 }
 Case 'R40 the last overview of a domain is a scoped setting and survives reload' {
  $key='Fleet.LastView.'+('cd'*32)
  $script:Settings[$key]='{"Version":1,"StoreId":"s","ScopeKey":"*","Machines":3}'
  Reload-Settings
  Expect ((Get-DomeniaSetting $key '') -like '*"Machines":3*') 'Derniere vue du tableau de bord perdue'
  Expect (Test-DomeniaScopedSettingName $key) 'Forme fermee refusee'
  foreach($bad in @('Fleet.LastView.short',('Fleet.LastView.'+('CD'*32)),('Fleet.LastView.'+('cd'*32)+'.extra'))){Expect (-not (Test-DomeniaScopedSettingName $bad)) ('Nom hors forme accepte : '+$bad)}
 }
 Case 'Unknown keys, invalid store names and non-string values remain rejected' {
  $values=@{'Storage.PolicyJson.extra'='x';'Storage.Backup.Last.short'='x';('Storage.Backup.Last.'+('A'*64))='x';('Storage.Backup.Last.'+('c'*64))=@('x');'Storage.PolicyJson'=@{AutomaticBackup=$true}}
  $clean=ConvertTo-DomeniaExperienceSettings $values (Get-DomeniaDefaultSettings)
  foreach($k in $values.Keys){Expect (-not $clean.Contains($k)) ('Unapproved value retained: '+$k)}
 }
 Case 'Complete snapshot restores layouts and query choices without restoring old paths or identities' {
  $pathKey='Storage.Database.'+('d'*64)
  $script:Settings['GridLayoutsJson']='{"Search":{"Width":180}}';$script:Settings['Dashboard.Fleet.Layout']='snapshot-layout';$script:Settings['Widgets.Fleet']='snapshot-widgets';$script:Settings['Query.Library']='snapshot-query'
  $script:Settings[$pathKey]='C:\old.db';$script:Settings['RemoteCredentialUser']='OLD\operator';$script:Settings['SecretsCredentialUser']='OLD\secrets'
  $snapshot=Get-DomeniaBackupPreferencesJson
  Expect ((-not $snapshot.Contains('OLD')) -and (-not $snapshot.Contains('old.db'))) 'snapshot contains no session identities or active database path'
  $script:Settings[$pathKey]='C:\new.db';$script:Settings['RemoteCredentialUser']='CURRENT\operator';$script:Settings['SecretsCredentialUser']='CURRENT\secrets';$script:Settings['Dashboard.Fleet.Layout']='changed-layout'
  Restore-DomeniaBackupPreferences -Json $snapshot
  Expect ((Get-DomeniaSetting 'Dashboard.Fleet.Layout' '') -ceq 'snapshot-layout') 'layout restored'
  Expect ((Get-DomeniaSetting 'Widgets.Fleet' '') -ceq 'snapshot-widgets') 'widgets restored'
  Expect ((Get-DomeniaSetting 'Query.Library' '') -ceq 'snapshot-query') 'query choices restored'
  Expect ((Get-DomeniaSetting 'GridLayoutsJson' '') -ceq '{"Search":{"Width":180}}') 'grid disposition restored'
  Expect ((Get-DomeniaSetting $pathKey '') -ceq 'C:\new.db') 'verified new database remains active after reload'
  Expect ((Get-DomeniaSetting 'RemoteCredentialUser' '') -ceq 'CURRENT\operator') 'current session account preserved'
  Expect ((Get-DomeniaSetting 'SecretsCredentialUser' '') -ceq 'CURRENT\secrets') 'current secret account preserved'
 }
 Case 'Preference write failure rolls back current layouts and leaves the active database choice intact' {
  $pathKey='Storage.Database.'+('e'*64);$script:Settings[$pathKey]='C:\verified.db';$script:Settings['Dashboard.Fleet.Layout']='current-layout';Reload-Settings
  $script:RejectNextPreferenceWrite=$true;$caught=$false
  try{Restore-DomeniaBackupPreferences -Json '{"Dashboard.Fleet.Layout":"old-layout"}'}catch{$caught=$true}
  Expect $caught 'preference restoration failure is visible'
  Expect ((Get-DomeniaSetting 'Dashboard.Fleet.Layout' '') -ceq 'current-layout') 'current in-memory layout rolled back'
  Reload-Settings
  Expect ((Get-DomeniaSetting 'Dashboard.Fleet.Layout' '') -ceq 'current-layout') 'current layout remains durable'
  Expect ((Get-DomeniaSetting $pathKey '') -ceq 'C:\verified.db') 'verified database choice preserved'
 }
 Case 'Extra preference size and count limits remain enforced' {
  $values=@{'Storage.PolicyJson'= ('x'*1048577)}
  for($i=0;$i -lt 260;$i++){$values[('Storage.Backup.Last.'+$i.ToString('x64'))]='2026-10-18T08:00:00Z'}
  $clean=ConvertTo-DomeniaExperienceSettings $values (Get-DomeniaDefaultSettings)
  Expect (-not $clean.Contains('Storage.PolicyJson')) 'Oversized policy retained'
  Expect (@($clean.Keys|Where-Object {$_ -like 'Storage.Backup.Last.*'}).Count -eq 256) 'Extra key bound changed'
 }
}finally{if(Test-Path $script:File){Remove-Item $script:File}}
$failed=@($rows|Where-Object{-not $_.Passed}).Count
$r=[ordered]@{Suite='StoragePreferences';PowerShell=$PSVersionTable.PSVersion.ToString();Passed=$rows.Count-$failed;Failed=$failed;DiskRoundtrip=$true;ProductionPreferencesTouched=$false;CoreSha256=(Get-FileHash (Join-Path $WadPath 'Domenia-Core.ps1') -Algorithm SHA256).Hash;ModelSha256=(Get-FileHash (Join-Path $WadPath 'modules\Domenia-Experience.Model.ps1') -Algorithm SHA256).Hash;Results=$rows.ToArray()}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($r|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
$r|ConvertTo-Json -Depth 5
if($failed){exit 1}
