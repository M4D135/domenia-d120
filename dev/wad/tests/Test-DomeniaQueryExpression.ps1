#requires -Version 5.1
# Nested conditions (points 62 and 66): visual tree editing, three-state semantics, French labels, per-condition
# explanation and parity between the workshop worker, dashboard widgets and Search selections. No network.
[CmdletBinding()]
param([switch]$QuerySource,[string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
if($QuerySource){Add-Type -Path (Join-Path (Split-Path -Parent $wad) 'vendor/m4d-admin-common/src/Query/QueryEngine.cs')}else{Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')}
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model','Query.Worker')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$script:checks=0;$clock=[Diagnostics.Stopwatch]::StartNew()
function Expect([bool]$Good,[string]$Name){$script:checks++;if(-not $Good){throw $Name}}
function Reject([scriptblock]$Action,[string]$Name){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Expect $failed $Name}
function New-Clause([string]$Field,[string]$Operator,$Value){return [pscustomobject]@{Kind='Clause';Clause=[pscustomobject]@{Field=$Field;Operator=$Operator;Value=$Value}}}
function New-Record([string]$Id,[hashtable]$Data){$d=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);foreach($k in $Data.Keys){$d[$k]=$Data[$k]};return [M4D.Admin.Common.Query.QueryRecord]::new($Id,$d)}
$match=[M4D.Admin.Common.Query.MatchState]::Match;$noMatch=[M4D.Admin.Common.Query.MatchState]::NoMatch;$unknown=[M4D.Admin.Common.Query.MatchState]::Unknown

# French labels: typed values keep their meaning (Oui/Non, unit, coded state, parameter), never raw engine ids.
$fields=Get-DomeniaQueryFieldMap
Expect ((Get-DomeniaQueryClauseLabel -Clause ([pscustomobject]@{Field='active';Operator='Equal';Value=$true}) -Fields $fields) -ceq 'Compte actif est égal à Oui') 'Boolean condition reads Oui'
Expect ((Get-DomeniaQueryClauseLabel -Clause ([pscustomobject]@{Field='ramGB';Operator='Less';Value=[decimal]8}) -Fields $fields) -ceq 'Mémoire relevée en Go est inférieur à 8 Go') 'Numeric condition keeps its unit'
Expect ((Get-DomeniaQueryClauseLabel -Clause ([pscustomobject]@{Field='diskFreePercent';Operator='Less';Value=[decimal]10.5}) -Fields $fields) -like '*10,5 %') 'French decimal separator and percent unit'
Expect ((Get-DomeniaQueryClauseLabel -Clause ([pscustomobject]@{Field='uptimeDays';Operator='Greater';Value=[decimal]2}) -Fields $fields) -like '* 2 j') 'Days are labelled'
Expect ((Get-DomeniaQueryClauseLabel -Clause ([pscustomobject]@{Field='laps';Operator='Equal';Value='E'}) -Fields $fields) -like '*est égal à Expiré') 'Coded state shows its French name'
Expect ((Get-DomeniaQueryClauseLabel -Clause ([pscustomobject]@{Field='name';Operator='StartsWith';Value='PC-'}) -Fields $fields) -ceq 'Nom du poste commence par « PC- »') 'Literal text is quoted'
Expect ((Get-DomeniaQueryClauseLabel -Clause ([pscustomobject]@{Field='logonDays';Operator='IsMissing';Value=$null}) -Fields $fields) -like '*est absent') 'Existence test has no synthetic value'
Expect ((Get-DomeniaQueryClauseLabel -Clause ([pscustomobject]@{Field='ramGB';Operator='Less';Value=[pscustomobject]@{Parameter='Seuil'}}) -Fields $fields) -like '*paramètre Seuil') 'Parameter reference is named'
Expect ((Format-DomeniaQueryValueLabel -Value 'Texte' -Bare) -ceq 'Texte') 'Observed text stays bare'

# Visual editor: add, nest, move, remove and clear, each result compiled before publication.
$recipe=New-DomeniaQueryRecipe -Name 'Arbre'
$recipe=Edit-DomeniaQueryExpression -Recipe $recipe -Path '' -Operation Add -Node ([pscustomobject]@{Kind='Any';Children=@()})
$recipe=Edit-DomeniaQueryExpression -Recipe $recipe -Path '/0' -Operation Add -Node (New-Clause 'ramGB' 'Less' ([decimal]8))
$recipe=Edit-DomeniaQueryExpression -Recipe $recipe -Path '/0' -Operation Add -Node (New-Clause 'diskFreePercent' 'Less' ([decimal]10))
$recipe=Edit-DomeniaQueryExpression -Recipe $recipe -Path '' -Operation Add -Node ([pscustomobject]@{Kind='Not';Children=@([pscustomobject]@{Kind='All';Children=@()})})
$recipe=Edit-DomeniaQueryExpression -Recipe $recipe -Path '/1' -Operation Add -Node (New-Clause 'active' 'Equal' $false)
$outline=@(Get-DomeniaQueryExpressionOutline -Node $recipe.Expression)
Expect ((@($outline|ForEach-Object{$_.Path}) -join ';') -ceq ';/0;/0/0;/0/1;/1;/1/0;/1/0/0') 'Tree paths follow the visual order'
Expect ($recipe.Format -ceq 'Domenia.Query/2' -and $outline[1].Label.Trim() -ceq 'Au moins une condition (OU)' -and $outline[4].Label.Trim() -like '*(NON)') 'Group labels are French'
Expect ($outline[2].Label -like '    Mémoire relevée en Go est inférieur à 8 Go') 'Outline indents and labels conditions'
$withClause=Edit-DomeniaQueryExpression -Recipe $recipe -Path '/0/0' -Operation Add -Node (New-Clause 'uptimeDays' 'Greater' ([decimal]30))
Expect (@($withClause.Expression.Children[0].Children).Count -eq 3) 'Adding while a condition is selected adds to its group'
$moved=Edit-DomeniaQueryExpression -Recipe $recipe -Path '/1' -Operation Up
Expect ([string]$moved.Expression.Children[0].Kind -ceq 'Not' -and [string]$moved.Expression.Children[1].Kind -ceq 'Any') 'Up swaps siblings'
$back=Edit-DomeniaQueryExpression -Recipe $moved -Path '/0' -Operation Down
Expect ([string]$back.Expression.Children[0].Kind -ceq 'Any') 'Down restores the order'
$removed=Edit-DomeniaQueryExpression -Recipe $recipe -Path '/0/1' -Operation Remove
Expect (@($removed.Expression.Children[0].Children).Count -eq 1 -and @($recipe.Expression.Children[0].Children).Count -eq 2) 'Remove edits a copy and leaves the source draft intact'
Reject {Edit-DomeniaQueryExpression -Recipe $recipe -Path '/1/0' -Operation Remove} 'NOT without its child is refused'
Reject {Edit-DomeniaQueryExpression -Recipe $recipe -Path '/9' -Operation Remove} 'A stale path is refused'
Expect ($null -eq (Edit-DomeniaQueryExpression -Recipe $recipe -Operation Clear).Expression) 'Clear removes every group'

# Explicit budgets: depth 8 and 64 condition leaves.
$deep=New-Clause 'active' 'Equal' $true;for($i=0;$i -lt 10;$i++){$deep=[pscustomobject]@{Kind='All';Children=@($deep)}}
Reject {ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Expression $deep)} 'More than eight levels are refused'
$wide=[pscustomobject]@{Kind='Any';Children=@(for($i=0;$i -lt 65;$i++){New-Clause 'ramGB' 'Less' ([decimal]$i)})}
Reject {ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Expression $wide)} 'More than 64 conditions are refused'

