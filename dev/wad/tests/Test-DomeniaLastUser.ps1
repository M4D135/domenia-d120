#requires -Version 5.1
<# Tests des fonctions REELLES extraites par AST. Pas de lancement d DOMENIA,
   pas de reseau, aucune ecriture dans le cache, aucune API WPF instanciee.
   Les acces distants, le dispatcher et les controles ont des doublures.
#>
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$corePath=Join-Path $root 'wad\Domenia-Core.ps1'
$source=[IO.File]::ReadAllText($corePath)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if (@($errors).Count -gt 0) { throw ('Syntaxe du coeur : '+$errors[0].Message) }
$names=@('Normalize-LinkComputer','Normalize-LinkUser','Get-DomeniaRunningComputerUserProbe',
 'Clear-DomeniaComputerUserProbeState','Receive-DomeniaComputerUserProbeProgress','Stop-DomeniaComputerUserProbeUi',
 'Request-UiTaskStop','Start-ComputerUserLinkProbe','Queue-DomeniaSelectedObjectOpen','Get-DomeniaLandingView',
 'Complete-DomeniaComputerUserProbeUi','Fail-DomeniaComputerUserProbeUi')
$nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
$definitions=New-Object 'System.Collections.Generic.List[string]'
foreach($name in $names) {
 $found=@($nodes | Where-Object {$_.Name -eq $name})
 if($found.Count -ne 1){throw ('Fonction unique introuvable : '+$name)}
 $definitions.Add($found[0].Extent.Text)
}
. ([scriptblock]::Create(($definitions.ToArray() -join "`n")))
# D120 resync: since RC1.10.7 Queue-DomeniaSelectedObjectOpen delegates the selection identity and its purge
# to Domenia-Selection.UI.ps1 (Enter-DomeniaSelectionContext) and checks Test-DomeniaAccessBusyWrite
# (Domenia-Access.UI.ps1). Import the real closed plan; the UI boundaries are replaced below.
. (Join-Path $root 'wad\Domenia-Modules.ps1')
$script:Results=New-Object 'System.Collections.Generic.List[object]'
function Assert-Test {param([bool]$Value,[string]$Message='Assertion fausse'); if(-not $Value){throw $Message}}
function Test-Case {
 param([string]$Name,[scriptblock]$Action)
 try {Reset-TestState;& $Action | Out-Null;$status='PASS';$detail=''}catch{$status='FAIL';$detail=$_.Exception.Message}
 $script:Results.Add([pscustomobject]@{Name=$Name;Status=$status;Detail=$detail})
 if(-not $Quiet -or $status -eq 'FAIL'){Write-Host ("$status | $Name | $detail")}
}
function Reset-TestState {
 $script:Live=$null
 $script:AsyncJobs=[ordered]@{};$script:SessionEpoch=[long]7;$script:ActiveLinkProbeId='';$script:ActiveLinkProbeComputer=''
 $script:LinkProbeDone=@{};$script:Starts=0;$script:Clears=0;$script:PendingInvokes=0;$script:AssociationRefreshes=0
 $script:SelectedComputer='PC-A';$script:MasterBuild='TEST-R1.3';$script:Messages=New-Object 'System.Collections.Generic.List[string]'
 $script:UiTexts=@{};$script:SelectedObject=[pscustomobject]@{Type='Machine';DN='CN=PC-A,DC=example,DC=test';Name='PC-A'}
 $script:Row=[pscustomobject]@{Type='Machine';DN=$script:SelectedObject.DN;Name='PC-A'}
 $script:SelectionResetDn=$script:SelectedObject.DN;$script:SuppressGridSelectionEvents=$false
 $script:CurrentObjectRequestId='';$script:CurrentObjectRequestDn='';$script:PendingObjectSelection=$null
 $script:Grid=[pscustomobject]@{IsEnabled=$true;SelectedItem=$script:Row;SelectedItems=@($script:Row)};$script:CacheLink=$null;$script:RecordedPayload=$null
 $script:AddedLinks=0
 # Selection identity state read by Domenia-Selection.UI.ps1. No credential: identity from epoch, base and reader.
 $script:SelectionLoad=$null;$script:SelectedObjectGeneration=0L;$script:GlobalSearchGeneration=1;$script:SelectionOpenTimer=$null
 $script:ActiveWriteTaskId='';$script:WriteState='Idle';$script:AsyncEngineClosing=$false;$script:DraftState=$null;$script:AccessState=$null
 $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=test';Server='dc.example.test';BindUser='EXAMPLE\reader';Credential=$null}
}
function Select-FixtureRow {
 param($Row)
 $script:Row=$Row;$script:Grid.SelectedItem=$Row;$script:Grid.SelectedItems=@($Row)
}
function Get-CfgValue {param($Section,$Key,$Default);return $Default}
function Write-AppLog {param($Message,$Level);$script:Messages.Add([string]$Message)}
function Add-DomeniaUiLog {param($Area,$Text,$Level)}
function Set-Status {param($Text,$Level);$script:UiTexts['Status']=[string]$Text}
function Set-DomeniaControlText {param($Name,$Text);$script:UiTexts[$Name]=[string]$Text;return $true}
function Get-CurrentSelectedComputerName {return $script:SelectedComputer}
function Get-ExistingLinkForComputer {param($Computer);return $script:CacheLink}
function Refresh-AssociationContext {param([switch]$SkipResultRefresh);$script:AssociationRefreshes++}
function Update-TaskUi {param([switch]$Force)}
function Get-DomeniaControl {param($Name);if($Name -eq 'DgObjects'){return $script:Grid};return $null}
function Get-DomeniaSelectedGridRow {return $script:Row}
# The old detailed resolver remains isolated from the automatic live scheduler here.
function Stop-DomeniaLiveJob {param($Job)}
function Stop-DomeniaSelectionOpenTimer {}
function Clear-DomeniaCurrentObjectRequest {param($RequestId)}
function Reset-DomeniaSelectionBoundViews {param($Dn,$Type,$Name);$script:Clears++}
function Invoke-DomeniaPendingSelectionOpen {$script:PendingInvokes++}
# UI boundaries of the selection path: no draft, no relations grid, no live probe, no navigation.
function Test-DomeniaDraftNavigation {param($DN,[switch]$Refresh);return $true}
function Restore-DomeniaRefusedSelection {param($DN)}
function Set-DomeniaRelationsGridSelection {}
function Select-DomeniaLiveResult {param([switch]$Force,[switch]$Manual,[switch]$Explicit)}
function Clear-DomeniaLiveProbeIntent {}
function Select-DomeniaWorkspace {param($Workspace,$Inner,$Tab)}
function Clear-Secrets {}
function Set-VisibleTabsForType {param($Type,[switch]$PreserveWorkspace)}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties);return $Result}
function Set-DomeniaItemsSource {param($Name,$Rows);return $true}
function Add-UserMachineLinkIfMissing {param($UserLogin,$Computer,$Source,$Details,$Confidence,$VerifiedInAD);$script:AddedLinks++;return $true}
function Register-DomeniaOperationSample {param($Operation,$Mode,$ItemCount,$DurationMs,$BytesEstimated,$RemoteAttempts,$FallbackTasks,$SuccessCount)}
function New-TestJob {
 param([string]$Id='job-1',[string]$Probe='probe-1',[string]$Computer='PC-A')
 $power=[pscustomobject]@{StopCount=0}
 $power | Add-Member -MemberType ScriptMethod -Name BeginStop -Value {param($callback,$state);$this.StopCount++;return [pscustomobject]@{IsCompleted=$false}}
 return [pscustomobject]@{Id=$Id;Name=('Dernier user '+$Computer);OperationId='ComputerLastUser';ReplaceKey=('lastuser:'+$Computer)
  SessionEpoch=[long]$script:SessionEpoch;CallbackState=[pscustomobject]@{Computer=$Computer;ProbeId=$Probe;Progress=(New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')}
  Started=(Get-Date).AddSeconds(-2);CancelRequested=$false;CancelRequestedAt=$null;Superseded=$false;NonCancellable=$false
  IsWrite=$false;TimeoutErrorDelivered=$false;StopHandle=$null;PowerShell=$power;CorrelationId=$Id;Handle=[pscustomobject]@{IsCompleted=$false}}
}
function Start-UiTask {
 param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$StatusText,$SuccessHandler,$ErrorHandler)
 $script:Starts++;$id='job-'+$script:Starts
 $job=New-TestJob -Id $id -Probe $CallbackState.ProbeId -Computer $CallbackState.Computer
 $job.CallbackState=$CallbackState;$script:AsyncJobs[$id]=$job;$script:RecordedPayload=$Payload
 return $id
}
Test-Case 'Double demande automatique : un seul worker' {
 Start-ComputerUserLinkProbe 'PC-A';$id=$script:ActiveLinkProbeId;Start-ComputerUserLinkProbe 'PC-A'
 Assert-Test ($script:Starts -eq 1 -and $script:ActiveLinkProbeId -eq $id)
}
Test-Case 'Rafraichir pendant la detection : pas de redemarrage meme avec Force' {
 Start-ComputerUserLinkProbe 'PC-A';$id=$script:ActiveLinkProbeId;Start-ComputerUserLinkProbe 'PC-A' -Force
 Assert-Test ($script:Starts -eq 1 -and $script:ActiveLinkProbeId -eq $id -and -not $script:AsyncJobs['job-1'].CancelRequested)
}
Test-Case 'Drapeau actif orphelin : relance automatique autorisee' {
 $script:ActiveLinkProbeId='orphelin';$script:ActiveLinkProbeComputer='PC-A'
 Start-ComputerUserLinkProbe 'PC-A'
 Assert-Test ($script:Starts -eq 1 -and $script:ActiveLinkProbeId -ne 'orphelin')
}
Test-Case 'Une tache annulee ne bloque pas une nouvelle detection' {
 $job=New-TestJob;$job.CancelRequested=$true;$script:AsyncJobs['old']=$job
 $script:ActiveLinkProbeId='probe-1';$script:ActiveLinkProbeComputer='PC-A'
 Start-ComputerUserLinkProbe 'PC-A'
 Assert-Test ($script:Starts -eq 1 -and $script:ActiveLinkProbeId -ne 'probe-1')
}
Test-Case 'Ancienne session de connexion exclue du registre actif' {
 $job=New-TestJob;$job.SessionEpoch=6;$script:AsyncJobs['old']=$job
 Assert-Test ($null -eq (Get-DomeniaRunningComputerUserProbe 'PC-A'))
}
Test-Case 'Resultat termine mais callback en attente : ne pas relancer' {
 $job=New-TestJob;$job.Handle.IsCompleted=$true;$script:AsyncJobs['old']=$job
 Assert-Test ($null -ne (Get-DomeniaRunningComputerUserProbe 'PC-A'))
 Start-ComputerUserLinkProbe 'PC-A' -Force
 Assert-Test ($script:Starts -eq 0 -and $script:ActiveLinkProbeId -eq 'probe-1')
}
Test-Case 'Annulation reelle : marqueur libere avant le retour BeginStop' {
 Start-ComputerUserLinkProbe 'PC-A';$job=$script:AsyncJobs['job-1']
 Request-UiTaskStop -Id 'job-1' -Reason 'Test annulation'
 Assert-Test ($job.CancelRequested -and $job.PowerShell.StopCount -eq 1 -and $script:ActiveLinkProbeId -eq '')
 Assert-Test (($script:Messages -join ' ') -match 'Test annulation')
}
Test-Case 'Annulation puis relance sur la meme machine' {
 Start-ComputerUserLinkProbe 'PC-A';Request-UiTaskStop 'job-1' -Reason 'Test'
 Start-ComputerUserLinkProbe 'PC-A'
 Assert-Test ($script:Starts -eq 2 -and -not $script:AsyncJobs['job-2'].CancelRequested)
}
Test-Case 'Nettoyage tardif ancien worker : nouveau marqueur conserve' {
 $script:ActiveLinkProbeId='nouveau';$script:ActiveLinkProbeComputer='PC-A'
 Clear-DomeniaComputerUserProbeState -ProbeId 'ancien' -Computer 'PC-A'
 Assert-Test ($script:ActiveLinkProbeId -eq 'nouveau')
}
# The purge of a selection is Enter-DomeniaSelectionContext (Selection.UI): it increments
# SelectedObjectGeneration and hides the previous object. A loaded fiche for the same DN must survive.
Test-Case 'Double clic meme DN : aucune purge de selection' {
 $script:SelectionLoad=[pscustomobject]@{Context=(Get-DomeniaSelectionContext);Token='t';Phase='Ready';Message='';VisibleType='Machine'}
 Assert-Test ($null -ne $script:SelectionLoad.Context) 'Contexte de selection de la fixture introuvable.'
 Queue-DomeniaSelectedObjectOpen -Immediate -Force
 Assert-Test ($script:SelectedObjectGeneration -eq 0 -and $null -ne $script:SelectedObject) ('Purge inattendue : generation '+$script:SelectedObjectGeneration)
 Assert-Test ($script:PendingInvokes -eq 1 -and $script:PendingObjectSelection.Force)
}
Test-Case 'Nouvelle machine : purge de selection toujours effectuee' {
 $script:SelectionLoad=[pscustomobject]@{Context=(Get-DomeniaSelectionContext);Token='t';Phase='Ready';Message='';VisibleType='Machine'}
 Select-FixtureRow ([pscustomobject]@{Type='Machine';DN='CN=PC-B,DC=example,DC=test';Name='PC-B'})
 Queue-DomeniaSelectedObjectOpen -Immediate -Force
 Assert-Test ($script:SelectedObjectGeneration -eq 1 -and $null -eq $script:SelectedObject) ('Purge absente : generation '+$script:SelectedObjectGeneration)
 Assert-Test ($script:PendingInvokes -eq 1 -and $script:PendingObjectSelection.Dn -eq 'CN=PC-B,DC=example,DC=test')
}
Test-Case 'Evenement de grille programme : aucune nouvelle lecture' {
 $script:SuppressGridSelectionEvents=$true
 Queue-DomeniaSelectedObjectOpen -Immediate -Force
 Assert-Test ($script:SelectedObjectGeneration -eq 0 -and $script:PendingInvokes -eq 0)
}
Test-Case 'Progression drainee une seule fois et trace persistante' {
 $job=New-TestJob;$script:ActiveLinkProbeId='probe-1';$script:ActiveLinkProbeComputer='PC-A'
 $job.CallbackState.Progress.Enqueue([pscustomobject]@{Method='CIM';Status='EN COURS';Detail='Test'})
 Receive-DomeniaComputerUserProbeProgress $job;Receive-DomeniaComputerUserProbeProgress $job
 Assert-Test ($script:Messages.Count -eq 1 -and $job.CallbackState.Progress.Count -eq 0 -and $script:UiTexts['LblLinkProbeStatus'] -match 'CIM')
}
Test-Case 'Progression ancienne machine : ne touche pas la fiche courante' {
 $job=New-TestJob -Computer 'PC-B';$script:ActiveLinkProbeId='nouveau';$script:ActiveLinkProbeComputer='PC-A'
 $job.CallbackState.Progress.Enqueue([pscustomobject]@{Method='CIM';Status='EN COURS';Detail='Test'})
 Receive-DomeniaComputerUserProbeProgress $job
 Assert-Test (-not $script:UiTexts.ContainsKey('LblLinkProbeStatus'))
}
Test-Case 'Erreur tardive apres annulation : pas de modification UI' {
 Fail-DomeniaComputerUserProbeUi -Message 'Ancienne erreur' -State ([pscustomobject]@{Computer='PC-A';ProbeId='ancien'})
 Assert-Test (-not $script:UiTexts.ContainsKey('LblLinkProbeStatus'))
}
Test-Case 'Erreur courante : marqueur libere et champ association rafraichi' {
 $script:ActiveLinkProbeId='probe-a';$script:ActiveLinkProbeComputer='PC-A'
 Fail-DomeniaComputerUserProbeUi -Message 'Erreur distante test' -State ([pscustomobject]@{Computer='PC-A';ProbeId='probe-a'})
 Assert-Test ($script:ActiveLinkProbeId -eq '' -and $script:AssociationRefreshes -eq 1 -and $script:UiTexts['LblLinkProbeStatus'] -match 'Erreur distante test')
}
Test-Case 'Succes tardif pour un autre poste : aucun lien ecrit' {
 $script:ActiveLinkProbeId='probe-b';$script:ActiveLinkProbeComputer='PC-B'
 Complete-DomeniaComputerUserProbeUi -Result ([pscustomobject]@{Success=$true}) -State ([pscustomobject]@{Computer='PC-B';ProbeId='probe-b'})
 Assert-Test ($script:AddedLinks -eq 0)
}
Test-Case 'Succes courant : lien enregistre et marqueur libere' {
 $script:ActiveLinkProbeId='probe-a';$script:ActiveLinkProbeComputer='PC-A'
 $result=[pscustomobject]@{Computer='PC-A';UserLogin='alice';Success=$true;VerifiedInAD=$true;Confidence=97;Source='CIM';Details='Test';Attempts=@();FallbackTasks=0;TaskBytes=0}
 Complete-DomeniaComputerUserProbeUi $result ([pscustomobject]@{Computer='PC-A';ProbeId='probe-a'})
 Assert-Test ($script:AddedLinks -eq 1 -and $script:ActiveLinkProbeId -eq '' -and ($script:Messages -join ' ') -match 'Utilisateur detecte')
}
Test-Case 'Cache recent : aucune sonde automatique supplementaire' {
 $script:CacheLink=[pscustomobject]@{UserLogin='alice';When=(Get-Date).ToString('o');Confidence=97;Source='CIM'}
 Start-ComputerUserLinkProbe 'PC-A'
 Assert-Test ($script:Starts -eq 0)
}
Test-Case 'Rafraichissement explicite : le cache ne bloque pas la sonde' {
 $script:CacheLink=[pscustomobject]@{UserLogin='alice';When=(Get-Date).ToString('o');Confidence=97;Source='CIM'}
 Start-ComputerUserLinkProbe 'PC-A' -Force
 Assert-Test ($script:Starts -eq 1)
}
Test-Case 'Progression : meme file partagee entre payload et callback' {
 Start-ComputerUserLinkProbe 'PC-A'
 Assert-Test ([object]::ReferenceEquals($script:RecordedPayload.Progress,$script:AsyncJobs['job-1'].CallbackState.Progress))
}
$failed=@($script:Results | Where-Object {$_.Status -ne 'PASS'}).Count
$report=[ordered]@{Build='2026.09.21-R1.3-LASTUSER';Mode='NativePowerShellWithMocks';PowerShell=$PSVersionTable.PSVersion.ToString();RunAt=(Get-Date).ToString('o');NoRemoteAccess=$true;Passed=($script:Results.Count-$failed);Failed=$failed;Tests=$script:Results.ToArray()}
if([string]::IsNullOrWhiteSpace($ReportPath)){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-lastuser-'+[guid]::NewGuid().ToString('N')+'.json')}
$ReportPath=[IO.Path]::GetFullPath($ReportPath)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ReportPath))
[IO.File]::WriteAllText($ReportPath,($report | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Host ('Tests detection : '+$report.Passed+' reussis, '+$failed+' echecs. Rapport : '+$ReportPath)
if($failed -gt 0){throw 'Tests de detection en echec. Aucune validation du parc reel revendiquee.'}
