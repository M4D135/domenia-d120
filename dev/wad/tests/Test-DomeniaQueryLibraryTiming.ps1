#requires -Version 5.1
# Point 61 qualification harness. It checks that the delivered models are prepared by the QueryLibrary worker instead
# of the UI thread, then measures each step on the machine that runs it. Durations are reported as measured here;
# only a run under Windows PowerShell 5.1 can qualify the gain. No network, AD, WMI, database or WPF.
[CmdletBinding()]
param([switch]$QuerySource,[string]$ReportPath='',[ValidateRange(1,20)][int]$Repeat=3)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
if($QuerySource){Add-Type -Path (Join-Path (Split-Path -Parent $wad) 'vendor/m4d-admin-common/src/Query/QueryEngine.cs')}else{Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')}
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model','Query.Worker','Search.Model','Query.UI')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$script:checks=0
function Expect([bool]$Good,[string]$Name){$script:checks++;if(-not $Good){throw $Name}}
function Measure-Step([scriptblock]$Action){$clock=[Diagnostics.Stopwatch]::StartNew();$null=& $Action;$clock.Stop();return [Math]::Round($clock.Elapsed.TotalMilliseconds,1)}
function Get-Median([double[]]$Values){$sorted=@($Values|Sort-Object);if(-not $sorted.Count){return 0};return [double]$sorted[[int][Math]::Floor(($sorted.Count-1)/2)]}
function Invoke-FreshWorker([string]$Code,$Payload){
    # Same shape as Start-UiTask: a new runspace that dot-sources the versioned models, so nothing is pre-cached.
    $runspace=[runspacefactory]::CreateRunspace();$runspace.ApartmentState='STA';$runspace.Open();$shell=$null
    try{
        $runspace.SessionStateProxy.SetVariable('Payload',$Payload)
        $shell=[powershell]::Create();$shell.Runspace=$runspace;[void]$shell.AddScript($Code)
        $clock=[Diagnostics.Stopwatch]::StartNew();$output=@($shell.Invoke());$clock.Stop()
        if(-not $output.Count){throw ('Worker sans résultat : '+[string](@($shell.Streams.Error)|Select-Object -First 1))}
        return [pscustomobject]@{Result=$output[-1];Ms=[Math]::Round($clock.Elapsed.TotalMilliseconds,1)}
    }finally{if($null -ne $shell){$shell.Dispose()};$runspace.Dispose()}
}
$saved=@(for($i=0;$i -lt 125;$i++){New-DomeniaQueryRecipe -Id ('timing.'+$i) -Name ('Requête personnelle '+$i)})

# 1. Search startup path: AD views and saved recipes only, never the delivered models.
$startupMs=Measure-Step {$script:Light=@(Get-DomeniaSearchQueryCatalog -Saved $saved)}
Expect (($null -eq $script:DomeniaQueryTemplateCatalog) -and $script:Light.Count -eq 130) 'The Search startup list does not build the delivered models on the caller'

# 2. Former UI-thread cost, measured once cold (first build in this process) then warm (cached).
$coldMs=Measure-Step {$script:Templates=@(Get-DomeniaQueryTemplates)}
$warmMs=Measure-Step {[void]@(Get-DomeniaQueryTemplates)}

# 3. QueryLibrary worker body in fresh runspaces, as the engine runs it.
$workerRuns=@(for($i=0;$i -lt $Repeat;$i++){Invoke-FreshWorker -Code (Get-DomeniaQueryLibraryWorkerCode) -Payload ([pscustomobject]@{ModuleRoot=$modules;Saved=$saved})})
$rows=@($workerRuns[0].Result.Rows)
Expect ($rows.Count -eq ($script:Templates.Count+125)) 'The worker prepares every delivered model plus the saved recipes'

# 4. UI-thread work once the rows arrive: publish the prepared models, rebuild the Search list, page the library.
$script:SearchUiInitialized=$false
$publishMs=Measure-Step {Set-DomeniaPreparedQueryTemplateRows -Rows $rows}
$prepared=@(Get-DomeniaPreparedQueryTemplates)
Expect ($prepared.Count -eq $script:Templates.Count -and [string]$script:DomeniaQueryTemplateStatus -eq '') 'Prepared models are published once for Search and the library'
$searchRuns=@(for($i=0;$i -lt $Repeat;$i++){Measure-Step {$script:Full=@(Get-DomeniaSearchQueryCatalog -Saved $saved -Templates $prepared)}})
Expect ($script:Full.Count -eq ($script:Templates.Count+130)) 'The Search list gains every prepared model'
$script:Fake=@{};foreach($name in @('DgQueryLibrary','CmbQueryLibrarySource','CmbQueryLibraryCategory','TxtQueryLibrarySearch','BtnQueryLibraryPrevious','BtnQueryLibraryNext','BtnQueryLibraryUse')){$script:Fake[$name]=[pscustomobject]@{ItemsSource=@();SelectedItem=$null;SelectedIndex=-1;Text='';IsEnabled=$false}}
function Get-DomeniaControl([string]$Name){return $script:Fake[$Name]}
function Set-DomeniaControlText([string]$Name,[string]$Text){$script:LastLabel=$Text}
$script:DomeniaQueryState=[pscustomobject]@{LibraryReady=$true;LibraryOffset=0;LibraryRows=$rows}
$pageRuns=@(for($i=0;$i -lt $Repeat;$i++){$script:Fake.TxtQueryLibrarySearch.Text='';Measure-Step {Update-DomeniaQueryLibrary}})
Expect (@($script:Fake.DgQueryLibrary.ItemsSource).Count -eq 100) 'The library shows a first page of 100 recipes'
$filterRuns=@(for($i=0;$i -lt $Repeat;$i++){$script:Fake.TxtQueryLibrarySearch.Text='memoire';Measure-Step {Update-DomeniaQueryLibrary}})

# 5. Wiring: one background preparation per process, never repeated while pending, and no network operation.
$script:DomeniaQueryTemplateRows=$null;$script:DomeniaQueryTemplatePreparation=$null;$script:Tasks=[Collections.Generic.List[object]]::new()
$script:SessionEpoch=1L;$script:AsyncJobs=[ordered]@{}
# Same contract as the engine: a started task is listed in AsyncJobs until Complete-UiTasks removes it.
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$SuccessHandler,$ErrorHandler,$TimeoutSeconds,$TaskClass);$id='fixture-'+($script:Tasks.Count+1);$script:Tasks.Add([pscustomobject]@{Id=$id;OperationId=$OperationId;Payload=$Payload;State=$CallbackState;ReplaceKey=$ReplaceKey;TaskClass=$TaskClass;Success=$SuccessHandler});$script:AsyncJobs[$id]=$script:Tasks[$script:Tasks.Count-1];return $id}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties);return $Result}
function Add-DomeniaRuntimeMetric {param($Provenance,$OperationId,$DurationMs);$script:Metric=[pscustomobject]@{Provenance=$Provenance;OperationId=$OperationId;DurationMs=$DurationMs}}
Request-DomeniaQueryTemplatePreparation;Request-DomeniaQueryTemplatePreparation
Expect ($script:Tasks.Count -eq 1 -and $script:Tasks[0].OperationId -ceq 'QueryLibrary' -and $script:Tasks[0].TaskClass -ceq 'Background' -and @($script:Tasks[0].Payload.Saved).Count -eq 0) 'A single local background preparation is admitted'
Expect ([string]$script:DomeniaQueryTemplateStatus -like 'Modèles livrés en préparation*') 'Search states that the delivered models are still being prepared'
# A callback dropped by the engine (new session or database switch) never leaves the models blocked in preparation.
$script:SessionEpoch=2L
Request-DomeniaQueryTemplatePreparation
Expect ($script:Tasks.Count -eq 2 -and [long]$script:DomeniaQueryTemplatePreparation.Epoch -eq 2L -and [string]$script:DomeniaQueryTemplatePreparation.JobId -ceq $script:Tasks[1].Id) 'A preparation started before a new session is replaced by a new one'
$script:AsyncJobs.Remove($script:Tasks[1].Id)
Request-DomeniaQueryTemplatePreparation
Expect ($script:Tasks.Count -eq 3) 'A preparation whose task ended without its callback is started again'
& $script:Tasks[0].Success -Result ([pscustomobject]@{Rows=$rows}) -State $script:Tasks[0].State
Expect (@(Get-DomeniaPreparedQueryTemplates).Count -eq 0) 'A late result of a replaced preparation is ignored'
$script:AsyncJobs.Remove($script:Tasks[2].Id)
& $script:Tasks[2].Success -Result ([pscustomobject]@{Rows=$rows}) -State $script:Tasks[2].State
Expect (@(Get-DomeniaPreparedQueryTemplates).Count -eq $script:Templates.Count -and $script:Metric.OperationId -ceq 'QueryTemplates:Publish') 'Completion publishes the models and records its UI-thread duration'
Request-DomeniaQueryTemplatePreparation
Expect ($script:Tasks.Count -eq 3) 'Prepared models are never rebuilt in the same process'