# Three-state logic: NOT keeps Unknown, AND/OR follow strong Kleene logic.
$not=ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Expression ([pscustomobject]@{Kind='Not';Children=@((New-Clause 'ramGB' 'Less' ([decimal]8)))}))
Expect ($not.Evaluate((New-Record 'a' @{}).Values) -eq $unknown) 'NOT of an unknown value stays unknown'
Expect ($not.Evaluate((New-Record 'a' @{'ramGB'=4}).Values) -eq $noMatch -and $not.Evaluate((New-Record 'a' @{'ramGB'=16}).Values) -eq $match) 'NOT inverts known verdicts'
$any=ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Expression ([pscustomobject]@{Kind='Any';Children=@((New-Clause 'ramGB' 'Less' ([decimal]8)),(New-Clause 'active' 'Equal' $true))}))
$all=ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Expression ([pscustomobject]@{Kind='All';Children=@((New-Clause 'ramGB' 'Less' ([decimal]8)),(New-Clause 'active' 'Equal' $true))}))
Expect ($any.Evaluate((New-Record 'a' @{'active'=$true}).Values) -eq $match -and $all.Evaluate((New-Record 'a' @{'active'=$false}).Values) -eq $noMatch -and $all.Evaluate((New-Record 'a' @{'active'=$true}).Values) -eq $unknown) 'Unknown OR true is true, unknown AND false is false, unknown AND true is unknown'

