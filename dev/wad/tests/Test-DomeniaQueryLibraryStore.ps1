#requires -Version 5.1
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$t=$null;$e=$null;$core=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Core parse failed'}
$native=@($core.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-DomeniaWinSqliteNative'},$true))[0].Extent.Text
if($PSVersionTable.PSEdition -eq 'Core'){
    $native=$native.Replace('[AppDomain]::CurrentDomain.DefineDynamicAssembly','[Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly')
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)){$native=$native.Replace('winsqlite3.dll','/usr/lib/libsqlite3.dylib')}
    elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){$native=$native.Replace('winsqlite3.dll','libsqlite3.so.0')}
}
. ([scriptblock]::Create($native));[void](Initialize-DomeniaWinSqliteNative)
Add-Type -Path (Join-Path $wad 'modules/M4D.Admin.Common.Query.dll')
Add-Type -Path (Join-Path $wad 'modules/Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model','QueryLibrary.Model')){. (Join-Path $wad ('modules/Domenia-'+$name+'.ps1'))}
. (Join-Path $wad 'modules/Domenia-Store.Model.ps1')
. (Join-Path $wad 'modules/Domenia-Cache.Model.ps1')
. (Join-Path $wad 'modules/Domenia-Storage.Worker.ps1')
. (Join-Path $wad 'modules/Domenia-Engine.Worker.ps1')
$worker=Get-DomeniaStorageWorkerCode;$reader=Get-DomeniaLocalIndexReadWorkerCode
$ast=[Management.Automation.Language.Parser]::ParseInput($worker,[ref]$t,[ref]$e)
if($e.Count){throw 'Worker parse failed'}
foreach($fn in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){. ([scriptblock]::Create($fn.Extent.Text))}
$folder=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.domenia-store-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder);$path=Join-Path $folder 'test.sqlite'
$context=[pscustomobject]@{Version=1;Path=$path;DomainDn='dc=test';StoreId=(Get-DomeniaStoreId $path 'dc=test');RequestId='test';Generation=1;SessionEpoch=1;ScopeDn='ou=parc,dc=test';Subtree=$true}
$cases=[Collections.Generic.List[object]]::new();$script:checks=0
function Expect {param([bool]$Good,[string]$Name);$script:checks++;if(-not $Good){throw $Name}}
function Case {param([string]$Name,[scriptblock]$Code);try{& $Code;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}}
function Read-TestDb {param([string]$Sql);$db=Open-DomeniaDatabase $path;try{return @(Invoke-DomeniaDbQuery $Sql $db)}finally{Close-DomeniaDatabase $db}}
function Commit {param([object[]]$Changes,[string]$Id=([guid]::NewGuid().ToString()),$Ctx=$context)
    $batch=ConvertTo-DomeniaStoreBatch -Context $Ctx -BatchId $Id -Sequence 1 -Changes $Changes
    $Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='StoreBatch';Json=$batch.Json;Hash=$batch.Hash})}
    return & ([scriptblock]::Create($worker))
}
function RecipeChange {
 param([string]$Id='personal.one',[string]$Name='Mémoire connue',[long]$Expected=0,[bool]$Archived=$false,[string]$Category='Mes requêtes')
 $recipe=New-DomeniaQueryRecipe -Id $Id -Name $Name -Clauses @()
 $record=New-DomeniaQueryLibraryRecord -Context $context -Recipe $recipe -ExpectedRevision $Expected -Category $Category -NowUtc ([datetime]'2026-01-01Z')
 $record.Archived=$Archived
 return [pscustomobject]@{Kind='QueryRecipe';Record=$record}
}
function LibraryRead {
 param([string]$Term='',[switch]$IncludeArchived,[int]$Offset=0,[int]$Limit=100,[long]$SnapshotRevision=0)
 $q=New-DomeniaQueryLibraryRead -Context $context -Text $Term -Offset $Offset -Limit $Limit -IncludeArchived:$IncludeArchived
 $q|Add-Member -NotePropertyName SnapshotRevision -NotePropertyValue $SnapshotRevision -Force
 return Read-Store $q
}
function Refused {param([scriptblock]$Code,[string]$Text='');$caught=$false;try{& $Code|Out-Null}catch{$caught=$true;if($Text){Expect ($_.Exception.Message -like ('*'+$Text+'*')) 'specific refusal'}};Expect $caught 'refused'}
function Read-Store {param($Query,$Ctx=$context)
    $Payload=[pscustomobject]@{Action='StoreRead';Path=$path;StoreId=$Ctx.StoreId;DomainDn=$Ctx.DomainDn;Query=$Query;BusyTimeoutMs=1000}
    return & ([scriptblock]::Create($reader))
}
$guid='00000000-0000-0000-0000-000000000001';$dn='CN=PC-1,OU=Parc,DC=test';$at='2026-01-01T00:00:00Z'
function Directory {param([string]$Id=$guid,[string]$Name='PC-1',[string]$At=$at)
 return [pscustomobject]@{Kind='DirectoryObject';Guid=$Id;DN=('CN='+$Name+',OU=Parc,DC=test');ObservedAtUtc=$At;Source='dc.test';Fields=@('Type','Name','State','Details');Data=[pscustomobject]@{Type='Machine';Name=$Name;State='Actif';Details=[pscustomobject]@{department='IT';member=@('one','two')}};Facts=[pscustomobject]@{OsVersion='26100';WhenCreated=$At}}
}
function Observation {param([string]$Family='Presence',[string]$At=$at,[string]$Status='Success',$Data=([pscustomobject]@{Computer='PC-1';Presence='En ligne'}))
 return [pscustomobject]@{Kind='Observation';Guid=$guid;DN=$dn;Family=$Family;AttemptedAtUtc=$At;ObservedAtUtc=$(if($Status -eq 'Success'){$At}else{''});Status=$Status;Error=$(if($Status -eq 'Error'){'denied'}else{''});Data=$Data}
}
try{
 $schema=@($core.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]},$true)|Where-Object{$_.Value -match '^PRAGMA journal_mode=WAL;' -and $_.Value -match 'CREATE TABLE IF NOT EXISTS schema_info'})
 if($schema.Count -ne 1){throw 'Schema count'}
 $db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec $schema[0].Value $db);$script:sqliteVersion=[string](@(Invoke-DomeniaDbQuery 'SELECT sqlite_version() AS v;' $db)[0].v)}finally{Close-DomeniaDatabase $db}

 Case 'Commit publishes canonical recipes separately from directory rows' {
  $r=Commit @((RecipeChange));Expect ($r.Saved -and $r.QueryRecipes.Count -eq 1 -and $r.Rows.Count -eq 0) 'typed readback';Expect ($r.QueryRecipes[0].Revision -eq 1 -and $r.QueryRecipes[0].CreatedUtc -eq $r.QueryRecipes[0].UpdatedUtc) 'initial revision';Expect ($r.QueryRecipes[0].DefinitionSHA256 -ceq (Get-DomeniaStoreHash $r.QueryRecipes[0].DefinitionJson)) 'persisted hash'
 }
 Case 'Revision conflict rolls back an earlier valid recipe in the same batch' {
  $before=(Read-TestDb 'SELECT revision FROM domenia_store_state;')[0].revision
  Refused {Commit @((RecipeChange 'personal.rollback'),(RecipeChange 'personal.one' 'Conflict' 0))} 'QueryRevisionConflict'
  Expect ((Read-TestDb "SELECT count(*) n FROM domenia_query_recipes WHERE id='personal.rollback';")[0].n -eq 0) 'all or nothing';Expect ((Read-TestDb 'SELECT revision FROM domenia_store_state;')[0].revision -eq $before) 'revision unchanged'
 }
 Case 'Update creates immutable historical revision and preserves original creation time' {
  $change=RecipeChange 'personal.one' 'Renommée' 1;$change.Record.UpdatedUtc='2026-02-01T00:00:00.0000000Z';$r=Commit @($change)
  Expect ($r.QueryRecipes[0].Revision -eq 2 -and $r.QueryRecipes[0].CreatedUtc -like '2026-01-01*' -and $r.QueryRecipes[0].UpdatedUtc -like '2026-02-01*') 'dates/revisions';Expect ((Read-TestDb "SELECT count(*) n FROM domenia_query_recipe_revisions WHERE id='personal.one';")[0].n -eq 2) 'history retained'
 }
 Case 'Batch retry keeps identity and revision; changed wire with same id refuses' {
  $id=[guid]::NewGuid().ToString();$change=RecipeChange 'personal.retry';$first=Commit @($change) $id;$again=Commit @($change) $id
  Expect ($again.Already -and $again.Revision -eq $first.Revision -and $again.QueryRecipes[0].Revision -eq 1) 'retry dedup'
  $change=RecipeChange 'personal.retry' 'Different';Refused {Commit @($change) $id} 'reutilise'
 }
 Case 'Real SQL trigger proves callback is a SELECT instead of input echo' {
  $db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec "CREATE TRIGGER query_readback AFTER INSERT ON domenia_query_recipes WHEN NEW.id='personal.trigger' BEGIN UPDATE domenia_query_recipes SET category='SQL witness' WHERE id=NEW.id; END;" $db)}finally{Close-DomeniaDatabase $db}
  $r=Commit @((RecipeChange 'personal.trigger'));Expect ($r.QueryRecipes[0].Category -ceq 'SQL witness') 'database value'
 }
 Case 'Dependency blocks archive until explicitly detached at the known revision' {
  $dependency=[pscustomobject]@{Kind='QueryDependency';RecipeId='personal.one';ConsumerKind='Fleet';ConsumerId='query.personal.one';BoundRevision=2;Remove=$false}
  $r=Commit @($dependency);Expect ($r.QueryDependencies.Count -eq 1 -and $r.QueryDependencies[0].BoundRevision -eq 2) 'dependency readback'
  Refused {Commit @((RecipeChange 'personal.one' 'Archived' 2 $true))} 'QueryDependenciesExist'
  $dependency.Remove=$true;$dependency.BoundRevision=1;Refused {Commit @($dependency)} 'QueryDependencyConflict'
  $dependency.BoundRevision=2;$r=Commit @($dependency,(RecipeChange 'personal.one' 'Archived' 2 $true))
  Expect ($r.QueryRecipes[0].Archived -and $r.QueryDependencies.Count -eq 0) 'explicit ordered detach and archive'
  $dependency.Remove=$false;$dependency.BoundRevision=3;Refused {Commit @($dependency)} 'QueryDependencyConflict'
 }
 Case 'New recipe and dependency can commit in one transaction' {
  $dep=[pscustomobject]@{Kind='QueryDependency';RecipeId='personal.bound';ConsumerKind='Computer';ConsumerId='query.personal.bound';BoundRevision=1;Remove=$false}
  $r=Commit @((RecipeChange 'personal.bound'),$dep);Expect ($r.QueryRecipes.Count -eq 1 -and $r.QueryDependencies.Count -eq 1) 'atomic creation'
 }
 Case 'Read omits archived by default and IncludeArchived preserves their IDs for migration' {
  $r=LibraryRead;Expect (@($r.QueryRecipes|Where-Object Id -eq 'personal.one').Count -eq 0) 'default active'
  $r=LibraryRead -IncludeArchived;Expect (@($r.QueryRecipes|Where-Object Id -eq 'personal.one').Count -eq 1) 'no legacy resurrection'
 }
 Case 'SQL search is accent normalized and literal for percent underscore quote' {
  [void](Commit @((RecipeChange 'personal.literal' "Été 100%_d'O"),(RecipeChange 'personal.wild' 'Été 100XadO')))
  $r=LibraryRead 'ete';Expect ($r.Total -eq 2) 'accent search';$r=LibraryRead "100%_d'o";Expect ($r.Total -eq 1 -and $r.QueryRecipes[0].Id -ceq 'personal.literal') 'literal wildcard characters'
 }
 Case 'Read pagination is stable and refuses a superseded snapshot' {
  $one=LibraryRead -Limit 1;$two=LibraryRead -Limit 1 -Offset 1 -SnapshotRevision $one.SnapshotRevision
  Expect ($one.Total -eq $two.Total -and $one.QueryRecipes[0].Id -cne $two.QueryRecipes[0].Id) 'paged exact total'
  [void](Commit @((RecipeChange 'personal.later')));Refused {LibraryRead -SnapshotRevision $one.SnapshotRevision} 'Revision'
  Refused {LibraryRead -Limit 251} 'Pagination'
 }
 Case 'Migration marker requires every ID and rolls back the final batch on omission' {
  $hash=Get-DomeniaStoreHash 'legacy';$marker=[pscustomobject]@{Kind='QueryMigration';SourceHash=$hash;RecipeIds=@('personal.one','personal.missing')}
  Refused {Commit @((RecipeChange 'personal.rollback2'),$marker)} 'Migration incomplete'
  Expect ((Read-TestDb "SELECT count(*) n FROM domenia_query_recipes WHERE id='personal.rollback2';")[0].n -eq 0) 'final batch rollback';Expect ((Read-TestDb 'SELECT count(*) n FROM domenia_query_migrations;')[0].n -eq 0) 'no premature marker'
  $marker.RecipeIds=@('personal.one','personal.bound');$r=Commit @($marker);Expect ($r.QueryMigrations.Count -eq 1 -and $r.QueryMigrations[0].SourceHash -ceq $hash -and $r.QueryRecipes.Count -eq 0) 'persisted migration marker including archived identity'
  $r=LibraryRead -IncludeArchived;Expect ($r.QueryMigrations.Count -eq 1) 'startup discovers migration'
 }
 Case 'Point 68: operator category is stored, read back and filterable' {
  $r=Commit @((RecipeChange 'personal.category' 'Revue rangée' 0 $false 'Audit 2026'));Expect ($r.QueryRecipes[0].Category -ceq 'Audit 2026') 'category readback'
  $q=New-DomeniaQueryLibraryRead -Context $context -Category 'Audit 2026';$read=Read-Store $q
  Expect ($read.Total -eq 1 -and $read.QueryRecipes[0].Id -ceq 'personal.category') 'category filter'
  Refused {RecipeChange 'personal.category' 'Revue rangée' 1 $false ('x'*81)} 'Catégorie'
 }
 Case 'Point 68: an archived recipe is restored with a new revision checked by SQLite' {
  $current=@((LibraryRead -IncludeArchived).QueryRecipes|Where-Object{$_.Id -ceq 'personal.one'})[0]
  Expect ($current.Archived) 'fixture archived'
  Refused {Commit @((RecipeChange 'personal.one' 'Archived' ($current.Revision-1) $false))} 'QueryRevisionConflict'
  $r=Commit @((RecipeChange 'personal.one' 'Archived' $current.Revision $false))
  Expect (-not $r.QueryRecipes[0].Archived -and $r.QueryRecipes[0].Revision -eq ($current.Revision+1)) 'restored active revision'
  Expect ((Read-TestDb "SELECT count(*) n FROM domenia_query_recipe_revisions WHERE id='personal.one';")[0].n -eq $r.QueryRecipes[0].Revision) 'every revision kept'
 }
 Case 'Admission rejects altered hash, executable properties, wrong domain and metadata' {
  $r=RecipeChange 'personal.invalid';$r.Record.DefinitionSHA256='a'*64;Refused {Commit @($r)} 'empreinte'
  $r=RecipeChange 'personal.invalid';$json=$r.Record.DefinitionJson|ConvertFrom-Json;$json|Add-Member NoteProperty Script 'anything';$r.Record.DefinitionJson=$json|ConvertTo-Json -Depth 16 -Compress;$r.Record.DefinitionSHA256=Get-DomeniaStoreHash $r.Record.DefinitionJson;Refused {Commit @($r)} 'Propriété'
  $r=RecipeChange 'personal.invalid';$r.Record.DomainDn='dc=other';Refused {Commit @($r)} 'Contexte'
  $r=RecipeChange 'personal.invalid';$r.Record.Name='wrong';Refused {Commit @($r)} 'Metadonnee'
 }
 Case 'Worker independently checks hash and metadata even if wire hash is recomputed' {
  $b=ConvertTo-DomeniaStoreBatch $context ([guid]::NewGuid().ToString()) 1 @((RecipeChange 'personal.tampered'));$envelope=$b.Json|ConvertFrom-Json;$envelope.Changes[0].Record.DefinitionSHA256='b'*64;$json=$envelope|ConvertTo-Json -Depth 24 -Compress
  $Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='StoreBatch';Json=$json;Hash=(Get-DomeniaStoreHash $json)})}
  Refused {& ([scriptblock]::Create($worker))} 'Empreinte de definition'
  Expect ((Read-TestDb "SELECT count(*) n FROM domenia_query_recipes WHERE id='personal.tampered';")[0].n -eq 0) 'no invalid row'
 }
 Case 'Receipt failure rolls back recipe revisions and dependencies' {
  $db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec "CREATE TRIGGER query_rollback BEFORE INSERT ON domenia_store_batches BEGIN SELECT RAISE(ABORT,'fixture failed receipt'); END;" $db)}finally{Close-DomeniaDatabase $db}
  try{Refused {Commit @((RecipeChange 'personal.noreceipt'))};Expect ((Read-TestDb "SELECT count(*) n FROM domenia_query_recipe_revisions WHERE id='personal.noreceipt';")[0].n -eq 0) 'no orphan history'}finally{$db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec 'DROP TRIGGER query_rollback;' $db)}finally{Close-DomeniaDatabase $db}}
 }
}finally{Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue}
$failed=@($cases|Where-Object{-not $_.Passed});$report=[pscustomobject]@{Suite='QueryLibraryStore';Passed=($failed.Count -eq 0);Total=$cases.Count;Failed=$failed.Count;Assertions=$script:checks;SQLiteVersion=$script:sqliteVersion;PowerShell=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.ToString();Cases=$cases.ToArray();Limitations=@('Synthetic local SQLite fixtures; no AD or remote workstation; no WPF.')}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
Write-Output ('QueryLibraryStore: '+($cases.Count-$failed.Count)+'/'+$cases.Count+' cases, '+$script:checks+' assertions');if($failed.Count){exit 1};exit 0
