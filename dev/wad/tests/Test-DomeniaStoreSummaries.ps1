#requires -Version 5.1
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
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
foreach($name in @('Common.Model','Boards.Model','Probes.Model','Query.Model','QueryLibrary.Model')){. (Join-Path $wad ('modules/Domenia-'+$name+'.ps1'))}
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
 param([string]$Id='personal.one',[string]$Name='Mémoire connue',[long]$Expected=0,[bool]$Archived=$false)
 $recipe=New-DomeniaQueryRecipe -Id $Id -Name $Name -Clauses @()
 $record=New-DomeniaQueryLibraryRecord -Context $context -Recipe $recipe -ExpectedRevision $Expected -NowUtc ([datetime]'2026-01-01Z')
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

 Case 'Summary stores exact counts and excludes rows and schema after COMMIT' {
  [void](Commit @((Directory)))
  $script:definition='SELECT Name FROM Win32_OperatingSystem';$script:request=Get-DomeniaStoreHash ('root\cimv2'+"`n"+$definition)
  $script:data=[pscustomobject]@{Mode='Select';Namespace='root\cimv2';CanonicalQuery=$definition;RequestKey=$request;StoredCount=1;CountComplete=$true;Truncated=$false;Rows=@([pscustomobject]@{Name=('large '+('é'*100000))});Schema=@([pscustomobject]@{Property='Name';Type='String'})}
  $script:change=[pscustomobject]@{Kind='DetailResult';Guid=$guid;DN=$dn;ResultKind='WmiQuery';RequestKey=$request;Status='Success';AttemptedAtUtc=$at;ObservedAtUtc=$at;Error='';Data=$data}
  [void](Commit @($change));$script:q=[pscustomobject]@{Kind='Detail';Guids=@($guid);ResultKind='WmiQuery';RequestKey=$request;DetailProjection='QuerySummary';Limit=1}
  $r=Read-Store $q;Expect ($r.Details.Count -eq 1 -and $r.Details[0].Data.StoredCount -eq 1 -and $r.Details[0].Data.CountComplete) 'canonical exact summary'
  Expect ($null -eq $r.Details[0].Data.PSObject.Properties['Rows'] -and $null -eq $r.Details[0].Data.PSObject.Properties['Schema']) 'heavy fields absent'
  $s=(Read-TestDb 'SELECT length(summary_payload) n,length(payload) full_size FROM domenia_details;')[0];Expect ($s.n -lt 2000 -and $s.full_size -gt 100000) 'compact SQL projection'
 }
 Case 'QuerySummary never decodes the full payload or attempt payload' {
  $db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec "UPDATE domenia_details SET payload='intentionally invalid JSON',attempt_payload='also invalid';" $db)}finally{Close-DomeniaDatabase $db}
  $r=Read-Store $q;Expect ($r.Details[0].Data.StoredCount -eq 1) 'summary independent of large JSON'
  $q.DetailProjection='Full';Refused {Read-Store $q};$q.DetailProjection='QuerySummary'
  $db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec ('UPDATE domenia_details SET payload='+(ConvertTo-DomeniaSqlLiteral ($data|ConvertTo-Json -Depth 10 -Compress))+',attempt_payload=NULL;') $db)}finally{Close-DomeniaDatabase $db}
 }
 Case 'Failed attempt keeps successful summary and records its separate status and time' {
  $change.Status='Error';$change.AttemptedAtUtc='2026-01-02T00:00:00Z';$change.ObservedAtUtc='';$change.Error='denied';$change.Data=[pscustomobject]@{Mode='Select';Error='denied'}
  [void](Commit @($change));$r=Read-Store $q;$d=$r.Details[0]
  Expect ($d.Status -ceq 'Error' -and $d.LastSuccessAtUtc -like '2026-01-01*' -and $d.LastAttemptAtUtc -like '2026-01-02*') 'two clocks'
  Expect ($d.Data.StoredCount -eq 1 -and $null -eq $d.AttemptData) 'last success retained without invented error count'
 }
 Case 'Legacy absent summary stays unknown without scanning or assuming zero' {
  $db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec 'UPDATE domenia_details SET summary_payload=NULL,attempt_summary=NULL;' $db)}finally{Close-DomeniaDatabase $db}
  $r=Read-Store $q;Expect ($r.Details.Count -eq 1 -and $null -eq $r.Details[0].Data) 'unknown'
 }
 Case 'Explicit complete zero is distinguished from absent or incomplete data' {
  $change.Status='Success';$change.AttemptedAtUtc='2026-01-03T00:00:00Z';$change.ObservedAtUtc=$change.AttemptedAtUtc;$change.Error='';$change.Data=[pscustomobject]@{Mode='Select';Namespace='root\cimv2';CanonicalQuery=$definition;RequestKey=$request;StoredCount=0;CountComplete=$true;Truncated=$false;Rows=@();Schema=@()}
  [void](Commit @($change));$r=Read-Store $q;Expect ($null -ne $r.Details[0].Data -and $r.Details[0].Data.StoredCount -eq 0 -and $r.Details[0].Data.CountComplete -and -not $r.Details[0].Data.Truncated) 'known zero'
 }
 Case 'Invalid summary metadata refuses the whole transaction' {
  $change.AttemptedAtUtc='2026-01-04T00:00:00Z';$change.ObservedAtUtc=$change.AttemptedAtUtc;$change.Data.RequestKey='a'*64
  Refused {Commit @($change)} 'Resume'
  $r=Read-Store $q;Expect ($r.Details[0].LastSuccessAtUtc -like '2026-01-03*') 'previous success preserved'
 }
}finally{Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue}
$failed=@($cases|Where-Object{-not $_.Passed});$report=[pscustomobject]@{Suite='StoreSummaries';Passed=($failed.Count -eq 0);Total=$cases.Count;Failed=$failed.Count;Assertions=$script:checks;SQLiteVersion=$script:sqliteVersion;PowerShell=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.ToString();Cases=$cases.ToArray();Limitations=@('Synthetic local SQLite fixtures; no AD or remote workstation; no WPF.')}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
Write-Output ('StoreSummaries: '+($cases.Count-$failed.Count)+'/'+$cases.Count+' cases, '+$script:checks+' assertions');if($failed.Count){exit 1};exit 0