# Parity: the same nested definition selects the same identities in the workshop worker, a dashboard widget
# and the Search selection built by Appliquer aux résultats de Recherche.
$records=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
$index=0
foreach($active in @($true,$false,$null)){foreach($ram in @(4,16,$null)){foreach($disk in @(5,50,$null)){
    $index++;$data=@{'name'=('PC-'+$index);'dn'=('CN=PC-'+$index+',OU=Fixture,DC=example,DC=test')}
    if($null -ne $active){$data['active']=$active};if($null -ne $ram){$data['ramGB']=$ram};if($null -ne $disk){$data['diskFreePercent']=$disk}
    $records.Add((New-Record (([guid]::new($index,0,0,[byte[]](0,0,0,0,0,0,0,0))).ToString('D')) $data))
}}}
$tree=[pscustomobject]@{Kind='Any';Children=@(
    [pscustomobject]@{Kind='All';Children=@((New-Clause 'active' 'Equal' $true),(New-Clause 'ramGB' 'Less' ([decimal]8)))},
    [pscustomobject]@{Kind='Not';Children=@([pscustomobject]@{Kind='All';Children=@((New-Clause 'diskFreePercent' 'GreaterOrEqual' ([decimal]20)))})}
)}
$nested=New-DomeniaQueryRecipe -Name 'Parité' -Clauses @([pscustomobject]@{Field='name';Operator='StartsWith';Value='PC-'}) -Expression $tree
$widget=Measure-DomeniaQueryWidget -Records $records -Recipe $nested
$ids=Get-DomeniaQueryMatchIds -Records $records -Recipe $nested
$Payload=[pscustomobject]@{ModuleRoot=$modules;Records=$records;Recipe=$nested;Saved=@();CachedWidgets=@{};CachedProbeWidgets=@{};SortField='name';Descending=$false;Offset=0;Selection='Match';MaxAgeDays=30;TextFilter='';StateFilter=''}
$worker=& ([scriptblock]::Create((Get-DomeniaQueryWorkerCode)))
$workerIds=@($worker.Rows|ForEach-Object{([string]$_.Id).ToLowerInvariant()}|Sort-Object)
Expect ($widget.Total -eq 27 -and ($widget.Matched+$widget.Unknown+$widget.NotMatched) -eq 27) 'Widget partitions every record exactly once'
Expect ($widget.Matched -eq $ids.Count -and $worker.Matched -eq $widget.Matched -and $worker.Unknown -eq $widget.Unknown) 'Workshop worker, widget and Search selection count the same matches'
Expect ((($workerIds) -join ',') -ceq ((@($ids.Keys|Sort-Object)) -join ',')) 'Workshop worker and Search selection keep the same identities'
$expected=0;foreach($record in $records){$v=$record.Values;$left=($v.ContainsKey('active') -and [bool]$v['active'] -and $v.ContainsKey('ramGB') -and [double]$v['ramGB'] -lt 8);$right=($v.ContainsKey('diskFreePercent') -and [double]$v['diskFreePercent'] -lt 20);if($left -or $right){$expected++}}
Expect ($widget.Matched -eq $expected) 'Matches equal an independent hand computation of the known verdicts'

