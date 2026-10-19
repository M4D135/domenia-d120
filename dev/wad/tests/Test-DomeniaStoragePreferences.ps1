#requires -Version 5.1
param([string]$ReportPath='', [string]$WadPath=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $WadPath 'modules\Domenia-Experience.Model.ps1')
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $WadPath 'Domenia-Core.ps1'),[ref]$t,[ref]$e);if($e.Count){throw 'Core parse failure'}
foreach($name in @('Get-DomeniaDefaultSettings','Load-DomeniaSettings','Save-DomeniaSettings','Get-DomeniaSetting','Set-DomeniaSetting')){
 $node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));if($node.Count -ne 1){throw $name};. ([scriptblock]::Create($node[0].Extent.Text))
}
$script:File=Join-Path ([IO.Path]::GetTempPath()) ('domenia-prefs-'+[guid]::NewGuid().ToString('N')+'.json')
function Read-DomeniaPreference($FileName){if($FileName -eq 'Domenia.settings.json' -and (Test-Path $script:File)){return [IO.File]::ReadAllText($script:File)};return ''}
function Write-DomeniaPreference($FileName,$Value){if($FileName -ne 'Domenia.settings.json'){throw 'Unexpected preference'};[IO.File]::WriteAllText($script:File,$Value,[Text.UTF8Encoding]::new($false));return $true}
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
 Case 'Unknown keys, invalid store names and non-string values remain rejected' {
  $values=@{'Storage.PolicyJson.extra'='x';'Storage.Backup.Last.short'='x';('Storage.Backup.Last.'+('A'*64))='x';('Storage.Backup.Last.'+('c'*64))=@('x');'Storage.PolicyJson'=@{AutomaticBackup=$true}}
  $clean=ConvertTo-DomeniaExperienceSettings $values (Get-DomeniaDefaultSettings)
  foreach($k in $values.Keys){Expect (-not $clean.Contains($k)) ('Unapproved value retained: '+$k)}
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
