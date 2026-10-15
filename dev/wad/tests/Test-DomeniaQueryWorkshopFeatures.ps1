#requires -Version 5.1
[CmdletBinding()]
param([switch]$QuerySource,[string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
if($QuerySource){Add-Type -Path (Join-Path (Split-Path -Parent $wad) 'vendor/m4d-admin-common/src/Query/QueryEngine.cs')}else{Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')}
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','Probes.Model','Query.Model','QueryLibrary.Model','Query.Worker','Query.UI')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$script:checks=0;$clock=[Diagnostics.Stopwatch]::StartNew()
function Expect([bool]$Good,[string]$Name){$script:checks++;if(-not $Good){throw $Name}}
function Reject([scriptblock]$Action,[string]$Name){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Expect $failed $Name}
foreach($case in @(@('ramGB','8192 Mo',8),@('ramGB','1,5 To',1536),@('ramGB','8',8),@('uptimeDays','48 h',2),@('checkedDays','1440 min',1),@('diskFreePercent','10,5 %',10.5),@('probe:net.speed','1 Gbit/s',1000),@('probe:hw.cpumhz','2,5 GHz',2500))){Expect ((ConvertTo-DomeniaQueryNumber -Field $case[0] -Text $case[1]) -eq [decimal]$case[2]) ('Unit conversion '+$case[0]+'/'+$case[1])}
foreach($case in @(@('ramGB','8 h'),@('uptimeDays','8 Go'),@('diskFreePercent','NaN'),@('ramGB','1e999'),@('name','8 Go'))){Reject {ConvertTo-DomeniaQueryNumber -Field $case[0] -Text $case[1]} ('Unit rejection '+$case[0]+'/'+$case[1])}
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
$Payload=[pscustomobject]@{ModuleRoot=$modules;Saved=@(for($i=0;$i -lt 125;$i++){New-DomeniaQueryRecipe -Name ('Personal '+$i)})}
$actual=& ([scriptblock]::Create((Get-DomeniaQueryLibraryWorkerCode)))
Expect ($actual.Rows.Count -eq 643 -and @($actual.Rows|Where-Object SourceId -eq 'Saved').Count -eq 125) 'actual lazy worker prepares full518models (three for installed applications) plus125personal definitions'
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
# Actual UI pagination with inert controls, no WPF claim.
$script:Fake=@{};foreach($name in @('DgQueryLibrary','CmbQueryLibrarySource','CmbQueryLibraryCategory','TxtQueryLibrarySearch','BtnQueryLibraryPrevious','BtnQueryLibraryNext','BtnQueryLibraryUse')){$script:Fake[$name]=[pscustomobject]@{ItemsSource=@();SelectedItem=$null;SelectedIndex=-1;Text='';IsEnabled=$false}}
function Get-DomeniaControl([string]$Name){return $script:Fake[$Name]}
function Set-DomeniaControlText([string]$Name,[string]$Text){$script:LastLabel=$Text}
$script:DomeniaQueryState=[pscustomobject]@{LibraryReady=$true;LibraryOffset=0;LibraryRows=$actual.Rows}
Update-DomeniaQueryLibrary
Expect ($script:Fake.DgQueryLibrary.ItemsSource.Count -eq 100 -and $script:Fake.BtnQueryLibraryNext.IsEnabled -and -not $script:Fake.BtnQueryLibraryPrevious.IsEnabled) 'library first page is100 with explicit navigation'
$script:DomeniaQueryState.LibraryOffset=600;Update-DomeniaQueryLibrary -KeepPage
Expect ($script:Fake.DgQueryLibrary.ItemsSource.Count -eq 40 -and -not $script:Fake.BtnQueryLibraryNext.IsEnabled) 'library last page preserves remaining40recipes'
$script:Fake.TxtQueryLibrarySearch.Text='Personal 124';Update-DomeniaQueryLibrary
Expect ($script:Fake.DgQueryLibrary.ItemsSource.Count -eq 1 -and $script:DomeniaQueryState.LibraryOffset -eq 0) 'search applies to full library and resets pagination'
$report=[pscustomobject]@{Status='PASS';Assertions=$checks;CoveragePopulation=20000;SourceMode=[bool]$QuerySource;ElapsedSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,3);PowerShell=$PSVersionTable.PSVersion.ToString();Scope='Actual models, worker factories, XML-independent UI pagination with inert controls; no network, AD, WMI or WPF'}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Compress
