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
Expect ($page.Filtered -eq 12 -and @($page.Rows|Where-Object{$_.Label -notlike '*1999*'}).Count -eq 0) 'filter searches the complete distribution, not only the visible page (01999, 11999, 19990 to 19999)'
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
$nestedLines=@((ConvertTo-DomeniaQueryPowerShell -Recipe $advanced) -split "`r`n")
$indentOf={param([string]$Line)[regex]::Match($Line,'^# *').Length}
$collectionLine=@($nestedLines|Where-Object{$_ -like '#*Au moins une instance de « Volumes locaux*'})
$groupLine=@($nestedLines|Where-Object{$_ -like '#*Toutes les conditions suivantes (ET) :'})
$clauseLine=@($nestedLines|Where-Object{$_ -like '#*- *FreeSpace*est inférieur à 1000000000*'})
Expect ($collectionLine.Count -eq 1 -and $groupLine.Count -eq 1 -and $clauseLine.Count -eq 1 -and (& $indentOf $collectionLine[0]) -lt (& $indentOf $groupLine[0]) -and (& $indentOf $groupLine[0]) -lt (& $indentOf $clauseLine[0])) 'the exported comments keep the nesting of the collection, its group and its conditions'
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
function Save-DomeniaQueryRecipe{param($Recipe,[string]$SuccessHandler='Complete-DomeniaQueryRecipeSaveUi',$CallbackState=$null,[switch]$Archive,[object[]]$AdditionalDependencies=@(),[string]$ErrorHandler='',[switch]$ImpactConfirmed)$script:Saves.Add([pscustomobject]@{Recipe=$Recipe;SuccessHandler=$SuccessHandler;CallbackState=$CallbackState;Archive=[bool]$Archive;ImpactConfirmed=[bool]$ImpactConfirmed;AdditionalDependencies=@($AdditionalDependencies)});return [pscustomobject]@{Accepted=$true}}
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
# Workshop button « Créer une sonde dashboard »: the same in-page review precedes any write and any widget.
. (Join-Path $modules 'Domenia-QueryTargets.UI.ps1')
$script:Fake['CmbQueryWidgetDestination']=[pscustomobject]@{SelectedItem=[pscustomobject]@{Tag='Fleet'}}
$script:Fake['CmbQueryWidgetVisual']=[pscustomobject]@{SelectedItem=[pscustomobject]@{Tag='Bar'}}
function Set-DomeniaBoardLayout{param($Board,$Layout,$Undo,$Highlight)$script:BoardWrite=[pscustomobject]@{Board=$Board;Layout=@($Layout);Highlight=$Highlight}}
$script:BoardWrite=$null;$script:Saves.Clear();$script:CurrentDraft=$modified
Add-DomeniaWorkshopWidget
Expect ($script:Saves.Count -eq 0 -and $null -eq $script:BoardWrite -and $script:DomeniaQueryState.ImpactPending.Mode -ceq 'Widget' -and $script:Fake.PnlQueryImpact.Visibility -ceq 'Visible' -and $script:Fake.BtnQueryImpactMigrate.Visibility -ceq 'Visible' -and $script:Fake.BtnQueryImpactKeep.Visibility -ceq 'Visible' -and $script:Fake.BtnQueryImpactArchive.Visibility -ceq 'Collapsed') 'the dashboard widget button reviews a modified definition in the page: no dialog, no write, no widget before the choice'
Expect ($script:Labels.LblQueryImpact -like '5 élément(s) utilisent la révision 3*widget demandé est ajouté au tableau de bord général seulement après ce choix*' -and $script:Labels.LblQueryStatus -like '*rien nʼest encore enregistré*') 'the review announces that the widget waits for the choice'
Invoke-DomeniaQueryImpactAction 'Migrate'
$migrated=$script:Saves[0]
Expect ($script:Saves.Count -eq 1 -and $migrated.ImpactConfirmed -and $migrated.Recipe.Id -ceq 'personal.a' -and @($migrated.Recipe.Clauses).Count -eq 2 -and $migrated.SuccessHandler -ceq 'Complete-DomeniaWorkshopWidgetSave' -and $migrated.CallbackState.Destination -ceq 'Fleet' -and $migrated.CallbackState.Visual -ceq 'Bar' -and @($migrated.AdditionalDependencies).Count -eq 1 -and $migrated.AdditionalDependencies[0].ConsumerKind -ceq 'Fleet' -and $migrated.AdditionalDependencies[0].ConsumerId -ceq 'w-linked' -and $script:Fake.PnlQueryImpact.Visibility -ceq 'Collapsed') 'updating the linked elements saves the new definition and the widget link in one confirmed batch'
$script:Saves.Clear();Add-DomeniaWorkshopWidget;Invoke-DomeniaQueryImpactAction 'Keep'
$kept=$script:Saves[0]
Expect ($script:Saves.Count -eq 1 -and $kept.ImpactConfirmed -and $kept.Recipe.Id -cne 'personal.a' -and $kept.Recipe.Name -ceq 'Postes à surveiller (nouvelle version)' -and $kept.SuccessHandler -ceq 'Complete-DomeniaWorkshopWidgetSave' -and $kept.CallbackState.Item.Key -ceq $kept.Recipe.Id -and $kept.CallbackState.Item.Id -cne 'w-linked' -and $kept.CallbackState.KeptRevision -eq 3 -and @($kept.AdditionalDependencies).Count -eq 1 -and $kept.AdditionalDependencies[0].ConsumerId -ceq $kept.CallbackState.Item.Id) 'keeping the old version saves a copy and links the new widget to the copy only'
Complete-DomeniaWorkshopWidgetSave -Recipe $kept.Recipe -Record ([pscustomobject]@{Revision=1}) -State $kept.CallbackState
Expect ($script:BoardWrite.Board -ceq 'Fleet' -and @($script:BoardWrite.Layout|Where-Object{$_.Key -ceq $kept.Recipe.Id}).Count -eq 1 -and @($script:BoardWrite.Layout|Where-Object{$_.Key -ceq 'personal.a'}).Count -eq 2 -and $script:DraftSet.Id -ceq $kept.Recipe.Id) 'the copy gets its own widget; the widgets of the saved recipe stay in place'
Expect ($script:Labels.LblQueryStatus -like 'Nouvelle requête « Postes à surveiller (nouvelle version) » enregistrée (révision 1) et ajoutée au tableau de bord général*« Postes à surveiller » et ses 5 élément(s) liés restent à la révision 3*') 'the confirmation names the copy, its board and the preserved revision'
$script:Saves.Clear();$script:CurrentDraft=$saved;Add-DomeniaWorkshopWidget
Expect ($script:Saves.Count -eq 1 -and $script:Saves[0].ImpactConfirmed -and $script:Saves[0].SuccessHandler -ceq 'Complete-DomeniaWorkshopWidgetSave' -and $null -eq $script:DomeniaQueryState.ImpactPending -and $script:Fake.PnlQueryImpact.Visibility -ceq 'Collapsed') 'an unchanged definition adds its widget without review and without a dialog'

