#requires -Version 5.1
# W13 (points 118, 121, 123, 124): traces of the operations, explained slowness, operations panel and redacted
# diagnostic. The real rule and adapter modules are dot-sourced with fake jobs; no worker, no domain, no network.
# The engine hooks of Domenia-Core.ps1 are checked on its syntax tree; the panel view is loaded by XamlReader (STA).
[CmdletBinding()]
param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$modules=Join-Path $wad 'modules'
$script:Checks=New-Object 'System.Collections.Generic.List[object]'
function Check-Suite {param([string]$Name,[scriptblock]$Code)
    try{if(-not (& $Code)){throw 'Condition non verifiee.'};$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Detail=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Detail=$_.Exception.Message})}
}
foreach($file in @('Domenia-Common.Model.ps1','Domenia-Relations.Model.ps1','Domenia-Access.Model.ps1','Domenia-Shell.Model.ps1','Domenia-Guard.Model.ps1','Domenia-Observability.Model.ps1','Domenia-Observability.UI.ps1')){. (Join-Path $modules $file)}
$script:TraceLines=New-Object 'System.Collections.Generic.List[string]'
function Write-DomeniaTrace {param([string]$Text,[string]$Area='Tache') $script:TraceLines.Add('['+$Area+'] '+$Text)}
function Write-AppLog {param($Text,$Level)}
function Set-Status {param($Text,$Level)}
function Protect-DomeniaLogText {param([string]$Text) return (Protect-DomeniaSecretText $Text)}
function Get-DomeniaRuntimeMetricSummary {param($Provenance,$Prefix) return [pscustomobject]@{Count=4;P50=12.0;P95=48.0;Max=60.0}}
function New-TraceJob {
    param([string]$Id='job1',[string]$Correlation=('a'*32),[string]$Name='GPUpdate PC-SENTINEL-01',[string]$Operation='ComputerGpUpdate',[switch]$Write)
    return [pscustomobject]@{Id=$Id;Name=$Name;OperationId=$Operation;CorrelationId=$Correlation;IsWrite=[bool]$Write;Started=(Get-Date).AddSeconds(-2);QueuedAt=(Get-Date).AddSeconds(-3);SuccessHandler='Complete-DomeniaComputerToolUi';Demo=$false;Isolated=$false;State='Running'}
}
function Reset-TraceState {$script:DomeniaTraceRing=$null;$script:DomeniaSlowEvents=$null;$script:DomeniaUiWork=$null;$script:DomeniaLastStall=$null;$script:AccessCurrentJob=$null;$script:DomeniaDirectoryReads=@{};$script:TraceLines.Clear()}

