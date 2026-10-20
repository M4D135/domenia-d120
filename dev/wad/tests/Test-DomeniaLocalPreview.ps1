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
. (Join-Path $wad 'modules/Domenia-Common.Model.ps1')
. (Join-Path $wad 'modules/Domenia-ProbeCatalog.Model.ps1')
. (Join-Path $wad 'modules/Domenia-QueryLibrary.Model.ps1')
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
 # The AST keeps the here-string unexpanded: the query library tables are inserted exactly as the core does at run time.
 $schemaSql=[string]$schema[0].Value;if($schemaSql.Contains('$(Get-DomeniaQueryLibrarySchema)')){$schemaSql=$schemaSql.Replace('$(Get-DomeniaQueryLibrarySchema)',(Get-DomeniaQueryLibrarySchema))}
 $db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec $schemaSql $db);$script:sqliteVersion=[string](@(Invoke-DomeniaDbQuery 'SELECT sqlite_version() AS v;' $db)[0].v)}finally{Close-DomeniaDatabase $db}
 foreach($item in @((Directory), (Directory '00000000-0000-0000-0000-000000000002' 'PC-10'), (Directory '00000000-0000-0000-0000-000000000003' 'PC_2'), (Directory '00000000-0000-0000-0000-000000000004' 'OTHER-PC'))){[void](Commit @($item))}
 $nested=Directory '00000000-0000-0000-0000-000000000005' 'PC-NESTED';$nested.DN='CN=PC-NESTED,OU=Child,OU=Parc,DC=test';[void](Commit @($nested))
 Case 'Prefix preview reads canonical stored rows before any directory call' {$r=Read-Store @{Kind='Directory';Prefix='PC-1';Projection='List';Limit=10};Expect ($r.DataSource -eq 'SQLite' -and $r.Rows.Count -eq 2) 'prefix results';Expect ([datetime]$r.Rows[0].ObservedAtUtc -eq [datetime]$at) 'original observation time'}
 Case 'Prefix literal underscore never acts as a wildcard' {$r=Read-Store @{Kind='Directory';Prefix='PC_';Limit=10};Expect ($r.Rows.Count -eq 1 -and $r.Rows[0].Name -eq 'PC_2') 'literal underscore'}
 Case 'Prefix literal percent never expands the query' {$r=Read-Store @{Kind='Directory';Prefix='PC%';Limit=10};Expect ($r.Rows.Count -eq 0) 'literal percent'}
 Case 'One-level and subtree previews preserve the selected OU' {$a=Read-Store @{Kind='Directory';Prefix='PC-';ScopeDn='OU=Parc,DC=test';Subtree=$false;Limit=10};$b=Read-Store @{Kind='Directory';Prefix='PC-';ScopeDn='OU=Parc,DC=test';Subtree=$true;Limit=10};Expect ($a.Rows.Count -eq 2 -and $b.Rows.Count -eq 3) 'scope/depth'}
 Case 'Object preview uses exact DN and GUID together' {$a=Read-Store @{Kind='Directory';DN=$dn.ToLowerInvariant();Guids=@($guid);Limit=1};$b=Read-Store @{Kind='Directory';DN=$dn;Guids=@('00000000-0000-0000-0000-000000000002');Limit=1};Expect ($a.Rows.Count -eq 1 -and $b.Rows.Count -eq 0) 'identity intersection'}
 Case 'Local type filter does not return a workstation as a person' {$r=Read-Store @{Kind='Directory';Prefix='PC';Types=@('Utilisateur');Limit=10};Expect ($r.Rows.Count -eq 0) 'type filter'}
 . (Join-Path $wad 'modules/Domenia-Common.Model.ps1')
 . (Join-Path $wad 'modules/Domenia-Directory.Model.ps1')
 . (Join-Path $wad 'modules/Domenia-DirectoryStore.Model.ps1')
 . (Join-Path $wad 'modules/Domenia-DirectoryStore.UI.ps1')
 . (Join-Path $wad 'modules/Domenia-Selection.UI.ps1')
 . (Join-Path $wad 'modules/Domenia-LocalPreview.UI.ps1')
 foreach($name in @('Test-DomeniaSensitiveAttributeName','Remove-DomeniaSensitiveProperties','Get-TypeLdapFilter','Get-VisitCacheValue','Get-DomeniaEffectiveWorkerResult','Test-DomeniaObjectCallbackIsCurrent','Clear-DomeniaCurrentObjectRequest','Fail-DomeniaOpenObjectTaskUi')){
  $node=@($core.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));if($node.Count -ne 1){throw ('Definition '+$name)};. ([scriptblock]::Create($node[0].Extent.Text))
 }
 function Get-CfgValue {param($Section,$Name,$Default);return $Default}
 function Write-DomeniaTrace {param($Area,$Text)}
 function Test-DomeniaLiveSearchActive {return $script:SearchActive}
 function Invoke-DomeniaTimerSoon {param($Owner);$script:Wake=$Owner}
 function Show-AdObjectResult {param($Result,$Dn,$Type,[switch]$NoNavigate,[switch]$SuppressRemoteProbes);$script:Rendered=[pscustomobject]@{Result=$Result;Cached=[bool]$script:ShowingCachedObject;NoProbes=[bool]$SuppressRemoteProbes}}
 function Fail-DomeniaOpenObjectUi {param($Message,$Dn);$script:ObjectError=$Message}
 function Request-DomeniaStoreRead {param($Context,$Query,$SuccessHandler,$ErrorHandler,$CallbackState,[switch]$Preview);$script:Dispatched=[pscustomobject]@{Query=$Query;Preview=[bool]$Preview;State=$CallbackState};return 'local-job'}
 function New-SearchFixture {
  $script:DatabaseScopedPath=$path;$script:SearchActive=$true;$script:Wake=''
  $s=[pscustomobject]@{State=[pscustomobject]@{ViewId='';MatchMode='';PlanKind='Default';Search='PC-1';TypeFilter=(Get-TypeLdapFilter Machines);BaseDn='OU=Parc,DC=test';Scope='Subtree';Limit=100;StoreContext=$context};Ended=$false;Error='';CacheProgress=[Collections.Concurrent.ConcurrentQueue[object]]::new()}
  $script:Live=[pscustomobject]@{Search=$s};return $s
 }
 function New-ObjectFixture {
  $script:DatabaseScopedPath=$path;$script:SessionEpoch=7L;$script:Conn=[pscustomobject]@{Credential=$null;BaseDn='DC=test';Server='dc.test';BindUser='fixture'}
  $script:CurrentObjectRequestId='object-1';$script:Rendered=$null;$script:ObjectError='';$script:SelectedObject=$null
  return [pscustomobject]@{RequestId='object-1';Dn=$dn;Type='Machine';ExpectedGuid=$guid;Epoch=7L;Identity=(Get-DomeniaObjectReadIdentity);SelectionBound=$false;UserInitiated=$false;NoNavigate=$true;StoreContext=$context;DirectoryPipe=$null;LocalPreviewPending=$true;DeferredReadError=''}
 }
 Case 'Normalized display projection preserves values and never mutates its source' {
  $p=@{objectguid=@($guid);distinguishedname=@($dn);name=@('PC-1');objectclass=@('computer');samaccountname=@('PC-1$');useraccountcontrol=@(4096);description=@('fixture');dnshostname=@('pc-1.test')}
  $original=$p|ConvertTo-Json -Depth 4 -Compress
  $a=ConvertTo-DomeniaDirectoryDisplayRow $p Machine;$b=ConvertTo-DomeniaDirectoryDisplayRow $p Machine -Normalized
  Expect (($a|ConvertTo-Json -Compress) -ceq ($b|ConvertTo-Json -Compress)) 'same display values'
  Expect (($p|ConvertTo-Json -Depth 4 -Compress) -ceq $original) 'source unchanged'
  $script:ProjectionTimings=@()
  foreach($round in 1..3){foreach($fast in @($false,$true)){$watch=[Diagnostics.Stopwatch]::StartNew();for($i=0;$i -lt 100;$i++){[void](ConvertTo-DomeniaDirectoryDisplayRow $p Machine -Normalized:$fast)};$watch.Stop();$script:ProjectionTimings+=@([pscustomobject]@{Round=$round;Normalized=$fast;Rows=100;Ms=$watch.Elapsed.TotalMilliseconds})}}
 }
 Case 'Simple search starts a short preview of its exact perimeter' {$s=New-SearchFixture;Request-DomeniaLocalSearchPreview $s;Expect ($script:Dispatched.Preview -and $script:Dispatched.Query.Prefix -eq 'PC-1' -and $script:Dispatched.Query.ScopeDn -eq 'OU=Parc,DC=test' -and $script:Dispatched.Query.Types[0] -eq 'Machine') 'preview request'}
 Case 'Complex searches never receive a broader local substitute' {$s=New-SearchFixture;foreach($term in @('PC*','PC one','(PC)')){$s.State.Search=$term;Expect ($null -eq (Get-DomeniaLocalSearchPreviewQuery $s.State)) ('unsupported '+$term)};$s.State.Search='PC';$s.State.ViewId='custom';Expect ($null -eq (Get-DomeniaLocalSearchPreviewQuery $s.State)) 'work view'}
 Case 'Stored rows are published as cached, with their actual date' {$s=New-SearchFixture;$data=Read-Store @{Kind='Directory';Prefix='PC-1';Projection='List';Limit=10};Complete-DomeniaLocalSearchPreview $data $s;$event=$null;[void]$s.CacheProgress.TryDequeue([ref]$event);Expect ($event.Kind -ne 'Row' -and $event.DataSource -eq 'SQLite' -and [datetime]$event.ObservedUtc -eq [datetime]$at) 'cached date/source';Expect ($script:Wake -eq 'Timer:Live') 'immediate dispatcher wake'}
 Case 'Late cache cannot replace a completed directory result' {$s=New-SearchFixture;$s.Ended=$true;$data=Read-Store @{Kind='Directory';Prefix='PC-1'};Complete-DomeniaLocalSearchPreview $data $s;Expect ($s.CacheProgress.Count -eq 0) 'late successful refresh'}
 Case 'Old search callback cannot paint a new search' {$old=New-SearchFixture;$new=New-SearchFixture;$data=Read-Store @{Kind='Directory';Prefix='PC-1'};Complete-DomeniaLocalSearchPreview $data $old;Expect ($new.CacheProgress.Count -eq 0 -and $old.CacheProgress.Count -eq 0) 'replaced search'}
 Case 'Directory failure still permits an available local preview' {$s=New-SearchFixture;$s.Ended=$true;$s.Error='offline';$data=Read-Store @{Kind='Directory';Prefix='PC-1'};Complete-DomeniaLocalSearchPreview $data $s;Expect ($s.CacheProgress.Count -eq 2) 'offline preview'}
 Case 'Stored object is rendered without a remote probe or fresh confirmation' {$s=New-ObjectFixture;$data=Read-Store @{Kind='Directory';DN=$dn;Limit=1};Complete-DomeniaLocalObjectPreview $data $s;Expect ($null -ne $script:Rendered -and $script:Rendered.Cached -and $script:Rendered.NoProbes -and -not $script:Rendered.Result.Live) 'readonly cached render';Expect (-not $s.LocalPreviewPending -and $script:CurrentObjectRequestId -eq 'object-1') 'AD refresh stays current'}
 Case 'Object from an old epoch never renders' {$s=New-ObjectFixture;$script:SessionEpoch=8L;$data=Read-Store @{Kind='Directory';DN=$dn;Limit=1};Complete-DomeniaLocalObjectPreview $data $s;Expect ($null -eq $script:Rendered) 'old epoch'}
 Case 'Different object GUID never renders from the local store' {$s=New-ObjectFixture;$data=Read-Store @{Kind='Directory';DN=$dn;Limit=1};$s.ExpectedGuid='00000000-0000-0000-0000-000000000002';Complete-DomeniaLocalObjectPreview $data $s;Expect ($null -eq $script:Rendered) 'GUID mismatch'}
 Case 'Fast AD failure waits for the already pending local object' {$s=New-ObjectFixture;Fail-DomeniaOpenObjectTaskUi 'offline' $s;Expect ($script:CurrentObjectRequestId -eq 'object-1' -and $s.DeferredReadError -eq 'offline') 'defer error';$data=Read-Store @{Kind='Directory';DN=$dn;Limit=1};Complete-DomeniaLocalObjectPreview $data $s;Expect ($null -ne $script:Rendered -and $script:ObjectError -eq 'offline' -and -not $script:CurrentObjectRequestId) 'cached object survives failed refresh'}
 Case 'Programme 6 Delta accepts only mapped fields and rejects identity security and unknown shapes' {
  $state=New-ObjectFixture
  $properties=@{objectGUID=@($guid);name=@('PC-1');description=@('old');distinguishedName=@($dn);userAccountControl=@(4096)}
  $script:SelectedObject=[pscustomobject]@{DN=$dn;Type='Machine';Guid=$guid;RenderIdentity=(Get-DomeniaObjectReadIdentity);Entry=[pscustomobject]@{Properties=$properties}}
  $copy=$properties.Clone();$copy.description=@('new');$result=[pscustomobject]@{Properties=$copy}
  $delta=Get-DomeniaObjectPresentationDelta $result $dn Machine
  Expect ($null -ne $delta -and $delta.Fields.Count -eq 1 -and $delta.Fields['TxtCompDescription'] -ceq 'new') 'only changed description'
  $copy.userAccountControl=@(4098);Expect ($null -eq (Get-DomeniaObjectPresentationDelta $result $dn Machine)) 'account state needs complete fill'
  $copy.userAccountControl=@(4096);$copy.objectGUID=@('different');Expect ($null -eq (Get-DomeniaObjectPresentationDelta $result $dn Machine)) 'identity replacement needs complete fill'
  $copy.objectGUID=@($guid);$copy.description=@([pscustomobject]@{Text='opaque'});Expect ($null -eq (Get-DomeniaObjectPresentationDelta $result $dn Machine)) 'unknown shape needs complete fill'
  $copy.description=@('new');$script:SelectedObject.RenderIdentity='other';Expect ($null -eq (Get-DomeniaObjectPresentationDelta $result $dn Machine)) 'reader replacement needs complete fill'
 }
 Case 'Programme 6 Real object callback skips fills and changes one field without skipping safety or freshness' {
  $state=New-ObjectFixture
  foreach($name in @('Show-AdObjectResult','Get-DeProp','Get-DomeniaEntryFirstString','Convert-DateLabel','Ensure-DomeniaPermissions')){
   $node=@($core.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));Expect ($node.Count -eq 1) ('real function '+$name);. ([scriptblock]::Create($node[0].Extent.Text))
  }
  . (Join-Path $wad 'modules/Domenia-LogonActivity.Model.ps1')
  . (Join-Path $wad 'modules/Domenia-LogonActivity.UI.ps1')
  $script:PresentationCalls=@{Clear=0;Generic=0;Machine=0;Permissions=0;Secrets=0;Freshness=0};$script:PresentationWrites=@{}
  function Keep-DomeniaDraftOnResult {param($Result,$DN,$Type);return $false}
  function Clear-ObjectDetails {$script:PresentationCalls.Clear++}
  function Fill-GenericObject {param($Entry,$Type);$script:PresentationCalls.Generic++}
  function Fill-ComputerObject {param($Entry);$script:PresentationCalls.Machine++}
  function Set-DomeniaControlText {param($Name,$Text);$script:PresentationWrites[$Name]=$Text;return $true}
  function Set-DomeniaObservationTime {param($Record,$Family,$At,[switch]$Succeeded);$script:PresentationCalls.Freshness++}
  function Get-DomeniaActiveFreshnessTable {return @{}}
  function Get-DomeniaRecordFreshness {param($Record,$Family,$Table);return [pscustomobject]@{State='Fresh'}}
  function Apply-CurrentPermissionUi {$script:PresentationCalls.Permissions++}
  function Clear-Secrets {$script:PresentationCalls.Secrets++}
  function Clear-DomeniaActualCapabilityDenials {param($Dn)}
  function Set-DomeniaRelationsSelection {param($Object)}
  function Stop-DomeniaSecretReadTasks {}
  function Sync-DomeniaResultRowFromEntry {param($Entry,$Type)}
  function Snapshot-DomeniaFicheEdit {param($Type)}
  function Update-DomeniaComputerAssistView {param($Uac)}
  function Refresh-AssociationContext {param([switch]$SkipResultRefresh)}
  function Set-DomeniaSupportObjectSource {param($Dn,[bool]$IsLive)}
  function Reset-DomeniaDeferredViews {param($Dn)}
  function Set-VisibleTabsForType {param($Type,[switch]$PreserveWorkspace)}
  function Set-Status {param($Text)}
  function Get-DomeniaControl {param($Name);if($Name -eq 'BtnCompLogonByDc'){return $script:PresentationLogonButton};return $null}
  function Start-PermissionAnalysis {$script:PresentationPermissionStarts++}
  function Get-DomeniaLogonByDcWorkerCode {return ''}
  function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,$DisableControls,$TimeoutSeconds,$TaskClass);$script:PresentationLogonStarts++;return 'explicit-logon'}
  function Update-Dashboard {}
  function Save-DomeniaDraftBaseline {param($DN)}
  $script:AsyncJobs=@{};$script:ShowingCachedObject=$true;$script:RenderingObjectWithoutProbes=$false
  $script:DemoMode=$false;$script:PresentationLogonButton=[pscustomobject]@{IsEnabled=$false};$script:PresentationLogonStarts=0;$script:PresentationPermissionStarts=0
  $script:DeferredPermissionsDn=$dn;$script:DeferredRawDn='keep-raw'
  $properties=@{objectGUID=@($guid);name=@('PC-1');description=@('old');distinguishedName=@($dn);userAccountControl=@(4096)}
  $script:SelectedObject=[pscustomobject]@{DN=$dn;Type='Machine';Guid=$guid;RenderIdentity=(Get-DomeniaObjectReadIdentity);Entry=[pscustomobject]@{Properties=$properties}}
  $copy=$properties.Clone();$result=[pscustomobject]@{Properties=$copy;Type='Machine';DataSource='SQLite';Live=$true;ObservedUtc='2026-01-02T00:00:00Z'}
  Show-AdObjectResult $result $dn Machine -NoNavigate -SuppressRemoteProbes
  Expect ($script:PresentationCalls.Generic -eq 0 -and $script:PresentationCalls.Machine -eq 0 -and $script:PresentationCalls.Clear -eq 0) 'unchanged callback must not fill or clear'
  Expect ($script:PresentationCalls.Permissions -eq 1 -and $script:PresentationCalls.Secrets -eq 1 -and $script:PresentationCalls.Freshness -eq 1) 'unchanged callback retains safety and source time'
  # A cast from ISO Z to DateTime is local on Windows; DateTime equality does not normalise Kind.
  # Compare exact UTC ticks against an independently constructed instant, never against a local cast.
  $expectedReceiptUtc=[datetime]::new(2026,1,2,0,0,0,[DateTimeKind]::Utc)
  Expect ($script:SelectedObject.LoadedAt.Kind -eq [DateTimeKind]::Local -and $script:SelectedObject.LoadedAt.ToUniversalTime().Ticks -eq $expectedReceiptUtc.Ticks) 'receipt time retained'
  Expect ($script:PresentationLogonButton.IsEnabled -and $script:DomeniaLogonTargets.Computer.Generation -eq $script:SelectedObjectGeneration) 'cached receipt rebinds the enabled logon button'
  Start-DomeniaLogonByDcRead Computer;Expect ($script:PresentationLogonStarts -eq 1) 'explicit logon gesture admitted after cached receipt'
  Ensure-DomeniaPermissions;Expect ($script:PresentationPermissionStarts -eq 1 -and $script:DeferredRawDn -ceq 'keep-raw') 'permissions reevaluate without invalidating raw view'
  $result.ObservedUtc='2026-01-02T02:00:00+02:00'
  $script:ShowingCachedObject=$false;Show-AdObjectResult $result $dn Machine -NoNavigate -SuppressRemoteProbes
  Expect ($script:SelectedObject.LoadedAt.ToUniversalTime().Ticks -eq $expectedReceiptUtc.Ticks) 'identical receipt with explicit offset retains the same instant'
  Expect ($script:DomeniaLogonTargets.Computer.Generation -eq $script:SelectedObjectGeneration) 'identical AD receipt rebinds target generation'
  Start-DomeniaLogonByDcRead Computer;Ensure-DomeniaPermissions
  Expect ($script:PresentationLogonStarts -eq 2 -and $script:PresentationPermissionStarts -eq 2) 'identical AD receipt permits explicit logon and reevaluates permissions'
  $copy.description=@('new');$result.ObservedUtc='2026-01-03T03:00:00+02:00';Show-AdObjectResult $result $dn Machine -NoNavigate -SuppressRemoteProbes
  Expect ($script:SelectedObject.LoadedAt.ToUniversalTime().Ticks -eq [datetime]::new(2026,1,3,1,0,0,[DateTimeKind]::Utc).Ticks) 'field delta advances to the actual source instant'
  Expect (@($script:PresentationWrites.Keys|Where-Object{$_ -ne 'TxtCompLogonByDc'}).Count -eq 1 -and $script:PresentationWrites['TxtCompDescription'] -ceq 'new' -and $script:PresentationCalls.Generic -eq 0 -and $script:PresentationCalls.Clear -eq 0) 'one changed field plus local logon summary only'
  Expect ($script:DomeniaLogonTargets.Computer.Generation -eq $script:SelectedObjectGeneration) 'field delta rebinds logon target'
  Start-DomeniaLogonByDcRead Computer;Ensure-DomeniaPermissions
  Expect ($script:PresentationLogonStarts -eq 3 -and $script:PresentationPermissionStarts -eq 3) 'field delta permits explicit logon and reevaluates permissions'
  $copy.userAccountControl=@(4098);Show-AdObjectResult $result $dn Machine -NoNavigate -SuppressRemoteProbes
  Expect ($script:PresentationCalls.Generic -eq 1 -and $script:PresentationCalls.Machine -eq 1 -and $script:PresentationCalls.Clear -eq 1) 'security change retains full fill'
  Expect ($script:PresentationCalls.Permissions -eq 4 -and $script:PresentationCalls.Secrets -eq 4 -and $script:PresentationCalls.Freshness -eq 4) 'all paths retain safety and freshness'
 }
 Case 'Unchanged canonical attributes preserve presentation only for the same reader and identity' {
  $state=New-ObjectFixture
  $properties=@{objectGUID=@($guid);name=@('PC-1');description=@('same');distinguishedName=@($dn)}
  $script:SelectedObject=[pscustomobject]@{DN=$dn;Type='Machine';Guid=$guid;RenderIdentity=(Get-DomeniaObjectReadIdentity);Entry=[pscustomobject]@{Properties=$properties}}
  $copy=@{objectGUID=@($guid);name=@('PC-1');description=@('same');distinguishedName=@($dn)}
  $result=[pscustomobject]@{Properties=$copy}
  Expect (Test-DomeniaObjectPresentationUnchanged $result $dn Machine) 'unchanged map'
  $copy.description=@('changed');Expect (-not (Test-DomeniaObjectPresentationUnchanged $result $dn Machine)) 'changed field must redraw'
  $copy.description=@('same');$copy.objectGUID=@('00000000-0000-0000-0000-000000000099');Expect (-not (Test-DomeniaObjectPresentationUnchanged $result $dn Machine)) 'recreated object'
  $copy.objectGUID=@($guid);$script:SelectedObject.RenderIdentity='another-reader';Expect (-not (Test-DomeniaObjectPresentationUnchanged $result $dn Machine)) 'reader changed'
 }
 Case 'Expired visit can be shown as a preview without extending its freshness' {$script:VisitCache=@{k=[pscustomobject]@{Expires=(Get-Date).AddSeconds(-5);Created=(Get-Date).AddMinutes(-2);Value='stored';Accessed=(Get-Date).AddMinutes(-2)}};$script:CacheStats=[pscustomobject]@{Hits=0;Misses=0;Errors=0;Evictions=0};$expiry=$script:VisitCache.k.Expires;Expect ((Get-VisitCacheValue k -AllowExpired) -eq 'stored' -and $script:VisitCache.k.Expires -eq $expiry) 'stale preview';Expect ($null -eq (Get-VisitCacheValue k)) 'ordinary cache still expires'}
}finally{if([IO.Directory]::Exists($folder)){[IO.Directory]::Delete($folder,$true)}}
$failed=@($cases|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='DomeniaLocalPreview';Passed=($failed -eq 0);Total=$cases.Count;Failed=$failed;Assertions=$script:checks;SQLiteVersion=$script:sqliteVersion;ProjectionTimings=$script:ProjectionTimings;Cases=$cases.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 6
if($failed){exit 1};exit 0