# ---------------------------------------------------------------------------------------------------------------
# Points 154, 155, 156: WMI metadata explorer with cache, WQL review, relations by identity. Remote cmdlets are
# replaced by fixtures; the actual QuerySchema worker body runs against them.
. (Join-Path $modules 'Domenia-ProbeDetails.Model.ps1')
. (Join-Path $modules 'Domenia-QuerySchema.Worker.ps1')
. (Join-Path $modules 'Domenia-QuerySchema.UI.ps1')
$mmi=$true;try{Add-Type -AssemblyName Microsoft.Management.Infrastructure -ErrorAction Stop}catch{$mmi=$false}
function New-FixtureProperty([string]$Name,[string]$Type='String',[switch]$Key,[string]$Unit='',[string]$Description='',[switch]$Localized){
    $qualifiers=[Collections.Generic.List[object]]::new()
    if($Key){$qualifiers.Add([pscustomobject]@{Name='Key';Value=$true})}
    if($Unit){$qualifiers.Add([pscustomobject]@{Name='Units';Value=$Unit})}
    if($Localized -and $Description){$qualifiers.Add([pscustomobject]@{Name='Description';Value=$Description})}
    return [pscustomobject]@{Name=$Name;CimType=$Type;Qualifiers=$qualifiers.ToArray()}
}
function Get-FixtureClass([string]$Name,[switch]$Localized){
    $classQualifiers=[Collections.Generic.List[object]]::new();$properties=@()
    switch($Name){
        'Win32_Service'{$properties=@((New-FixtureProperty 'Name' -Key -Description "Nom unique`r`ndu service" -Localized:$Localized),(New-FixtureProperty 'State'),(New-FixtureProperty 'StartMode'),(New-FixtureProperty 'ProcessId' 'UInt32'),(New-FixtureProperty 'WaitHint' 'UInt32' -Unit 'milliseconds'),(New-FixtureProperty 'Dependencies' 'StringArray'),(New-FixtureProperty 'LegacyPassword'));if($Localized){$classQualifiers.Add([pscustomobject]@{Name='Description';Value='Service Windows'})}}
        'Win32_Process'{$properties=@((New-FixtureProperty 'Handle' -Key),(New-FixtureProperty 'Name'),(New-FixtureProperty 'ProcessId' 'UInt32'),(New-FixtureProperty 'ParentProcessId' 'UInt32'),(New-FixtureProperty 'CreationDate' 'DateTime'),(New-FixtureProperty 'ExecutablePath'),(New-FixtureProperty 'CommandLine'))}
        'Win32_DiskDrive'{$properties=@((New-FixtureProperty 'DeviceID' -Key),(New-FixtureProperty 'Model'))}
        'Win32_DiskPartition'{$properties=@((New-FixtureProperty 'DeviceID' -Key),(New-FixtureProperty 'Size' 'UInt64' -Unit 'bytes'))}
        'Win32_DiskDriveToDiskPartition'{$properties=@((New-FixtureProperty 'Antecedent' 'Reference' -Key),(New-FixtureProperty 'Dependent' 'Reference' -Key));$classQualifiers.Add([pscustomobject]@{Name='Association';Value=$true})}
        'CIM_LogicalElement'{$properties=@((New-FixtureProperty 'Name'));$classQualifiers.Add([pscustomobject]@{Name='Abstract';Value=$true})}
        'Win32_Product'{$properties=@((New-FixtureProperty 'IdentifyingNumber' -Key))}
        '__SystemClass'{$properties=@()}
        default{throw ('Classe absente du poste fictif : '+$Name)}
    }
    return [pscustomobject]@{CimClassName=$Name;CimClassProperties=$properties;CimClassQualifiers=$classQualifiers.ToArray()}
}
function Get-WMachineCredential($Context){return $null}
function New-WDomeniaCimSession($Context,$Computer,$Credential,$TimeoutSeconds){$script:Sessions++;if($script:SessionFailure){throw $script:SessionFailure};return $script:FixtureSession}
function Remove-WDomeniaCimSession($Session){$script:Removed++}
function Assert-WCredentialAllowed{param($Context,$Channel)}
function Register-WCredentialFailure{param($Context,$ErrorValue,$Channel)return ([string]$ErrorValue -like '*fixture-logon-failure*')}
function Get-CimClass{[CmdletBinding()]param($CimSession,[string]$Namespace,[string]$ClassName,[int]$OperationTimeoutSec)
    $script:CimCalls.Add('Get-CimClass '+$Namespace+' '+$ClassName)
    if($ClassName -and -not $ClassName.Contains('*')){return (Get-FixtureClass $ClassName)}
    return @(foreach($name in @('Win32_Service','Win32_Process','Win32_DiskDrive','Win32_DiskPartition','Win32_DiskDriveToDiskPartition','CIM_LogicalElement','Win32_Product','__SystemClass')){if(-not $ClassName -or $name -like $ClassName){Get-FixtureClass $name}})
}
function Get-CimInstance{[CmdletBinding()]param($CimSession,[string]$Namespace,[string]$ClassName,[string]$Query,[int]$OperationTimeoutSec)
    $script:CimCalls.Add('Get-CimInstance '+$Namespace+' '+$ClassName+$Query)
    if($ClassName -eq '__NAMESPACE'){return @([pscustomobject]@{Name='cimv2'},[pscustomobject]@{Name='Microsoft'},[pscustomobject]@{Name='bad name'})}
    if($Query -like '* FROM Win32_Service*'){
        $all=@([pscustomobject]@{Name='Spooler';State='Running';StartMode='Auto';ProcessId=[uint32]1234;__RELPATH='Win32_Service.Name="Spooler"'},[pscustomobject]@{Name='Fax';State='Stopped';StartMode='Manual';ProcessId=[uint32]0;__RELPATH='Win32_Service.Name="Fax"'})
        if($Query -like '*WHERE ProcessId=1234'){return @($all[0])};return $all
    }
    if($Query -like "* FROM Win32_Process WHERE Handle='1234'"){return @([pscustomobject]@{Handle='1234';Name='spoolsv.exe';ProcessId=[uint32]1234;ParentProcessId=[uint32]600;CreationDate=[datetime]'2026-10-15T07:00:00Z';ExecutablePath='C:\Windows\System32\spoolsv.exe';CommandLine='spoolsv.exe --fixture-argument';__RELPATH='Win32_Process.Handle="1234"'})}
    return @()
}
function New-CimInstance{[CmdletBinding()]param([string]$ClassName,[string]$Namespace,$Property,[string[]]$Key,[switch]$ClientOnly)$script:CimCalls.Add('New-CimInstance '+$ClassName+' '+($Key -join ','));return [pscustomobject]@{ClassName=$ClassName;Keys=$Property}}
function Get-CimAssociatedInstance{[CmdletBinding()]param($InputObject,$CimSession,[string]$Namespace,[string]$Association,[string]$ResultClassName,[int]$OperationTimeoutSec)
    $script:CimCalls.Add('Get-CimAssociatedInstance '+$Association+' '+$ResultClassName+' '+[string]$InputObject.Keys.DeviceID)
    return @([pscustomobject]@{DeviceID='Disk #0, Partition #0';Size=[uint64]536870912;__RELPATH='Win32_DiskPartition.DeviceID="Disk #0, Partition #0"'},[pscustomobject]@{DeviceID='Disk #0, Partition #1';Size=[uint64]107374182400;__RELPATH='Win32_DiskPartition.DeviceID="Disk #0, Partition #1"'})
}
$script:FixtureSession=[pscustomobject]@{Fixture=$true}
$script:FixtureSession|Add-Member ScriptMethod GetClass {param($Namespace,$Name,$Options)$script:LocalizedCalls++;return (Get-FixtureClass $Name -Localized)}
$Context=[pscustomobject]@{UseCim=$true}
$msiNames=@(Get-DomeniaMsiProviderClassNames)
function Invoke-SchemaWorker([hashtable]$Values){
    $script:CimCalls=[Collections.Generic.List[string]]::new();$script:Sessions=0;$script:Removed=0
    $payload=[pscustomobject]@{ModuleRoot=$modules;Mode='Schema';Computer='PC-01';Namespace='root\cimv2';ClassName='Win32_Service';Query='';Limit=100;MsiClassNames=$msiNames;StopToken=$null;KeyValues=$null;AssociationClass='';ResultClass='';ClassFilter='';SourceProperty='';SourceValue=$null;TargetProperty=''}
    foreach($key in $Values.Keys){$payload.$key=$Values[$key]}
    $Payload=$payload
    return (& ([scriptblock]::Create((Get-DomeniaQuerySchemaWorkerCode))))
}
$script:LocalizedCalls=0
$result=Invoke-SchemaWorker @{Mode='Namespaces';Namespace='root'}
Expect ((@($result.Namespaces).Namespace -join ',') -ceq 'root\cimv2,root\Microsoft' -and $result.CanonicalQuery -ceq 'NAMESPACES root' -and $result.RequestKey -ceq (Get-DomeniaQuerySchemaRequestKey 'root' 'NAMESPACES root')) 'namespaces: one level, sorted, invalid names dropped'
Expect ($script:CimCalls.Count -eq 1 -and $script:CimCalls[0] -ceq 'Get-CimInstance root __NAMESPACE' -and $script:Removed -eq 1) 'namespace listing is a single non-recursive read and the session is closed'
$result=Invoke-SchemaWorker @{Mode='Classes'}
$classes=@{};foreach($row in $result.Classes){$classes[$row.Class]=$row}
Expect (-not $classes.ContainsKey('__SystemClass') -and $classes.Count -eq 7 -and $classes['Win32_Product'].Note -like 'Fournisseur MSI*' -and $classes['CIM_LogicalElement'].Note -like 'Fournisseur MSI*' -and $classes['Win32_DiskDriveToDiskPartition'].Association -and $classes['Win32_Service'].Keys -eq 1 -and $classes['Win32_Service'].Properties -eq 7) 'class list states properties, keys, associations and MSI refusal without reading any instance'
Expect (@($script:CimCalls|Where-Object{$_ -like 'Get-CimInstance*'}).Count -eq 0 -and $result.CanonicalQuery -ceq 'CLASSES root\cimv2 *') 'class listing never enumerates instances'
$result=Invoke-SchemaWorker @{Mode='Classes';ClassFilter='Win32_Disk*'}
Expect (@($result.Classes).Count -eq 3 -and $result.Filter -ceq 'Win32_Disk*' -and $result.CanonicalQuery -ceq 'CLASSES root\cimv2 Win32_Disk*') 'class filter keeps its wildcard and canonical key'
Reject {Invoke-SchemaWorker @{Mode='Classes';ClassFilter="Win32_* OR 1=1"}} 'an invalid class filter is refused'
Expect ($script:Sessions -eq 0) 'a refused filter opens no session'
$result=Invoke-SchemaWorker @{Mode='Schema'}
$properties=@{};foreach($row in $result.Schema){$properties[$row.Property]=$row}
Expect (-not $properties.ContainsKey('LegacyPassword') -and $properties['WaitHint'].Unit -ceq 'milliseconds' -and $properties['Dependencies'].IsArray -and $properties['Name'].IsKey -and $result.CanonicalQuery -ceq 'SCHEMA Win32_Service') 'schema gives types, keys, arrays and units, never a secret property'
if($mmi){Expect ($result.DescriptionsAvailable -and $script:LocalizedCalls -eq 1 -and $result.ClassDescription -ceq 'Service Windows' -and $properties['Name'].Description -ceq 'Nom unique du service') 'localized descriptions are read once and flattened to one line'}
else{Expect (-not $result.DescriptionsAvailable) 'without the CIM client library, descriptions are announced as unavailable'}
$script:FixtureSession=[pscustomobject]@{Fixture=$true}
$result=Invoke-SchemaWorker @{Mode='Schema'}
Expect (-not $result.DescriptionsAvailable -and -not $result.ClassDescription -and @($result.Schema).Count -eq 6) 'a provider without localized qualifiers falls back to the plain schema, said as such'
Reject {Invoke-SchemaWorker @{Mode='Schema';ClassName='Win32_Product'}} 'the MSI provider schema is never read'
$result=Invoke-SchemaWorker @{Mode='Select';Query="SELECT State FROM Win32_Service WHERE StartMode = 'Auto'"}
Expect (@($script:CimCalls|Where-Object{$_ -like "Get-CimInstance root\cimv2 SELECT State,Name FROM Win32_Service WHERE StartMode = 'Auto'"}).Count -eq 1 -and $result.Rows[0].KeyValues.Name -ceq 'Spooler' -and $result.StoredCount -eq 2) 'a SELECT keeps the provider key to preserve instance identity'
$result=Invoke-SchemaWorker @{Mode='Reference';ClassName='Win32_Service';SourceProperty='ProcessId';SourceValue=[uint32]1234;ResultClass='Win32_Process';TargetProperty='Handle'}
Expect (@($script:CimCalls|Where-Object{$_ -like "*FROM Win32_Process WHERE Handle='1234'"}).Count -eq 1 -and $result.Rows.Count -eq 1 -and $result.Rows[0].ClassName -ceq 'Win32_Process' -and $result.Rows[0].KeyValues.Handle -ceq '1234') 'the hosting process is read by its key Handle, not by a name'
Expect ($null -eq $result.Rows[0].Values.PSObject.Properties['CommandLine'] -and $result.CanonicalQuery -ceq 'REFERENCE Win32_Service.ProcessId=1234 TO Win32_Process.Handle' -and $result.Relation -like 'ProcessId*Win32_Process.Handle') 'a reference relation never reads the command line and keeps its identity in the canonical key'
$result=Invoke-SchemaWorker @{Mode='Reference';ClassName='Win32_Process';SourceProperty='Handle';SourceValue='1234';ResultClass='Win32_Service';TargetProperty='ProcessId'}
Expect (@($script:CimCalls|Where-Object{$_ -like '*FROM Win32_Service WHERE ProcessId=1234'}).Count -eq 1 -and $result.Rows.Count -eq 1 -and $result.Rows[0].KeyValues.Name -ceq 'Spooler') 'services hosted by a process are read by ProcessId'
foreach($bad in @(@{SourceValue=0},@{SourceValue="1 OR 1=1"},@{TargetProperty='Name'},@{ResultClass='Win32_Product';TargetProperty='Handle'})){
    $values=@{Mode='Reference';ClassName='Win32_Service';SourceProperty='ProcessId';SourceValue=[uint32]1234;ResultClass='Win32_Process';TargetProperty='Handle'};foreach($key in $bad.Keys){$values[$key]=$bad[$key]}
    Reject {Invoke-SchemaWorker $values} ('unsafe or unplanned reference refused: '+(($bad.GetEnumerator()|ForEach-Object{$_.Key+'='+$_.Value}) -join ','))
    Expect ($script:Sessions -eq 0) 'a refused relation opens no session'
}
$result=Invoke-SchemaWorker @{Mode='Associations';ClassName='Win32_DiskDrive';KeyValues=[pscustomobject]@{DeviceID='\\.\PHYSICALDRIVE0'};AssociationClass='Win32_DiskDriveToDiskPartition';ResultClass='Win32_DiskPartition'}
Expect (@($script:CimCalls|Where-Object{$_ -ceq 'New-CimInstance Win32_DiskDrive DeviceID'}).Count -eq 1 -and @($script:CimCalls|Where-Object{$_ -ceq 'Get-CimAssociatedInstance Win32_DiskDriveToDiskPartition Win32_DiskPartition \\.\PHYSICALDRIVE0'}).Count -eq 1) 'the association starts from the source instance key'
Expect ($result.Rows.Count -eq 2 -and $result.Rows[1].KeyValues.DeviceID -ceq 'Disk #0, Partition #1' -and $result.Rows[1].Id -like 'Win32_DiskPartition.DeviceID=*' -and $result.Relation -ceq 'Win32_DiskDriveToDiskPartition') 'each associated partition keeps its provider identity'
$script:SessionFailure='fixture-logon-failure';Reject {Invoke-SchemaWorker @{Mode='Schema'}} 'a rejected logon stops the read';$script:SessionFailure=$null
# UI: cache first for metadata, explicit in-page offer for a remote read, review before recipe.
function Add-FakeEvents($Control){foreach($eventName in @('Add_Click','Add_TextChanged','Add_SelectionChanged','Add_MouseDoubleClick')){$Control|Add-Member ScriptMethod $eventName {param($Handler)}};return $Control}
$script:Fake=@{}
foreach($name in @('TxtQueryWmiNamespace','TxtQueryWmiClass','TxtQueryWmiClassFilter','TxtQueryWmiLimit','TxtQueryWql','ChkQueryWmiForceRead','LstQueryWmiNamespaces','DgQueryWmiClasses','DgQuerySchema','DgQueryWmiRows','TxtQueryAssociationClass','TxtQueryAssociationResult','BtnQueryWqlRecipe','BtnQueryWmiRemoteRead','LblQueryWqlPlan','QueryWorkspaceTabs','TabQueryPublish')){$script:Fake[$name]=Add-FakeEvents ([pscustomobject]@{Text='';IsChecked=$false;ItemsSource=@();SelectedItem=$null;IsEnabled=$true;Visibility='Collapsed';Tag=$null})}
$combo=Add-FakeEvents ([pscustomobject]@{ItemsSource=@();SelectedIndex=-1;Tag=$null});$combo|Add-Member ScriptProperty SelectedItem {$items=@($this.ItemsSource);if($this.SelectedIndex -ge 0 -and $this.SelectedIndex -lt $items.Count){$items[$this.SelectedIndex]}else{$null}};$script:Fake['CmbQueryAssociationPreset']=$combo
$script:Fake.TxtQueryWmiNamespace.Text='root\cimv2';$script:Fake.TxtQueryWmiClass.Text='Win32_Service';$script:Fake.TxtQueryWmiLimit.Text='100';$script:Fake.TxtQueryWql.Text="SELECT State FROM Win32_Service WHERE StartMode = 'Auto'"
function Get-DomeniaControl([string]$Name){return $script:Fake[$Name]}
function Set-DomeniaControlText([string]$Name,[string]$Text){$script:Labels[$Name]=$Text;return $true}
function Get-DomeniaWmiComputer{return 'PC-01'}
function New-DomeniaClassicCollectionState{param([string]$Computer,[string]$ResultKind,[string]$RequestKey,[string]$PublishHandler,[string]$PublishErrorHandler)return [pscustomobject]@{Computer=$Computer;ResultKind=$ResultKind;RequestKey=$RequestKey;PublishHandler=$PublishHandler;PublishErrorHandler=$PublishErrorHandler;StoreContext=[pscustomobject]@{StoreId='fixture-store'};StoreGuid='aaaaaaaa-0000-4000-8000-000000000001';StoreDn='CN=PC-01,DC=example,DC=test'}}
function Request-DomeniaStoreRead{param($Context,$Query,$SuccessHandler,$ErrorHandler,$CallbackState)$script:StoreReads.Add($Query);$script:LastStoreState=$CallbackState;return 'job-store'}
function Show-DomeniaDialog{param($Title,$Message,$Kind,$Buttons,$Details)$script:Dialogs.Add($Message);return $script:DialogAnswer}
function Start-UiTask{param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$SuccessHandler,$ErrorHandler,$TimeoutSeconds,$HardTimeoutSeconds,$TaskClass)$script:Tasks.Add([pscustomobject]@{OperationId=$OperationId;Payload=$Payload;State=$CallbackState});return 'job-remote'}
function Test-DomeniaRemoteStoreContext($State,$Result){return $true}
function Test-DomeniaClassicResultCurrent($Result,$State,[switch]$ContextOnly){return $true}
$script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-01';DN='CN=PC-01,DC=example,DC=test';Safety=[pscustomobject]@{Guid='aaaaaaaa-0000-4000-8000-000000000001'}}
$script:Labels=@{};$script:StoreReads=[Collections.Generic.List[object]]::new();$script:Dialogs=[Collections.Generic.List[string]]::new();$script:Tasks=[Collections.Generic.List[object]]::new();$script:DialogAnswer='Yes'
$script:DomeniaQueryState=[pscustomobject]@{Generation=1}
Initialize-DomeniaQuerySchemaUi
Expect ($script:Labels.LblQueryWqlPlan -like '*Pas encore testée*' -and -not $script:Fake.BtnQueryWqlRecipe.IsEnabled) 'the WQL review is shown before any read and the recipe waits for a test'
Invoke-DomeniaQuerySchemaAction 'Schema'
$schemaKey=Get-DomeniaQuerySchemaRequestKey 'root\cimv2' 'SCHEMA Win32_Service'
Expect ($script:StoreReads.Count -eq 1 -and $script:StoreReads[0].ResultKind -ceq 'WmiSchema' -and $script:StoreReads[0].RequestKey -ceq $schemaKey -and $script:Dialogs.Count -eq 0 -and $script:Tasks.Count -eq 0) 'schema is first looked up in the local database, without remote read'
$stored=Invoke-SchemaWorker @{Mode='Schema'}
$cached=[pscustomobject]@{DataSource='SQLite';StoreId='fixture-store';Busy=$false;Missing=$false;SnapshotRevision=9;Details=@([pscustomobject]@{Guid='AAAAAAAA-0000-4000-8000-000000000001';ResultKind='WmiSchema';RequestKey=$schemaKey;Status='Success';LastSuccessAtUtc='2026-10-14T09:30:00Z';Data=$stored})}
Complete-DomeniaQuerySchemaCacheRead -Result $cached -State $script:LastStoreState
Expect (@($script:Fake.DgQuerySchema.ItemsSource).Count -eq 6 -and $script:Labels.LblQueryWmiStatus -like '*métadonnées enregistrées le*sans nouvelle lecture du poste*' -and $script:Tasks.Count -eq 0 -and $script:Dialogs.Count -eq 0) 'stored metadata is displayed with its date and no remote access'
Expect (@($script:Fake.DgQuerySchema.ItemsSource|Where-Object{$_.Description -ceq 'Description non fournie'}).Count -eq 6 -and $script:Labels.LblQueryWmiClassDescription -like 'Win32_Service : descriptions non fournies*') 'missing descriptions are stated, never invented'
$script:Fake.TxtQueryWmiClass.Text='Win32_Process';Invoke-DomeniaQuerySchemaAction 'Schema'
Complete-DomeniaQuerySchemaCacheRead -Result ([pscustomobject]@{DataSource='SQLite';StoreId='fixture-store';Busy=$false;Missing=$false;Details=@()}) -State $script:LastStoreState
Expect ($script:Fake.BtnQueryWmiRemoteRead.Visibility -ceq 'Visible' -and $script:Labels.LblQueryWmiStatus -like 'Aucune métadonnée enregistrée*Lire sur le poste*' -and $script:Tasks.Count -eq 0 -and $script:Dialogs.Count -eq 0) 'without stored metadata, a callback only offers an explicit in-page remote read'
Invoke-DomeniaQuerySchemaAction 'Remote'
Expect ($script:Dialogs.Count -eq 1 -and $script:Tasks.Count -eq 1 -and $script:Tasks[0].OperationId -ceq 'QuerySchema' -and $script:Tasks[0].Payload.Mode -ceq 'Schema' -and $script:Tasks[0].Payload.ClassName -ceq 'Win32_Process' -and $script:Fake.BtnQueryWmiRemoteRead.Visibility -ceq 'Collapsed') 'the explicit button confirms then reads only the chosen workstation'
$old=$script:LastStoreState;Invoke-DomeniaQuerySchemaAction 'Namespaces'
Complete-DomeniaQuerySchemaCacheRead -Result $cached -State $old
Expect ($script:Labels.LblQueryWmiStatus -like 'Recherche des métadonnées*') 'a late cache answer of an older request is ignored'
$script:Fake.ChkQueryWmiForceRead.IsChecked=$true;$reads=$script:StoreReads.Count;Invoke-DomeniaQuerySchemaAction 'Classes'
Expect ($script:StoreReads.Count -eq $reads -and $script:Tasks.Count -eq 2 -and $script:Tasks[1].Payload.Mode -ceq 'Classes' -and $script:Dialogs.Count -eq 2) 'forced refresh goes to the workstation after confirmation'
$script:DialogAnswer='No';Invoke-DomeniaQuerySchemaAction 'Namespaces'
Expect ($script:Tasks.Count -eq 2 -and $script:Labels.LblQueryWmiStatus -ceq 'Lecture sur le poste non lancée.') 'a declined confirmation reads nothing'
$script:DialogAnswer='Yes';$script:Fake.ChkQueryWmiForceRead.IsChecked=$false
$classesStored=Invoke-SchemaWorker @{Mode='Classes'};$state=$script:LastStoreState;$state.Mode='Classes';$state.FromCache=$false;$script:DomeniaQueryState.SchemaGeneration=$state.SchemaGeneration
Complete-DomeniaQuerySchemaStored -Result ($classesStored|Add-Member NoteProperty DataSource 'SQLite' -PassThru) -State $state
Expect (@($script:Fake.DgQueryWmiClasses.ItemsSource).Count -eq 7 -and $script:Labels.LblQueryWmiStatus -like '*7 classe(s)*lecture du poste enregistrée*') 'classes read on the workstation are displayed after storage'
# Select, test status and recipe readiness.
Invoke-DomeniaQuerySchemaAction 'Select'
$selectState=$script:Tasks[$script:Tasks.Count-1].State
$selected=Invoke-SchemaWorker @{Mode='Select';Query=$script:Tasks[$script:Tasks.Count-1].Payload.Query};$selected|Add-Member NoteProperty DataSource 'SQLite';$selected|Add-Member NoteProperty SourceCompletedUtc '2026-10-15T08:00:00Z' -Force
Complete-DomeniaQuerySchemaStored -Result $selected -State $selectState
Expect ($script:Fake.BtnQueryWqlRecipe.IsEnabled -and $script:Labels.LblQueryWqlPlan -like '*Testée sur PC-01*' -and @($script:Fake.DgQueryWmiRows.ItemsSource).Count -eq 2) 'a stored test of the same SELECT enables the recipe'
$script:Fake.TxtQueryWql.Text='SELECT State, StartMode FROM Win32_Service';Update-DomeniaQueryWqlPlan
Expect (-not $script:Fake.BtnQueryWqlRecipe.IsEnabled) 'editing the SELECT requires a new test'
function Set-DomeniaQueryDraft($Recipe){$script:DraftSet=$Recipe}
$script:DraftSet=$null;Invoke-DomeniaQuerySchemaAction 'Recipe'
Expect ($null -eq $script:DraftSet -and $script:Labels.LblQueryWmiStatus -like '*nʼa pas été testée*') 'an untested SELECT never becomes a recipe'
$script:Fake.TxtQueryWql.Text="SELECT State FROM Win32_Service WHERE StartMode = 'Auto'";Invoke-DomeniaQuerySchemaAction 'Recipe'
Expect ($null -ne $script:DraftSet -and $script:DraftSet.ReadDefinition.CanonicalQuery -ceq $selected.CanonicalQuery -and $script:DraftSet.ReadDefinition.Limit -eq 100) 'the recipe stores the tested canonical SELECT'
$script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-01';DN='CN=PC-01,DC=example,DC=test';Safety=[pscustomobject]@{Guid='bbbbbbbb-0000-4000-8000-000000000002'}};Update-DomeniaQueryWqlPlan
Expect (-not $script:Fake.BtnQueryWqlRecipe.IsEnabled) 'a recreated workstation with the same name must be tested again'
$script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-01';DN='CN=PC-01,DC=example,DC=test';Safety=[pscustomobject]@{Guid='aaaaaaaa-0000-4000-8000-000000000001'}}
# Relations offered for the selected instance.
$service=@($script:Fake.DgQueryWmiRows.ItemsSource|Where-Object{$_.KeyValues.Name -eq 'Spooler'})[0];$script:Fake.DgQueryWmiRows.SelectedItem=$service
Update-DomeniaQueryRelationPresets
Expect (@($combo.ItemsSource).Count -eq 3 -and $combo.SelectedItem.Kind -ceq 'Association' -and $script:Fake.TxtQueryAssociationClass.Text -ceq 'Win32_DependentService') 'relations planned for a service are offered first'
$combo.SelectedIndex=1;Use-DomeniaQueryRelationPreset
Expect ($combo.SelectedItem.Kind -ceq 'Reference' -and -not $script:Fake.TxtQueryAssociationClass.IsEnabled) 'a reference relation needs no free association text'
$tasks=$script:Tasks.Count;Invoke-DomeniaQuerySchemaAction 'Relation'
Expect ($script:Tasks.Count -eq $tasks -and $script:Labels.LblQueryWmiStatus -like '*ProcessId nʼa pas été lue*') 'a reference without the identity property read is refused before any confirmation'
$withPid=[pscustomobject]@{Id=$service.Id;ClassName='Win32_Service';KeyValues=$service.KeyValues;Values=[pscustomobject]@{State='Running';Name='Spooler';ProcessId=1234}};$script:Fake.DgQueryWmiRows.SelectedItem=$withPid
Invoke-DomeniaQuerySchemaAction 'Relation'
$last=$script:Tasks[$script:Tasks.Count-1]
Expect ($script:Tasks.Count -eq $tasks+1 -and $last.Payload.Mode -ceq 'Reference' -and [string]$last.Payload.SourceValue -ceq '1234' -and $last.Payload.ResultClass -ceq 'Win32_Process' -and $last.Payload.TargetProperty -ceq 'Handle' -and $last.State.ResultKind -ceq 'WmiQuery') 'the hosting process read is confirmed then sent with the source identity'
$script:Fake.DgQueryWmiRows.SelectedItem=$null;$tasks=$script:Tasks.Count;Invoke-DomeniaQuerySchemaAction 'Relation'
Expect ($script:Tasks.Count -eq $tasks -and $script:Labels.LblQueryWmiStatus -like '*Sélectionnez une instance*') 'no relation without a selected stored instance'

