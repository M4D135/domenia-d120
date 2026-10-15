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

# @@NEXT-SECTION@@

$report=[pscustomobject]@{Status='PASS';Assertions=$script:checks;SourceMode=[bool]$QuerySource;ElapsedSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,3);PowerShell=$PSVersionTable.PSVersion.ToString();Scope='Actual models, worker factories and click handlers with inert controls; remote WMI cmdlets replaced by fixtures; no network, AD, WMI or WPF'}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Compress
