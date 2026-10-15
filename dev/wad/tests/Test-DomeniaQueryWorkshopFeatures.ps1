#requires -Version 5.1
[CmdletBinding()]
param([switch]$QuerySource,[string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
if($QuerySource){Add-Type -Path (Join-Path (Split-Path -Parent $wad) 'vendor/m4d-admin-common/src/Query/QueryEngine.cs')}else{Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')}
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model','QueryLibrary.Model','Query.Worker','QueryTransfer.Worker','Query.UI')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
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
$values['name']='FIXTURE';$values['ramGB']=8;$values['_at:field:name']='2026-10-13T10:00:00Z';$values['_at:inventory']='2026-10-10T10:00:00Z';$values['_quality:diskFreePercent']='Expiré';$values['_quality:probe:sec.defender']='Erreur de lecture';$values['_quality:probe:hw.cpu']='Lecture incomplète'
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
# One planner for the workshop and the widgets: with the reuse age of the survey (New-DomeniaCollectionPlan
# -ReuseMaxAgeDays), a stored answer of the family or probe younger than that age is reused, flagged values are not.
$reusePlan=New-DomeniaQueryMissingCollectionPlan -Records $planRecords -Recipe $planRecipe -CacheMinutes 15 -NowUtc $now -ReuseMaxAgeDays 30
$reuseOld=@($reusePlan.Targets|Where-Object{$_.name -ceq 'OLD'});$reuseError=@($reusePlan.Targets|Where-Object{$_.name -ceq 'ERR'})
Expect ($reusePlan.ReuseMaxAgeDays -eq 30 -and $reusePlan.Reused -eq 1 -and @($reusePlan.Targets).Count -eq 2 -and $reuseOld.Count -eq 1 -and (@($reuseOld[0].MissingFields) -join ',') -ceq 'probe:hw.cpuload' -and $reuseError.Count -eq 1 -and (@($reuseError[0].MissingFields) -join ',') -ceq 'ramGB') 'with the survey reuse age a three-hour-old inventory is answered while an unread probe and a flagged value stay missing'
$consoleRecords=@(New-PlanRecord 'aaaaaaaa-0000-0000-0000-000000000006' @{'name'='NOUSER';'dn'='CN=NOUSER,DC=example,DC=test';'active'=$true;'_at:console'=$now.AddDays(-2).ToString('o')})
$consoleSurvey=New-DomeniaMissingCollectionPlan -Records $consoleRecords -Fields @('user') -NowUtc $now -ReuseMaxAgeDays 30
$consoleCache=New-DomeniaMissingCollectionPlan -Records $consoleRecords -Fields @('user') -NowUtc $now -CacheMinutes 15
Expect ($consoleSurvey.Reused -eq 1 -and @($consoleSurvey.Targets).Count -eq 0 -and @($consoleCache.Targets).Count -eq 1) 'a console read that found nobody answers the survey rule, not the cache rule'
$expiredRecords=@(New-PlanRecord 'aaaaaaaa-0000-0000-0000-000000000007' @{'name'='EXPIRED';'dn'='CN=EXPIRED,DC=example,DC=test';'active'=$true;'_at:console'=$now.AddDays(-40).ToString('o');'_quality:user'='Expiré'})
Expect (@((New-DomeniaMissingCollectionPlan -Records $expiredRecords -Fields @('user') -NowUtc $now -ReuseMaxAgeDays 30).Targets).Count -eq 1) 'an expired console read is missing under the survey rule'
$reuseText=Format-DomeniaQueryCollectionPlanText -Plan $reusePlan -Concurrency 4
Expect ($reuseText -like '*de plus de 30 jours sont à relire*' -and $reuseText -like '*met de côté ceux qui sont déjà à jour*' -and $reuseText -notlike '*utilisateur console*') 'the plan states the survey reuse age and reads no console user the recipe does not use'
$Payload=[pscustomobject]@{ModuleRoot=$modules;Records=$planRecords;Recipe=$planRecipe;PlanCollection=$true;CacheMinutes=15;Saved=@();MaxAgeDays=30}
$workerPlan=(& ([scriptblock]::Create((Get-DomeniaQueryWorkerCode)))).CollectionPlan
$Payload.CacheMinutes=0
$workerForced=(& ([scriptblock]::Create((Get-DomeniaQueryWorkerCode)))).CollectionPlan
Expect ($workerPlan.ReuseMaxAgeDays -eq 30 -and @($workerPlan.Targets).Count -eq 2 -and $workerForced.ReuseMaxAgeDays -eq 0 -and @($workerForced.Targets).Count -eq 3) 'the plan worker uses the observation age of the survey, and keeps nothing for a forced re-read'
$Payload=[pscustomobject]@{ModuleRoot=$modules;Saved=@(for($i=0;$i -lt 125;$i++){New-DomeniaQueryRecipe -Name ('Personal '+$i)})}
$actual=& ([scriptblock]::Create((Get-DomeniaQueryLibraryWorkerCode)))
$templateCount=@(Get-DomeniaQueryTemplates).Count
# 518 delivered models before the parameterised ones (three of them for installed applications), plus point 65.
Expect ($templateCount -ge 518 -and $actual.Rows.Count -eq ($templateCount+125) -and @($actual.Rows|Where-Object SourceId -eq 'Saved').Count -eq 125) 'actual lazy worker prepares every delivered model plus 125 personal definitions'
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
# An interrupted rollback hides its source import only with the recipes it did not restore offered under its own id.
$partialUndo=New-DomeniaQueryImportJournalEntry -Context $context -Applied @([pscustomobject]@{Id='personal.pack2';Name='Disque plein';Revision=2;Sequence=1;Before=$null}) -Plan $journalEntry -RollsBack $journalEntry.ImportId -Remaining @($journalEntry.Items[0]) -NowUtc $now
$partialLine=ConvertTo-Json -InputObject $partialUndo -Depth 32 -Compress
$afterPartial=ConvertFrom-DomeniaQueryImportJournal -Lines @($line,$partialLine) -StoreId $context.StoreId
$rest=@($afterPartial.Entries)
Expect ($rest.Count -eq 1 -and $rest[0].ImportId -ceq $partialUndo.ImportId -and $rest[0].Partial -and $rest[0].Restorable -and @($rest[0].Items).Count -eq 1 -and [string]$rest[0].Items[0].Id -ceq 'personal.pack1' -and [long]$rest[0].Items[0].Revision -eq 5 -and $rest[0].DisplayName -like '*Revue matériel v3 · restauration interrompue, 1 recette(s) encore à restaurer') 'an interrupted rollback keeps the recipes it did not restore restorable'
$finish=ConvertTo-Json -InputObject (New-DomeniaQueryImportJournalEntry -Context $context -Applied @($rest[0].Items[0]) -Plan $rest[0] -RollsBack $partialUndo.ImportId -NowUtc $now) -Depth 32 -Compress
Expect (@((ConvertFrom-DomeniaQueryImportJournal -Lines @($line,$partialLine,$finish) -StoreId $context.StoreId).Entries).Count -eq 0) 'restoring the rest of an interrupted rollback closes the import'
$journalPath=Join-Path ([IO.Path]::GetTempPath()) ('domenia-'+[guid]::NewGuid().ToString('N')+'.sqlite.query-imports.jsonl')
$exportPath=Join-Path ([IO.Path]::GetTempPath()) ('domenia-pack-'+[guid]::NewGuid().ToString('N')+'.json')
try{
    for($i=0;$i -lt 41;$i++){$Payload=[pscustomobject]@{ModuleRoot=$modules;Mode='JournalAppend';Path=$journalPath;Entry=(New-DomeniaQueryImportJournalEntry -Context $context -Applied $applied -Plan $verifiedPlan -NowUtc $now)};$appended=& ([scriptblock]::Create((Get-DomeniaQueryTransferWorkerCode)))}
    Expect ($appended.Journaled -and @([IO.File]::ReadAllLines($journalPath)|Where-Object{$_}).Count -eq 40) 'the journal keeps its most recent lines within the explicit bound'
    $Payload=[pscustomobject]@{ModuleRoot=$modules;Mode='JournalRead';Path=$journalPath;StoreId=$context.StoreId}
    $journalRead=& ([scriptblock]::Create((Get-DomeniaQueryTransferWorkerCode)))
    Expect (@($journalRead.Entries).Count -eq 20 -and $journalRead.Entries[0].Restorable) 'reading returns the twenty most recent restorable imports'
    # 40 lines of at most 3 Mio stay under any read bound; an oversized line never makes the journal unusable.
    $Payload=[pscustomobject]@{ModuleRoot=$modules;Mode='JournalAppend';Path=$journalPath;Entry=[pscustomobject]@{Kind='Import';Filler=('x'*3145728)}}
    $refused=& ([scriptblock]::Create((Get-DomeniaQueryTransferWorkerCode)))
    Expect (-not $refused.Journaled -and [string]$refused.Reason -like '*3 Mio*' -and @([IO.File]::ReadAllLines($journalPath)|Where-Object{$_}).Count -eq 40) 'an import line above 3 Mio is refused before any write'
    [IO.File]::AppendAllText($journalPath,(('y'*3145729)+"`n"),[Text.UTF8Encoding]::new($false))
    $Payload=[pscustomobject]@{ModuleRoot=$modules;Mode='JournalRead';Path=$journalPath;StoreId=$context.StoreId}
    $oversizedRead=& ([scriptblock]::Create((Get-DomeniaQueryTransferWorkerCode)))
    Expect (@($oversizedRead.Entries).Count -eq 20 -and [int]$oversizedRead.Rejected -eq 1) 'an oversized line is counted and skipped when reading'
    $Payload=[pscustomobject]@{ModuleRoot=$modules;Mode='JournalAppend';Path=$journalPath;Entry=(New-DomeniaQueryImportJournalEntry -Context $context -Applied $applied -Plan $verifiedPlan -NowUtc $now)}
    $recovered=& ([scriptblock]::Create((Get-DomeniaQueryTransferWorkerCode)))
    $kept=@([IO.File]::ReadAllLines($journalPath)|Where-Object{$_})
    Expect ($recovered.Journaled -and $kept.Count -eq 40 -and @($kept|Where-Object{$_.Length -gt 3145728}).Count -eq 0) 'the next import compacts an oversized line away'
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
$deliveredModel=@(Get-DomeniaQueryTemplates)[0]
Expect ((Get-DomeniaQueryDefinitionBinding -Recipe $bindingRecipe -Row $archivedBinding).State -ceq 'Archived' -and (Get-DomeniaQueryDefinitionBinding -Recipe $bindingRecipe).State -ceq 'Unsaved' -and (Get-DomeniaQueryDefinitionBinding -Recipe (Copy-DomeniaQueryRecipe $deliveredModel) -Template $deliveredModel).State -ceq 'Template') 'archived, unsaved and delivered definitions are distinguished'
$editedModel=Copy-DomeniaQueryRecipe $deliveredModel;$editedModel.Clauses=@(@($editedModel.Clauses)+@([pscustomobject]@{Field='ramGB';Operator='Less';Value=[decimal]4}))
$editedBinding=Get-DomeniaQueryDefinitionBinding -Recipe $editedModel -Template $deliveredModel
Expect ($editedBinding.State -ceq 'Modified' -and $editedBinding.Label -like 'brouillon modifié depuis le modèle livré (*') 'an edited delivered model is never presented as the delivered model'
Expect ((Get-DomeniaQueryDefinitionBinding -Recipe $deliveredModel).State -ceq 'Unknown') 'a delivered model is not certified without the model as delivered'
# The workshop and Search compare with the models prepared by the worker and wait for a confirmed library read.
$script:DomeniaQueryTemplateRows=@([pscustomobject]@{SourceId='Template';Recipe=$deliveredModel})
Expect ((Get-DomeniaQueryRecipeBinding $editedModel).State -ceq 'Modified' -and (Get-DomeniaQueryRecipeBinding (Copy-DomeniaQueryRecipe $deliveredModel)).State -ceq 'Template') 'the binding uses the prepared delivered model'
$script:DomeniaQueryTemplateRows=$null
Expect ((Get-DomeniaQueryRecipeBinding $editedModel).State -ceq 'Unknown') 'without prepared models the delivered state stays undetermined'
$script:DomeniaQueryLibraryStoreState=$null
Expect ((Get-DomeniaQueryRecipeBinding $bindingRecipe).State -ceq 'Unknown') 'without a library store a saved recipe is never called an unsaved draft'
$script:DomeniaQueryLibraryStoreState=[pscustomobject]@{Loaded=$false;Rows=@{}}
Expect ((Get-DomeniaQueryRecipeBinding $bindingRecipe).State -ceq 'Unknown') 'while the library is read a saved recipe is never called an unsaved draft'
$script:DomeniaQueryLibraryStoreState=[pscustomobject]@{Loaded=$true;Rows=@{'personal.binding'=$bindingRow}}
Expect ((Get-DomeniaQueryRecipeBinding (ConvertFrom-Json -InputObject $bindingRow.DefinitionJson)).State -ceq 'Saved' -and (Get-DomeniaQueryRecipeBinding (New-DomeniaQueryRecipe -Id 'personal.unsaved' -Name 'Nouvelle')).State -ceq 'Unsaved') 'a confirmed library read distinguishes saved and unsaved recipes'
$script:DomeniaQueryLibraryStoreState=$null
$paramStored=Copy-DomeniaQueryRecipe (@(Get-DomeniaQueryTemplates|Where-Object{$_.Id -ceq 'template.param.diskfree'})[0]) -Id 'personal.param';$paramStored.ParameterValues=[pscustomobject]@{Seuil=15}
$paramRow=New-DomeniaQueryLibraryRecord -Context $context -Recipe $paramStored -ExpectedRevision 0
$paramDraft=Copy-DomeniaQueryRecipe $paramStored;$paramDraft.ParameterValues=@{Seuil=[decimal]15}
Expect ((Get-DomeniaQueryDefinitionBinding -Recipe $paramDraft -Row $paramRow).State -ceq 'Saved') 'equal parameter values held in another container do not fake a modification'
$workshopDraft=Copy-DomeniaQueryRecipe $bindingRecipe;$workshopDraft.ParameterValues=@{}
Expect ((Get-DomeniaQueryDefinitionBinding -Recipe $workshopDraft -Row $bindingRow).State -ceq 'Saved') 'the empty parameter values of a workshop draft do not fake a modification'
# The comparison covers the whole definition: probe segment value, GUID set, parameter bounds and any other element.
$segmentA=New-DomeniaQueryRecipe -Id 'personal.segment' -Name 'Antivirus' -ProbeSelection ([pscustomobject]@{Key='sec.av';Mode='Equal';Value='A'})
$segmentRow=New-DomeniaQueryLibraryRecord -Context $context -Recipe $segmentA -ExpectedRevision 1
$segmentB=Copy-DomeniaQueryRecipe $segmentA;$segmentB.ProbeSelection.Value='B'
$segmentChanges=@(Compare-DomeniaQueryRecipeDefinitions -Before $segmentA -After $segmentB)
Expect ($segmentChanges.Count -eq 1 -and $segmentChanges[0].Element -ceq 'Segment de sonde' -and $segmentChanges[0].Before -cne $segmentChanges[0].After) 'a probe segment that differs only by its value is listed'
Expect ((Get-DomeniaQueryDefinitionBinding -Recipe $segmentB -Row $segmentRow).State -ceq 'Modified') 'a draft whose segment value changed is not the stored revision'
$segmentPack=New-DomeniaQueryPack -Context $context -Recipes @($segmentB) -PackName 'Segments' -PackVersion 1
$segmentItem=(New-DomeniaQueryPackImportPlan -Context $context -Json (ConvertTo-Json -InputObject $segmentPack -Depth 32) -ExistingRows @($segmentRow)).Items[0]
Expect ($segmentItem.Status -ceq 'Conflit' -and $segmentItem.ChangeSummary -ceq '1 différence(s) : Segment de sonde') 'a pack conflict shows the segment value it would replace'
$frozenA=New-DomeniaQueryRecipe -Id 'personal.frozen' -Name 'Sélection' -ObjectIds @('aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002')
$frozenRow=New-DomeniaQueryLibraryRecord -Context $context -Recipe $frozenA -ExpectedRevision 0
$frozenB=Copy-DomeniaQueryRecipe $frozenA;$frozenB.ObjectIds=@('aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000003')
$frozenChanges=@(Compare-DomeniaQueryRecipeDefinitions -Before $frozenA -After $frozenB)
Expect ($frozenChanges.Count -eq 1 -and $frozenChanges[0].Element -ceq 'Sélection figée' -and $frozenChanges[0].Before -like '2 GUID · empreinte *' -and $frozenChanges[0].After -like '2 GUID · empreinte *' -and $frozenChanges[0].Before -cne $frozenChanges[0].After) 'another frozen selection of the same size is a listed difference'
Expect ((Get-DomeniaQueryDefinitionBinding -Recipe $frozenB -Row $frozenRow).State -ceq 'Modified') 'a draft bound to other workstations is not the stored revision'
$frozenSame=Copy-DomeniaQueryRecipe $frozenA;$frozenSame.ObjectIds=@('AAAAAAAA-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001')
Expect ((Get-DomeniaQueryDefinitionBinding -Recipe $frozenSame -Row $frozenRow).State -ceq 'Saved') 'GUID order or case never fakes a modification'
$boundA=Copy-DomeniaQueryRecipe (@(Get-DomeniaQueryTemplates|Where-Object{$_.Id -ceq 'template.param.diskfree'})[0]) -Id 'personal.bounds'
$boundB=Copy-DomeniaQueryRecipe $boundA;$boundB.Parameters[0]|Add-Member -NotePropertyName Maximum -NotePropertyValue 90 -Force
$boundChanges=@(Compare-DomeniaQueryRecipeDefinitions -Before $boundA -After $boundB)
Expect (@($boundChanges|Where-Object{($_.Element -ceq 'Paramètre ajouté') -and ($_.After -like '*90 %*')}).Count -eq 1) 'a parameter whose bound changed is listed'
$netA=Copy-DomeniaQueryRecipe $boundA;$netA.ParameterValues=[pscustomobject]@{Seuil=15}
$netB=Copy-DomeniaQueryRecipe $netA;$netB.Parameters[0]|Add-Member -NotePropertyName Default -NotePropertyValue 20 -Force
$netChanges=@(Compare-DomeniaQueryRecipeDefinitions -Before $netA -After $netB)
Expect ($netChanges.Count -eq 1 -and $netChanges[0].Element -ceq 'Autre élément de la définition' -and $netChanges[0].Before -cne $netChanges[0].After) 'a difference no readable row describes is still reported'
Expect (@(Compare-DomeniaQueryRecipeDefinitions -Before $netA -After (Copy-DomeniaQueryRecipe $netA)).Count -eq 0) 'an identical definition reports no difference'
# An exported script keeps every single-quote character, typographic ones included, inside its data literal.
$quoteName='Postes d'+[char]0x2019+'accueil '+[char]0x2018+'A'+[char]0x201A+[char]0x201B+''''
$quoted=New-DomeniaQueryRecipe -Id 'personal.quotes' -Name $quoteName -Clauses @([pscustomobject]@{Field='name';Operator='Equal';Value=('PC'+[char]0x2019+'; Remove-Item fixture')})
$exportedScript=ConvertTo-DomeniaQueryPowerShell -Recipe $quoted
$scriptTokens=$null;$scriptErrors=$null;$scriptAst=[Management.Automation.Language.Parser]::ParseInput($exportedScript,[ref]$scriptTokens,[ref]$scriptErrors)
$dataLiterals=@($scriptAst.FindAll({param($node)($node -is [Management.Automation.Language.StringConstantExpressionAst]) -and ($node.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuoted) -and ($node.Value.StartsWith('{'))},$true))
$injected=@($scriptAst.FindAll({param($node)($node -is [Management.Automation.Language.CommandAst]) -and ([string]$node.GetCommandName() -ceq 'Remove-Item')},$true))
Expect (@($scriptErrors).Count -eq 0 -and $dataLiterals.Count -eq 1 -and $injected.Count -eq 0) 'typographic quotes never end the data literal of an exported script'
$roundTrip=ConvertFrom-Json -InputObject $dataLiterals[0].Value
Expect ($roundTrip.Name -ceq $quoteName -and [string]$roundTrip.Clauses[0].Value -ceq ('PC'+[char]0x2019+'; Remove-Item fixture')) 'the exported definition keeps its exact text'
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
# Point 69: a run left by a new session or another database no longer blocks import and rollback, and its
# confirmed writes are still journaled beside their own database (inert controls, no worker started).
foreach($name in @('QueryLibrary.Store.UI','QueryTransfer.UI')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$script:SessionEpoch=4L;$script:DatabaseScopedPath=$context.Path;$script:Conn=[pscustomobject]@{BaseDn=$context.DomainDn}
$storeContext=[pscustomobject]@{Version=1;StoreId=$context.StoreId;DomainDn=$context.DomainDn;Path=$context.Path;SessionEpoch=3L}
$script:DomeniaQueryLibraryStoreState=[pscustomobject]@{Context=$storeContext;Generation=2L;Loaded=$true;Saving=$false;Rows=@{};Categories=@{}}
$staleRun=[pscustomobject]@{StoreId=$context.StoreId;Epoch=3L;Generation=2L;Context=$storeContext;JournalPath=($context.Path+'.query-imports.jsonl');Items=@($applied[0]);Index=1;Applied=[Collections.Generic.List[object]]::new();Running=$true;Rollback=$false;Error='';Plan=$verifiedPlan;SourceImportId=''}
$staleRun.Applied.Add($applied[0])
$script:DomeniaQueryState=[pscustomobject]@{ImportRun=$staleRun;ImportHistory=@()}
$script:TransferTasks=[Collections.Generic.List[object]]::new()
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,$TimeoutSeconds,$TaskClass);$script:TransferTasks.Add([pscustomobject]@{OperationId=$OperationId;Payload=$Payload;State=$CallbackState});return ('transfer-'+$script:TransferTasks.Count)}
Expect (-not (Test-DomeniaQueryImportRunActive $staleRun)) 'a run of a former session is no longer active'
$freshRun=[pscustomobject]@{StoreId=$context.StoreId;Epoch=4L;Generation=2L;Running=$true}
Expect (Test-DomeniaQueryImportRunActive $freshRun) 'a run of the current store still blocks a second import'
Close-DomeniaQueryStaleImportRun
$journalTask=@($script:TransferTasks)
Expect (-not $staleRun.Running -and $journalTask.Count -eq 1 -and $journalTask[0].OperationId -ceq 'QueryTransfer' -and [string]$journalTask[0].Payload.Mode -ceq 'JournalAppend' -and [string]$journalTask[0].Payload.Path -ceq $staleRun.JournalPath -and @($journalTask[0].Payload.Entry.Items).Count -eq 1 -and @($script:DomeniaQueryState.ImportHistory).Count -eq 1) 'the confirmed writes of a stale run stay restorable and are journaled beside their database'
Close-DomeniaQueryStaleImportRun
Expect ($script:TransferTasks.Count -eq 1) 'a stale run is journaled once'
# The workshop collection of the missing information goes through the survey planner of the widgets: the survey
# receives the reuse age of the plan and reads the console user only when the recipe uses it (inert controls).
$script:SurveyCalls=[Collections.Generic.List[object]]::new()
function Start-DomeniaOnlinePark {param([switch]$PingOnly,[switch]$WmiOnly,[switch]$Inventory,[switch]$NoConsole,[object[]]$ScopeTargets=$null,[string]$ScopeLabel='',[object[]]$Probes=$null,[int]$ReuseMaxAgeDays=0,[switch]$PassThru);$script:SurveyCalls.Add([pscustomobject]@{Targets=@($ScopeTargets);PingOnly=[bool]$PingOnly;WmiOnly=[bool]$WmiOnly;Inventory=[bool]$Inventory;NoConsole=[bool]$NoConsole;Probes=@($Probes);Reuse=$ReuseMaxAgeDays});return 'park-fixture'}
function Get-DomeniaEffectiveWorkerResult {param($Result,[string[]]$RequiredProperties=@());foreach($name in $RequiredProperties){if($null -eq $Result.PSObject.Properties[$name]){return $null}};return $Result}
function Get-DomeniaFleetScope {return [pscustomobject]@{Key='scope-fixture';Name='Postes'}}
function Get-DomeniaSetting {param([string]$Name,$Default=$null);return $Default}
$script:FleetQuerySnapshotKey='snapshot-fixture'
foreach($routed in @(@($reusePlan,30,$true),@($forced,0,$false))){
    $script:DomeniaQueryState=[pscustomobject]@{Generation=7L;Busy=$true;Job='job';Records=$null;At=[datetime]::UtcNow;SnapshotKey=''}
    $routeState=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Generation=7L;SnapshotKey='snapshot-fixture';ScopeKey='scope-fixture';RecordsAt=[datetime]::UtcNow;PlanCollection=$true}
    $script:SurveyCalls.Clear()
    Complete-DomeniaQueryEvaluation -Result ([pscustomobject]@{Records=@();CollectionPlan=$routed[0]}) -State $routeState
    $survey=@($script:SurveyCalls)
    Expect ($survey.Count -eq 1 -and $survey[0].Reuse -eq [int]$routed[1] -and $survey[0].NoConsole -and $survey[0].WmiOnly -and $survey[0].Inventory -and @($survey[0].Probes).Count -eq 1 -and @($survey[0].Targets).Count -eq @($routed[0].Targets).Count) ('the workshop survey is started with the reuse age '+[string]$routed[1]+' and without the console user')
    Expect (($script:LastLabel -like '*met de côté ceux qui sont déjà à jour*') -eq [bool]$routed[2]) 'the workshop status names the check of the stored measurements only when the survey makes it'
}
$report=[pscustomobject]@{Status='PASS';Assertions=$checks;CoveragePopulation=20000;SourceMode=[bool]$QuerySource;ElapsedSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,3);PowerShell=$PSVersionTable.PSVersion.ToString();Scope='Actual models, worker factories, XML-independent UI pagination with inert controls; no network, AD, WMI or WPF'}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Compress