# ---------------------------------------------------------------------------------------------------------------
# Point 152: collections with at least one, all and none; several criteria on the SAME disk or software.
function New-FixtureCollection([string]$ProbeId,[object[]]$Rows,[bool]$Complete=$true,[string[]]$Unknown=@()){
    $instances=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new();$i=0
    foreach($row in $Rows){
        $values=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach($key in $row.Keys){$values['instance:'+$ProbeId+':'+$key]=$row[$key]}
        foreach($key in $Unknown){$values['_unknown:instance:'+$ProbeId+':'+$key]=$true}
        $instances.Add([M4D.Admin.Common.Query.QueryRecord]::new(($ProbeId+':'+$i),$values));$i++
    }
    return [M4D.Admin.Common.Query.QueryCollection]::new($instances,$Complete)
}
function New-CollectionRecord([string]$Id,$Collections=@{}){
    $values=@{name=$Id};foreach($key in $Collections.Keys){$values['_instances:probe:'+$key]=$Collections[$key]}
    return (New-FixtureRecord $Id $values)
}
function New-Clause([string]$Field,[string]$Operator,$Value){return [pscustomobject]@{Kind='Clause';Clause=[pscustomobject]@{Field=$Field;Operator=$Operator;Value=$Value}}}
function New-CollectionNode([string]$ProbeId,[string]$Quantifier,[object[]]$Clauses){return [pscustomobject]@{Kind='Collection';CollectionField=('probe:'+$ProbeId);Quantifier=$Quantifier;Children=@([pscustomobject]@{Kind='All';Children=@($Clauses)})}}
function Get-Verdicts($Recipe,$Records){$compiled=ConvertTo-DomeniaCompiledQuery $Recipe;$out=@{};foreach($record in $Records){$out[$record.Id]=[string]$compiled.Evaluate($record.Values)};return $out}
$disks=@(
    (New-CollectionRecord 'pc-a' @{'disk.volumes'=(New-FixtureCollection 'disk.volumes' @(@{DeviceID='C:';FreeSpace=500000000},@{DeviceID='D:';FreeSpace=50000000000}))}),
    (New-CollectionRecord 'pc-b' @{'disk.volumes'=(New-FixtureCollection 'disk.volumes' @(@{DeviceID='C:';FreeSpace=50000000000},@{DeviceID='D:';FreeSpace=500000000}))}),
    (New-CollectionRecord 'pc-c' @{'disk.volumes'=(New-FixtureCollection 'disk.volumes' @())}),
    (New-CollectionRecord 'pc-d' @{'disk.volumes'=(New-FixtureCollection 'disk.volumes' @(@{DeviceID='C:';FreeSpace=50000000000}) -Complete $false)}),
    (New-CollectionRecord 'pc-e'),
    (New-CollectionRecord 'pc-f' @{'disk.volumes'=(New-FixtureCollection 'disk.volumes' @(@{DeviceID='C:'}) -Unknown @('FreeSpace'))}))
