#requires -Version 5.1
param([string]$ReportPath='',[string]$CaseFilter='')
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
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
foreach($module in @('Common.Model','QueryLibrary.Model','Store.Model','Cache.Model','Storage.Worker')){. (Join-Path $wad ('modules/Domenia-'+$module+'.ps1'))}
$maintenance=Get-DomeniaStorageMaintenanceWorkerCode;$retention=Get-DomeniaStorageRetentionWorkerCode;$integrity=Get-DomeniaStorageIntegrityWorkerCode;$usageCode=Get-DomeniaStorageUsageWorkerCode
$ast=[Management.Automation.Language.Parser]::ParseInput($maintenance,[ref]$t,[ref]$e);if($e.Count){throw 'Maintenance worker parse failed'}
foreach($fn in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){. ([scriptblock]::Create($fn.Extent.Text))}
$folder=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.domenia-maintenance-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder)
$cases=[Collections.Generic.List[object]]::new();$script:checks=0;$domain='dc=test'
function Expect {param([bool]$Condition,[string]$Text);$script:checks++;if(-not $Condition){throw $Text}}
function Case {param([string]$Name,[scriptblock]$Code);if($CaseFilter -and $Name -notmatch $CaseFilter){return};try{& $Code;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}}
function Refused {param([scriptblock]$Code,[string]$Contains='');$caught=$false;try{& $Code|Out-Null}catch{$caught=$true;if($Contains){Expect ($_.Exception.Message -like ('*'+$Contains+'*')) ('refusal '+$Contains)}};Expect $caught 'refused'}
$schema=@($core.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]},$true)|Where-Object{$_.Value -match '^PRAGMA journal_mode=WAL;' -and $_.Value -match 'CREATE TABLE IF NOT EXISTS schema_info'})
if($schema.Count -ne 1){throw 'Schema count'}
# The AST keeps the here-string unexpanded: the query library tables are inserted exactly as the core does at run time.
$schemaSql=[string]$schema[0].Value;if($schemaSql.Contains('$(Get-DomeniaQueryLibrarySchema)')){$schemaSql=$schemaSql.Replace('$(Get-DomeniaQueryLibrarySchema)',(Get-DomeniaQueryLibrarySchema))}
function New-Database {param([string]$Name,[long]$Revision=7,[switch]$NoState)
 $p=Join-Path $folder ($Name+'.db');$db=Open-DomeniaDatabase $p
 try{[void](Invoke-DomeniaDbExec $schemaSql $db);$id=Get-DomeniaStoreId $p $domain;if(-not $NoState){[void](Invoke-DomeniaDbExec ("INSERT INTO domenia_store_state(id,store_id,domain_dn,revision) VALUES(1,'$id','$domain',$Revision);") $db)}}finally{Close-DomeniaDatabase $db};return $p
}
function New-CorruptFile {param([string]$Name);$p=Join-Path $folder ($Name+'.db');[IO.File]::WriteAllBytes($p,[Text.Encoding]::ASCII.GetBytes(('not a sqlite database '*256)));return $p}
function Get-TestHash {param([string]$Path);return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Run-Integrity {param([string]$Path);$Payload=[pscustomobject]@{Path=$Path;DomainDn=$domain};return & ([scriptblock]::Create($integrity))}
function Run-Usage {param([string]$Path);$Payload=[pscustomobject]@{Path=$Path};return & ([scriptblock]::Create($usageCode))}
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
 Case 'Backup is standalone and readable after export without WAL sidecars' {
  $p=New-Database 'backup-source';$export=Join-Path $folder 'export.db'
  $Payload=[pscustomobject]@{Database=$p;BackupDirectory=(Join-Path $folder 'manual-backups');CopyTo=$export;BudgetSeconds=30;Keep=2}
  $r=& ([scriptblock]::Create((Get-DomeniaStorageBackupWorkerCode)))
  Expect ($r.Verified -and $r.CopiedTo -ceq $export) 'backup published and exported'
  foreach($path in @($r.Backup,$export)){
   Expect ((Query $path 'PRAGMA journal_mode;')[0].journal_mode -eq 'delete') 'standalone journal mode'
   Expect ((Query $path 'SELECT revision FROM domenia_store_state;')[0].revision -eq 7) 'export readable without sidecars'
   foreach($suffix in @('-wal','-shm')){Expect (-not [IO.File]::Exists($path+$suffix)) 'no auxiliary file required'}
   Expect ((Get-TestHash $path).ToLowerInvariant() -ceq $r.SHA256) 'same verified bytes'
  }
 }
 Case 'Complete backup restores canonical data queries and the hash-linked preferences snapshot' {
  $p=New-Database 'complete-source' 4;$current=New-Database 'complete-active' 20
  $data='{"Name":"PC-SNAPSHOT","State":"Actif"}';$recipe='{"Name":"Saved recipe","Class":"Win32_OperatingSystem"}'
  $settings='{"Theme":"Dark","GridLayoutsJson":"{\"Search\":{\"Width\":180}}","Dashboard.Fleet.Layout":"fixture-layout","Widgets.Fleet":"fixture-widgets","Query.Library":"fixture-query"}'
  Query $p ("INSERT INTO domenia_directory_data(object_guid,payload,field_times,revision,observed_at) VALUES('00000000-0000-0000-0000-000000000001',"+(ConvertTo-DomeniaSqlLiteral $data)+",'{}',4,'2026-10-01T00:00:00Z');INSERT INTO domenia_account_preferences VALUES('dc=test','Remote','TEST\operator','2026-10-01T00:00:00Z',4);INSERT INTO domenia_query_recipes(id,domain_dn,name,name_fold,category,revision,definition_version,definition_json,definition_sha256,created_utc,updated_utc) VALUES('snapshot-query','dc=test','Saved recipe','saved recipe','Personal',1,1,"+(ConvertTo-DomeniaSqlLiteral $recipe)+",'fixture-hash','2026-10-01','2026-10-01');INSERT INTO domenia_query_recipe_revisions VALUES('snapshot-query',1,1,"+(ConvertTo-DomeniaSqlLiteral $recipe)+",'fixture-hash','2026-10-01');") -Write
  $export=Join-Path $folder 'complete-export.db'
  $Payload=[pscustomobject]@{Database=$p;BackupDirectory=(Join-Path $folder 'complete-backups');CopyTo=$export;BudgetSeconds=30;Keep=2;PreferencesJson=$settings}
  $backup=& ([scriptblock]::Create((Get-DomeniaStorageBackupWorkerCode)))
  Expect ($backup.PreferencesIncluded -and [IO.File]::Exists($backup.PreferencesPath) -and [IO.File]::Exists($export+'.preferences.json')) 'both exported and local copies carry their snapshot'
  $sidecar=[IO.File]::ReadAllText($export+'.preferences.json')|ConvertFrom-Json
  Expect ($sidecar.DatabaseSHA256 -ceq (Get-TestHash $export).ToLowerInvariant()) 'sidecar identifies exact database bytes'
  $preview=Run-Maintenance Inspect $current -Source $export
  Expect ($preview.Source.Preferences.Present -and $preview.Source.Preferences.SettingsJson -ceq $settings) 'preview confirms exact settings'
  $restored=Join-Path $folder 'complete-restored.db'
  $r=Run-Maintenance Restore $current $restored ([guid]::NewGuid().ToString('D')) $preview.Source.Fingerprint -Source $export
  Expect ($r.Committed -and $r.Preferences.Present -and $r.Preferences.SettingsJson -ceq $settings) 'receipt carries verified snapshot only after successful publication'
  Expect ((Query $restored 'SELECT payload FROM domenia_directory_data;')[0].payload -ceq $data) 'canonical data restored'
  Expect ((Query $restored 'SELECT definition_json FROM domenia_query_recipes;')[0].definition_json -ceq $recipe) 'saved query restored'
  Expect ((Query $restored 'SELECT definition_json FROM domenia_query_recipe_revisions;')[0].definition_json -ceq $recipe) 'query history restored'
  Expect ((Query $restored 'SELECT user_name FROM domenia_account_preferences;')[0].user_name -ceq 'TEST\operator') 'database account preferences restored'
 }
 Case 'Mismatched or over-deep preferences are refused before a restore changes its active base' {
  $p=New-Database 'snapshot-invalid-source';$active=New-Database 'snapshot-invalid-active';$sidecar=$p+'.preferences.json'
  $bad=[pscustomobject]@{Format='Domenia.BackupPreferences.1';DatabaseSHA256=('0'*64);SettingsJson='{"Theme":"Dark"}'}
  [IO.File]::WriteAllText($sidecar,($bad|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $before=Get-TestHash $active
  Refused {Run-Maintenance Inspect $active -Source $p} 'SHA-256'
  Expect ((Get-TestHash $active) -ceq $before) 'bad attachment does not change active database'
  $bad.DatabaseSHA256=(Get-TestHash $p).ToLowerInvariant();$bad.SettingsJson=('{"a":'*10)+'0'+('}'*10)
  [IO.File]::WriteAllText($sidecar,($bad|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  Refused {Run-Maintenance Inspect $active -Source $p} 'imbriquees'
  Expect ((Get-TestHash $active) -ceq $before) 'over-deep attachment does not change active database'
  [IO.File]::Delete($sidecar)
  $preview=Run-Maintenance Inspect $active -Source $p
  Expect (-not $preview.Source.Preferences.Present) 'old backups explicitly report no preferences snapshot'
  $target=Join-Path $folder 'legacy-data-only.db'
  $r=Run-Maintenance Restore $active $target ([guid]::NewGuid().ToString('D')) $preview.Source.Fingerprint -Source $p
  Expect ($r.Committed -and (-not $r.Preferences.Present)) 'old database restores without inventing preferences'
 }
 Case 'Changing only the preferences attachment invalidates a confirmed restore preview' {
  $source=New-Database 'snapshot-changed-source';$active=New-Database 'snapshot-changed-active';$sidecar=$source+'.preferences.json'
  $doc=[pscustomobject]@{Format='Domenia.BackupPreferences.1';DatabaseSHA256=(Get-TestHash $source).ToLowerInvariant();SettingsJson='{"Theme":"Dark"}'}
  [IO.File]::WriteAllText($sidecar,($doc|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $preview=Run-Maintenance Inspect $active -Source $source
  $doc.SettingsJson='{"Theme":"Light"}';[IO.File]::WriteAllText($sidecar,($doc|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $target=Join-Path $folder 'snapshot-stale.db'
  Refused {Run-Maintenance Restore $active $target ([guid]::NewGuid().ToString('D')) $preview.Source.Fingerprint -Source $source} 'source a change'
  Expect (-not [IO.File]::Exists($target)) 'no copy published under an obsolete confirmation'
 }
 Case 'Migration backup preserves pre-change schema and survives regular backup rotation' {
  $script:MigrationFixturePath=New-Database 'migration-rollback'
  Query $script:MigrationFixturePath "CREATE TABLE migration_fixture(id INTEGER PRIMARY KEY,value TEXT NOT NULL);INSERT INTO migration_fixture VALUES(1,'original');" -Write
  foreach($name in @('Get-DomeniaStoreBackupDirectory','Backup-DomeniaDatabase')){
   $node=@($core.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));Expect ($node.Count -eq 1) ('production helper '+$name);. ([scriptblock]::Create($node[0].Extent.Text))
  }
  function Get-DomeniaDatabasePath {return $script:MigrationFixturePath}
  function Get-CfgValue {param($Section,$Key,$Default);return $Default}
  $saved=Backup-DomeniaDatabase -Migration
  Expect ([IO.File]::Exists($saved) -and ([IO.Path]::GetFileName([IO.Path]::GetDirectoryName($saved)) -eq 'migrations')) 'rollback snapshot outside the rotation'
  Expect ((Query $saved 'PRAGMA journal_mode;')[0].journal_mode -eq 'delete') 'rollback copy standalone'
  $savedHash=Get-TestHash $saved
  $db=Open-DomeniaDatabase $script:MigrationFixturePath
  try{
   [void](Invoke-DomeniaDbExec 'BEGIN IMMEDIATE;ALTER TABLE migration_fixture ADD COLUMN phase TEXT;' $db)
   $caught=$false;try{[void](Invoke-DomeniaDbExec "INSERT INTO migration_fixture(id,value) VALUES(1,'duplicate');" $db)}catch{$caught=$true}
   Expect $caught 'actual SQLite constraint failure interrupts migration transaction'
   [void](Invoke-DomeniaDbExec 'ROLLBACK;' $db)
  }finally{Close-DomeniaDatabase $db}
  Expect (@(Query $script:MigrationFixturePath 'PRAGMA table_info(migration_fixture);'|Where-Object name -eq phase).Count -eq 0) 'schema extension rolled back'
  Expect ((Query $script:MigrationFixturePath 'SELECT value FROM migration_fixture;')[0].value -ceq 'original') 'data retained after failure'
  $Payload=[pscustomobject]@{Database=$script:MigrationFixturePath;BackupDirectory=(Join-Path ([IO.Path]::GetDirectoryName($script:MigrationFixturePath)) 'Backups');CopyTo='';BudgetSeconds=30;Keep=2}
  foreach($i in 1..3){[void](& ([scriptblock]::Create((Get-DomeniaStorageBackupWorkerCode))))}
  Expect ((Get-TestHash $saved) -ceq $savedHash) 'migration rollback snapshot preserved byte for byte through rotation'
  Expect ((Query $saved 'SELECT value FROM migration_fixture;')[0].value -ceq 'original') 'pre-migration state still readable'
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
 Case 'Retention with no eligible rows avoids a redundant backup and preserves the revision' {
  $p=New-Database 'retention-empty';$cut=[datetime]::UtcNow.AddDays(-30).ToString('o');$limits=[pscustomobject]@{Presence=$cut}
  $before=Run-Retention $p -Cutoffs $limits
  Expect ((@($before.Counts|Where-Object Family -eq Presence)[0].Rows -eq 0) -and ($before.Revision -eq 7)) 'empty preview'
  $backupDirectory=Join-Path ([IO.Path]::GetDirectoryName($p)) 'Backups'
  $filesBefore=@(Get-ChildItem -LiteralPath $backupDirectory -Filter 'Domenia-retention-*.db' -File -ErrorAction SilentlyContinue).Count
  Refused {Run-Retention $p $false $before.Fingerprint -Cutoffs $limits} 'Aucune mesure a retirer'
  $filesAfter=@(Get-ChildItem -LiteralPath $backupDirectory -Filter 'Domenia-retention-*.db' -File -ErrorAction SilentlyContinue).Count
  Expect ($filesAfter -eq $filesBefore) 'no extra full database backup'
  Expect ((Query $p 'SELECT revision FROM domenia_store_state WHERE id=1;')[0].revision -eq 7) 'no revision write'
 }
 Case 'Retention refusal rolls back and never silently accepts stale confirmation' {
  $p=Run-Retention $ret;Query $ret 'UPDATE domenia_store_state SET revision=revision+1;' -Write
  Refused {Run-Retention $ret $false $p.Fingerprint} 'mesures ont change'
  Query $ret "CREATE TRIGGER refuse_retention BEFORE DELETE ON domenia_observations BEGIN SELECT RAISE(ABORT,'guard'); END;" -Write
  Refused {Run-Retention $ret} 'declencheur'
 }
 Case 'Point 31: inspection validates the destination with a write test and states sizes' {
  $p=New-Database 'location';$dest=Join-Path $folder 'location-new.db'
  $r=Run-Maintenance Inspect $p $dest
  Expect ($r.Target.Writable -and $r.Target.Path -ceq $dest) 'destination checked'
  Expect ($r.Target.RequiredBytes -eq (Get-DomeniaStorageCopyReserve ([long]$r.Source.Bytes))) 'same reserve rule as the model'
  Expect ([long]$r.Target.FreeBytes -ge -1) 'free space measured or unknown'
  Expect (-not [IO.File]::Exists($dest)) 'inspection creates no base'
  Expect (@(Get-ChildItem -LiteralPath $folder -Filter '.domenia-probe-*' -Force).Count -eq 0) 'write probe removed'
  $text=(Get-DomeniaStorageMaintenancePreview -Mode Move -Inspection $r).Text
  Expect (($text -like '*réserve exigée*') -and ($text -like '*Retour arrière*') -and ($text -like ('*'+$dest+'*'))) 'preview names destination, reserve and rollback'
  Refused {Run-Maintenance Inspect $p $p} 'nouveau fichier'
  Refused {Run-Maintenance Inspect $p (Join-Path (Join-Path $folder 'missing') 'x.db')} 'doit exister'
 }
 Case 'Point 32: a move refused before publication says so and leaves the active base without marker' {
  $p=New-Database 'unpublished';$taken=Join-Path $folder 'unpublished-taken.db';[IO.File]::WriteAllBytes($taken,[byte[]]@(1));$before=Get-TestHash $p
  $preview=Run-Maintenance Inspect $p
  $message='';try{[void](Run-Maintenance Move $p $taken ([guid]::NewGuid().ToString('D')) $preview.Source.Fingerprint)}catch{$message=[string]$_.Exception.Message}
  Expect ($message -like 'StorageNothingPublished : *nouveau fichier*') ('pre-publication refusal stated: '+$message)
  $message='';try{[void](Run-Maintenance Move $p (Join-Path $folder 'unpublished-new.db') ([guid]::NewGuid().ToString('D')) ('0'*64))}catch{$message=[string]$_.Exception.Message}
  Expect ($message -like 'StorageNothingPublished : *source a change*') ('changed source stated: '+$message)
  Expect ((Get-TestHash $p) -ceq $before) 'active base byte for byte unchanged'
  Expect ($null -eq (Run-Maintenance ReadRedirect $p).Redirect) 'no marker'
  Expect (@(Get-ChildItem -LiteralPath $folder -Filter '.domenia-*.partial.db*' -Force).Count -eq 0) 'no temporary copy left'
  Expect (-not [IO.File]::Exists((Join-Path $folder 'unpublished-new.db'))) 'nothing published'
 }
 Case 'Point 31: a completed move is undone only through the marker of its original' {
  $p=New-Database 'undo' 30;$dest=Join-Path $folder 'undo-new.db';$id=[guid]::NewGuid().ToString('D')
  $preview=Run-Maintenance Inspect $p;$moved=Run-Maintenance Move $p $dest $id $preview.Source.Fingerprint
  Expect ($moved.RedirectWritten -and $moved.Revision -eq 31) 'switch completed with marker'
  # The session now runs on the copy; the undo names the original, which holds the marker, as the worker's base.
  $back=Run-Maintenance Rollback $p $dest $id
  Expect (($back.TargetPath -ceq $p) -and ($back.StoreId -ceq (Get-DomeniaStoreId $p $domain)) -and ($back.Revision -eq 30) -and (-not $back.RedirectWritten)) 'original returned with its identity'
  Expect ($null -eq (Run-Maintenance ReadRedirect $p).Redirect) 'marker removed'
  Expect ([IO.File]::Exists($dest)) 'copy kept'
 }
 Case 'Point 32: a base without canonical write can be moved, then rolled back to' {
  $p=New-Database 'fresh' -NoState;$dest=Join-Path $folder 'fresh-moved.db';$id=[guid]::NewGuid().ToString('D')
  $preview=Run-Maintenance Inspect $p $dest;Expect ($preview.Source.StoreId -ceq '' -and $preview.Source.Revision -eq 0) 'stateless source accepted for the active base'
  $r=Run-Maintenance Move $p $dest $id $preview.Source.Fingerprint
  Expect ($r.Committed -and $r.RedirectWritten -and $r.ActiveReadable -and $r.Revision -eq 1) 'copy identified'
  Expect ((Query $dest 'SELECT store_id FROM domenia_store_state;')[0].store_id -ceq (Get-DomeniaStoreId $dest $domain)) 'target identity row'
  Expect ((Query $p 'SELECT store_id FROM domenia_store_state;')[0].store_id -ceq (Get-DomeniaStoreId $p $domain)) 'original receives its own identity before the marker'
  $back=Run-Maintenance Rollback $p $dest $id;Expect ($back.TargetPath -ceq $p -and -not $back.RedirectWritten) 'rollback to the original'
 }
 Case 'Point 34: restore preview dates the backup and compares it with the active base' {
  $p=New-Database 'compare-active' 12;$b=New-Database 'compare-backup' 4;$dest=Join-Path $folder 'compare-restored.db'
  Query $p "INSERT INTO ad_objects(object_key,object_guid,object_type,name) VALUES('k1','g1','Machine','PC1'),('k2','g2','Machine','PC2');" -Write
  Query $b "INSERT INTO ad_objects(object_key,object_guid,object_type,name) VALUES('k1','g1','Machine','PC1');INSERT INTO domenia_store_batches(batch_id,payload_hash,request_id,sequence,revision,committed_at,changes_json) VALUES('b1','h','r',1,4,'2026-01-02T03:04:05.0000000Z','[]');" -Write
  $r=Run-Maintenance Inspect $p $dest -Source $b
  Expect ($r.Active.Readable -and $r.Active.Info.Counts.ad_objects -eq 2 -and $r.Source.Counts.ad_objects -eq 1) 'both sides counted'
  Expect ([string]$r.Source.LastCommitUtc -like '2026-01-02T03:04:05*' -and [string]$r.Source.LastWriteUtc) 'backup dated'
  $text=(Get-DomeniaStorageMaintenancePreview -Mode Restore -Inspection $r).Text
  Expect (($text -like '*Sauvegarde choisie*') -and ($text -like '*1 objet(s) AD de moins*')) 'restore preview announces the difference'
 }
 Case 'Point 34: restore over a corrupt active base leaves it untouched and writes no marker' {
  $p=New-CorruptFile 'corrupt-active';$b=New-Database 'corrupt-backup' 5;$dest=Join-Path $folder 'corrupt-restored.db';$before=Get-TestHash $p
  $preview=Run-Maintenance Inspect $p $dest -Source $b
  Expect ((-not $preview.Active.Readable) -and (Test-DomeniaStorageUnreadableMessage $preview.Active.Problem)) 'unreadable active reported'
  $r=Run-Maintenance Restore $p $dest ([guid]::NewGuid().ToString('D')) $preview.Source.Fingerprint -Source $b
  Expect ($r.Committed -and (-not $r.ActiveReadable) -and (-not $r.RedirectWritten) -and $r.Revision -eq 6) 'restored without marker'
  Expect ((Get-TestHash $p) -ceq $before) 'corrupt file byte for byte unchanged'
  Expect ((Query $dest 'SELECT store_id FROM domenia_store_state;')[0].store_id -ceq (Get-DomeniaStoreId $dest $domain)) 'restored copy identified'
  Refused {Run-Maintenance Move $p (Join-Path $folder 'corrupt-move.db') ([guid]::NewGuid().ToString('D')) 'x'}
 }
 Case 'Point 36: unreadable patterns are the same in the model and the maintenance worker' {
  foreach($text in @('SQLite prepare code 26 : file is not a database','SQLite step code 11 : database disk image is malformed','Integrite SQLite non confirmee.','Controle du stockage impossible : SQLite 26','SQLite step code 5 : database is locked','Domaine de base absent ou different.','SQLite code 110','')){
   Expect ((Test-MaintWUnreadable $text) -eq (Test-DomeniaStorageUnreadableMessage $text)) ('same decision: '+$text)
  }
  Expect (Test-DomeniaStorageUnreadableMessage 'SQLite prepare code 26 : file is not a database') 'corruption recognised'
  Expect (-not (Test-DomeniaStorageUnreadableMessage 'SQLite step code 5 : database is locked')) 'lock is not corruption'
 }
 Case 'Point 36: the integrity worker checks exactly the tables and columns of the model' {
  $expected=Get-DomeniaStorageSchemaExpectation
  $tablesText=[regex]::Match($integrity,'\$requiredTables=@\(([^)]*)\)').Groups[1].Value
  $tables=@([regex]::Matches($tablesText,"'([a-z_]+)'")|ForEach-Object{$_.Groups[1].Value})
  Expect (($tables -join '|') -ceq (@($expected.Tables) -join '|')) 'same table list'
  foreach($table in @($expected.Columns.Keys)){
   $line=[regex]::Match($integrity,'(?m)^\s*'+$table+'=@\(([^)]*)\)').Groups[1].Value
   $columns=@([regex]::Matches($line,"'([a-z_]+)'")|ForEach-Object{$_.Groups[1].Value})
   Expect (($columns -join '|') -ceq (@($expected.Columns[$table]) -join '|')) ('same columns for '+$table)
  }
  $p=New-Database 'schema-gaps';$db=Open-DomeniaDatabase $p -ReadOnly
  try{$tables=@(Invoke-DomeniaDbQuery "SELECT name FROM sqlite_master WHERE type='table';" $db|ForEach-Object{[string]$_.name});$columns=@{};foreach($table in @($expected.Columns.Keys)){$columns[$table]=@(Invoke-DomeniaDbQuery ('PRAGMA table_info('+$table+');') $db|ForEach-Object{[string]$_.name})}}finally{Close-DomeniaDatabase $db}
  Expect (@(Get-DomeniaStorageSchemaGaps -Tables $tables -Columns $columns).Count -eq 0) 'the real schema text has no gap'
 }
 Case 'Point 36: integrity check of a healthy base is read-only and clean' {
  $p=New-Database 'integrity-ok';$before=Get-TestHash $p
  $r=Run-Integrity $p;$verdict=Get-DomeniaStorageIntegrityVerdict $r
  Expect ($r.ReadOnly -and $r.Readable -and $verdict.Verdict -ceq 'Sain' -and $verdict.Failed -eq 0) ('healthy verdict: '+$verdict.Text)
  Expect ((Get-TestHash $p) -ceq $before) 'nothing written by the check'
 }
 Case 'Point 36: integrity check reports foreign identity, newer receipts and missing columns' {
  $p=New-Database 'integrity-bad'
  Query $p "UPDATE domenia_store_state SET store_id='other';INSERT INTO domenia_store_batches(batch_id,payload_hash,request_id,sequence,revision,committed_at,changes_json) VALUES('b9','h','r',1,99,'2026-01-01T00:00:00Z','[]');DROP TABLE domenia_details;CREATE TABLE domenia_details(object_guid TEXT NOT NULL,result_kind TEXT NOT NULL,request_key TEXT NOT NULL,dn TEXT NOT NULL,attempt_at TEXT NOT NULL,status TEXT NOT NULL,success_at TEXT NOT NULL DEFAULT '',payload TEXT,attempt_payload TEXT,revision INTEGER NOT NULL,PRIMARY KEY(object_guid,result_kind,request_key));" -Write
  $r=Run-Integrity $p;$verdict=Get-DomeniaStorageIntegrityVerdict $r
  $failed=@($r.Checks|Where-Object{$_.Status -eq 'Failed'}|ForEach-Object{$_.Id})
  Expect (($failed -contains 'Identity') -and ($failed -contains 'Receipts') -and ($failed -contains 'Tables')) ('failed checks: '+($failed -join ','))
  Expect ((@($r.Checks|Where-Object Id -eq 'Tables')[0].Detail -like '*domenia_details.summary_payload*') -and $verdict.Verdict -ceq 'Défaut') 'missing column named, verdict defect'
 }
 Case 'Point 36: integrity check of an unreadable file reports it without throwing' {
  $p=New-CorruptFile 'integrity-corrupt';$r=Run-Integrity $p
  Expect ((-not $r.Readable) -and @($r.Checks).Count -eq 1 -and $r.Checks[0].Id -eq 'Open' -and $r.Checks[0].Status -eq 'Failed') 'open failure only'
  Expect ((Get-DomeniaStorageIntegrityVerdict $r).Verdict -ceq 'Défaut') 'defect verdict'
 }
 Case 'Point 37: link history keeps every change and the bounds of each period' {
  $p=New-Database 'history';$cut=[datetime]::UtcNow.AddDays(-30).ToString('o')
  $sql=[Text.StringBuilder]::new()
  $rows=@(@('PC1','alice','2026-01-01'),@('PC1','alice','2026-01-02'),@('PC1','alice','2026-01-03'),@('PC1','alice','2026-01-04'),@('PC1','bob','2026-01-05'),@('PC1','ALICE','2026-01-06'),@('PC1','alice','2026-01-07'),@('PC2','carol','2026-01-01'),@('PC2','carol','02/01/2026'),@('PC2','carol','2026-01-03'),@('PC2','carol','2026-01-04'),@('PC4','eve','2026-01-01'),@('PC4','eve','2026-01-02'),@('PC4','eve','2026-01-03'))
  foreach($row in $rows){$when=if($row[2] -match '^\d{4}'){$row[2]+'T00:00:00Z'}else{$row[2]};[void]$sql.AppendLine("INSERT INTO user_machine_history(user_login,computer_key,computer,source,observed_at) VALUES('"+$row[1]+"','"+$row[0]+"','"+$row[0]+"','Console','"+$when+"');")}
  [void]$sql.AppendLine("INSERT INTO user_machine_links(computer_key,user_login,computer,source) VALUES('PC4','eve','PC4','Manual');")
  # Point 137 (W15): associations imported from GLPI or osquery are protected like a CSV import, their history too.
  [void]$sql.AppendLine("INSERT INTO user_machine_links(computer_key,user_login,computer,source) VALUES('PC5','gil','PC5','Import GLPI'),('PC6','oscar','PC6','Import osquery');")
  foreach($pc in @(@('PC5','gil'),@('PC6','oscar'))){foreach($day in @('01','02','03')){[void]$sql.AppendLine("INSERT INTO user_machine_history(user_login,computer_key,computer,source,observed_at) VALUES('"+$pc[1]+"','"+$pc[0]+"','"+$pc[0]+"','Console','2026-01-"+$day+"T00:00:00Z');")}}
  Query $p $sql.ToString() -Write
  $cutoffs=[pscustomobject]@{Presence='';Console='';Inventory='';Probe='';Detail='';LinkHistory=$cut}
  $preview=Run-Retention $p $true '' $cutoffs
  Expect (@($preview.Counts|Where-Object Family -eq LinkHistory)[0].Rows -eq 3) 'two repeated alice and one repeated carol'
  $r=Run-Retention $p $false $preview.Fingerprint $cutoffs
  Expect ($r.Committed -and $r.DeletedRows -eq 3 -and $r.Backup.Verified) 'compaction committed after a verified backup'
  $left=@(Query $p "SELECT user_login||'@'||observed_at AS v FROM user_machine_history WHERE computer_key='PC1' ORDER BY id;"|ForEach-Object{$_.v})
  Expect (($left -join ',') -ceq 'alice@2026-01-01T00:00:00Z,alice@2026-01-04T00:00:00Z,bob@2026-01-05T00:00:00Z,ALICE@2026-01-06T00:00:00Z,alice@2026-01-07T00:00:00Z') ('changes and bounds kept: '+($left -join ','))
  Expect ((Query $p "SELECT count(*) n FROM user_machine_history WHERE computer_key='PC2' AND observed_at='02/01/2026';")[0].n -eq 1) 'unreadable date kept'
  Expect ((Query $p "SELECT count(*) n FROM user_machine_history WHERE computer_key='PC4';")[0].n -eq 3) 'declared association history untouched'
  Expect ((Query $p "SELECT count(*) n FROM user_machine_history WHERE computer_key IN ('PC5','PC6');")[0].n -eq 6) 'GLPI or osquery imported association history compacted'
  $lines=@(Get-DomeniaStorageRetentionLines -Counts @($preview.Counts) -Cutoffs $cutoffs -DryRun $true)
  Expect (@($lines|Where-Object{$_ -like 'Historique des associations : 3 observation(s) répétée(s)*'}).Count -eq 1) 'loss of detail announced before'
 }
 Case 'Point 37: link history compaction reads each observation once on a large park' {
  # 2,000 computers x 200 observations, two periods of one user each: 196 removable per computer. The former correlated
  # previous/next subqueries re-read the history of the computer for every row (tens of seconds to minutes here).
  $p=New-Database 'history-scale';$cut=[datetime]::UtcNow.AddDays(-30).ToString('o')
  Query $p "WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<399999) INSERT INTO user_machine_history(user_login,computer_key,computer,source,observed_at) SELECT CASE WHEN (i%200)<100 THEN 'alice' ELSE 'bob' END,'PC'||(i/200),'PC'||(i/200),'Console',strftime('%Y-%m-%dT%H:%M:%SZ','2024-01-01',(i%200)||' hours') FROM n;" -Write
  Expect ((Query $p 'SELECT count(*) n FROM user_machine_history;')[0].n -eq 400000) 'fixture size'
  $cutoffs=[pscustomobject]@{Presence='';Console='';Inventory='';Probe='';Detail='';LinkHistory=$cut}
  $watch=[Diagnostics.Stopwatch]::StartNew();$preview=Run-Retention $p $true '' $cutoffs;$watch.Stop()
  Expect (@($preview.Counts|Where-Object Family -eq LinkHistory)[0].Rows -eq 392000) 'every observation inside a period except its two bounds'
  Expect ($watch.Elapsed.TotalSeconds -lt 20) ('bounded preview: '+[int]$watch.Elapsed.TotalSeconds+' s')
  Expect ((Query $p 'SELECT count(*) n FROM user_machine_history;')[0].n -eq 400000) 'a preview removes nothing'
  Expect ((Query $p "SELECT count(*) n FROM sqlite_master WHERE name='domenia_retention_links';")[0].n -eq 0) 'the helper table is temporary, never written to the base'
 }
 Case 'Point 39: the composite index exists and the measured reads report their plan' {
  $p=New-Database 'probes'
  Query $p "INSERT INTO ad_objects(object_key,object_guid,object_type,name,state,search_key) VALUES('k1','g1','Machine','PC1','Actif','pc1'),('k2','g2','Machine','PC2','Actif','pc2'),('k3','g3','Utilisateur','U1','Actif','u1');" -Write
  Expect ((Query $p "SELECT count(*) n FROM sqlite_master WHERE type='index' AND name='ix_ad_objects_type_name';")[0].n -eq 1) 'index created by the schema text'
  $u=Run-Usage $p
  $names=@($u.ReadProbes|ForEach-Object{$_.Name})
  Expect (($names -join ',') -ceq 'DirectoryPage,ActiveMachines,FamilyPage,TextSearch') 'four measured reads'
  Expect ((@($u.ReadProbes|Where-Object Name -eq ActiveMachines)[0].Rows -eq 2) -and (@($u.ReadProbes|Where-Object Name -eq DirectoryPage)[0].Plan -like '*ix_ad_objects_type_name*')) 'rows counted and index used for the typed page'
  $line=Format-DomeniaStorageReadProbes -Probes @($u.ReadProbes)
  Expect ($line -like 'Lectures mesurées sur cette base : *') 'measure shown'
 }
 Case 'RC13: confirmation reports the actual identity and revision, without writing' {
  $p=New-Database 'confirm' 17;$before=Get-TestHash $p
  $r=Run-Maintenance ReadRedirect $p
  Expect ($r.ReadOnly -and $r.StoreId -ceq (Get-DomeniaStoreId $p $domain) -and $r.Revision -eq 17 -and $null -eq $r.Redirect) 'actual identity and revision'
  Expect ((Get-TestHash $p) -ceq $before) 'read confirmation modified the file'
  $p=New-Database 'confirm-no-state' -NoState;$r=Run-Maintenance ReadRedirect $p
  Expect (-not $r.StoreId -and $r.Revision -eq 0) 'missing identity must not be invented'
 }
 Case 'RC13: asynchronous switch waits for receipt confirmation and rejects stale or changed copies' {
  . (Join-Path $wad 'modules/Domenia-Storage.UI.ps1')
  $definition=@($core.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DomeniaEffectiveWorkerResult'},$true))[0].Extent.Text
  . ([scriptblock]::Create($definition))
  function Set-DomeniaControlText {param($Name,$Text)}
  function Set-Status {param($Text,$Level)}
  function Write-AppLog {param($Text,$Level)}
  function Update-DomeniaStorageMaintenanceControls {}
  function Clear-DomeniaStoragePendingForOtherBase {param($ActivePath);return 0}
  function Request-DomeniaStorageWork {}
  function Resume-DomeniaDatabaseViews {param([switch]$ReloadLocalState)}
  function Update-DomeniaStorageSpaceUi {}
  function Update-DomeniaStorageLimitsUi {}
  function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,$TimeoutSeconds,$TaskClass);$script:confirmPayload=$Payload;return 'confirmation-job'}
  function Switch-DomeniaDatabaseContext {param($Path,$ExpectedPath,$ExpectedEpoch,$StoreId,$Revision);$script:switchCount++;$script:DatabaseScopedPath=$Path;$script:SessionEpoch++}
  $original=New-Database 'ui-original';$target=New-Database 'ui-target' 18
  $script:Conn=[pscustomobject]@{BaseDn=$domain}
  foreach($scenario in @('valid','wrong-store','old-revision','redirect','missing-store','stale-epoch','other-maintenance','cancelled')){
   $script:SessionEpoch=12L;$script:DatabaseScopedPath=$original;$script:switchCount=0;$script:confirmPayload=$null
   $receipt=[pscustomobject]@{TargetPath=$target;StoreId=(Get-DomeniaStoreId $target $domain);DomainDn=$domain;Revision=18L;Action='Move';RedirectWritten=$true;ActiveReadable=$true}
   $state=[pscustomobject]@{Id='operation';Epoch=12L;Path=$original;DomainDn=$domain;Mode='Move';Job='';Locked=$true;Hold=$true;Recovery=$false;Receipt=$receipt}
   $script:StorageMaintenance=$state
   Invoke-DomeniaStorageMaintenanceSwitch $state $receipt
   Expect ($script:switchCount -eq 0 -and $script:DatabaseScopedPath -ceq $original -and $state.Locked -and $state.Job -eq 'confirmation-job') ('context changed before worker: '+$scenario)
   Expect ($script:confirmPayload.Action -eq 'ReadRedirect' -and $script:confirmPayload.ActivePath -ceq $target) 'wrong confirmation target'
   $r=Run-Maintenance ReadRedirect $target
   switch($scenario){
    'wrong-store' {$r.StoreId='foreign'}
    'old-revision' {$r.Revision=17L}
    'redirect' {$r.Redirect=[pscustomobject]@{TargetPath='elsewhere'}}
    'missing-store' {$r.PSObject.Properties.Remove('StoreId')}
    'stale-epoch' {$script:SessionEpoch=13L}
    'other-maintenance' {$script:StorageMaintenance=[pscustomobject]@{Id='other'}}
   }
   if($scenario -eq 'cancelled'){Fail-DomeniaStorageMaintenanceSwitchConfirm 'Cancelled' $state}else{Complete-DomeniaStorageMaintenanceSwitchConfirm $r $state}
   if($scenario -eq 'valid'){
    Expect ($script:switchCount -eq 1 -and $script:DatabaseScopedPath -ceq $target -and -not $state.Locked -and -not $state.Hold) 'verified copy not switched once'
   }else{
    Expect ($script:switchCount -eq 0 -and $script:DatabaseScopedPath -ceq $original -and $state.Locked) ('unconfirmed context switched: '+$scenario)
   }
  }
 }
 Case 'RC14 StorageUsage splits domain metadata families, tolerates the old base and never double counts shared bytes' {
  $p=New-Database 'rc14-usage'
  Query $p "INSERT INTO domenia_domain_metadata(domain_dn,family,request_key,attempt_at,status,revision) VALUES('dc=test','Presence','p1','2026-01-01T00:00:00Z','Success',7),('dc=test','Presence','p2','2026-01-02T00:00:00Z','Success',7),('dc=test','Inventory','i1','2026-01-03T00:00:00Z','Success',7),('dc=test','Directory','d1','2026-01-04T00:00:00Z','Success',7),('dc=test','AdSchema','s1','2026-01-05T00:00:00Z','Success',7);" -Write
  $before=Get-TestHash $p
  $u=Run-Usage $p
  $obs=@($u.Categories|Where-Object Category -eq Observations)[0]
  $idx=@($u.Categories|Where-Object Category -eq Index)[0]
  $obsMeta=@($obs.Tables|Where-Object Table -eq domenia_domain_metadata)
  $idxMeta=@($idx.Tables|Where-Object Table -eq domenia_domain_metadata)
  Expect ((@($obsMeta).Count -eq 1) -and (@($idxMeta).Count -eq 1)) 'the shared table is listed once per coherent category'
  Expect (($obsMeta[0].Rows -eq 3) -and ($idxMeta[0].Rows -eq 1)) ('family split Presence+Inventory/Directory: '+$obsMeta[0].Rows+' and '+$idxMeta[0].Rows)
  Expect (($obsMeta[0].Bytes -eq -1) -and ($idxMeta[0].Bytes -eq -1) -and ($obs.Bytes -eq -1) -and ($idx.Bytes -eq -1)) 'shared table bytes stay unknown, never counted twice'
  $sharedRows=@($u.Categories|ForEach-Object{$_.Tables}|Where-Object Table -eq domenia_domain_metadata|ForEach-Object{$_.Rows}|Measure-Object -Sum).Sum
  Expect ($sharedRows -eq 4) ('the five stored rows are counted once each, the unlisted family in none: '+$sharedRows)
  Expect ((Get-TestHash $p) -ceq $before) 'the measured base is byte for byte unchanged'
  Expect ($u.ReadOnly -and ($u.DatabaseBytes -eq (Get-Item -LiteralPath $p).Length)) 'read-only measure reports the real file'
  $old=New-Database 'rc14-old-base';Query $old 'DROP TABLE domenia_domain_metadata;' -Write
  Expect ((Query $old "SELECT count(*) n FROM sqlite_master WHERE name='domenia_domain_metadata';")[0].n -eq 0) 'the old base really has no such table'
  $u=Run-Usage $old
  $absent=@($u.Categories|ForEach-Object{$_.Tables}|Where-Object Table -eq domenia_domain_metadata)
  Expect ((@($absent).Count -eq 2) -and (@($absent|Where-Object{($_.Rows -eq 0) -and ($_.Bytes -eq 0) -and ($_.State -ceq 'Absent')}).Count -eq 2)) 'an old base without the table measures zero, not an error'
 }
}finally{
 $report=[pscustomobject]@{Suite='StorageMaintenance';Platform=[Environment]::OSVersion.VersionString;PowerShell=$PSVersionTable.PSVersion.ToString();Cases=$cases.ToArray();Total=$cases.Count;Passed=@($cases|Where-Object Passed).Count;Failed=@($cases|Where-Object{-not $_.Passed}).Count;Assertions=$script:checks;NoNetwork=$true;Scope='Temporary SQLite databases; no Active Directory or real-user data.'}
 if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
 Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
}
$report|Select-Object Total,Passed,Failed,Assertions|Format-List
if($report.Failed -gt 0){exit 1};exit 0