Check-Suite 'P123 : une tache sans contexte ouvre sa propre trace avec sa demande' {
    Reset-TraceState
    $job=New-TraceJob
    $trace=Start-DomeniaJobTrace -Job $job
    ($job.TraceId -ceq ('a'*32)) -and ($trace.Events.Count -eq 1) -and ([string]$trace.Events[0].Phase -eq 'Request') -and ($trace.OpenJobs.Count -eq 1)
}
Check-Suite 'P123 : une tache lancee depuis le rappel d une autre rejoint sa trace' {
    Reset-TraceState
    $first=New-TraceJob;[void](Start-DomeniaJobTrace -Job $first)
    $script:AccessCurrentJob=$first
    $next=New-TraceJob -Id 'job2' -Correlation ('b'*32) -Operation 'LocalIndexRead'
    [void](Start-DomeniaJobTrace -Job $next)
    $script:AccessCurrentJob=$null
    ($next.TraceId -ceq $first.TraceId) -and ((Get-DomeniaTraceRing).Count -eq 1) -and ((Get-DomeniaTraceRing)[$first.TraceId].OpenJobs.Count -eq 2)
}
Check-Suite 'P123 : recherche et fiche partagent l identifiant de leur contexte local' {
    Reset-TraceState
    $request='11111111-2222-3333-4444-555555555555'
    $job=New-TraceJob -Operation 'GlobalSearch'
    [void](Start-DomeniaJobTrace -Job $job -CallbackState ([pscustomobject]@{StoreContext=[pscustomobject]@{RequestId=$request}}))
    $collector=[hashtable]::Synchronized(@{Started=$false})
    $script:DomeniaDirectoryReads=@{x=[pscustomobject]@{Collector=$collector;Context=[pscustomobject]@{RequestId='99999999-2222-3333-4444-555555555555'}}}
    $object=New-TraceJob -Id 'job3' -Correlation ('c'*32) -Operation 'OpenAdObject'
    [void](Start-DomeniaJobTrace -Job $object -Payload ([pscustomobject]@{DirectoryReadState=$collector}))
    $explicit=New-TraceJob -Id 'job4' -Correlation ('d'*32) -Operation 'LocalIndexRead'
    [void](Start-DomeniaJobTrace -Job $explicit -RequestedTraceId $request)
    ($job.TraceId -ceq $request) -and ($object.TraceId -ceq '99999999-2222-3333-4444-555555555555') -and ($explicit.TraceId -ceq $request)
}
Check-Suite 'P123 : lecture locale et publication d une demande sont ajoutees a sa trace, une demande inconnue est ignoree' {
    Reset-TraceState
    $request='11111111-2222-3333-4444-555555555555'
    $job=New-TraceJob -Operation 'GlobalSearch';[void](Start-DomeniaJobTrace -Job $job -RequestedTraceId $request)
    Add-DomeniaRequestTraceEvent -RequestId $request -Phase 'StoreRead' -Volume 100 -DurationMs 30
    Add-DomeniaRequestTraceEvent -RequestId $request -Phase 'StoreRead' -Volume 50 -DurationMs 0
    Add-DomeniaRequestTraceEvent -RequestId 'inconnue-0000' -Phase 'StoreRead' -Volume 1
    Add-DomeniaRequestTraceEvent -RequestId $request -Phase 'Publish' -Volume 150 -Detail 'lignes transmises à la liste' -Final
    $trace=(Get-DomeniaTraceRing)[$request]
    $store=@($trace.Events|Where-Object{$_.Phase -eq 'StoreRead'})
    ((Get-DomeniaTraceRing).Count -eq 1) -and ($store.Count -eq 1) -and ([int]$store[0].Volume -eq 150) -and ($script:TraceLines.Count -eq 1) -and ($script:TraceLines[0].Contains('[trace 11111111]'))
}
Check-Suite 'P123/P121 : fin de tache : file, collecte, validation, publication puis fin, une seule fois' {
    Reset-TraceState
    $job=New-TraceJob;[void](Start-DomeniaJobTrace -Job $job)
    $slow=Register-DomeniaJobPublication -Job $job -PublishMs 40 -Volume 3 -ThresholdMs 120 -ValidateMs 2
    $trace=Complete-DomeniaJobTrace -Job $job -Outcome 'Succeeded' -ValidateMs 2
    $again=Complete-DomeniaJobTrace -Job $job -Outcome 'Failed'
    $phases=@($trace.Events|ForEach-Object{[string]$_.Phase})
    $summary=Get-DomeniaOperationTraceSummary -Trace $trace
    ($slow -eq '') -and ($null -eq $again) -and (($phases -join ',') -eq 'Request,Queue,Collect,Validate,Publish,End') -and ($summary.Outcome -eq 'Succeeded') -and ([double]@($trace.Events|Where-Object{$_.Phase -eq 'Queue'})[0].DurationMs -ge 900) -and ($script:TraceLines.Count -eq 1)
}
Check-Suite 'P123 : la ligne de Domenia.log ne porte ni le nom de la cible ni le nom affiche' {
    $line=[string]$script:TraceLines[0]
    $line.Contains('[trace aaaaaaaa]') -and $line.Contains('tâches aaaaaaaa') -and $line.Contains('ComputerGpUpdate') -and (-not $line.Contains('PC-SENTINEL-01'))
}
Check-Suite 'P121 : callback lent : explication par operation, phases, volume et traitement, conservee pour la sante' {
    Reset-TraceState
    $job=New-TraceJob -Name 'Recherche dans l annuaire' -Operation 'GlobalSearch';$job.SuccessHandler='Complete-DomeniaGlobalSearchUi'
    [void](Start-DomeniaJobTrace -Job $job)
    $text=Register-DomeniaJobPublication -Job $job -PublishMs 850 -Volume 1240 -ThresholdMs 120 -ValidateMs 3
    [void](Complete-DomeniaJobTrace -Job $job -Outcome 'Succeeded' -ValidateMs 3)
    $lines=@(Get-DomeniaSlowEventLines -Maximum 3)
    $text.StartsWith('Interface lente : ') -and $text.Contains('Complete-DomeniaGlobalSearchUi') -and $text.Contains('1240 éléments') -and $text.Contains('Trace aaaaaaaa') -and ($lines.Count -eq 1) -and (@($script:DomeniaUiWork).Count -eq 1)
}
Check-Suite 'P121 : retard de l interface attribue au travail suivi, une seule fois en cinq secondes' {
    Reset-TraceState
    $now=Get-DomeniaTraceNow
    Register-DomeniaUiWork -Name 'Lecture objet Utilisateur' -OperationId 'OpenAdObject' -Handler 'Complete-DomeniaOpenObjectTaskUi' -StartMs ($now-900) -EndMs ($now-10)
    $first=Register-DomeniaDispatcherLateness -LateMs 800
    $second=Register-DomeniaDispatcherLateness -LateMs 700
    $small=Register-DomeniaDispatcherLateness -LateMs 120
    ($null -ne $first) -and [bool]$first.Attributed -and $first.Text.Contains('Complete-DomeniaOpenObjectTaskUi') -and ($null -eq $second) -and ($null -eq $small) -and (@($script:DomeniaSlowEvents).Count -eq 1) -and ($script:TraceLines[0].StartsWith('[Lenteur]'))
}
Check-Suite 'P118 : dernieres operations : etat par symbole et mot, etape dominante, conseil sans relance automatique' {
    Reset-TraceState
    $ok=New-TraceJob;[void](Start-DomeniaJobTrace -Job $ok);[void](Complete-DomeniaJobTrace -Job $ok -Outcome 'Succeeded')
    $ko=New-TraceJob -Id 'job2' -Correlation ('b'*32) -Operation 'LapsRead';[void](Start-DomeniaJobTrace -Job $ko);[void](Complete-DomeniaJobTrace -Job $ko -Outcome 'Failed' -Category 'AccessDenied')
    $run=New-TraceJob -Id 'job3' -Correlation ('c'*32) -Operation 'SessionsList';[void](Start-DomeniaJobTrace -Job $run)
    $rows=@(Get-DomeniaRecentTraceRows -Maximum 20)
    $failed=@($rows|Where-Object{$_.Reference -eq 'bbbbbbbb'})[0];$open=@($rows|Where-Object{$_.Reference -eq 'cccccccc'})[0]
    ($rows.Count -eq 3) -and $failed.State.Contains('Échec') -and $failed.State.StartsWith([string][char]0x2715) -and $failed.Detail.Contains('compte autorisé') -and $failed.Detail.Contains('bbbbbbbb') -and $open.State.Contains('En cours') -and ($rows[0].Reference -eq 'cccccccc')
}
Check-Suite 'P124 : diagnostic de la session : aucun nom de cible, aucun message, aucun secret' {
    Reset-TraceState
    $job=New-TraceJob -Name 'Lecture LAPS PC-SENTINEL-01 pwd=SECRET_SENTINEL_W13';[void](Start-DomeniaJobTrace -Job $job);[void](Complete-DomeniaJobTrace -Job $job -Outcome 'Failed' -Category 'AccessDenied')
    $script:DomeniaErrorOccurrences=@{('System.UnauthorizedAccessException|Acces refuse a CN=PC-SENTINEL-01,OU=Postes pwd=SECRET_SENTINEL_W13|C:\Domenia\wad\Domenia-Core.ps1:2345')=[pscustomobject]@{Code='INC-7F3A';Count=2;LastWrite=(Get-Date)}}
    $script:DomeniaRuntimeMetrics=@{'Ldap|GlobalSearch'=(New-Object 'System.Collections.Generic.Queue[double]')};$script:DomeniaRuntimeMetrics['Ldap|GlobalSearch'].Enqueue(120.0)
    $script:Version='1.0';$script:MasterBuild='2026.10.13-DOMENIA-1.0-RC1.17.7-D120';$script:CurrentUiProfile='Tech';$script:AsyncJobs=@{};$script:DetachedReadJobs=@();$script:Persistence=$null;$script:ReceiptPending=0
    $session=New-DomeniaSessionDiagnostic
    $json=[string]$session.Json
    (-not $json.Contains('SENTINEL')) -and $json.Contains('INC-7F3A') -and $json.Contains('Domenia-Core.ps1:2345') -and $json.Contains('ComputerGpUpdate') -and $json.Contains('AccessDenied') -and $session.Preview.Contains('Jamais inclus')
}
# Engine hooks, checked on the syntax tree of the real sources.
function Get-SuiteFunctionText {param([string]$Path,[string]$Name)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw $errors[0].Message}
    $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($nodes.Count -ne 1){throw ('Definition absente : '+$Name)}
    return [string]$nodes[0].Extent.Text
}
$core=Join-Path $wad 'Domenia-Core.ps1'
Check-Suite 'P123 : Start-UiTask ouvre la trace avant file ou envoi, et la ferme sur un refus' {
    $t=Get-SuiteFunctionText $core 'Start-UiTask'
    $t.Contains('[string]$TraceId') -and ($t.IndexOf('Start-DomeniaJobTrace') -lt $t.IndexOf("if (`$admission -eq 'Queue')")) -and $t.Contains("Complete-DomeniaJobTrace -Job `$job -Outcome 'Refused' -NotDispatched")
}
Check-Suite 'P123 : Complete-UiTasks ferme la trace sur chaque fin (arret, remplacement, reussite, echec)' {
    $t=Get-SuiteFunctionText $core 'Complete-UiTasks'
    ([regex]::Matches($t,'Complete-DomeniaJobTrace').Count -ge 4) -and $t.Contains('Register-DomeniaJobPublication') -and $t.Contains('Get-DomeniaOutputVolume') -and $t.Contains("'InterfaceCallback'")
}
Check-Suite 'P123 : detachement et retrait de file ecrivent la fin de la trace' {
    (Get-SuiteFunctionText $core 'Detach-DomeniaReadUiTask').Contains('Complete-DomeniaJobTrace') -and (Get-SuiteFunctionText (Join-Path $modules 'Domenia-Engine.UI.ps1') 'Remove-DomeniaQueuedTask').Contains('Complete-DomeniaJobTrace') -and (Get-SuiteFunctionText $core 'Request-UiTaskStop').Contains('-TraceOutcome')
}
Check-Suite 'P123 : lecture locale relue et publication de la recherche reliees a la demande' {
    $store=Join-Path $modules 'Domenia-DirectoryStore.UI.ps1'
    (Get-SuiteFunctionText $store 'Complete-DomeniaDirectoryStoreBatch').Contains("-Phase 'StoreRead'") -and (Get-SuiteFunctionText $store 'Invoke-DomeniaDirectoryStoreTick').Contains("-Phase 'Publish'") -and (Get-SuiteFunctionText (Join-Path $modules 'Domenia-Storage.UI.ps1') 'Request-DomeniaStoreRead').Contains('-TraceId ([string]$Context.RequestId)')
}
Check-Suite 'P121 : le battement de garde et les minuteurs alimentent l attribution des retards' {
    (Get-SuiteFunctionText (Join-Path $modules 'Domenia-Guard.UI.ps1') 'Initialize-DomeniaGuard').Contains('Register-DomeniaDispatcherLateness') -and (Get-SuiteFunctionText (Join-Path $modules 'Domenia-Engine.UI.ps1') 'Invoke-DomeniaTimerTick').Contains('Register-DomeniaUiWork')
}
Check-Suite 'P124 : export du diagnostic : apercu complet, confirmation, puis fichier choisi' {
    $t=Get-SuiteFunctionText (Join-Path $modules 'Domenia-Dossier.UI.ps1') 'Export-DomeniaTechnicalDossier'
    $t.Contains('New-DomeniaSessionDiagnostic') -and ($t.IndexOf('Show-DomeniaDialog') -lt $t.IndexOf('Confirm-Action')) -and ($t.IndexOf('Confirm-Action') -lt $t.IndexOf('ShowDialog($script:Window)'))
}
Check-Suite 'P118 : vue du panneau : controles nommes, info-bulle egale au texte d aide et au catalogue' {
    [xml]$view=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-Operations.xaml'),[Text.Encoding]::UTF8)
    $help=@(Get-Content -LiteralPath (Join-Path $modules 'Domenia-UX.help.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
    $byName=@{};foreach($entry in $help){$byName[[string]$entry.Name]=$entry}
    $x='http://schemas.microsoft.com/winfx/2006/xaml'
    foreach($name in @('DgOperationsRecent','LblOperationsTrace','BtnOperationsCopyTrace','BtnOperationsJournal','BtnOperationsDiagnostic','LblOperationsHealth')){
        $node=@($view.SelectNodes('//*')|Where-Object{$_.GetAttribute('Name',$x) -eq $name})
        if($node.Count -ne 1){throw ($name+' : '+$node.Count+' occurrence(s)')}
        $tip=[string]$node[0].GetAttribute('ToolTip')
        if((-not $tip) -or ($tip -cne [string]$node[0].GetAttribute('AutomationProperties.HelpText'))){throw ($name+' : info-bulle et texte d aide differents')}
        if(-not [string]$node[0].GetAttribute('AutomationProperties.Name')){throw ($name+' : nom accessible absent')}
        if((-not $byName.ContainsKey($name)) -or ([string]$byName[$name].Text -cne $tip)){throw ($name+' : catalogue d aide absent ou different')}
    }
    $true
}
Check-Suite 'P118/P113 : la vue du panneau se charge et defile en entier (STA)' {
    if([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA){throw 'Fil STA requis : lancer la suite avec -STA.'}
    Add-Type -AssemblyName PresentationFramework
    [xml]$document=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-Operations.xaml'),[Text.Encoding]::UTF8)
    $reader=New-Object Xml.XmlNodeReader $document
    try{$view=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    ($view.Child -is [Windows.Controls.ScrollViewer]) -and ($null -ne $view.FindName('DgOperationsRecent')) -and ($null -ne $view.FindName('BtnOperationsDiagnostic'))
}
$failed=@($script:Checks|Where-Object{-not $_.Passed})
$report=[ordered]@{Suite='Test-DomeniaOperationTrace';Runtime=$PSVersionTable.PSVersion.ToString();Executed=(Get-Date).ToString('o');Passed=$script:Checks.Count-$failed.Count;Failed=$failed.Count;WpfExecuted=$true;NoADAccess=$true;NoNetwork=$true;Tests=$script:Checks.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-trace-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){$script:Checks|Format-Table Name,Passed -AutoSize;Write-Host ('Rapport : '+$ReportPath)}
if($failed.Count){throw ('Tests des traces en echec : '+$failed.Count)}