$lowFree=New-Clause 'instance:disk.volumes:FreeSpace' 'Less' 1000000000;$systemDrive=New-Clause 'instance:disk.volumes:DeviceID' 'Equal' 'C:'
$same=Get-Verdicts (New-DomeniaQueryRecipe -Expression (New-CollectionNode 'disk.volumes' 'Any' @($systemDrive,$lowFree))) $disks
Expect ($same['pc-a'] -ceq 'Match' -and $same['pc-b'] -ceq 'NoMatch' -and $same['pc-c'] -ceq 'NoMatch' -and $same['pc-d'] -ceq 'Unknown' -and $same['pc-e'] -ceq 'Unknown' -and $same['pc-f'] -ceq 'Unknown') 'two criteria on the same volume: only the workstation whose C: is full matches'
$separate=Get-Verdicts (New-DomeniaQueryRecipe -Expression ([pscustomobject]@{Kind='All';Children=@((New-CollectionNode 'disk.volumes' 'Any' @($systemDrive)),(New-CollectionNode 'disk.volumes' 'Any' @($lowFree)))})) $disks
Expect ($separate['pc-a'] -ceq 'Match' -and $separate['pc-b'] -ceq 'Match') 'two separate collections may be satisfied by two different volumes: the difference is explicit'
$all=Get-Verdicts (New-DomeniaQueryRecipe -Expression (New-CollectionNode 'disk.volumes' 'All' @((New-Clause 'instance:disk.volumes:FreeSpace' 'Greater' 1000000000)))) $disks
Expect ($all['pc-a'] -ceq 'NoMatch' -and $all['pc-c'] -ceq 'Match' -and $all['pc-d'] -ceq 'Unknown' -and $all['pc-e'] -ceq 'Unknown') 'all instances: a partial read never proves that every volume qualifies'
$none=Get-Verdicts (New-DomeniaQueryRecipe -Expression (New-CollectionNode 'disk.volumes' 'None' @($lowFree))) $disks
Expect ($none['pc-a'] -ceq 'NoMatch' -and $none['pc-b'] -ceq 'NoMatch' -and $none['pc-c'] -ceq 'Match' -and $none['pc-d'] -ceq 'Unknown' -and $none['pc-f'] -ceq 'Unknown') 'no instance: a partial read or an unreadable value stays unknown'
$software=@(
    (New-CollectionRecord 'pc-x' @{'soft.installed'=(New-FixtureCollection 'soft.installed' @(@{ProgramId='p1';Name='7-Zip';Version='19.00'},@{ProgramId='p2';Name='Firefox';Version='118.0'}))}),
    (New-CollectionRecord 'pc-y' @{'soft.installed'=(New-FixtureCollection 'soft.installed' @(@{ProgramId='p3';Name='7-Zip';Version='23.01'}))}),
    (New-CollectionRecord 'pc-z' @{'soft.installed'=(New-FixtureCollection 'soft.installed' @(@{ProgramId='p4';Name='7-Zip';Version='23.01'},@{ProgramId='p5';Name='Outil interne';Version='19.1'}))}))