# Explanation: every node of the tree gets its own verdict and observed value for the selected workstation.
$target=@($records|Where-Object{$_.Values['name'] -ceq 'PC-2'})[0]
$rows=@(Get-DomeniaQueryExplanation -Record $target -Recipe $nested)
Expect ($rows.Count -eq 8) 'One legacy condition plus the seven tree nodes are explained'
Expect ($rows[0].Condition -ceq '1. Nom du poste commence par « PC- »' -and $rows[0].Verdict -ceq 'Vrai') 'Legacy condition keeps its French label and verdict'
$ramRow=@($rows|Where-Object{$_.Condition -like '*Mémoire relevée en Go est inférieur à 8 Go'})[0]
Expect ($ramRow.Value -ceq '4 Go' -and $ramRow.Verdict -ceq 'Vrai') 'Observed value is shown with its unit'
$notRow=@($rows|Where-Object{$_.Condition -like '*(NON)'})[0]
Expect ($notRow.Verdict -ceq 'Faux' -and $notRow.Value -ceq 'Verdicts des sous-conditions') 'NOT group verdict is explained from its children'
$unknownTarget=@($records|Where-Object{$_.Values['name'] -ceq 'PC-27'})[0]
$unknownRows=@(Get-DomeniaQueryExplanation -Record $unknownTarget -Recipe $nested)
Expect (@($unknownRows|Where-Object{$_.Condition -like '*Espace libre*'})[0].Verdict -ceq 'Inconnu' -and @($unknownRows|Where-Object{$_.Condition -like '*Espace libre*'})[0].State -ceq 'Non lu') 'Unread value stays unknown with its reason'

# Collection node explained from the projection provenance kept by the workshop (no raw instances in memory).
$collectionRecipe=New-DomeniaQueryRecipe -Name 'Service' -Expression ([pscustomobject]@{Kind='All';Children=@([pscustomobject]@{Kind='Collection';CollectionField='probe:soft.servicedetails';Quantifier='Any';Children=@([pscustomobject]@{Kind='All';Children=@((New-Clause 'instance:soft.servicedetails:Name' 'Equal' 'Spooler'))})})})
$node=@(Get-DomeniaQueryCollectionNodes $collectionRecipe)[0]
$collectionRecords=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new();$collectionRecords.Add((New-Record 'aaaaaaaa-0000-0000-0000-00000000000a' @{'name'='SERVICE';'active'=$true}))
$projection=[pscustomobject]@{Guid='aaaaaaaa-0000-0000-0000-00000000000a';ProjectionKey=$node.ProjectionKey;ProbeId='soft.servicedetails';Verdict=[int]$match;CheckedUtc='2026-10-15T08:00:00.0000000Z';Coverage='Disponible';InstanceCount=3}
$projected=(Add-DomeniaQueryCollectionProjectionRecords -Records $collectionRecords -Projections @($projection))[0]
$collectionRows=@(Get-DomeniaQueryExplanation -Record $projected -Recipe $collectionRecipe)
Expect ($collectionRows.Count -eq 2 -and $collectionRows[1].Condition -like '*Au moins une instance de « *' -and $collectionRows[1].Value -ceq '3 instance(s) examinée(s)' -and $collectionRows[1].State -ceq 'Disponible' -and $collectionRows[1].Verdict -ceq 'Vrai') 'Collection verdict shows the examined instances and their coverage'

$report=[pscustomobject]@{Status='PASS';Assertions=$script:checks;SourceMode=[bool]$QuerySource;ElapsedSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,3);PowerShell=$PSVersionTable.PSVersion.ToString();Scope='Actual query model, compiler and LocalQuery worker body; no network, AD, WMI or WPF'}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Compress
