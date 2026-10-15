#requires -Version 5.1
[CmdletBinding()]
param([switch]$QuerySource,[string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
if($QuerySource){Add-Type -Path (Join-Path (Split-Path -Parent $wad) 'vendor/m4d-admin-common/src/Query/QueryEngine.cs')}else{Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')}
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model','QueryLibrary.Model','Query.Worker','Query.UI')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$script:checks=0;$clock=[Diagnostics.Stopwatch]::StartNew()
function Expect([bool]$Good,[string]$Name){$script:checks++;if(-not $Good){throw $Name}}
function Reject([scriptblock]$Action,[string]$Name){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Expect $failed $Name}
foreach($case in @(@('ramGB','8192 Mo',8),@('ramGB','1,5 To',1536),@('ramGB','8',8),@('uptimeDays','48 h',2),@('checkedDays','1440 min',1),@('diskFreePercent','10,5 %',10.5),@('probe:net.speed','1 Gbit/s',1000),@('probe:hw.cpumhz','2,5 GHz',2500))){Expect ((ConvertTo-DomeniaQueryNumber -Field $case[0] -Text $case[1]) -eq [decimal]$case[2]) ('Unit conversion '+$case[0]+'/'+$case[1])}
foreach($case in @(@('ramGB','8 h'),@('uptimeDays','8 Go'),@('diskFreePercent','NaN'),@('ramGB','1e999'),@('name','8 Go'))){Reject {ConvertTo-DomeniaQueryNumber -Field $case[0] -Text $case[1]} ('Unit rejection '+$case[0]+'/'+$case[1])}
# Point 67: the conversion is shown before the condition is added and the stored value stays typed.
$preview=Get-DomeniaQueryNumberPreview -Text '8192 Mo' -Field 'ramGB'
Expect ($preview.Valid -and $preview.Value -eq 8 -and $preview.Text -ceq '8192 Mo = 8 Go') 'live preview shows the converted canonical value'
$preview=Get-DomeniaQueryNumberPreview -Text '48 h' -Field 'uptimeDays'
Expect ($preview.Text -ceq '48 h = 2 j' -and $preview.Value -is [decimal]) 'hours convert exactly to days and stay a decimal'
$preview=Get-DomeniaQueryNumberPreview -Text '8 h' -Field 'ramGB'
Expect (-not $preview.Valid -and $preview.Text -like 'Unité incompatible*') 'an incompatible unit is explained before adding'
Expect ((Get-DomeniaQueryNumberPreview -Text '' -Field 'ramGB').Text -ceq '') 'an empty entry shows nothing'
Expect ((Get-DomeniaQueryNumberPreview -Text '10' -Field 'diskFreePercent').Text -ceq 'Valeur retenue : 10 %') 'a plain number shows the retained unit'
$values=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
$values['name']='FIXTURE';$values['ramGB']=8;$values['_at:ad']='2026-10-13T10:00:00Z';$values['_at:inventory']='2026-10-10T10:00:00Z';$values['_quality:diskFreePercent']='Expiré';$values['_quality:probe:sec.defender']='Erreur de lecture';$values['_quality:probe:hw.cpu']='Lecture incomplète'
$record=[M4D.Admin.Common.Query.QueryRecord]::new('11111111-1111-1111-1111-111111111111',$values)
$recipe=New-DomeniaQueryRecipe -Junction Any -Clauses @([pscustomobject]@{Field='ramGB';Operator='Less';Value=16},[pscustomobject]@{Field='name';Operator='Equal';Value='OTHER'},[pscustomobject]@{Field='diskFreePercent';Operator='Less';Value=10})
$explanation=@(Get-DomeniaQueryExplanation -Record $record -Recipe $recipe)
Expect ($explanation.Count -eq 3 -and $explanation[0].Verdict -ceq 'Vrai' -and $explanation[1].Verdict -ceq 'Faux' -and $explanation[2].Verdict -ceq 'Inconnu') 'each clause exposes real engine three-state verdict'
Expect ($explanation[2].State -ceq 'Expiré') 'unknown condition keeps its expired reason'
$coverageRecipe=New-DomeniaQueryRecipe -Clauses @(@('name','ramGB','diskFreePercent','probe:sec.defender','probe:hw.cpu','user')|ForEach-Object{[pscustomobject]@{Field=$_;Operator='IsPresent';Value=$null}})
$population=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
for($i=0;$i -lt 20000;$i++){$population.Add($record)}
$coverage=Measure-DomeniaQueryCoverage -Records $population -Recipe $coverageRecipe
Expect ($coverage.Total -eq 20000 -and $coverage.Incomplete -eq 20000 -and $coverage.MixedPeriod -eq 20000 -and $coverage.Undated -eq 20000) 'coverage scans20000 sources and reports temporal differences without silently discarding rows'
$rows=@{};foreach($row in $coverage.Rows){$rows[$row.Id]=$row}
Expect ($rows.ramGB.Available -eq 20000 -and $rows.diskFreePercent.Expired -eq 20000 -and $rows['probe:sec.defender'].Error -eq 20000 -and $rows['probe:hw.cpu'].Partial -eq 20000 -and $rows.user.Unread -eq 20000) 'coverage distinguishes available expired error incomplete and unread'
foreach($row in $coverage.Rows){Expect (($row.Available+$row.Expired+$row.Error+$row.Partial+$row.Unread) -eq $coverage.Total) ('Coverage field totals reconcile '+$row.Id)}
$Payload=[pscustomobject]@{ModuleRoot=$modules;Records=@($record);Recipe=$recipe;CoverageOnly=$true;Saved=@();MaxAgeDays=30}
$actual=& ([scriptblock]::Create((Get-DomeniaQueryWorkerCode)))
Expect ($actual.Coverage.Total -eq 1 -and $null -eq $actual.PSObject.Properties['Matched']) 'coverage worker stops before applying query conditions'
# Point 64: collect only the missing or stale measurements, with a counted cost and no invented duration.
$now=[datetime]::new(2026,10,15,12,0,0,[DateTimeKind]::Utc)
function New-PlanRecord([string]$Id,[hashtable]$Data){$d=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);foreach($k in $Data.Keys){$d[$k]=$Data[$k]};return [M4D.Admin.Common.Query.QueryRecord]::new($Id,$d)}
$freshAt=$now.AddMinutes(-2).ToString('o');$oldAt=$now.AddHours(-3).ToString('o');$probeAt=$now.AddSeconds(-20).ToString('o')
$planRecords=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
$planRecords.Add((New-PlanRecord 'aaaaaaaa-0000-0000-0000-000000000001' @{'name'='FRESH';'dn'='CN=FRESH,DC=example,DC=test';'active'=$true;'ramGB'=8;'_at:inventory'=$freshAt;'probe:hw.cpuload'=10;'_at:probe:hw.cpuload'=$probeAt}))
$planRecords.Add((New-PlanRecord 'aaaaaaaa-0000-0000-0000-000000000002' @{'name'='OLD';'dn'='CN=OLD,DC=example,DC=test';'active'=$true;'ramGB'=8;'_at:inventory'=$oldAt}))
$planRecords.Add((New-PlanRecord 'aaaaaaaa-0000-0000-0000-000000000003' @{'name'='ERR';'dn'='CN=ERR,DC=example,DC=test';'active'=$true;'ramGB'=8;'_at:inventory'=$freshAt;'_quality:ramGB'='Erreur de lecture';'probe:hw.cpuload'=5;'_at:probe:hw.cpuload'=$probeAt}))
$planRecords.Add((New-PlanRecord 'aaaaaaaa-0000-0000-0000-000000000004' @{'name'='OFF';'dn'='CN=OFF,DC=example,DC=test';'active'=$false}))
$planRecords.Add((New-PlanRecord 'aaaaaaaa-0000-0000-0000-000000000005' @{'name'='UNKNOWN';'dn'='CN=UNKNOWN,DC=example,DC=test'}))
$planRecipe=New-DomeniaQueryRecipe -Clauses @([pscustomobject]@{Field='ramGB';Operator='Less';Value=16},[pscustomobject]@{Field='probe:hw.cpuload';Operator='Greater';Value=80},[pscustomobject]@{Field='active';Operator='Equal';Value=$true})
$plan=New-DomeniaQueryMissingCollectionPlan -Records $planRecords -Recipe $planRecipe -CacheMinutes 15 -NowUtc $now
Expect ($plan.Total -eq 5 -and $plan.Reused -eq 1 -and $plan.Disabled -eq 1 -and $plan.UnknownState -eq 1 -and @($plan.Targets).Count -eq 2) 'plan proposes only active accounts with missing or stale measurements'
$oldTarget=@($plan.Targets|Where-Object{$_.name -ceq 'OLD'})[0];$errorTarget=@($plan.Targets|Where-Object{$_.name -ceq 'ERR'})[0]
Expect ((@($oldTarget.MissingFields) -join ',') -ceq 'probe:hw.cpuload,ramGB' -and (@($oldTarget.MissingProbeIds) -join ',') -ceq 'hw.cpuload') 'stale inventory and unread probe are both listed for one target'
Expect ((@($errorTarget.MissingFields) -join ',') -ceq 'ramGB' -and -not @($errorTarget.MissingProbeIds).Count) 'a flagged value is missing even when recent while a fresh probe is reused'
Expect ($plan.Inventory -and -not $plan.Ping -and $plan.Wmi -and (@($plan.ProbeIds) -join ',') -ceq 'hw.cpuload') 'only missing families and probes are planned'
Expect ($plan.FieldCounts[0].Field -ceq 'ramGB' -and $plan.FieldCounts[0].Missing -eq 2) 'most missing information is ranked first'
$forced=New-DomeniaQueryMissingCollectionPlan -Records $planRecords -Recipe $planRecipe -CacheMinutes 0 -NowUtc $now
Expect (@($forced.Targets).Count -eq 3 -and $forced.Reused -eq 0) 'forced re-read proposes every active account and still excludes disabled or unknown accounts'
$generic=New-DomeniaMissingCollectionPlan -Records $planRecords -Fields @('presence','name','presence') -CacheMinutes 15 -NowUtc $now
Expect (@($generic.Targets).Count -eq 3 -and $generic.Ping -and -not $generic.Wmi -and @($generic.Fields).Count -eq 1) 'reusable field plan ignores local AD fields and duplicates'
$selected=New-DomeniaQueryMissingCollectionPlan -Records $planRecords -Recipe (New-DomeniaQueryRecipe -Clauses @($planRecipe.Clauses) -ObjectIds @('aaaaaaaa-0000-0000-0000-000000000002')) -NowUtc $now
Expect ($selected.Total -eq 1 -and @($selected.Targets).Count -eq 1) 'a frozen identity selection bounds the plan'
$detailPlan=New-DomeniaMissingCollectionPlan -Records $planRecords -Fields @('detail:fixture:Caption') -NowUtc $now
Expect (@($detailPlan.Targets).Count -eq 0 -and $detailPlan.NotCollectable -eq 3 -and $detailPlan.Reused -eq 0) 'advanced WMI detail fields are reported as not park-collectable, never reused'
Reject {New-DomeniaMissingCollectionPlan -Records $planRecords -Fields @(for($i=0;$i -lt 300;$i++){'probe:fixture'+$i})} 'plan field budget is explicit'
$workload=Measure-DomeniaCollectionPlanWorkload $plan
Expect ($workload.Mode -ceq 'Wmi' -and $workload.Targets -eq 2 -and $workload.ProbeReads -eq 1 -and $workload.PingReads -eq 0 -and $workload.InventoryReads -eq 2 -and $workload.Level -ceq 'Faible') 'workload counts contacts, inventory and probe reads for the WMI-only mode'
$text=Format-DomeniaQueryCollectionPlanText -Plan $plan -Workload $workload -Concurrency 4
Expect ($text -like '*2 poste(s) à relire sur 5 examiné(s)*' -and $text -like '*Coût : Faible*' -and $text -like '*Durée non estimée*' -and $text -notlike '*ping ICMP*' -and $text -like '*Mémoire relevée en Go (2)*') 'plan text states targets, cost and missing information and never invents a duration'
$Payload=[pscustomobject]@{ModuleRoot=$modules;Saved=@(for($i=0;$i -lt 125;$i++){New-DomeniaQueryRecipe -Name ('Personal '+$i)})}
$actual=& ([scriptblock]::Create((Get-DomeniaQueryLibraryWorkerCode)))
$templateCount=@(Get-DomeniaQueryTemplates).Count
Expect ($templateCount -ge 515 -and $actual.Rows.Count -eq ($templateCount+125) -and @($actual.Rows|Where-Object SourceId -eq 'Saved').Count -eq 125) 'actual lazy worker prepares every delivered model plus 125 personal definitions'
$context=[pscustomobject]@{Version=1;StoreId='fixture';DomainDn='DC=example,DC=test';Path=(Join-Path ([IO.Path]::GetTempPath()) 'fixture-query.sqlite')}
$personal=New-DomeniaQueryRecipe -Id 'personal.fixture' -Name 'Équipements  mémoire'
$entry=New-DomeniaQueryLibraryRecord -Context $context -Recipe $personal -ExpectedRevision 7
Expect ($entry.ExpectedRevision -eq 7 -and $entry.Revision -eq 8 -and $entry.NameFold -ceq 'equipements memoire' -and $entry.DefinitionVersion -eq 1) 'library record binds expected revision and canonical Unicode search'
Expect ((ConvertTo-DomeniaQuerySearchKey ([string][char]0x45+[char]0x301+'QUIPEMENTS')) -ceq 'equipements') 'decomposed Unicode accents have the same search key'
$hash=[Security.Cryptography.SHA256]::Create();try{$sha=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($entry.DefinitionJson))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
Expect ($sha -ceq $entry.DefinitionSHA256) 'exact immutable JSON has reproducible SHA256'
Reject {New-DomeniaQueryLibraryRecord -Context $null -Recipe $personal -ExpectedRevision 0} 'library requires domain/store context'
Reject {New-DomeniaQueryLibraryRecord -Context $context -Recipe $personal -ExpectedRevision -1} 'library rejects negative expected revision'
$bad=New-DomeniaQueryRecipe;$bad|Add-Member NoteProperty Script 'Remove-Item fixture'
Reject {New-DomeniaQueryLibraryRecord -Context $context -Recipe $bad -ExpectedRevision 0} 'library definition rejects executable extension properties'
$read=New-DomeniaQueryLibraryRead -Context $context -Text 'ÉQUIPE%' -Offset 200 -Limit 100
Expect ($read.Term -ceq 'equipe%' -and $read.Offset -eq 200 -and $read.OrderBy -ceq 'name_fold,id') 'library read uses bounded stable order and literal filter DTO'
Reject {New-DomeniaQueryLibraryRead -Context $context -Limit 10000} 'library read budget250 is explicit'
$pack=[pscustomobject]@{Format='Domenia.QueryPack/1';Origin='Fixture non exécutée';DomainDn=$context.DomainDn;Recipes=@($personal)}
$plan=New-DomeniaQueryPackImportPlan -Context $context -Json ($pack|ConvertTo-Json -Depth 16)
Expect ($plan.Items[0].Status -ceq 'Nouvelle' -and $plan.Items[0].DefaultAction -ceq 'Ignorer' -and -not $plan.Executable) 'new imported recipe is preview only and not selected by default'
$plan=New-DomeniaQueryPackImportPlan -Context $context -Json ($pack|ConvertTo-Json -Depth 16) -ExistingRows @($entry)
Expect ($plan.Items[0].Status -ceq 'Identique' -and $plan.Items[0].ExpectedRevision -eq 8) 'identical pack preserves optimistic revision'
$personal.Name='Different';$plan=New-DomeniaQueryPackImportPlan -Context $context -Json ($pack|ConvertTo-Json -Depth 16) -ExistingRows @($entry)
Expect ($plan.Items[0].Status -ceq 'Conflit' -and $plan.Items[0].Before.DefinitionJson -ceq $entry.DefinitionJson) 'conflict preview preserves old definition for eventual rollback'
$pack.Recipes=@(New-DomeniaQueryRecipe -ObjectIds @($record.Id));$pack.DomainDn='DC=another,DC=test'
$plan=New-DomeniaQueryPackImportPlan -Context $context -Json ($pack|ConvertTo-Json -Depth 16)
Expect ($plan.Items[0].Status -ceq 'Domaine différent' -and $plan.Items[0].AllowedActions.Count -eq 1) 'identity-bound imported query cannot silently switch domains'
# Point 69: versioned packs with a verified fingerprint, readable differences and a durable rollback journal.
$packRecipes=@((New-DomeniaQueryRecipe -Id 'personal.pack1' -Name 'Mémoire faible' -Clauses @([pscustomobject]@{Field='ramGB';Operator='Less';Value=[decimal]8})),(New-DomeniaQueryRecipe -Id 'personal.pack2' -Name 'Disque plein' -Clauses @([pscustomobject]@{Field='diskFreePercent';Operator='Less';Value=[decimal]10})))
$packed=New-DomeniaQueryPack -Context $context -Recipes $packRecipes -PackName 'Revue matériel' -PackVersion 3 -NowUtc $now
Expect ($packed.Format -ceq 'Domenia.QueryPack/2' -and $packed.PackId -ceq (Get-DomeniaQueryPackId 'REVUE MATERIEL') -and $packed.ContentSHA256 -cmatch '^[0-9a-f]{64}$') 'a pack carries a stable identity per name and a content fingerprint'
$packJson=ConvertTo-Json -InputObject $packed -Depth 32
$verifiedPlan=New-DomeniaQueryPackImportPlan -Context $context -Json $packJson -History @([pscustomobject]@{PackId=$packed.PackId;PackVersion=2})
Expect ($verifiedPlan.Verified -and $verifiedPlan.PackName -ceq 'Revue matériel' -and $verifiedPlan.PackVersion -eq 3 -and $verifiedPlan.PreviousVersion -eq 2 -and -not $verifiedPlan.Executable -and $verifiedPlan.Items[0].ChangeSummary -ceq 'Nouvelle requête') 'the preview verifies the fingerprint and recalls the version already imported'
$tampered=ConvertFrom-Json -InputObject $packJson;$tampered.Recipes[0].Clauses[0].Value=4
Reject {New-DomeniaQueryPackImportPlan -Context $context -Json (ConvertTo-Json -InputObject $tampered -Depth 32)} 'an altered pack is refused before any preview'
$renamed=ConvertFrom-Json -InputObject $packJson;$renamed.PackName='Autre pack'
Reject {New-DomeniaQueryPackImportPlan -Context $context -Json (ConvertTo-Json -InputObject $renamed -Depth 32)} 'a pack whose identity does not match its name is refused'
Reject {New-DomeniaQueryPack -Context $context -Recipes $packRecipes -PackName 'Revue' -PackVersion 0} 'the pack version range is explicit'
$existingRow=New-DomeniaQueryLibraryRecord -Context $context -Recipe $packRecipes[0] -ExpectedRevision 4
$changedRecipe=Copy-DomeniaQueryRecipe $packRecipes[0];$changedRecipe.Clauses[0].Value=16;$changedRecipe.Name='Mémoire à revoir'
$changePack=New-DomeniaQueryPack -Context $context -Recipes @($changedRecipe) -PackName 'Revue matériel' -PackVersion 4
$conflict=(New-DomeniaQueryPackImportPlan -Context $context -Json (ConvertTo-Json -InputObject $changePack -Depth 32) -ExistingRows @($existingRow)).Items[0]
Expect ($conflict.Status -ceq 'Conflit' -and $conflict.ChangeSummary -like '3 différence(s) : *' -and @($conflict.Changes|Where-Object{$_.Element -ceq 'Condition ajoutée' -and $_.After -like '*16 Go'}).Count -eq 1 -and @($conflict.Changes|Where-Object{$_.Element -ceq 'Nom' -and $_.Before -ceq 'Mémoire faible'}).Count -eq 1) 'a conflict lists each readable difference before any choice'
$archivedRow=New-DomeniaQueryLibraryRecord -Context $context -Recipe $packRecipes[0] -ExpectedRevision 4;$archivedRow.Archived=$true
$archivedItem=(New-DomeniaQueryPackImportPlan -Context $context -Json $packJson -ExistingRows @($archivedRow)).Items[0]
Expect ($archivedItem.Status -ceq 'Archivée localement' -and $archivedItem.AllowedActions -ccontains 'Remplacer après confirmation') 'a locally archived recipe can be restored only by an explicit replacement'
$applied=@([pscustomobject]@{Id='personal.pack1';Name='Mémoire faible';Revision=5;Sequence=0;Before=$existingRow},[pscustomobject]@{Id='personal.pack2';Name='Disque plein';Revision=1;Sequence=1;Before=$null})
$journalEntry=New-DomeniaQueryImportJournalEntry -Context $context -Applied $applied -Plan $verifiedPlan -NowUtc $now
Expect ($journalEntry.Kind -ceq 'Import' -and $journalEntry.PackVersion -eq 3 -and $journalEntry.Items[0].Before.DefinitionSHA256 -ceq $existingRow.DefinitionSHA256 -and $null -eq $journalEntry.Items[1].Before) 'the journal keeps the provenance and only the definitions it replaced'
$line=ConvertTo-Json -InputObject $journalEntry -Depth 32 -Compress
$foreignEntry=ConvertFrom-Json -InputObject $line;$foreignEntry.StoreId='another-store'
$journal=ConvertFrom-DomeniaQueryImportJournal -Lines @($line,'{not json',(ConvertTo-Json -InputObject $foreignEntry -Depth 32 -Compress)) -StoreId $context.StoreId
Expect (@($journal.Entries).Count -eq 1 -and $journal.Entries[0].Restorable -and $journal.Rejected -eq 1 -and $journal.Entries[0].DisplayName -like '*Revue matériel v3 · 2 recette(s)') 'an import of this store stays restorable after a restart; foreign and unreadable lines are not offered'
Expect (-not (ConvertFrom-DomeniaQueryImportJournal -Lines @($line.Replace($existingRow.DefinitionSHA256,('0'*64))) -StoreId $context.StoreId).Entries[0].Restorable) 'an altered replaced definition is never restorable'
$undo=ConvertTo-Json -InputObject (New-DomeniaQueryImportJournalEntry -Context $context -Applied @($applied[0]) -RollsBack $journalEntry.ImportId -NowUtc $now) -Depth 32 -Compress
Expect (@((ConvertFrom-DomeniaQueryImportJournal -Lines @($line,$undo) -StoreId $context.StoreId).Entries).Count -eq 0) 'an import already rolled back is no longer offered'
$journalPath=Join-Path ([IO.Path]::GetTempPath()) ('domenia-'+[guid]::NewGuid().ToString('N')+'.sqlite.query-imports.jsonl')
$exportPath=Join-Path ([IO.Path]::GetTempPath()) ('domenia-pack-'+[guid]::NewGuid().ToString('N')+'.json')
try{
    for($i=0;$i -lt 41;$i++){$Payload=[pscustomobject]@{ModuleRoot=$modules;Mode='JournalAppend';Path=$journalPath;Entry=(New-DomeniaQueryImportJournalEntry -Context $context -Applied $applied -Plan $verifiedPlan -NowUtc $now)};$appended=& ([scriptblock]::Create((Get-DomeniaQueryTransferWorkerCode)))}
    Expect ($appended.Journaled -and @([IO.File]::ReadAllLines($journalPath)|Where-Object{$_}).Count -eq 40) 'the journal keeps its most recent lines within the explicit bound'
    $Payload=[pscustomobject]@{ModuleRoot=$modules;Mode='JournalRead';Path=$journalPath;StoreId=$context.StoreId}
    $journalRead=& ([scriptblock]::Create((Get-DomeniaQueryTransferWorkerCode)))
    Expect (@($journalRead.Entries).Count -eq 20 -and $journalRead.Entries[0].Restorable) 'reading returns the twenty most recent restorable imports'
    $Payload=[pscustomobject]@{ModuleRoot=$modules;Mode='JournalRead';Path=($journalPath+'.txt');StoreId=$context.StoreId}
    Reject {& ([scriptblock]::Create((Get-DomeniaQueryTransferWorkerCode)))} 'only the dedicated journal file is read'
    $Payload=[pscustomobject]@{ModuleRoot=$modules;Mode='ExportPack';Path=$exportPath;Context=$context;Recipes=$packRecipes;PackName='Revue matériel';PackVersion=5}
    $exported=& ([scriptblock]::Create((Get-DomeniaQueryTransferWorkerCode)))
    $Payload=[pscustomobject]@{ModuleRoot=$modules;Mode='ImportPreview';Path=$exportPath;Context=$context;ExistingRows=@();History=@()}
    $preview=& ([scriptblock]::Create((Get-DomeniaQueryTransferWorkerCode)))
    Expect ($exported.Complete -and $exported.PackVersion -eq 5 -and $preview.Plan.Verified -and $preview.Plan.PackVersion -eq 5 -and @($preview.Plan.Items).Count -eq 2) 'a pack written by Domenia is verified when it is examined again'
}finally{foreach($file in @($journalPath,$exportPath)){if([IO.File]::Exists($file)){[IO.File]::Delete($file)}}}
# Actual UI pagination with inert controls, no WPF claim.
$script:Fake=@{};foreach($name in @('DgQueryLibrary','CmbQueryLibrarySource','CmbQueryLibraryCategory','TxtQueryLibrarySearch','BtnQueryLibraryPrevious','BtnQueryLibraryNext','BtnQueryLibraryUse')){$script:Fake[$name]=[pscustomobject]@{ItemsSource=@();SelectedItem=$null;SelectedIndex=-1;Text='';IsEnabled=$false}}
function Get-DomeniaControl([string]$Name){return $script:Fake[$Name]}
function Set-DomeniaControlText([string]$Name,[string]$Text){$script:LastLabel=$Text}
$script:DomeniaQueryState=[pscustomobject]@{LibraryReady=$true;LibraryOffset=0;LibraryRows=$actual.Rows}
Update-DomeniaQueryLibrary
Expect ($script:Fake.DgQueryLibrary.ItemsSource.Count -eq 100 -and $script:Fake.BtnQueryLibraryNext.IsEnabled -and -not $script:Fake.BtnQueryLibraryPrevious.IsEnabled) 'library first page is100 with explicit navigation'
$script:DomeniaQueryState.LibraryOffset=600;Update-DomeniaQueryLibrary -KeepPage
Expect ($script:Fake.DgQueryLibrary.ItemsSource.Count -eq ($actual.Rows.Count-600) -and -not $script:Fake.BtnQueryLibraryNext.IsEnabled) 'library last page preserves the remaining recipes'
$script:Fake.TxtQueryLibrarySearch.Text='Personal 124';Update-DomeniaQueryLibrary
Expect ($script:Fake.DgQueryLibrary.ItemsSource.Count -eq 1 -and $script:DomeniaQueryState.LibraryOffset -eq 0) 'search applies to full library and resets pagination'
# Point 70: list, indicator and report name the versioned definition they evaluate; a draft is never presented
# as the stored revision, and equal values typed differently do not fake a modification.
$bindingRecipe=New-DomeniaQueryRecipe -Id 'personal.binding' -Name 'Liée' -Clauses @([pscustomobject]@{Field='ramGB';Operator='Less';Value=[decimal]8})
$bindingRow=New-DomeniaQueryLibraryRecord -Context $context -Recipe $bindingRecipe -ExpectedRevision 2
$saved=Get-DomeniaQueryDefinitionBinding -Recipe (ConvertFrom-Json -InputObject $bindingRow.DefinitionJson) -Row $bindingRow
Expect ($saved.State -ceq 'Saved' -and $saved.Revision -eq 3 -and $saved.DefinitionSHA256 -ceq $bindingRow.DefinitionSHA256 -and $saved.Label -ceq 'révision 3 enregistrée') 'the stored revision is named with its fingerprint'
$draft=Copy-DomeniaQueryRecipe $bindingRecipe;$draft.Clauses[0].Value=16
$modified=Get-DomeniaQueryDefinitionBinding -Recipe $draft -Row $bindingRow
Expect ($modified.State -ceq 'Modified' -and $modified.Label -ceq 'brouillon modifié depuis la révision 3 (2 différence(s))') 'a modified draft is never presented as the stored revision'
$archivedBinding=New-DomeniaQueryLibraryRecord -Context $context -Recipe $bindingRecipe -ExpectedRevision 2;$archivedBinding.Archived=$true
Expect ((Get-DomeniaQueryDefinitionBinding -Recipe $bindingRecipe -Row $archivedBinding).State -ceq 'Archived' -and (Get-DomeniaQueryDefinitionBinding -Recipe $bindingRecipe).State -ceq 'Unsaved' -and (Get-DomeniaQueryDefinitionBinding -Recipe @(Get-DomeniaQueryTemplates)[0]).State -ceq 'Template') 'archived, unsaved and delivered definitions are distinguished'
$paramStored=Copy-DomeniaQueryRecipe (@(Get-DomeniaQueryTemplates|Where-Object{$_.Id -ceq 'template.param.diskfree'})[0]) -Id 'personal.param';$paramStored.ParameterValues=[pscustomobject]@{Seuil=15}
$paramRow=New-DomeniaQueryLibraryRecord -Context $context -Recipe $paramStored -ExpectedRevision 0
$paramDraft=Copy-DomeniaQueryRecipe $paramStored;$paramDraft.ParameterValues=@{Seuil=[decimal]15}
Expect ((Get-DomeniaQueryDefinitionBinding -Recipe $paramDraft -Row $paramRow).State -ceq 'Saved') 'equal parameter values held in another container do not fake a modification'
# Point 68: personal recipes keep their stored category; archives are parsed off the UI thread and listed apart.
$archivedRecipe=New-DomeniaQueryRecipe -Id 'personal.archived' -Name 'Ancienne revue'
$Payload=[pscustomobject]@{ModuleRoot=$modules;Saved=@(New-DomeniaQueryRecipe -Id 'personal.sorted' -Name 'Revue rangée');Categories=@{'personal.sorted'='Audit 2026';'personal.archived'='Audit 2025'};Archived=@(
    [pscustomobject]@{Id='personal.archived';Category='Audit 2025';Revision=4;UpdatedUtc='2026-10-01T08:00:00.0000000Z';DefinitionJson=(ConvertTo-Json -InputObject $archivedRecipe -Depth 32 -Compress)},
    [pscustomobject]@{Id='personal.broken';Category='Audit 2025';Revision=1;UpdatedUtc='';DefinitionJson='{"Format":"Inconnu"}'})}
$organised=& ([scriptblock]::Create((Get-DomeniaQueryLibraryWorkerCode)))
$sortedRow=@($organised.Rows|Where-Object{$_.Id -ceq 'personal.sorted'})[0];$archivedRows=@($organised.Rows|Where-Object{$_.SourceId -ceq 'Archived'})
Expect ($sortedRow.Category -ceq 'Audit 2026' -and $sortedRow.SourceId -ceq 'Saved') 'a saved recipe is listed in its stored category'
Expect ($archivedRows.Count -eq 1 -and $archivedRows[0].Category -ceq 'Audit 2025' -and $archivedRows[0].Description -like 'Requête archivée le *révision 4*' -and $organised.ArchivedRejected -eq 1) 'archived definitions are checked off the UI thread and unreadable ones are counted, never shown'
$script:Fake['BtnQueryLibraryRestore']=[pscustomobject]@{IsEnabled=$false;Visibility='Collapsed'}
$script:DomeniaQueryState=[pscustomobject]@{LibraryReady=$true;LibraryOffset=0;LibraryRows=$organised.Rows}
$script:Fake.TxtQueryLibrarySearch.Text='';$script:Fake.CmbQueryLibrarySource.SelectedItem=$null;Update-DomeniaQueryLibrary
Expect (@($script:Fake.DgQueryLibrary.ItemsSource|Where-Object{$_.SourceId -ceq 'Archived'}).Count -eq 0) 'archived recipes stay out of the usable views'
$script:Fake.CmbQueryLibrarySource.SelectedItem=[pscustomobject]@{Tag='Archived'};Update-DomeniaQueryLibrary
Expect (@($script:Fake.DgQueryLibrary.ItemsSource).Count -eq 1 -and @($script:Fake.DgQueryLibrary.ItemsSource)[0].Id -ceq 'personal.archived') 'the Archives view lists the archived recipe'
$script:Fake.DgQueryLibrary.SelectedItem=@($script:Fake.DgQueryLibrary.ItemsSource)[0];Show-DomeniaQueryLibraryDetails
Expect ([string]$script:Fake.BtnQueryLibraryRestore.Visibility -ceq 'Visible' -and $script:Fake.BtnQueryLibraryRestore.IsEnabled -and -not $script:Fake.BtnQueryLibraryUse.IsEnabled) 'an archived recipe offers Restaurer instead of Utiliser'
$script:Fake.CmbQueryLibrarySource.SelectedItem=$null
# Point 65: the typed parameter editor checks the entry with the compiler rule before Apply (inert controls).
$paramRecipe=Copy-DomeniaQueryRecipe (@(Get-DomeniaQueryTemplates|Where-Object{$_.Id -ceq 'template.param.diskfree'})[0])
$paramRow=@(Get-DomeniaQueryParameterRows $paramRecipe)[0]
foreach($name in @('DgQueryParameters','TxtQueryParameterValue','CmbQueryParameterChoice','BtnQueryParameterApply','BtnQueryParameterScope')){$script:Fake[$name]=[pscustomobject]@{ItemsSource=@($paramRow);SelectedItem=$paramRow;SelectedIndex=0;Text='';IsEnabled=$false;Visibility='Visible'}}
$script:DomeniaQueryState=[pscustomobject]@{Recipe=$paramRecipe;LibraryReady=$true;LibraryOffset=0;LibraryRows=@()}
Show-DomeniaQueryParameterEditor
Expect ($script:Fake.TxtQueryParameterValue.Text -ceq '10' -and [string]$script:Fake.CmbQueryParameterChoice.Visibility -ceq 'Collapsed' -and $script:Fake.BtnQueryParameterApply.IsEnabled -and [string]$script:Fake.BtnQueryParameterScope.Visibility -ceq 'Collapsed') 'a numeric parameter opens a text entry with its current value'
$script:Fake.TxtQueryParameterValue.Text='150';Update-DomeniaQueryParameterCheck
Expect (-not $script:Fake.BtnQueryParameterApply.IsEnabled -and $script:LastLabel -like '*inférieure ou égale à 100 %*') 'an out-of-range entry disables Apply and states the bound'
$script:Fake.TxtQueryParameterValue.Text='15 %';Update-DomeniaQueryParameterCheck
Expect ($script:Fake.BtnQueryParameterApply.IsEnabled -and $script:LastLabel -ceq 'Valeur retenue : 15 %') 'a valid entry shows the retained typed value'
$report=[pscustomobject]@{Status='PASS';Assertions=$checks;CoveragePopulation=20000;SourceMode=[bool]$QuerySource;ElapsedSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,3);PowerShell=$PSVersionTable.PSVersion.ToString();Scope='Actual models, worker factories, XML-independent UI pagination with inert controls; no network, AD, WMI or WPF'}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Compress