$sevenZip=New-Clause 'instance:soft.installed:Name' 'Equal' '7-Zip';$oldVersion=New-Clause 'instance:soft.installed:Version' 'StartsWith' '19.'
$sameSoftware=Get-Verdicts (New-DomeniaQueryRecipe -Expression (New-CollectionNode 'soft.installed' 'Any' @($sevenZip,$oldVersion))) $software
$anySoftware=Get-Verdicts (New-DomeniaQueryRecipe -Expression ([pscustomobject]@{Kind='All';Children=@((New-CollectionNode 'soft.installed' 'Any' @($sevenZip)),(New-CollectionNode 'soft.installed' 'Any' @($oldVersion)))})) $software
Expect ($sameSoftware['pc-x'] -ceq 'Match' -and $sameSoftware['pc-y'] -ceq 'NoMatch' -and $sameSoftware['pc-z'] -ceq 'NoMatch' -and $anySoftware['pc-z'] -ceq 'Match') 'name and version are checked on the same installed application'
$noSoftware=Get-Verdicts (New-DomeniaQueryRecipe -Expression (New-CollectionNode 'soft.installed' 'None' @($sevenZip))) $software
Expect ($noSoftware['pc-x'] -ceq 'NoMatch' -and $noSoftware['pc-y'] -ceq 'NoMatch') 'no installed copy is expressed with None'
Reject {ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Expression (New-CollectionNode 'soft.installed' 'Any' @($lowFree)))} 'a collection only accepts properties of its own instances'
Reject {ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Expression ([pscustomobject]@{Kind='All';Children=@($sevenZip)}))} 'an instance property outside its collection is refused'
Reject {ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Expression (New-CollectionNode 'soft.installed' 'Some' @($sevenZip)))} 'only Any, All and None quantifiers exist'
$installed=Get-DomeniaProbe 'soft.installed'
Expect ($null -ne $installed -and $installed.Class -ceq 'Win32_InstalledWin32Program' -and $installed.Mode -ceq 'All' -and @($installed.Properties) -contains 'Version' -and -not (Test-DomeniaMsiProviderClass $installed.Class)) 'installed applications come from the inventory provider, never from Windows Installer'
Expect (@(Get-DomeniaQueryInstanceFields|Where-Object{$_.ProbeId -eq 'soft.installed'}).Count -eq 4) 'every installed application property can be used in a collection'
# End-to-end from a stored observation: the typed instances become a complete collection.
$now=[datetime]::UtcNow
$fleet=[pscustomobject]@{Groups=@();Machines=@([pscustomobject]@{name='PC-X';object_guid='cccccccc-0000-4000-8000-000000000003';distinguished_name='CN=PC-X,DC=example,DC=test';gid='';st='A';logon=''})}
$probeResult=[pscustomobject]@{Count=2;CheckedUtc=$now.AddMinutes(-5).ToString('o');Error='';Truncated=$false;Instances=@([pscustomobject]@{Id='Win32_InstalledWin32Program.ProgramId="p1"';Values=[pscustomobject]@{ProgramId='p1';Name='7-Zip';Vendor='Igor Pavlov';Version='19.00'}},[pscustomobject]@{Id='Win32_InstalledWin32Program.ProgramId="p2"';Values=[pscustomobject]@{ProgramId='p2';Name='Firefox';Vendor='Mozilla';Version='118.0'}})}
$observations=@{'cn=pc-x,dc=example,dc=test'=[pscustomobject]@{Guid='cccccccc-0000-4000-8000-000000000003';Probes=[pscustomobject]@{'soft.installed'=$probeResult}}}
$stored=ConvertTo-DomeniaQueryRecords -Fleet $fleet -Observations $observations -NowUtc $now
$collection=$stored[0].Values['_instances:probe:soft.installed']
$softwareRecipe=New-DomeniaQueryRecipe -Name 'Ancien 7-Zip' -Expression (New-CollectionNode 'soft.installed' 'Any' @($sevenZip,$oldVersion))
Expect ($collection.Complete -and $collection.Instances.Count -eq 2 -and (ConvertTo-DomeniaCompiledQuery $softwareRecipe).Evaluate($stored[0].Values) -eq [M4D.Admin.Common.Query.MatchState]::Match) 'stored application instances keep their properties together'
$probeResult.Truncated=$true;$stored=ConvertTo-DomeniaQueryRecords -Fleet $fleet -Observations $observations -NowUtc $now
Expect ((ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Expression (New-CollectionNode 'soft.installed' 'None' @($sevenZip)))).Evaluate($stored[0].Values) -eq [M4D.Admin.Common.Query.MatchState]::NoMatch -and (ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Expression (New-CollectionNode 'soft.installed' 'None' @((New-Clause 'instance:soft.installed:Name' 'Equal' 'Absent'))))).Evaluate($stored[0].Values) -eq [M4D.Admin.Common.Query.MatchState]::Unknown) 'a truncated list can prove a presence but never an absence'
$probeResult.Truncated=$false
# Paged SQL path: collection verdicts are projected per workstation, then reused by the engine.
$nodes=@(Get-DomeniaQueryCollectionNodes $softwareRecipe)
$projections=@(ConvertTo-DomeniaQueryCollectionProjections -Observations @([pscustomobject]@{Guid='cccccccc-0000-4000-8000-000000000003';Family='Probe:soft.installed';Status='Success';Data=[pscustomobject]@{Probes=[pscustomobject]@{'soft.installed'=$probeResult}}}) -Nodes $nodes -NowUtc $now)
$projected=Add-DomeniaQueryCollectionProjectionRecords -Records (ConvertTo-DomeniaQueryRecords -Fleet $fleet -Observations @{} -NowUtc $now) -Projections $projections
Expect ($nodes.Count -eq 1 -and $projections.Count -eq 1 -and $projections[0].Coverage -ceq 'Disponible' -and $projections[0].InstanceCount -eq 2 -and (ConvertTo-DomeniaCompiledQuery $softwareRecipe).Evaluate($projected[0].Values) -eq [M4D.Admin.Common.Query.MatchState]::Match) 'the projected verdict of the same-instance collection is reused without reloading instances'
# Builder: a collection groups the instance criteria under one node.
$tree=Edit-DomeniaQueryExpression -Recipe (New-DomeniaQueryRecipe) -Path '' -Operation Add -Node ([pscustomobject]@{Kind='Collection';CollectionField='probe:soft.installed';Quantifier='Any';Children=@([pscustomobject]@{Kind='All';Children=@()})})
$tree=Edit-DomeniaQueryExpression -Recipe $tree -Path '/0' -Operation Add -Node $sevenZip
$tree=Edit-DomeniaQueryExpression -Recipe $tree -Path '/0' -Operation Add -Node $oldVersion
$outline=@(Get-DomeniaQueryExpressionOutline $tree.Expression)
Expect (@($outline|Where-Object{$_.Kind -eq 'Clause' -and $_.CollectionProbe -ceq 'soft.installed'}).Count -eq 2 -and (ConvertTo-DomeniaCompiledQuery $tree).Evaluate($software[2].Values) -eq [M4D.Admin.Common.Query.MatchState]::NoMatch) 'the builder adds both criteria inside the same collection'
Reject {Edit-DomeniaQueryExpression -Recipe $tree -Path '/0' -Operation Add -Node (New-Clause 'name' 'Equal' 'PC')} 'the builder refuses a workstation criterion inside an instance collection'

$report=[pscustomobject]@{Status='PASS';Assertions=$script:checks;SourceMode=[bool]$QuerySource;ElapsedSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,3);PowerShell=$PSVersionTable.PSVersion.ToString();Scope='Actual models, worker factories and click handlers with inert controls; remote WMI cmdlets replaced by fixtures; no network, AD, WMI or WPF'}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Compress
