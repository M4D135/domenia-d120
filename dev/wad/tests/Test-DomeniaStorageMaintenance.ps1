#requires -Version 5.1
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$t=$null;$e=$null
$core=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Core parse failed'}
$native=@($core.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-DomeniaWinSqliteNative'},$true))[0].Extent.Text
if($PSVersionTable.PSEdition -eq 'Core'){
 $native=$native.Replace('[AppDomain]::CurrentDomain.DefineDynamicAssembly','[Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly')
 if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)){$native=$native.Replace('winsqlite3.dll','/usr/lib/libsqlite3.dylib')}
 elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){$native=$native.Replace('winsqlite3.dll','libsqlite3.so.0')}
}
. ([scriptblock]::Create($native));[void](Initialize-DomeniaWinSqliteNative)
foreach($module in @('Store.Model','Cache.Model','Storage.Worker')){. (Join-Path $wad ('modules/Domenia-'+$module+'.ps1'))}
$maintenance=Get-DomeniaStorageMaintenanceWorkerCode;$retention=Get-DomeniaStorageRetentionWorkerCode
$ast=[Management.Automation.Language.Parser]::ParseInput($maintenance,[ref]$t,[ref]$e);if($e.Count){throw 'Maintenance worker parse failed'}
foreach($fn in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){. ([scriptblock]::Create($fn.Extent.Text))}
$folder=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.domenia-maintenance-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder)
$cases=[Collections.Generic.List[object]]::new();$script:checks=0;$domain='dc=test'
function Expect {param([bool]$Condition,[string]$Text);$script:checks++;if(-not $Condition){throw $Text}}
function Case {param([string]$Name,[scriptblock]$Code);try{& $Code;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}}
function Refused {param([scriptblock]$Code,[string]$Contains='');$caught=$false;try{& $Code|Out-Null}catch{$caught=$true;if($Contains){Expect ($_.Exception.Message -like ('*'+$Contains+'*')) ('refusal '+$Contains)}};Expect $caught 'refused'}
$schema=@($core.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]},$true)|Where-Object{$_.Value -match '^PRAGMA journal_mode=WAL;' -and $_.Value -match 'CREATE TABLE IF NOT EXISTS schema_info'})
if($schema.Count -ne 1){throw 'Schema count'}
function New-Database {param([string]$Name,[long]$Revision=7)
 $p=Join-Path $folder ($Name+'.db');$db=Open-DomeniaDatabase $p
 try{[void](Invoke-DomeniaDbExec $schema[0].Value $db);$id=Get-DomeniaStoreId $p $domain;[void](Invoke-DomeniaDbExec ("INSERT INTO domenia_store_state(id,store_id,domain_dn,revision) VALUES(1,'$id','$domain',$Revision);") $db)}finally{Close-DomeniaDatabase $db};return $p
}
function Query {param([string]$Path,[string]$Sql,[switch]$Write)
 $db=Open-DomeniaDatabase $Path -ReadOnly:(-not $Write)
 try{if($Write){[void](Invoke-DomeniaDbExec $Sql $db)}else{return @(Invoke-DomeniaDbQuery $Sql $db)}}finally{Close-DomeniaDatabase $db}
}
function Run-Maintenance {param([string]$Action,[string]$Path,[string]$Target='',[string]$Id=([guid]::NewGuid().ToString('D')),[string]$Fingerprint='',[string]$Source=$Path)
 $Payload=[pscustomobject]@{Action=$Action;ActivePath=$Path;SourcePath=$Source;TargetPath=$Target;OperationId=$Id;DomainDn=$domain;ExpectedFingerprint=$Fingerprint;BudgetSeconds=30}
 return & ([scriptblock]::Create($maintenance))
}
function Run-Retention {param([string]$Path,[bool]$DryRun=$true,[string]$Fingerprint='',$Cutoffs=$script:cutoffs)
 $Payload=[pscustomobject]@{Path=$Path;DomainDn=$domain;StoreId=(Get-DomeniaStoreId $Path $domain);Cutoffs=$Cutoffs;DryRun=$DryRun;ExpectedFingerprint=$Fingerprint}
 return & ([scriptblock]::Create($retention))
}
try{
 Case 'Policy defaults are opt-in and reject invalid bounds' {
  $p=ConvertTo-DomeniaStoragePolicy;Expect (-not $p.AutomaticBackup -and $p.BackupHours -eq 24 -and $p.BackupKeep -eq 7) 'safe defaults'
  foreach($bad in @(@{BackupHours=0},@{BackupKeep=1},@{PresenceDays=-1},@{AutomaticBackup='true'},@{Version=2})){Refused {ConvertTo-DomeniaStoragePolicy $bad}}
  Expect ((ConvertTo-DomeniaStoragePolicy @{PresenceDays=0}).PresenceDays -eq 0) 'explicit unlimited retention'
 }
 Case 'Backup scheduling respects interval, busy state and failed-attempt cooldown' {
  $now=[datetime]'2026-01-10T12:00:00Z';$p=ConvertTo-DomeniaStoragePolicy @{AutomaticBackup=$true}
  Expect ((Get-DomeniaStorageBackupDecision $p -NowUtc $now).Due) 'first backup due'
  Expect (-not (Get-DomeniaStorageBackupDecision $p -NowUtc $now -Busy $true).Due) 'busy'
  Expect ((Get-DomeniaStorageBackupDecision $p -NowUtc $now -LastAttemptUtc $now.AddMinutes(-5).ToString('o')).Reason -eq 'RetryCooldown') 'cooldown'
  Expect ((Get-DomeniaStorageBackupDecision $p -NowUtc $now -LastSuccessUtc $now.AddDays(1).ToString('o')).Reason -eq 'InvalidClock') 'future date'
 }
 Case 'Move copies and verifies then redirects the preserved original' {
  $script:active=New-Database 'move';$script:target=Join-Path $folder 'moved.db';$script:operation=[guid]::NewGuid().ToString('D')
  $before=Run-Maintenance Inspect $active
  $script:receipt=Run-Maintenance Move $active $target $operation $before.Source.Fingerprint
  Expect ($receipt.Committed -and $receipt.OriginalPreserved -and $receipt.Revision -eq 8) 'committed copy'
  Expect ([IO.File]::Exists($active) -and [IO.File]::Exists($target)) 'both files kept'
  Expect ($receipt.StoreId -ceq (Get-DomeniaStoreId $target $domain)) 'target identity'
  Refused {Query $active 'UPDATE domenia_store_state SET revision=9;' -Write} 'StorageRedirected'
  Expect ((Query $target 'SELECT revision FROM domenia_store_state;')[0].revision -eq 8) 'copy readback'
 }
 Case 'Restart discovers durable operation without writing and explicit resume verifies it' {
  $r=Run-Maintenance ReadRedirect $active;Expect ($r.ReadOnly -and $r.Redirect.OperationId -ceq $operation -and $r.Redirect.TargetPath -ceq $target) 'durable receipt'
  $r=Run-Maintenance Resume $active $target $operation;Expect ($r.Committed -and $r.TargetPath -ceq $target) 'resume'
  Refused {Run-Maintenance Resume $active $target ([guid]::NewGuid().ToString('D'))} 'Redirection differente'
 }
 Case 'Rollback removes only its own marker before any new target commit' {
  $r=Run-Maintenance Rollback $active $target $operation;Expect ($r.TargetPath -ceq $active -and $r.Revision -eq 7) 'old revision returned'
  Expect ($null -eq (Run-Maintenance ReadRedirect $active).Redirect) 'marker removed'
  Query $active 'UPDATE domenia_store_state SET revision=8;' -Write
  Expect ([IO.File]::Exists($target)) 'copy retained'
 }
 Case 'An intervening source write or preexisting destination refuses the copy' {
  $p=New-Database 'changed';$preview=Run-Maintenance Inspect $p;Query $p 'UPDATE domenia_store_state SET revision=revision+1;' -Write
  Refused {Run-Maintenance Move $p (Join-Path $folder 'not-created.db') ([guid]::NewGuid().ToString('D')) $preview.Source.Fingerprint} 'source a change'
  $preview=Run-Maintenance Inspect $p;Refused {Run-Maintenance Move $p $target ([guid]::NewGuid().ToString('D')) $preview.Source.Fingerprint} 'nouveau fichier'
 }
 Case 'Rollback refuses a target that received a later commit' {
  $p=New-Database 'later';$next=Join-Path $folder 'later-copy.db';$id=[guid]::NewGuid().ToString('D');$preview=Run-Maintenance Inspect $p
  [void](Run-Maintenance Move $p $next $id $preview.Source.Fingerprint);Query $next 'UPDATE domenia_store_state SET revision=revision+1;' -Write
  Refused {Run-Maintenance Rollback $p $next $id} 'nouvelle base a change'
  Expect ($null -ne (Run-Maintenance ReadRedirect $p).Redirect) 'marker retained'
 }
 Case 'Restore uses a separate verified target and never overwrites the active file' {
  $p=New-Database 'restore-active' 20;$source=New-Database 'restore-backup' 3;$dest=Join-Path $folder 'restored.db';$preview=Run-Maintenance Inspect $p -Source $source
  $r=Run-Maintenance Restore $p $dest ([guid]::NewGuid().ToString('D')) $preview.Source.Fingerprint -Source $source
  Expect ($r.Revision -eq 21 -and $r.TargetPath -ceq $dest -and [IO.File]::Exists($source)) 'restored independent revision'
 }
 Case 'Retention deletes only old migrated families and preserves unknown recent and legacy rows' {
  $script:ret=New-Database 'retention';$old=[datetime]::UtcNow.AddDays(-100).ToString('o');$recent=[datetime]::UtcNow.AddDays(-1).ToString('o');$cut=[datetime]::UtcNow.AddDays(-30).ToString('o');$script:cutoffs=[pscustomobject]@{Presence=$cut;Console=$cut;Inventory=$cut;Probe=$cut;Detail=$cut}
  $sql=[Text.StringBuilder]::new()
  foreach($id in 1..4){$guid='00000000-0000-0000-0000-'+$id.ToString('000000000000');if($id -ne 4){[void]$sql.AppendLine("INSERT INTO domenia_legacy_observation_imports(object_guid,payload_hash,imported_at) VALUES('$guid','','$old');")};$attempt=if($id -eq 2){$recent}elseif($id -eq 3){'invalid'}else{$old};[void]$sql.AppendLine("INSERT INTO domenia_observations(object_guid,family,dn,attempt_at,status,success_at,payload,revision) VALUES('$guid','Presence','CN=$id,DC=test','$attempt','Success','$old','{}',7);")}
  [void]$sql.AppendLine("INSERT INTO domenia_observations(object_guid,family,dn,attempt_at,status,success_at,payload,revision) VALUES('00000000-0000-0000-0000-000000000001','Inventory','CN=1,DC=test','$recent','Error','$old','{}',7);")
  Query $ret $sql.ToString() -Write
  $script:preview=Run-Retention $ret;Expect ($preview.DryRun -and -not $preview.Committed -and (@($preview.Counts|Where-Object Family -eq Presence)[0].Rows -eq 1)) 'only old migrated row'
  Expect ($preview.SkippedLegacyRows -eq 1) 'legacy protection'
  $r=Run-Retention $ret $false $preview.Fingerprint
  Expect ($r.Committed -and $r.DeletedRows -eq 1 -and $r.ReceiptsPreserved -and $r.Backup.Verified) 'transaction and mandatory backup'
  Expect ((Query $ret 'SELECT count(*) n FROM domenia_observations;')[0].n -eq 4) 'recent/error/unknown/legacy retained'
  Expect ((Query $r.Backup.Path 'SELECT count(*) n FROM domenia_observations;')[0].n -eq 5) 'backup precedes deletion'
  Expect ((Get-FileHash $r.Backup.Path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $r.Backup.SHA256) 'backup bytes'
 }
 Case 'Retention refusal rolls back and never silently accepts stale confirmation' {
  $p=Run-Retention $ret;Query $ret 'UPDATE domenia_store_state SET revision=revision+1;' -Write
  Refused {Run-Retention $ret $false $p.Fingerprint} 'mesures ont change'
  Query $ret "CREATE TRIGGER refuse_retention BEFORE DELETE ON domenia_observations BEGIN SELECT RAISE(ABORT,'guard'); END;" -Write
  Refused {Run-Retention $ret} 'declencheur'
 }
}finally{
 $report=[pscustomobject]@{Suite='StorageMaintenance';Platform=[Environment]::OSVersion.VersionString;PowerShell=$PSVersionTable.PSVersion.ToString();Cases=$cases.ToArray();Total=$cases.Count;Passed=@($cases|Where-Object Passed).Count;Failed=@($cases|Where-Object{-not $_.Passed}).Count;Assertions=$script:checks;NoNetwork=$true;Scope='Temporary SQLite databases; no Active Directory or real-user data.'}
 if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
 Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
}
$report|Select-Object Total,Passed,Failed,Assertions|Format-List
if($report.Failed -gt 0){exit 1};exit 0
