#requires -Version 5.1
# Pure portable tests: actual common DLL and adapters, no AD, WMI, WPF, network or VM.
[CmdletBinding()]
param([string]$ReportPath='',[switch]$QuerySource)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
if($QuerySource){Add-Type -Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'vendor/m4d-admin-common/src/Query/QueryEngine.cs')}else{Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')}
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model','Query.Worker')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$script:checks=0
function Expect {param([bool]$Good,[string]$Name);$script:checks++;if(-not $Good){throw $Name}}
$now=[datetime]::Parse('2026-10-12T14:00:00Z').ToUniversalTime()
$fleet=[pscustomobject]@{Groups=@([pscustomobject]@{gid='a';os='Windows 11';ver='26100';lb=0;cr='R';pw='R';lk='N';bk='U'},[pscustomobject]@{gid='d';os='Windows 10';ver='';lb=5;cr='';pw='';lk='';bk='U'});Machines=@(
    [pscustomobject]@{name='PC-1';object_guid='g1';distinguished_name='CN=PC-1,OU=A,DC=test';gid='a';st='A';logon='2026-10-10'},
    [pscustomobject]@{name='PC-2';object_guid='g2';distinguished_name='CN=PC-2,OU=A,DC=test';gid='a';st='A';logon='2026-10-10'},
    [pscustomobject]@{name='PC-3';object_guid='g3';distinguished_name='CN=PC-3,OU=B,DC=test';gid='d';st='D';logon=''}
)}
$observations=@{
    'cn=pc-1,ou=a,dc=test'=[pscustomobject]@{Guid='g1';CheckedUtc=$now.ToString('o');Inventory=[pscustomobject]@{CheckedUtc=$now.ToString('o');Model='Test';RamBytes=4GB;DiskSize=100GB;DiskFree=0;LastBootUtc=$now.AddDays(-31).ToString('o')};Probes=[pscustomobject]@{
        'hw.ram'=[pscustomobject]@{Count=1;Rows=@(,@('4294967296'));Error='';CheckedUtc=$now.AddDays(-40).ToString('o')}
        'hw.cpuload'=[pscustomobject]@{Count=1;Rows=@(,@('90'));Error='';CheckedUtc=$now.ToString('o')}
    }}
    'cn=pc-2,ou=a,dc=test'=[pscustomobject]@{Guid='recreated-other';CheckedUtc=$now.ToString('o');Inventory=[pscustomobject]@{RamBytes=32GB}}
}
$records=ConvertTo-DomeniaQueryRecords -Fleet $fleet -Observations $observations -NowUtc $now
Expect ($records.Count -eq 3) 'includes disabled computers'
Expect ($records[0].Values['diskFreePercent'] -eq 0) 'zero free space is a known value'
Expect (-not $records[1].Values.ContainsKey('ramGB')) 'GUID prevents observation inheritance'
Expect (-not $records[0].Values.ContainsKey('probe:hw.ram')) 'fresh ping cannot freshen stale probe'
Expect ((Get-DomeniaQueryValuePresentation $records[0] 'probe:hw.ram').State -ceq 'Expiré') 'expired probe is distinct from an unread probe'
Expect ((Get-DomeniaQueryValuePresentation $records[0] 'probe:sec.defender').State -ceq 'Non lu') 'uncollected probe is explicitly unread'
Expect ($records[0].Values['probe:hw.cpuload'] -eq 90) 'fresh probe value'
Expect (-not $records[2].Values.ContainsKey('logonDays')) 'missing logon unknown'
Expect (-not $records[0].Values.ContainsKey('bitlocker')) 'unread BitLocker unknown'
$unknownState=[pscustomobject]@{Groups=@();Machines=@([pscustomobject]@{name='UNKNOWN';object_guid='unknown';distinguished_name='CN=UNKNOWN,DC=test';gid='';st='';logon=''})}
$unknownRecords=ConvertTo-DomeniaQueryRecords -Fleet $unknownState -NowUtc $now
Expect (-not $unknownRecords[0].Values.ContainsKey('active')) 'unread account state is neither active nor disabled'
Expect ((ConvertTo-DomeniaQueryGridRows $unknownRecords)[0].StateLabel -ceq 'Non lu') 'unread account state has an explicit grid label'
$withoutPing=@{'cn=pc-1,ou=a,dc=test'=[pscustomobject]@{Guid='g1';CheckedUtc=$now.AddDays(-40).ToString('o');Presence='En ligne';ObservedUtc=$now.ToString('o');LinkUser='fixture-user';Inventory=[pscustomobject]@{CheckedUtc=$now.ToString('o');Model='Fresh WMI';RamBytes=16GB}}}
$independent=ConvertTo-DomeniaQueryRecords -Fleet $fleet -Observations $withoutPing -NowUtc $now
Expect ($independent[0].Values['ramGB'] -eq 16 -and $independent[0].Values['user'] -ceq 'fixture-user' -and -not $independent[0].Values.ContainsKey('presence')) 'fresh WMI and console remain usable independently of stale ping'
$withoutPing['cn=pc-1,ou=a,dc=test'].Inventory=[pscustomobject]@{CheckedUtc=$now.ToString('o')}
$independent=ConvertTo-DomeniaQueryRecords -Fleet $fleet -Observations $withoutPing -NowUtc $now
Expect (-not $independent[0].Values.ContainsKey('model') -and -not $independent[0].Values.ContainsKey('observedRelease')) 'missing inventory values are not manufactured display strings in query data'
$withoutPing['cn=pc-1,ou=a,dc=test']|Add-Member NoteProperty Probes ([pscustomobject]@{'soft.printers'=[pscustomobject]@{Rows=@();CheckedUtc=$now.ToString('o');Error=''};'hw.cpu'=[pscustomobject]@{Rows=@(,@('partial'));CheckedUtc=$now.ToString('o');Error='';Truncated=$true};'sec.defender'=[pscustomobject]@{Rows=@();CheckedUtc=$now.ToString('o');Error='fixture denied'}})
$incomplete=ConvertTo-DomeniaQueryRecords -Fleet $fleet -Observations $withoutPing -NowUtc $now
Expect (-not $incomplete[0].Values.ContainsKey('probe:soft.printers')) 'missing Count does not fabricate measured zero'
Expect ((Get-DomeniaQueryValuePresentation $incomplete[0] 'probe:hw.cpu').State -ceq 'Lecture incomplète') 'truncated first-instance read is not an available value'
Expect ((Get-DomeniaQueryValuePresentation $incomplete[0] 'probe:sec.defender').State -ceq 'Erreur de lecture') 'actual failed probe keeps its diagnostic state'
# UI conditionals may turn cached generic lists into Object[]. All cardinalities
# must cross the common DLL boundary as IEnumerable<QueryRecord>.
$unfiltered=New-DomeniaQueryRecipe
foreach($count in @(0,1,2)){
    [object[]]$untyped=@();for($i=0;$i -lt $count;$i++){$untyped+=@($records[$i])}
    $typedPopulation=Select-DomeniaQueryPopulation $untyped $unfiltered
    Expect ($typedPopulation -is [Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]] -and $typedPopulation.Count -eq $count) ('Object[] population stays typed at cardinality '+$count)
    $typedResult=(ConvertTo-DomeniaCompiledQuery $unfiltered).Execute($typedPopulation,$null)
    Expect ($typedResult.Total -eq $count -and $typedResult.Matched -eq $count) ('Object[] actual DLL Execute at cardinality '+$count)
    $typedWidget=Measure-DomeniaQueryWidget $untyped $unfiltered
    Expect ($typedWidget.Total -eq $count -and $typedWidget.Matched -eq $count) ('Object[] actual widget at cardinality '+$count)
}
$typedPopulation=Select-DomeniaQueryPopulation $records $unfiltered
Expect ([object]::ReferenceEquals($records,$typedPopulation)) 'already typed unrestricted population is not copied'
$typedPopulation=Select-DomeniaQueryPopulation $null $unfiltered
Expect ($typedPopulation -is [Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]] -and $typedPopulation.Count -eq 0) 'null population normalizes to typed empty list'
$templates=@(Get-DomeniaQueryTemplates)
foreach($template in $templates){[void](ConvertTo-DomeniaCompiledQuery $template);Expect $true ('template valid '+$template.Id)}
$disabled=ConvertTo-DomeniaCompiledQuery (@($templates|Where-Object{$_.Id -eq 'template.disabled'})[0])
$result=$disabled.Execute($records,$null)
Expect ($result.Total -eq 3 -and $result.Matched -eq 1 -and $result.Rows[0].Id -eq 'g3') 'disabled drilldown agrees with total'
$recipe=New-DomeniaQueryRecipe -Name 'RAM < 8' -Clauses @([pscustomobject]@{Field='ramGB';Operator='Less';Value=8})
$compiled=ConvertTo-DomeniaCompiledQuery $recipe;$result=$compiled.Execute($records,$null)
Expect ($result.Matched -eq 1 -and $result.Unknown -eq 2) 'coverage preserved'
$json=ConvertTo-DomeniaQueryLibraryJson @($recipe);$loaded=@(ConvertFrom-DomeniaQueryLibrary $json)
Expect ($loaded.Count -eq 1 -and $loaded[0].Id -eq $recipe.Id) 'library roundtrip'
$bad=$false;try{ConvertFrom-DomeniaQueryLibrary '{"Format":"wrong","Queries":[]}'|Out-Null}catch{$bad=$true};Expect $bad 'reject wrong format'
$bad=$false;try{ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Clauses @([pscustomobject]@{Field='name';Operator='Invoke';Value='Get-Process'}))|Out-Null}catch{$bad=$true};Expect $bad 'reject script-like operator'
Expect ($null -eq (ConvertTo-DomeniaProbeNumber 'NaN')) 'nonfinite probe number unknown'
$Payload=[pscustomobject]@{ModuleRoot=$modules;Records=$records;Recipe=$recipe;Saved=@($recipe);Offset=0;Selection='Unknown';TextFilter='';StateFilter='';MaxAgeDays=30}
$workerResult=& ([scriptblock]::Create((Get-DomeniaQueryWorkerCode)))
Expect ($workerResult.Matched -eq 1 -and $workerResult.Unknown -eq 2 -and @($workerResult.Rows).Count -eq 2) 'worker unknown page'
Expect ($workerResult.Widgets[$recipe.Id].Matched -eq 1) 'widget uses same query'
$Payload.TextFilter='PC-3';$Payload.Selection='Match';$Payload.Recipe=New-DomeniaQueryRecipe
$workerResult=& ([scriptblock]::Create((Get-DomeniaQueryWorkerCode)))
Expect ($workerResult.Total -eq 1 -and $workerResult.ScopeTotal -eq 3) 'quick filter covers snapshot without losing scope total'
$Payload.Records=$unknownRecords;$Payload.TextFilter='';$Payload.StateFilter='Désactivés'
$workerResult=& ([scriptblock]::Create((Get-DomeniaQueryWorkerCode)))
Expect ($workerResult.Total -eq 0 -and $workerResult.ScopeTotal -eq 1) 'actual worker never classifies unread account state as disabled'
$Payload.Records=$records;$Payload.StateFilter=''
$observations['cn=pc-1,ou=a,dc=test'].Inventory.CheckedUtc=$now.AddDays(-40).ToString('o')
$old=ConvertTo-DomeniaQueryRecords -Fleet $fleet -Observations $observations -NowUtc $now
Expect (-not $old[0].Values.ContainsKey('ramGB')) 'fresh ping cannot rejuvenate old inventory'
Expect ($old[2].Values['presenceBucket'] -eq 'Non verifie') 'missing presence has exact dashboard bucket'
$nullObs=ConvertTo-DomeniaQueryRecords -Fleet $fleet -Observations $null -NowUtc $now
Expect ($nullObs.Count -eq 3) 'null observations preserve complete fleet'
. (Join-Path $modules 'Domenia-Park.Model.ps1')
. (Join-Path $modules 'Domenia-Store.Model.ps1')
$probe=@(Add-DomeniaRemoteProbeDefinitionHash @(ConvertTo-DomeniaProbePayload @('hw.cpuload')))[0];$at=$now.ToString('o')
$previous=[pscustomobject]@{Guid='g1';Key='cn=pc-1';Inventory=[pscustomobject]@{CheckedUtc=$at};Probes=[pscustomobject]@{'hw.cpuload'=[pscustomobject]@{CheckedUtc=$at;Error='';Truncated=$false;DefinitionHash=$probe.DefinitionHash}}}
$plan=New-DomeniaCollectionPlan -Previous $previous -Guid g1 -Key 'cn=pc-1' -Probes @($probe,$probe) -Inventory $true -NowUtc $now
Expect ($plan.Reused -eq 2 -and -not $plan.Inventory -and $plan.Probes.Count -eq 0 -and $plan.Requested -eq 2) 'fresh collection deduplicated and reused'
$plan=New-DomeniaCollectionPlan -Previous $previous -Guid g1 -Key 'cn=pc-1' -Probes @($probe) -Inventory $true -NowUtc $now -CacheMinutes 0
Expect ($plan.Reused -eq 0 -and $plan.Inventory -and $plan.Probes.Count -eq 1) 'force collection'
$plan=New-DomeniaCollectionPlan -Previous $previous -Guid g2 -Key 'cn=pc-1' -Probes @($probe) -Inventory $true -NowUtc $now
Expect ($plan.Reused -eq 0) 'recreated AD object never inherits measurements'
$previous.Probes.'hw.cpuload'.CheckedUtc=$now.AddSeconds(-61).ToString('o')
$plan=New-DomeniaCollectionPlan -Previous $previous -Guid g1 -Key 'cn=pc-1' -Probes @($probe) -NowUtc $now
Expect ($plan.Probes.Count -eq 1) 'volatile measurement expires after one minute'
$previous.Probes.'hw.cpuload'.CheckedUtc=$now.AddMinutes(10).ToString('o')
$plan=New-DomeniaCollectionPlan -Previous $previous -Guid g1 -Key 'cn=pc-1' -Probes @($probe) -NowUtc $now
Expect ($plan.Probes.Count -eq 1) 'future timestamps cannot hide a new collection'
$visual=New-DomeniaQueryRecipe -Name 'Répartition active ou Windows 10' -Junction Any -Clauses @([pscustomobject]@{Field='active';Operator='Equal';Value=$true},[pscustomobject]@{Field='os';Operator='Contains';Value='Windows 10'}) -GroupBy active
$stats=Measure-DomeniaQueryWidget $records $visual
Expect ($stats.Matched -eq 3 -and @($stats.Items).Count -eq 2) 'query distribution covers all OR matches'
$segment=New-DomeniaQuerySegmentRecipe $visual (@($stats.Items|Where-Object{$_.Select.Value -eq $false})[0].Select)
$part=Select-DomeniaQueryPopulation $records $segment
Expect ($part.Count -eq 1 -and $part[0].Id -eq 'g3' -and $segment.Junction -eq 'Any') 'segment AND restriction preserves OR recipe semantics'
$roundtrip=@(ConvertFrom-DomeniaQueryLibrary (ConvertTo-DomeniaQueryLibraryJson @($segment)))
Expect ($roundtrip[0].GroupBy -eq 'active' -and @($roundtrip[0].Refinements).Count -eq 1) 'segment and visual saved together'
$many=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
for($n=0;$n -lt 16;$n++){$values=[Collections.Generic.Dictionary[string,object]]::new();$values['name']='P'+$n;$values['model']='Model '+$n;$many.Add([M4D.Admin.Common.Query.QueryRecord]::new([string]$n,$values))}
$values=[Collections.Generic.Dictionary[string,object]]::new();$values['name']='Missing';$many.Add([M4D.Admin.Common.Query.QueryRecord]::new('missing',$values))
$visual=New-DomeniaQueryRecipe -GroupBy model;$stats=Measure-DomeniaQueryWidget $many $visual
Expect (@($stats.Items).Count -eq 12) 'ten groups, remainder and unknown bucket'
$others=@($stats.Items|Where-Object{@($_.Select.Excluded).Count})[0]
$part=Select-DomeniaQueryPopulation $many (New-DomeniaQuerySegmentRecipe $visual $others.Select)
Expect ($part.Count -eq 6 -and $others.Value -eq 6) 'other categories drilldown exact and excludes unknown'
$missing=@($stats.Items|Where-Object{$_.Select.Missing})[0]
$part=Select-DomeniaQueryPopulation $many (New-DomeniaQuerySegmentRecipe $visual $missing.Select)
Expect ($part.Count -eq 1 -and $part[0].Id -eq 'missing') 'unknown category drilldown exact'
# Applying a query to Search keeps GUID membership, without retaining full records or a hidden one-minute expiry.
$selection=Get-DomeniaQueryMatchIds -Records $records -Recipe $recipe
Expect ($selection.Count -eq 1 -and $selection.ContainsKey('g1') -and $selection['g1'] -is [bool]) 'search selection stores matching identities only'
$selection=Get-DomeniaQueryMatchIds -Records $many -Recipe (New-DomeniaQuerySegmentRecipe $visual $others.Select)
Expect ($selection.Count -eq 6 -and -not $selection.ContainsKey('missing')) 'search selection respects segment and unknown values'
. (Join-Path $modules 'Domenia-Query.UI.ps1')
. (Join-Path $modules 'Domenia-QueryTargets.UI.ps1')
$script:DomeniaQueryState=[pscustomobject]@{SearchRecipe=$compiled;SearchRecords=@{g1=$true};SearchAt=$now.AddDays(-1);SearchSnapshotKey='original'}
$script:FleetQuerySnapshotKey='another-ou'
Expect (Test-DomeniaSearchQueryRow ([pscustomobject]@{Type='Machine';Guid='{G1}'})) 'dated search selection survives elapsed TTL and another dashboard OU'
Expect (-not (Test-DomeniaSearchQueryRow ([pscustomobject]@{Type='Machine';Guid='replacement';DN='CN=PC-1,OU=A,DC=test'}))) 'recreated object cannot inherit search selection'
Expect (-not (Test-DomeniaSearchQueryRow ([pscustomobject]@{Type='Utilisateur';Guid='g1'}))) 'query selection remains limited to workstations'
# A probe segment matches individual values, never a substring of a joined display cell.
$many=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
foreach($row in @(@('a',@('A','B')),@('b',@('AB')),@('c',@('B','C')))){
    $v=[Collections.Generic.Dictionary[string,object]]::new();$v['probe:sec.av']=$row[1] -join ' ; ';$v['_probe:sec.av']=[object[]]$row[1]
    $many.Add([M4D.Admin.Common.Query.QueryRecord]::new($row[0],$v))
}
$multi=New-DomeniaQueryRecipe -ProbeSelection ([pscustomobject]@{Key='sec.av';Mode='Equal';Value='B'})
Expect ((Select-DomeniaQueryPopulation $many $multi).Count -eq 2) 'multi-value exact segment'
Expect ((Get-DomeniaQueryMatchIds $many $multi).Count -eq 2) 'search shares multi-value segment'
$rest=New-DomeniaQueryRecipe -ProbeSelection ([pscustomobject]@{Key='sec.av';Mode='Other';Excluded=@('A','B')})
Expect ((Select-DomeniaQueryPopulation $many $rest).Count -eq 2) 'Other tests each distinct reading'
$roundtrip=@(ConvertFrom-DomeniaQueryLibrary (ConvertTo-DomeniaQueryLibraryJson @($multi)))[0]
Expect ((Select-DomeniaQueryPopulation $many $roundtrip).Count -eq 2) 'saved segment retains exact semantics'
$numeric=New-DomeniaQueryRecipe -ProbeSelection ([pscustomobject]@{Key='hw.cpuload';Mode='Range';Low=80;High=$null})
Expect ((Select-DomeniaQueryPopulation $records $numeric).Count -eq 1) 'numeric segment unbounded upper edge'
$exact=New-DomeniaQueryRecipe -ProbeSelection ([pscustomobject]@{Key='hw.cpuload';Mode='Equal';Value=90})
Expect ((Select-DomeniaQueryPopulation $records $exact).Count -eq 1) 'numeric segment exact value'
Expect (@(Get-DomeniaQueryProbeIds $multi) -contains 'sec.av') 'segment collection includes its probe'
# Exercise actual settings reload, not only query JSON serialization.
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
foreach($name in @('Get-DomeniaDefaultSettings','Load-DomeniaSettings')){
    $fn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))[0]
    . ([scriptblock]::Create($fn.Extent.Text))
}
. (Join-Path $modules 'Domenia-Experience.Model.ps1')
$script:storedSettings=[pscustomobject]@{'Query.Library'=(ConvertTo-DomeniaQueryLibraryJson @($multi));'Collection.Concurrency'='8';'Collection.CacheMinutes'='60';UiProfile='Tech';Theme='Light'}|ConvertTo-Json -Depth 8
function Read-DomeniaPreference {param($FileName);if($FileName -eq 'Domenia.settings.json'){return $script:storedSettings};return ''}
function Get-DomeniaStoredTheme {return 'Light'}
$reloaded=Load-DomeniaSettings
Expect ((@(ConvertFrom-DomeniaQueryLibrary $reloaded['Query.Library'])).Count -eq 1 -and $reloaded['Collection.Concurrency'] -eq 8 -and $reloaded['Collection.CacheMinutes'] -eq 60) 'settings reload retains saved queries and collection choices'
$script:storedSettings='{"Collection.Concurrency":"oops","Collection.CacheMinutes":-5}'
$reloaded=Load-DomeniaSettings
Expect ($reloaded['Collection.Concurrency'] -eq 4 -and $reloaded['Collection.CacheMinutes'] -eq 0) 'malformed collection settings safely default and clamp'
# Alert snapshots retain the complete selected identity set through filtering, saving and charts.
$selectedRecords=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
$selectedIds=[Collections.Generic.List[string]]::new()
for($n=1;$n -le 5000;$n++){
    $id=([guid]::NewGuid()).ToString('D');$v=[Collections.Generic.Dictionary[string,object]]::new();$v['name']='PC-'+$n;$v['model']='A'
    $selectedRecords.Add([M4D.Admin.Common.Query.QueryRecord]::new($id,$v));if($n -gt 250){$selectedIds.Add($id)}
}
$frozen=New-DomeniaQueryRecipe -Name 'Selection alerte' -ObjectIds $selectedIds.ToArray() -GroupBy model
$part=Select-DomeniaQueryPopulation $selectedRecords $frozen
Expect ($part.Count -eq 4750) 'alert detail keeps every selected PC beyond preview and first page'
Expect ((Get-DomeniaQueryMatchIds $selectedRecords $frozen).Count -eq 4750) 'search selection retains all alert identities'
$loaded=@(ConvertFrom-DomeniaQueryLibrary (ConvertTo-DomeniaQueryLibraryJson @($frozen)))[0]
Expect ((Select-DomeniaQueryPopulation $selectedRecords $loaded).Count -eq 4750) 'saved alert selection roundtrips without broadening'
$stats=Measure-DomeniaQueryWidget $selectedRecords $loaded
Expect ($stats.Total -eq 4750 -and $stats.Matched -eq 4750) 'widget count agrees with frozen alert detail'
$part=Select-DomeniaQueryPopulation $selectedRecords (New-DomeniaQuerySegmentRecipe $loaded $stats.Items[0].Select)
Expect ($part.Count -eq 4750) 'chart drilldown preserves alert identities'
Expect ((Select-DomeniaQueryPopulation $selectedRecords (New-DomeniaQueryRecipe -ObjectIds @())).Count -eq 0) 'empty frozen selection never expands to all'
$bad=$false;try{ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -ObjectIds @('bad-guid'))|Out-Null}catch{$bad=$true};Expect $bad 'malformed identity selection refused'
# The stale template follows the exact dashboard buckets and excludes missing dates and disabled PCs.
$stale=ConvertTo-DomeniaCompiledQuery (@(Get-DomeniaQueryTemplates|Where-Object{$_.Id -eq 'template.stale'})[0])
foreach($case in @(@(2,$true,$false),@(3,$true,$true),@(4,$true,$true),@(5,$true,$false),@(3,$false,$false))){
    $v=[Collections.Generic.Dictionary[string,object]]::new();$v['logonBucket']=[int]$case[0];$v['active']=[bool]$case[1]
    Expect (($stale.Evaluate($v) -eq [M4D.Admin.Common.Query.MatchState]::Match) -eq [bool]$case[2]) ('stale template bucket/state '+$case[0]+'/'+$case[1])
}
# A refused library save cannot silently reappear in a later settings write.
. (Join-Path $modules 'Domenia-Query.UI.ps1')
$script:Settings=[ordered]@{'Query.Library'='previous';Theme='Light'}
function Save-DomeniaSettings {param([switch]$Immediate,[switch]$ThrowOnFailure);throw 'storage unavailable'}
$refused=$false;try{Save-DomeniaQueryLibraryState 'new'}catch{$refused=$true}
Expect ($refused -and $script:Settings['Query.Library'] -ceq 'previous') 'failed library save rolls back in-memory value'
$script:Settings.Remove('Query.Library');try{Save-DomeniaQueryLibraryState 'new'}catch{}
Expect (-not $script:Settings.Contains('Query.Library')) 'failed first library save restores absent key'
function Save-DomeniaSettings {param([switch]$Immediate,[switch]$ThrowOnFailure);$script:storedLibrary=$script:Settings['Query.Library']}
Save-DomeniaQueryLibraryState 'accepted'
Expect ($script:Settings['Query.Library'] -ceq 'accepted' -and $script:storedLibrary -ceq 'accepted') 'accepted library save persists new value'
. (Join-Path $modules 'Domenia-Widgets.UI.ps1')
$entry=[pscustomobject]@{Items=@([pscustomobject]@{Label='range';Low=0;High=$null},[pscustomobject]@{Label='exact';ExactValue='A'},[pscustomobject]@{Label='other';Excluded=@('A','B')})}
Set-DomeniaBoardSegmentSelection $entry
Expect ($entry.Items[0].Select.Index -eq 0 -and $entry.Items[0].Select.Low -eq 0 -and $null -eq $entry.Items[0].Select.High) 'widget range selection preserves zero and open bound'
Expect ($entry.Items[1].Select.Index -eq 1 -and $entry.Items[1].Select.ExactValue -ceq 'A') 'widget exact selection metadata created with named arguments'
Expect ($entry.Items[2].Select.Excluded.Count -eq 2) 'widget Other selection preserves excluded categories'
Set-DomeniaBoardSegmentSelection $entry
Expect ($entry.Items[2].Select.Index -eq 2) 'widget rerender replaces existing selection metadata'
$unicodeLibrary='{"Format":"Domenia.QueryLibrary/1","Queries":[],"Padding":"'+([string][char]0x00e9)*8400000+'"}'
$refused=$false;try{ConvertFrom-DomeniaQueryLibrary $unicodeLibrary|Out-Null}catch{$refused=$_.Exception.Message -like '*16 Mio*'}
Expect ($unicodeLibrary.Length -lt 16777216 -and $refused) 'query library ceiling counts actual UTF8 bytes'
# Saved widgets must not reuse counts from another definition of the library.
function Get-DomeniaControl {param($Name);return $null}
function Show-DomeniaBoard {param($Board,[switch]$Quiet);$script:BoardRefreshed=$true}
$original=New-DomeniaQueryRecipe -Name 'Original'
$oldLibrary=ConvertTo-DomeniaQueryLibraryJson @($original)
$script:DomeniaQueryState=[pscustomobject]@{Saved=@($original);Recipe=$original;LibraryError='';Widgets=@{};WidgetLibrary=$oldLibrary;SnapshotKey='snapshot'}
$script:DomeniaQueryState.Widgets[$original.Id]=[pscustomobject]@{Matched=7;Unknown=0;NotMatched=0;Total=7;Error=''}
$script:FleetQuerySnapshotKey='snapshot'
Expect ((Get-DomeniaQueryBoardEntry $original.Id).Value -eq '7') 'widget first displays the calculated count'
$changed=New-DomeniaQueryRecipe -Id $original.Id -Name 'Changed' -Clauses @([pscustomobject]@{Field='active';Operator='Equal';Value=$false})
$script:BoardRefreshed=$false
[void](Save-DomeniaQueryRecipe $changed)
Expect ($script:DomeniaQueryState.Widgets.Count -eq 0 -and $script:DomeniaQueryState.WidgetLibrary -eq '' -and $script:BoardRefreshed) 'saved definition invalidates widget counts and repaints board'
Expect ((Get-DomeniaQueryBoardEntry $original.Id).Value -eq 'À calculer') 'changed widget cannot show old count under new title'
# A late worker carrying the previous library cannot bring those counts back.
$script:DomeniaQueryState=[pscustomobject]@{Saved=@($changed);Recipe=$changed;LibraryError='';Widgets=@{};WidgetLibrary='';SnapshotKey='snapshot';Generation=5;Busy=$true;Job='job';Result=$null;Records=$null;At=[datetime]::MinValue;ProbeWidgets=@{};ProbeLibrary='';Offset=0}
$script:SessionEpoch=7L
$script:TestControl=[pscustomobject]@{ItemsSource=@();IsEnabled=$false}
function Get-DomeniaControl {param($Name);return $script:TestControl}
function Get-DomeniaFleetScope {return [pscustomobject]@{Key='scope'}}
function Get-DomeniaBoardLayout {param($Board);return @([pscustomobject]@{Source='Query';Key=$original.Id})}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties);return $Result}
function Set-DomeniaControlText {param($Name,$Text)}
function Add-DomeniaUiLog {param($Area,$Text)}
$lateWidgets=@{};$lateWidgets[$original.Id]=[pscustomobject]@{Matched=7;Unknown=0;NotMatched=0;Total=7;Error=''}
$late=[pscustomobject]@{Rows=@();Records=@();Widgets=$lateWidgets;Matched=0;Unknown=0;NotMatched=0;Total=0;ScopeTotal=0;Offset=0;Selection='Match';ProbeWidgets=@{}}
$lateState=[pscustomobject]@{Epoch=7L;Generation=5;SnapshotKey='snapshot';ScopeKey='scope';RecordsAt=[datetime]::UtcNow;WidgetLibrary=$oldLibrary;ProbeLibrary='';RefreshWidgets=$true}
Complete-DomeniaQueryEvaluation $late $lateState
Expect ($script:DomeniaQueryState.Widgets.Count -eq 0 -and (Get-DomeniaQueryBoardEntry $original.Id).Value -eq 'À calculer') 'late callback from old library cannot restore obsolete widget'
# Result reset clears old counts, pages and details together after a changed draft.
$script:ResetControls=@{}
foreach($name in @('DgFleetMachines','DgQueryObjectFields','BtnQueryPrevious','BtnQueryNext','LblFleetMachineCount','LblQueryObject')){
    $script:ResetControls[$name]=[pscustomobject]@{ItemsSource=@('old result');Text='old count';IsEnabled=$true}
}
function Get-DomeniaControl {param($Name);return $script:ResetControls[$Name]}
function Set-DomeniaControlText {param($Name,$Text);if($script:ResetControls.ContainsKey($Name)){$script:ResetControls[$Name].Text=$Text}}
Reset-DomeniaQueryResults
Expect (@($script:ResetControls.DgFleetMachines.ItemsSource).Count -eq 0 -and @($script:ResetControls.DgQueryObjectFields.ItemsSource).Count -eq 0) 'query reset clears result and detail rows'
Expect (-not $script:ResetControls.BtnQueryPrevious.IsEnabled -and -not $script:ResetControls.BtnQueryNext.IsEnabled) 'query reset disables both page actions'
Expect ($script:ResetControls.LblFleetMachineCount.Text -like 'Aucun résultat calculé*' -and $script:ResetControls.LblQueryObject.Text -like 'Sélectionnez un poste*') 'query reset replaces stale counts and identity details'
# Exercise the real numeric Add action with lightweight control adapters.
function Initialize-DomeniaQueryWorkshop {}
function Get-DomeniaQueryDraft {return $script:NumericDraft}
function Set-DomeniaQueryDraft {param($Recipe);$script:NumericDraft=$Recipe}
function Set-Status {param($Text,$Level);$script:NumericError=$Text}
function Get-DomeniaControl {param($Name);return $script:NumericControls[$Name]}
$script:DomeniaQueryState=[pscustomobject]@{Timer=$null}
$script:NumericControls=@{
    CmbQueryField=[pscustomobject]@{SelectedItem=[pscustomobject]@{Id='ramGB';Kind='Number'}}
    CmbQueryOperator=[pscustomobject]@{SelectedItem=[pscustomobject]@{Id='Less'}}
    TxtQueryValue=[pscustomobject]@{Text='10,5'}
}
foreach($case in @(@('10,5',[decimal]10.5),@('0',[decimal]0),@('8.25',[decimal]8.25))){
    $script:NumericDraft=New-DomeniaQueryRecipe;$script:NumericError=''
    $script:NumericControls.TxtQueryValue.Text=$case[0]
    Invoke-DomeniaQueryAction 'Add'
    Expect ($script:NumericError -eq '' -and @($script:NumericDraft.Clauses).Count -eq 1 -and $script:NumericDraft.Clauses[0].Value -eq $case[1]) ('numeric Add action accepts '+$case[0])
}
$script:NumericDraft=New-DomeniaQueryRecipe;$script:NumericError='';$script:NumericControls.TxtQueryValue.Text='invalid'
Invoke-DomeniaQueryAction 'Add'
Expect ($script:NumericError -like '*Saisissez un nombre*' -and @($script:NumericDraft.Clauses).Count -eq 0) 'numeric Add action rejects invalid input without adding a clause'
Write-Output ('PASS Domenia Query adapters: '+$script:checks+' assertions; probes='+@(Get-DomeniaProbeCatalog).Count)
if($ReportPath){
 $hashes=@(foreach($file in @('Domenia-Query.Model.ps1','Domenia-Query.Worker.ps1','Domenia-Query.UI.ps1')){[pscustomobject]@{File=$file;Sha256=(Get-FileHash (Join-Path $modules $file) -Algorithm SHA256).Hash.ToLowerInvariant()}})
 [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),([pscustomobject]@{Status='PASS';Assertions=$script:checks;PowerShell=$PSVersionTable.PSVersion.ToString();Sources=$hashes;Scope='Actual DLL and query adapters/worker with local fixtures; no AD/WMI/network/WPF'}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
}
