#requires -Version 5.1
# Points 151-158: advanced query engine. Actual common DLL, models, worker factories and click handlers with inert
# controls. No AD, WMI, network, WPF or VM access; the remote WMI cmdlets are replaced by local fixtures.
[CmdletBinding()]
param([switch]$QuerySource,[string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
if($QuerySource){Add-Type -Path (Join-Path (Split-Path -Parent $wad) 'vendor/m4d-admin-common/src/Query/QueryEngine.cs')}else{Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')}
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','Probes.Model','Workstation.Model','QuerySchema.Model','Query.Model','QueryLibrary.Model','Query.Worker','Query.UI')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$script:checks=0;$clock=[Diagnostics.Stopwatch]::StartNew()
function Expect([bool]$Good,[string]$Name){$script:checks++;if(-not $Good){throw $Name}}
function Reject([scriptblock]$Action,[string]$Name,[string]$Like=''){$failed=$false;$message='';try{& $Action|Out-Null}catch{$failed=$true;$message=$_.Exception.Message};Expect $failed $Name;if($Like){Expect ($message -like $Like) ($Name+' : '+$message)}}
function New-FixtureRecord([string]$Id,[hashtable]$Values){$v=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);foreach($key in $Values.Keys){$v[$key]=$Values[$key]};return [M4D.Admin.Common.Query.QueryRecord]::new($Id,$v)}

# ---------------------------------------------------------------------------------------------------------------
# Point 158: exact distributions beyond 10 000 distinct values, bounded memory and paginated detail.
$records=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
for($i=0;$i -lt 20000;$i++){$records.Add((New-FixtureRecord ('00000000-0000-0000-0000-{0:000000000000}' -f $i) @{name=('PC-{0:00000}' -f $i);model=('Model {0:00000}' -f $i);active=($i % 4 -ne 0)}))}
for($i=20000;$i -lt 20500;$i++){$records.Add((New-FixtureRecord ('00000000-0000-0000-0000-{0:000000000000}' -f $i) @{name=('PC-{0:00000}' -f $i)}))}
$byModel=New-DomeniaQueryRecipe -Name 'Par modèle' -GroupBy 'model'
$summary=Get-DomeniaQueryGroupSummary -Records $records -Recipe $byModel
$known=0L;foreach($category in $summary.Categories){$known+=$category.Count}
Expect ($summary.CategoryCount -eq 20000 -and $summary.Missing -eq 500 -and $summary.Matched -eq 20500 -and ($known+$summary.Missing) -eq $summary.Matched) '20000 distinct values aggregate exactly with a separate unknown bucket'
Expect ($summary.Categories[0].Label -ceq 'Model 00000' -and $summary.Categories[19999].Label -ceq 'Model 19999' -and $summary.Categories[0].Rank -eq 1) 'equal counts keep the typed value order: deterministic ranking'
$widget=Measure-DomeniaQueryWidget -Records $records -Recipe $byModel
$sum=0L;foreach($item in $widget.Items){$sum+=[long]$item.Value}
Expect (@($widget.Items).Count -eq 12 -and $sum -eq 20500 -and $widget.CategoryCount -eq 20000) 'widget shows ten values, the exact remainder and unknown without losing a workstation'
Expect ((@($widget.Items|Where-Object Label -ceq 'Autres valeurs')[0]).Value -eq 19990 -and (@($widget.Items|Where-Object Label -ceq 'Valeur inconnue')[0]).Value -eq 500) 'remainder and unknown values are exact'
Expect ($widget.Items[0].Label -ceq $summary.Categories[0].Label -and $widget.Items[9].Label -ceq $summary.Categories[9].Label) 'widget top ten equals the first page of the complete distribution'
$page=Get-DomeniaQueryGroupPage -Summary $summary -Offset 0 -Limit 100
Expect (@($page.Rows).Count -eq 100 -and $page.HasNext -and -not $page.HasPrevious -and $page.Filtered -eq 20001) 'first page of the complete distribution is bounded to 100 values'
$page=Get-DomeniaQueryGroupPage -Summary $summary -Offset 19950 -Limit 100
Expect (@($page.Rows).Count -eq 51 -and -not $page.HasNext -and $page.Rows[50].Rank -ceq '—' -and $page.Rows[50].Label -ceq 'Valeur inconnue' -and $page.Rows[50].Select.Missing) 'last page reaches every value and keeps unknown last'
$page=Get-DomeniaQueryGroupPage -Summary $summary -Offset 900000 -Limit 100
Expect ($page.Offset -eq 20000 -and @($page.Rows).Count -eq 1) 'an offset beyond the list is clamped to the last page'
$page=Get-DomeniaQueryGroupPage -Summary $summary -Text 'model 1999' -Limit 100
Expect ($page.Filtered -eq 11 -and @($page.Rows|Where-Object{$_.Label -notlike '*1999*'}).Count -eq 0) 'filter searches the complete distribution, not only the visible page'
Expect ((Get-DomeniaQueryGroupPage -Summary $summary -Text 'MODÈLE INEXISTANT').Filtered -eq 0) 'filter without result is explicit'
Expect ($page.Rows[0].Share -ceq '0,0 %') 'share is formatted in French'
Reject {Get-DomeniaQueryGroupPage -Summary $summary -Limit 501} 'page budget is explicit'
$target=@((Get-DomeniaQueryGroupPage -Summary $summary -Text 'Model 12345').Rows)[0]
$ids=Get-DomeniaQueryMatchIds -Records $records -Recipe (New-DomeniaQuerySegmentRecipe $byModel $target.Select)
Expect ($ids.Count -eq 1 -and $ids.ContainsKey('00000000-0000-0000-0000-000000012345')) 'a value beyond the top ten opens exactly its workstation'
$unknown=@((Get-DomeniaQueryGroupPage -Summary $summary -Offset 20000).Rows)[0]
$ids=Get-DomeniaQueryMatchIds -Records $records -Recipe (New-DomeniaQuerySegmentRecipe $byModel $unknown.Select)
Expect ($ids.Count -eq 500) 'unknown bucket opens exactly the workstations without value'
Reject {Get-DomeniaQueryGroupSummary -Records $records -Recipe $byModel -MaxCategories 100} 'a distribution above its memory budget is refused, never sampled' '*valeurs distinctes*'
Reject {Get-DomeniaQueryGroupSummary -Records $records -Recipe $byModel -MaxCategories 100001} 'the category budget cannot exceed 100 000'
$byName=Measure-DomeniaQueryWidget -Records $records -Recipe (New-DomeniaQueryRecipe -GroupBy 'name')
Expect ($byName.CategoryCount -eq 20500) 'grouping by workstation name works on 20 500 workstations'
$byState=Get-DomeniaQueryGroupSummary -Records $records -Recipe (New-DomeniaQueryRecipe -GroupBy 'active')
Expect (@($byState.Categories.Label) -ccontains 'Oui' -and @($byState.Categories.Label) -ccontains 'Non' -and $byState.Missing -eq 500) 'Boolean categories are labelled Oui and Non and keep unknown separate'
$Payload=[pscustomobject]@{ModuleRoot=$modules;Records=$records;Recipe=$byModel;Saved=@();CachedWidgets=@{};CachedProbeWidgets=@{};Selection='Match';Offset=0;MaxAgeDays=30;TextFilter='PC-0000';StateFilter=''}
$actual=& ([scriptblock]::Create((Get-DomeniaQueryWorkerCode)))
Expect ($actual.Groups.CategoryCount -eq 20000 -and $actual.Groups.Matched -eq 20500 -and $actual.Matched -lt 20500) 'actual worker returns the complete distribution independently of the list filter'
$Payload.Recipe=New-DomeniaQueryRecipe;$actual=& ([scriptblock]::Create((Get-DomeniaQueryWorkerCode)))
Expect ($null -eq $actual.Groups) 'a counter recipe computes no distribution'
# Click handlers with inert controls.
$script:Fake=@{}
foreach($name in @('ExpQueryGroups','DgQueryGroups','TxtQueryGroupFilter','BtnQueryGroupsPrevious','BtnQueryGroupsNext','BtnQueryGroupsShow','CmbQueryResult')){$script:Fake[$name]=[pscustomobject]@{ItemsSource=@();SelectedItem=$null;SelectedIndex=-1;Text='';IsEnabled=$false;Visibility='Collapsed'}}
function Get-DomeniaControl([string]$Name){return $script:Fake[$Name]}
function Set-DomeniaControlText([string]$Name,[string]$Text){$script:Labels[$Name]=$Text;return $true}
$script:Labels=@{}
$script:DomeniaQueryState=[pscustomobject]@{Recipe=$byModel;Busy=$false;GroupSummary=$summary;GroupOffset=0}
Update-DomeniaQueryGroups
Expect ($script:Fake.ExpQueryGroups.Visibility -ceq 'Visible' -and @($script:Fake.DgQueryGroups.ItemsSource).Count -eq 100 -and $script:Fake.BtnQueryGroupsNext.IsEnabled -and $script:Labels.LblQueryGroups -like '*20*000 valeur(s) distincte(s)*total exact*') 'distribution panel announces exact totals and pages'
Move-DomeniaQueryGroupPage 1
Expect ($script:DomeniaQueryState.GroupOffset -eq 100 -and $script:Fake.BtnQueryGroupsPrevious.IsEnabled) 'next page moves by 100 values'
$script:Fake.TxtQueryGroupFilter.Text='Model 0000';$script:DomeniaQueryState.GroupOffset=0;Update-DomeniaQueryGroups
Expect (@($script:Fake.DgQueryGroups.ItemsSource).Count -eq 11 -and -not $script:Fake.BtnQueryGroupsNext.IsEnabled) 'filtered distribution shows only matching values (00000 to 00009 and 10000)'
$script:DomeniaQueryState.GroupSummary=[pscustomobject]@{Field='model';Error='Plus de 100 000 valeurs distinctes'};Update-DomeniaQueryGroups
Expect (@($script:Fake.DgQueryGroups.ItemsSource).Count -eq 0 -and $script:Labels.LblQueryGroups -like 'Répartition non calculée*') 'a refused distribution is reported, never drawn'
$script:DomeniaQueryState.GroupSummary=$null;Update-DomeniaQueryGroups
Expect ($script:Fake.ExpQueryGroups.Visibility -ceq 'Collapsed') 'no distribution panel without a computed distribution'
$script:DomeniaQueryState.GroupSummary=$summary;$script:Fake.TxtQueryGroupFilter.Text='';Update-DomeniaQueryGroups
$script:Fake.DgQueryGroups.SelectedItem=$script:Fake.DgQueryGroups.ItemsSource[3]
function Set-DomeniaQueryDraft($Recipe){$script:DraftSet=$Recipe}
function Start-DomeniaQueryEvaluation{$script:EvaluationStarted=$true}
Show-DomeniaQueryGroupMachines
Expect ($script:EvaluationStarted -and @($script:DraftSet.Refinements).Count -eq 1 -and $script:DraftSet.Refinements[0].Operator -ceq 'Equal' -and $script:DraftSet.Refinements[0].Value -ceq 'Model 00003') 'Afficher ces postes adds an exact segment and recalculates locally'
$script:DomeniaQueryState.Recipe=New-DomeniaQueryRecipe -GroupBy 'name';$script:EvaluationStarted=$false;Show-DomeniaQueryGroupMachines
Expect (-not $script:EvaluationStarted -and $script:Labels.LblQueryStatus -like '*relancez*') 'a distribution of another recipe cannot be applied to the current draft'

# ---------------------------------------------------------------------------------------------------------------
# Point 151: temporal coherence of conditions, dates of each source and proposed common window.
$base=[datetime]::Parse('2026-10-13T10:00:00Z').ToUniversalTime()
$coherent=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
for($i=0;$i -lt 100;$i++){
    $inventoryAt=if($i -lt 90){$base.AddHours(-2)}else{$base.AddDays(-5)}
    $values=@{os='Windows 11';'_at:field:os'=$base.ToString('o');ramGB=8.0;'_at:inventory'=$inventoryAt.ToString('o');'probe:hw.cpuload'=90;'_at:probe:hw.cpuload'=$base.AddMinutes(-30).ToString('o')}
    $coherent.Add((New-FixtureRecord ('10000000-0000-0000-0000-{0:000000000000}' -f $i) $values))
}
$mixedRecipe=New-DomeniaQueryRecipe -Name 'Charge et mémoire' -Clauses @([pscustomobject]@{Field='os';Operator='Contains';Value='Windows'},[pscustomobject]@{Field='ramGB';Operator='Less';Value=16},[pscustomobject]@{Field='probe:hw.cpuload';Operator='Greater';Value=80})
$coverage=Measure-DomeniaQueryCoverage -Records $coherent -Recipe $mixedRecipe
Expect ($coverage.WindowSource -ceq 'Référence' -and $coverage.CoherenceHours -eq 24 -and $coverage.MixedPeriod -eq 10 -and $coverage.SourceCount -eq 3) 'without a recipe window, the 24 h reference is announced as such'
$sources=@{};foreach($row in $coverage.Sources){$sources[$row.Source]=$row}
Expect ($sources.ContainsKey('Annuaire AD') -and $sources.ContainsKey('Inventaire du poste') -and @($coverage.Sources|Where-Object{$_.Source -like 'Sonde · *'}).Count -eq 1) 'AD, inventory and probe dates are reported as distinct sources'
Expect ($sources['Inventaire du poste'].Dated -eq 100 -and $sources['Inventaire du poste'].Oldest -ceq $base.AddDays(-5).ToLocalTime().ToString('dd/MM/yyyy HH:mm') -and $sources['Inventaire du poste'].Newest -ceq $base.AddHours(-2).ToLocalTime().ToString('dd/MM/yyyy HH:mm')) 'each source exposes its oldest and newest date'
Expect ($coverage.Proposal.Needed -and $coverage.Proposal.Hours -eq 6 -and $coverage.Proposal.Covered -eq 90 -and $coverage.Proposal.Text -like '*mesure instantanée*') 'a CPU load condition gets a short proposed window covering 90 % of dated workstations'
$windowed=Copy-DomeniaQueryRecipe $mixedRecipe;$windowed.CoherenceHours=48;$windowed.Format='Domenia.Query/2'
$coverage=Measure-DomeniaQueryCoverage -Records $coherent -Recipe $windowed
Expect ($coverage.WindowSource -ceq 'Recette' -and $coverage.CoherenceHours -eq 48 -and $coverage.MixedPeriod -eq 10) 'the recipe window is the one used by the coverage check'
$windowed.CoherenceHours=6
$compiled=ConvertTo-DomeniaCompiledQuery $windowed
Expect ($compiled.Evaluate($coherent[0].Values) -eq [M4D.Admin.Common.Query.MatchState]::Match -and $compiled.Evaluate($coherent[95].Values) -eq [M4D.Admin.Common.Query.MatchState]::Unknown) 'with the common window, values from different periods give Unknown instead of a mixed verdict'
$undatedValues=@{os='Windows 11';'_at:field:os'=$base.ToString('o');ramGB=8.0;'probe:hw.cpuload'=90;'_at:probe:hw.cpuload'=$base.ToString('o')}
$withUndated=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new($coherent);$withUndated.Add((New-FixtureRecord '10000000-0000-0000-0000-999999999999' $undatedValues))
$coverage=Measure-DomeniaQueryCoverage -Records $withUndated -Recipe $mixedRecipe
Expect ($coverage.Undated -eq 1 -and $coverage.Proposal.Dated -eq 100 -and $coverage.Proposal.Undated -eq 1 -and $coverage.Proposal.Text -like '*sans toutes les dates resteront inconnus*') 'a workstation without every date is never counted as coherent'
Expect (@($coverage.Sources|Where-Object{$_.Source -ceq 'Inventaire du poste'})[0].Missing -eq 1) 'the missing source date is attributed to its source'
$single=Measure-DomeniaQueryCoverage -Records $coherent -Recipe (New-DomeniaQueryRecipe -Clauses @([pscustomobject]@{Field='ramGB';Operator='Less';Value=16}))
Expect (-not $single.Proposal.Needed -and $null -eq $single.Proposal.Hours -and $single.SourceCount -eq 1) 'one dated source needs no common window'
$proposal=Get-DomeniaQueryCoherenceProposal -Spreads (@(0.5)*50+@(30.0)*50) -SourceCount 2
Expect ($proposal.Hours -eq 48 -and $proposal.Covered -eq 100 -and $proposal.Text -like '*48 h (2 jours)*') 'stable sources get the smallest usual window covering the threshold'
$proposal=Get-DomeniaQueryCoherenceProposal -Spreads (@(9000.0)*20) -SourceCount 2
Expect ($proposal.Needed -and $null -eq $proposal.Hours -and $proposal.Text -like '*plus dʼun an*') 'dates spread over more than a year are not hidden behind a huge window'
$proposal=Get-DomeniaQueryCoherenceProposal -Spreads (@(100.0)*20) -SourceCount 2 -Volatile $true
Expect ($proposal.Hours -eq 24 -and $proposal.Covered -eq 0 -and $proposal.Text -like 'Fenêtre proposée : 24 h. Seuls 0*') 'instantaneous measures are capped at 24 h and the shortfall is stated'
$proposal=Get-DomeniaQueryCoherenceProposal -Spreads @() -SourceCount 3 -Undated 12
Expect ($proposal.Needed -and $null -eq $proposal.Hours -and $proposal.Text -like '*aucun poste ne possède toutes les dates*') 'no fully dated workstation gives no invented window'
Reject {Get-DomeniaQueryCoherenceProposal -Spreads @(1.0) -SourceCount 2 -Threshold 0} 'proposal threshold is validated'
Expect ((Test-DomeniaQueryVolatileKey '_at:probe:hw.cpuload') -and (Test-DomeniaQueryVolatileKey '_at:presence') -and -not (Test-DomeniaQueryVolatileKey '_at:inventory') -and -not (Test-DomeniaQueryVolatileKey '_at:field:os')) 'instantaneous sources are identified'
$Payload=[pscustomobject]@{ModuleRoot=$modules;Records=$coherent;Recipe=$windowed;CoverageOnly=$true;Saved=@();MaxAgeDays=30}
$windowed.CoherenceHours=48;$actual=& ([scriptblock]::Create((Get-DomeniaQueryWorkerCode)))
Expect ($actual.Coverage.CoherenceHours -eq 48 -and $actual.Coverage.WindowSource -ceq 'Recette' -and $actual.Coverage.Proposal.Hours -eq 6) 'actual coverage worker compares dates with the recipe window and proposes one'
# Click handlers with inert controls.
$script:Fake=@{}
foreach($name in @('DgQueryCoherenceSources','BtnQueryApplyCoherence')){$script:Fake[$name]=[pscustomobject]@{ItemsSource=@();SelectedItem=$null;IsEnabled=$false}}
function Get-DomeniaControl([string]$Name){return $script:Fake[$Name]}
function Set-DomeniaControlText([string]$Name,[string]$Text){$script:Labels[$Name]=$Text;return $true}
$script:Labels=@{}
$script:DomeniaQueryState=[pscustomobject]@{Recipe=$mixedRecipe;CoherenceProposal=$null}
$coverage=Measure-DomeniaQueryCoverage -Records $coherent -Recipe $mixedRecipe
Show-DomeniaQueryCoherence -Coverage $coverage
Expect ($script:Fake.BtnQueryApplyCoherence.IsEnabled -and @($script:Fake.DgQueryCoherenceSources.ItemsSource).Count -eq 3 -and $script:DomeniaQueryState.CoherenceProposal.Hours -eq 6 -and $script:Labels.LblQueryCoherenceProposal -like 'Fenêtre proposée : 6 h*') 'the proposal is shown and can be applied explicitly'
function Get-DomeniaQueryDraft{return (Copy-DomeniaQueryRecipe $script:DomeniaQueryState.Recipe)}
function Set-DomeniaQueryDraft($Recipe){$script:DraftSet=$Recipe}
Use-DomeniaQueryCoherenceProposal
Expect ($script:DraftSet.CoherenceHours -eq 6 -and $script:DraftSet.Format -ceq 'Domenia.Query/2' -and $script:Labels.LblQueryStatus -like '*rien nʼest enregistré*') 'applying the proposal only changes the draft window'
$script:DomeniaQueryState.Recipe=$script:DraftSet;Show-DomeniaQueryCoherence -Coverage $coverage
Expect (-not $script:Fake.BtnQueryApplyCoherence.IsEnabled -and $null -eq $script:DomeniaQueryState.CoherenceProposal -and $script:Labels.LblQueryCoherenceProposal -like '*déjà celle du brouillon*') 'the same window is not proposed twice'
$script:DomeniaQueryState.CoherenceProposal=$null;Use-DomeniaQueryCoherenceProposal
Expect ($script:Labels.LblQueryStatus -like 'Fenêtre non appliquée*') 'no proposal, no change'

# ---------------------------------------------------------------------------------------------------------------
# Point 157: readable PowerShell export, parameters, sources, limits and structured output; nothing executed.
. (Join-Path $modules 'Domenia-QueryTransfer.Worker.ps1')
$hostile="Postes d"+[char]0x2019+"Anne's`r`n#> Remove-Item C:\ -Recurse "+[char]0x201C+"x"+[char]0x201D
$exported=New-DomeniaQueryRecipe -Id 'personal.export' -Name $hostile -Clauses @([pscustomobject]@{Field='active';Operator='Equal';Value=$true},[pscustomobject]@{Field='ramGB';Operator='Less';Value=[pscustomobject]@{Parameter='Seuil'}}) -Parameters @([pscustomobject]@{Name='Seuil';Field='ramGB';Default=16})
$text=ConvertTo-DomeniaQueryPowerShell -Recipe $exported -ExportedUtc ([datetime]::Parse('2026-10-15T08:00:00Z').ToUniversalTime())
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
Expect ($errors.Count -eq 0) ('exported script parses: '+(@($errors|ForEach-Object{$_.Message}) -join ' | '))
$commands=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_}|Sort-Object -Unique)
$allowed=@('Add-Type','ConvertFrom-Json','ConvertTo-DomeniaCompiledQuery','ConvertTo-Json','Get-DomeniaQueryRequestedFields','Get-DomeniaQueryValuePresentation','Join-Path','Select-DomeniaQueryPopulation','Where-Object','Write-Verbose')
Expect (@($commands|Where-Object{$_ -notin $allowed}).Count -eq 0) ('exported script calls only local evaluation commands: '+($commands -join ', '))
Expect ($text -notmatch '(?i)Credential|SecureString|Invoke-Expression|New-CimSession|Get-CimInstance|DirectoryEntry|Remove-Item C:\\ -Recurse\r\n') 'no credential, connection or injected command line in the export'
$parameterNames=@($ast.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})
Expect (($parameterNames -join ',') -ceq 'ModuleRoot,Records,Selection,ParameterValues,ShowDefinition') 'script parameters are explicit and contain no identity'
$lines=@($text -split "`r`n")
$codeStart=[Array]::IndexOf($lines,'[CmdletBinding()]')
Expect ($lines[0] -ceq '#requires -Version 5.1' -and $codeStart -gt 5 -and @($lines[1..($codeStart-1)]|Where-Object{$_ -notlike '#*'}).Count -eq 0) 'the header is made of comment lines only'
$nameLine=@($lines|Where-Object{$_ -like '# Nom : *'})
Expect ($nameLine.Count -eq 1 -and $nameLine[0] -like '*Anne*Remove-Item*') 'a hostile name stays on one comment line'
Expect ($text -like '*paramètre Seuil*' -and $text -like '*Seuil : Mémoire relevée en Go, valeur 16*' -and $text -like '*Mémoire relevée en Go : Relevé du poste*' -and $text -like '*donne Inconnu, jamais Faux ni zéro*' -and $text -like '*15/10/2026 08:00 UTC*') 'conditions, parameters, sources, limits and export date are documented'
$literal=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'ConvertFrom-Json'},$true))[0].CommandElements[2]
Expect ($literal.Value -cmatch '^[\x20-\x7E]+$' -and (ConvertFrom-Json -InputObject $literal.Value).Name -ceq $hostile) 'the recipe literal is pure ASCII and restores the exact name'
$folder=Join-Path ([IO.Path]::GetTempPath()) ('domenia-query-export-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder)
try{
    $script=Join-Path $folder 'requete.ps1';[IO.File]::WriteAllText($script,$text,[Text.UTF8Encoding]::new($true))
    $snapshot=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
    $snapshot.Add((New-FixtureRecord 'a1' @{name='PC-A';dn='CN=PC-A,DC=example,DC=test';active=$true;ramGB=8.0;'_at:inventory'='2026-10-15T07:00:00Z'}))
    $snapshot.Add((New-FixtureRecord 'a2' @{name='PC-B';dn='CN=PC-B,DC=example,DC=test';active=$true;ramGB=32.0}))
    $snapshot.Add((New-FixtureRecord 'a3' @{name='PC-C';dn='CN=PC-C,DC=example,DC=test';active=$true}))
    $snapshot.Add((New-FixtureRecord 'a4' @{name='PC-D';dn='CN=PC-D,DC=example,DC=test';active=$false;ramGB=4.0}))
    $rows=@(& $script -ModuleRoot $modules -Records $snapshot)
    Expect ($rows.Count -eq 1 -and $rows[0].Id -ceq 'a1' -and $rows[0].Nom -ceq 'PC-A' -and $rows[0].Verdict -ceq 'Correspond' -and $rows[0].Valeurs.ramGB -eq 8 -and $rows[0].Etats.ramGB -ceq 'Disponible') 'the script returns structured objects for matching workstations'
    $rows=@(& $script -ModuleRoot $modules -Records $snapshot -Selection Unknown)
    Expect ($rows.Count -eq 1 -and $rows[0].Id -ceq 'a3' -and $rows[0].Verdict -ceq 'Inconnu' -and $null -eq $rows[0].Valeurs.ramGB -and $rows[0].Etats.ramGB -ceq 'Non lu') 'an unread value stays unknown in the script output'
    $rows=@(& $script -ModuleRoot $modules -Records $snapshot -ParameterValues @{Seuil=64})
    Expect ($rows.Count -eq 2) 'recipe parameters are changed at run time without editing the script'
    Reject {& $script -ModuleRoot $modules -Records $snapshot -ParameterValues @{Inconnu=1}} 'an unknown parameter is refused' '*Paramètre inconnu*'
    $definition=(& $script -ModuleRoot $modules -ShowDefinition|Out-String)
    Expect ((ConvertFrom-Json $definition).Id -ceq 'personal.export') 'ShowDefinition prints the criteria without evaluation'
    $Payload=[pscustomobject]@{ModuleRoot=$modules;Mode='ExportPowerShell';Path=(Join-Path $folder 'worker.ps1');Recipe=$exported;Context=$null}
    $result=& ([scriptblock]::Create((Get-DomeniaQueryTransferWorkerCode)))
    $bytes=[IO.File]::ReadAllBytes($result.Path)
    Expect ($result.Complete -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF -and @(Get-ChildItem -LiteralPath $folder -Filter '*.tmp' -Force).Count -eq 0) 'actual transfer worker writes the UTF-8 BOM script atomically'
    Reject {& ([scriptblock]::Create((Get-DomeniaQueryTransferWorkerCode)))} 'an existing script is never overwritten'
}finally{Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue}
$advanced=New-DomeniaQueryRecipe -Name 'Disque presque plein' -Expression ([pscustomobject]@{Kind='Collection';CollectionField='probe:disk.volumes';Quantifier='Any';Children=@([pscustomobject]@{Kind='All';Children=@([pscustomobject]@{Kind='Clause';Clause=[pscustomobject]@{Field='instance:disk.volumes:FreeSpace';Operator='Less';Value=1000000000}},[pscustomobject]@{Kind='Clause';Clause=[pscustomobject]@{Field='instance:disk.volumes:DeviceID';Operator='Equal';Value='C:'}})})}) -CoherenceHours 48 -GroupBy 'model'
$outline=Get-DomeniaQueryRecipeOutline $advanced
Expect (@($outline.Conditions|Where-Object{$_ -like '*Au moins une instance de « Volumes locaux*même instance*'}).Count -eq 1 -and @($outline.Conditions|Where-Object{$_ -like '*FreeSpace*est inférieur à 1000000000*'}).Count -eq 1) 'collection criteria are described on the same instance'
Expect (@($outline.Notes|Where-Object{$_ -like 'Fenêtre commune : 48 h*'}).Count -eq 1 -and @($outline.Notes|Where-Object{$_ -like 'Répartition du widget*'}).Count -eq 1) 'window and distribution limits are stated'
Expect ((ConvertTo-DomeniaScriptCommentText ("a`nb"+[char]0x2028+'c')) -ceq 'a b c' -and (ConvertTo-DomeniaAsciiJson ('"'+[char]0x2019+'"')) -ceq '"\u2019"') 'comment and literal encoders neutralise line breaks and typographic quotes'

# ---------------------------------------------------------------------------------------------------------------
# Point 153: impact of a modified or archived recipe, migration or explicit preservation of the old version.
. (Join-Path $modules 'Domenia-QueryLibrary.Store.UI.ps1')
$fleetLayout=@(
    [pscustomobject]@{Id='w-linked';Source='Query';Key='personal.a';Visual='Kpi';Title='Postes à surveiller'},
    [pscustomobject]@{Id='w-legacy';Source='Query';Key='personal.a';Visual='Bar';Title=''},
    [pscustomobject]@{Id='w-other';Source='Query';Key='personal.b';Visual='Kpi';Title='Autre requête'},
    [pscustomobject]@{Id='b-fleet.machines';Source='Builtin';Key='fleet.machines';Visual='Kpi';Title=''})
$computerLayout=@([pscustomobject]@{Id='w-computer';Source='Query';Key='personal.a';Visual='Text';Title='Sur ce poste'})
$links=@(
    [pscustomobject]@{RecipeId='personal.a';ConsumerKind='Fleet';ConsumerId='w-linked';BoundRevision=3},
    [pscustomobject]@{RecipeId='personal.a';ConsumerKind='Computer';ConsumerId='w-computer';BoundRevision=2},
    [pscustomobject]@{RecipeId='personal.a';ConsumerKind='Fleet';ConsumerId='w-removed';BoundRevision=3},
    [pscustomobject]@{RecipeId='personal.b';ConsumerKind='Fleet';ConsumerId='w-other';BoundRevision=1})
$impact=Get-DomeniaQueryRecipeImpact -RecipeId 'personal.a' -Dependencies $links -Layouts @{Fleet=$fleetLayout;Computer=$computerLayout} -SearchFavorites @('local:personal.a','ad:locked') -CurrentRevision 3
Expect ($impact.Count -eq 5 -and $impact.Widgets -eq 3 -and $impact.Orphans -eq 1 -and $impact.Views -eq 1 -and $impact.HasConsumers) 'widgets, links without widget and Search views are all listed'
$byConsumer=@{};foreach($row in $impact.Rows){$byConsumer[[string]$row.ConsumerId]=$row}
Expect ($byConsumer['w-linked'].Link -ceq 'Lié à la révision 3' -and $byConsumer['w-legacy'].Link -like 'Widget sans lien*' -and $byConsumer['w-legacy'].Name -ceq 'Widget sans titre' -and $byConsumer['w-computer'].Link -ceq 'Lié à une ancienne révision (2)' -and $byConsumer['w-computer'].Element -ceq 'Tableau de bord du poste') 'each consumer states its board and bound revision'
Expect ($byConsumer['w-removed'].Kind -ceq 'Orphan' -and $byConsumer['local:personal.a'].Element -ceq 'Vue de Recherche' -and -not $byConsumer.ContainsKey('w-other')) 'another recipe is never listed as a consumer'
Expect (-not (Get-DomeniaQueryRecipeImpact -RecipeId 'personal.c' -Dependencies $links -Layouts @{Fleet=$fleetLayout}).HasConsumers) 'a recipe without consumers needs no review'
Reject {Get-DomeniaQueryRecipeImpact -RecipeId ''} 'the analysed recipe is mandatory'
$saved=New-DomeniaQueryRecipe -Id 'personal.a' -Name 'Postes à surveiller' -Clauses @([pscustomobject]@{Field='active';Operator='Equal';Value=$true})
$version=New-DomeniaQueryRecipeVersion $saved
Expect ($version.Id -cne 'personal.a' -and $version.Name -ceq 'Postes à surveiller (nouvelle version)' -and @($version.Clauses).Count -eq 1 -and $saved.Id -ceq 'personal.a') 'keeping the old version creates an independent copy'
Expect ((New-DomeniaQueryRecipeVersion (New-DomeniaQueryRecipe -Name ('N'*120))).Name.Length -eq 120) 'the copy name stays within 120 characters'
# Actual save path: ImpactConfirmed bypasses the modal confirmation, bindings move to the new revision atomically.
$script:FixtureContext=[pscustomobject]@{Version=1;StoreId='fixture-store';DomainDn='DC=example,DC=test';Path=(Join-Path ([IO.Path]::GetTempPath()) 'fixture-impact.sqlite');SessionEpoch=7;Generation=1}
$savedRow=New-DomeniaQueryLibraryRecord -Context $script:FixtureContext -Recipe $saved -ExpectedRevision 2
$savedRow|Add-Member NoteProperty Revision 3 -Force
function New-DomeniaStoreContext{param($RequestId,$Generation,$ScopeDn,$Subtree)return $script:FixtureContext}
function Show-DomeniaDialog{throw 'Aucune fenêtre modale attendue après la revue dans la page.'}
function Submit-DomeniaStoreBatch{param($Context,$BatchId,$Sequence,$Changes,$SuccessHandler,$ErrorHandler,$CallbackState)$script:Submitted=@($Changes);return [pscustomobject]@{Accepted=$true}}
$script:DomeniaQueryLibraryStoreState=[pscustomobject]@{Context=$script:FixtureContext;Generation=1;Loading=$false;Loaded=$true;Saving=$false;Error='';Rows=@{'personal.a'=$savedRow};Recipes=@($saved);Dependencies=$links}
$modified=Copy-DomeniaQueryRecipe $saved;$modified.Clauses=@($modified.Clauses)+@([pscustomobject]@{Field='os';Operator='Contains';Value='Windows 10'})
[void](Save-DomeniaQueryRecipe -Recipe $modified -ImpactConfirmed)
$rebound=@($script:Submitted|Where-Object{$_.Kind -eq 'QueryDependency'})
Expect ($rebound.Count -eq 3 -and @($rebound|Where-Object{$_.BoundRevision -ne 4 -or $_.Remove}).Count -eq 0 -and @($script:Submitted|Where-Object{$_.Kind -eq 'QueryRecipe'}).Count -eq 1) 'confirmed migration rebinds the three existing links to the new revision in one batch'
$script:DomeniaQueryLibraryStoreState.Saving=$false
# In-page review with inert controls and captured saves.
$script:Fake=@{}
foreach($name in @('PnlQueryImpact','DgQueryImpact','BtnQueryImpactMigrate','BtnQueryImpactKeep','BtnQueryImpactArchive')){$script:Fake[$name]=[pscustomobject]@{ItemsSource=@();Visibility='Collapsed';IsEnabled=$true}}
function Get-DomeniaControl([string]$Name){return $script:Fake[$Name]}
function Set-DomeniaControlText([string]$Name,[string]$Text){$script:Labels[$Name]=$Text;return $true}
function Get-DomeniaBoardLayout([string]$Board){if($Board -eq 'Fleet'){return $fleetLayout};return $computerLayout}
function Get-DomeniaSearchQueryFavorites{return @('local:personal.a')}
function Get-DomeniaQueryDraft{return (Copy-DomeniaQueryRecipe $script:CurrentDraft)}
function Save-DomeniaQueryRecipe{param($Recipe,[string]$SuccessHandler='Complete-DomeniaQueryRecipeSaveUi',$CallbackState=$null,[switch]$Archive,[object[]]$AdditionalDependencies=@(),[string]$ErrorHandler='',[switch]$ImpactConfirmed)$script:Saves.Add([pscustomobject]@{Recipe=$Recipe;SuccessHandler=$SuccessHandler;CallbackState=$CallbackState;Archive=[bool]$Archive;ImpactConfirmed=[bool]$ImpactConfirmed});return [pscustomobject]@{Accepted=$true}}
$script:Labels=@{};$script:Saves=[Collections.Generic.List[object]]::new()
$script:DomeniaQueryState=[pscustomobject]@{Generation=5;Recipe=$saved;ImpactPending=$null}
$script:CurrentDraft=$saved
Request-DomeniaQueryRecipeSave
Expect ($script:Saves.Count -eq 1 -and $script:Saves[0].ImpactConfirmed -and $script:Fake.PnlQueryImpact.Visibility -ceq 'Collapsed') 'an unchanged definition is saved without review'
$script:Saves.Clear();$script:CurrentDraft=$modified
Request-DomeniaQueryRecipeSave
Expect ($script:Saves.Count -eq 0 -and $script:Fake.PnlQueryImpact.Visibility -ceq 'Visible' -and @($script:Fake.DgQueryImpact.ItemsSource).Count -eq 5 -and $script:Fake.BtnQueryImpactMigrate.Visibility -ceq 'Visible' -and $script:Fake.BtnQueryImpactArchive.Visibility -ceq 'Collapsed') 'a modified definition with consumers is reviewed in the page before any write'
Expect ($script:Labels.LblQueryImpact -like '5 élément(s) utilisent la révision 3*3 widget(s), 1 vue(s) de Recherche, 1 lien(s) sans widget*Aucune alerte*' -and $script:Labels.LblQueryStatus -like '*rien nʼest encore enregistré*') 'the review states every consumer kind and that nothing was written'
Invoke-DomeniaQueryImpactAction 'Migrate'
Expect ($script:Saves.Count -eq 1 -and $script:Saves[0].ImpactConfirmed -and $script:Saves[0].Recipe.Id -ceq 'personal.a' -and @($script:Saves[0].Recipe.Clauses).Count -eq 2 -and $script:Fake.PnlQueryImpact.Visibility -ceq 'Collapsed') 'migration saves the new definition after the explicit choice'
$script:Saves.Clear();Request-DomeniaQueryRecipeSave;Invoke-DomeniaQueryImpactAction 'Keep'
Expect ($script:Saves.Count -eq 1 -and $script:Saves[0].Recipe.Id -cne 'personal.a' -and $script:Saves[0].SuccessHandler -ceq 'Complete-DomeniaQueryRecipeVersionUi' -and $script:Saves[0].CallbackState.KeptRevision -eq 3) 'keeping the old version saves a copy and leaves the saved recipe untouched'
$script:Saves.Clear();Request-DomeniaQueryRecipeSave
$script:CurrentDraft=Copy-DomeniaQueryRecipe $modified;$script:CurrentDraft.Name='Renommée après la revue'
Invoke-DomeniaQueryImpactAction 'Migrate'
Expect ($script:Saves.Count -eq 0 -and $script:Labels.LblQueryStatus -like '*Le brouillon a changé*' -and $script:Fake.PnlQueryImpact.Visibility -ceq 'Collapsed') 'a draft changed after the review is never saved with an outdated review'
$script:CurrentDraft=$modified;Request-DomeniaQueryRecipeSave;$savedRow.Revision=4
Invoke-DomeniaQueryImpactAction 'Migrate'
Expect ($script:Saves.Count -eq 0 -and $script:Labels.LblQueryStatus -like '*modifiée entre-temps*') 'a recipe changed elsewhere requires a new review'
$savedRow.Revision=3;Request-DomeniaQueryRecipeSave;$script:DomeniaQueryState.Generation=6
Invoke-DomeniaQueryImpactAction 'Migrate'
Expect ($script:Saves.Count -eq 0) 'a review from an older draft generation is refused'
$script:DomeniaQueryState.Generation=5;$script:CurrentDraft=$saved
Request-DomeniaQueryRecipeSave -Archive
Expect ($script:Saves.Count -eq 0 -and $script:Fake.BtnQueryImpactArchive.Visibility -ceq 'Visible' -and $script:Fake.BtnQueryImpactMigrate.Visibility -ceq 'Collapsed' -and $script:Labels.LblQueryImpact -like '*retire ces widgets*') 'archiving with consumers is reviewed first'
Invoke-DomeniaQueryImpactAction 'Migrate'
Expect ($script:Saves.Count -eq 0 -and $script:Labels.LblQueryStatus -like '*ne correspond pas*') 'a save choice cannot answer an archive review'
Request-DomeniaQueryRecipeSave -Archive;Invoke-DomeniaQueryImpactAction 'Archive'
Expect ($script:Saves.Count -eq 1 -and $script:Saves[0].Archive -and $script:Saves[0].ImpactConfirmed -and $script:Saves[0].SuccessHandler -ceq 'Complete-DomeniaQueryRecipeArchiveUi') 'archive is written only after the explicit choice'
$script:Saves.Clear();Request-DomeniaQueryRecipeSave -Archive;Invoke-DomeniaQueryImpactAction 'Cancel'
Expect ($script:Saves.Count -eq 0 -and $null -eq $script:DomeniaQueryState.ImpactPending -and $script:Labels.LblQueryStatus -like 'Modification non enregistrée*') 'cancel writes nothing'
Complete-DomeniaQueryRecipeVersionUi -Recipe $version -Record ([pscustomobject]@{Revision=1}) -State ([pscustomobject]@{DraftGeneration=5;KeptName='Postes à surveiller';KeptRevision=3;Count=5})
Expect ($script:Labels.LblQueryStatus -like 'Nouvelle requête*(nouvelle version)*révision 1*Postes à surveiller*5 élément(s) liés restent à la révision 3*' -and $script:DraftSet.Id -ceq $version.Id) 'the confirmation names the copy and the preserved revision'

# @@NEXT-SECTION@@

$report=[pscustomobject]@{Status='PASS';Assertions=$script:checks;SourceMode=[bool]$QuerySource;ElapsedSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,3);PowerShell=$PSVersionTable.PSVersion.ToString();Scope='Actual models, worker factories and click handlers with inert controls; remote WMI cmdlets replaced by fixtures; no network, AD, WMI or WPF'}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Compress