$windows51=(($PSVersionTable.PSVersion.Major -eq 5) -and ([string]$PSVersionTable.PSEdition -ne 'Core'))
$measurements=[ordered]@{
    SearchStartupListMs=$startupMs
    TemplatesColdBuildMs=$coldMs
    TemplatesWarmBuildMs=$warmMs
    LibraryWorkerFreshRunspaceMedianMs=(Get-Median @($workerRuns|ForEach-Object{[double]$_.Ms}))
    PreparedModelsPublishMs=$publishMs
    SearchListWithPreparedModelsMedianMs=(Get-Median $searchRuns)
    LibraryFirstPageMedianMs=(Get-Median $pageRuns)
    LibraryFilteredPageMedianMs=(Get-Median $filterRuns)
}
$report=[pscustomobject]@{Suite='Domenia.QueryLibraryTiming';Status='PASS';Assertions=$script:checks;PowerShell=$PSVersionTable.PSVersion.ToString();Edition=[string]$PSVersionTable.PSEdition;WindowsPowerShell51=$windows51;Repeat=$Repeat;Templates=$script:Templates.Count;SavedRecipes=125;Measurements=[pscustomobject]$measurements
    Interpretation='Avant le point 61, Recherche construisait les modèles sur le fil UI à son initialisation (TemplatesColdBuildMs). Désormais le fil UI ne paie que SearchStartupListMs puis PreparedModelsPublishMs et SearchListWithPreparedModelsMedianMs ; la construction se fait dans le worker QueryLibrary (LibraryWorkerFreshRunspaceMedianMs).'
    Qualification=$(if($windows51){'Mesure prise sous Windows PowerShell 5.1 : à rattacher au ZIP qualifié.'}else{'Mesure hors Windows PowerShell 5.1 : non qualifiante.'})
    Scope='Actual models, worker body, Search mapping and library paging with inert controls; WPF rendering is not measured'}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 4
